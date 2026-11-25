{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Thumbnails: small pictures of image files, made on a thread of their
  own so a folder of photos shows at once and fills in as they come.

  Request(Path, ModificationTime, Size) queues a file (the newest
  requests first: what was just scrolled to); the thread looks in the
  disk cache (Controls.ThumbnailCache: a PNG per file, at most
  ThumbnailSize pixels across, named after the path, the time and the
  size, so a changed file gets a new one), else reads the picture with
  libimage (any format it reads; an SVG drawn at the thumbnail's size)
  and writes the cache. The window's thread is told with a message and
  hears of each one (OnThumbnail) with the picture and the original's
  size in pixels (0 x 0 when it could not be read).

  The pictures stay the loader's until Clear (a new folder) or the end:
  an item view's items may point at them meanwhile.
}
unit Controls.ThumbnailLoader;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Drawing.Surfaces,
  Windowing.Messages;

const
  ThumbnailSize = 256;
  MessageThumbnailReady = MessageUser + 41;

type
  TThumbnailEvent = procedure(Sender: TObject; const Path: string; const Picture: TSurface;
    OriginalWidth, OriginalHeight: LongInt) of object;

  TThumbnailJob = class
  public
    Path: string;
    ModificationTime: Int64;
    Size: QWord;
    Picture: TSurface;
    OriginalWidth: LongInt;
    OriginalHeight: LongInt;
  end;

  TThumbnailLoader = class(TMessageReceiver)
  private
    FLock: TRTLCriticalSection;
    FWake: Int64;
    FThread: Int64;
    FQueue: TList;
    FDone: TList;
    FKept: TList;
    FStopping: Boolean;
    FGeneration: LongWord;
    FMessagePosted: Boolean;
    FOnThumbnail: TThumbnailEvent;
    procedure StartThread;
    procedure DeliverDone;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    procedure Request(const Path: string; ModificationTime: Int64; Size: QWord);
    { Forgets what is queued and frees every picture made. }
    procedure Clear;
    { (The thread.) Runs the queue until stopped. }
    procedure Work;
    property OnThumbnail: TThumbnailEvent read FOnThumbnail write FOnThumbnail;
  end;

{ Reads the picture at Path and makes its thumbnail (no cache); False if
  it cannot be read. }
function MakeThumbnail(const Path: string; MaximumSize: LongInt; out Picture: TSurface;
  out OriginalWidth, OriginalHeight: LongInt): Boolean;

implementation

uses
  Sys.Objects,
  Sys.Threads,
  Image.Model,
  Image.Files,
  Image.Scaling,
  Image.Scalable,
  Image.Surfaces,
  Controls.ThumbnailCache;

const
  WaitForever = -1;

function RunLoader(Argument: Pointer): LongInt;
begin
  TThumbnailLoader(Argument).Work;
  Result := 0;
end;

function MakeThumbnail(const Path: string; MaximumSize: LongInt; out Picture: TSurface;
  out OriginalWidth, OriginalHeight: LongInt): Boolean;
var
  Loaded: TImage;
  Small: TImage;
  Width: LongInt;
  Height: LongInt;
begin
  Picture := Default(TSurface);
  OriginalWidth := 0;
  OriginalHeight := 0;
  Result := False;
  Loaded := nil;
  Small := nil;
  try
    try
      Loaded := LoadImage(Path, [ImageLoadApplyOrientation]);
      OriginalWidth := Loaded.Width;
      OriginalHeight := Loaded.Height;
      FitSize(Loaded.Width, Loaded.Height, MaximumSize, MaximumSize, Width, Height);
      if Width < 1 then
        Width := 1;
      if Height < 1 then
        Height := 1;
      if Loaded is TScalableImage then
        Small := TScalableImage(Loaded).Render(Width, Height)
      else if (Loaded.Width <= MaximumSize) and (Loaded.Height <= MaximumSize) then
      begin
        Small := Loaded;
        Loaded := nil;
      end
      else
        Small := ThumbnailImage(Loaded, MaximumSize, MaximumSize);
      Picture := SurfaceTakingImage(Small);
      Small := nil;
      Result := True;
    except
      on Exception do
        Result := False;
    end;
  finally
    Small.Free;
    Loaded.Free;
  end;
end;

constructor TThumbnailLoader.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FQueue := TList.Create;
  FDone := TList.Create;
  FKept := TList.Create;
  FWake := CreateEvent(False, False);
  FThread := -1;
end;

destructor TThumbnailLoader.Destroy;
var
  ExitCode: LongInt;
  Index: LongInt;
begin
  EnterCriticalSection(FLock);
  FStopping := True;
  LeaveCriticalSection(FLock);
  if FThread >= 0 then
  begin
    SetEvent(FWake);
    WaitForThread(FThread, WaitForever, ExitCode);
    CloseThreadHandle(FThread);
  end;
  Clear;
  for Index := 0 to FDone.Count - 1 do
    TThumbnailJob(FDone[Index]).Free;
  FQueue.Free;
  FDone.Free;
  FKept.Free;
  if FWake >= 0 then
    CloseHandle(FWake);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TThumbnailLoader.StartThread;
begin
  if (FThread >= 0) or (FWake < 0) then
    Exit;
  FThread := CreateThread(@RunLoader, Self);
end;

procedure TThumbnailLoader.Request(const Path: string; ModificationTime: Int64; Size: QWord);
var
  Job: TThumbnailJob;
begin
  Job := TThumbnailJob.Create;
  Job.Path := Path;
  UniqueString(Job.Path);
  Job.ModificationTime := ModificationTime;
  Job.Size := Size;
  EnterCriticalSection(FLock);
  { Newest first: what was asked for last is what is in view. }
  FQueue.Insert(0, Job);
  LeaveCriticalSection(FLock);
  StartThread;
  if FThread < 0 then
  begin
    { No thread: made here and now. }
    Work;
    Exit;
  end;
  SetEvent(FWake);
end;

procedure TThumbnailLoader.Clear;
var
  Index: LongInt;
  Job: TThumbnailJob;
begin
  EnterCriticalSection(FLock);
  for Index := 0 to FQueue.Count - 1 do
    TThumbnailJob(FQueue[Index]).Free;
  FQueue.Clear;
  for Index := 0 to FDone.Count - 1 do
  begin
    Job := TThumbnailJob(FDone[Index]);
    FreeSurface(Job.Picture);
    Job.Free;
  end;
  FDone.Clear;
  Inc(FGeneration);
  LeaveCriticalSection(FLock);
  for Index := 0 to FKept.Count - 1 do
  begin
    Job := TThumbnailJob(FKept[Index]);
    FreeSurface(Job.Picture);
    Job.Free;
  end;
  FKept.Clear;
end;

procedure TThumbnailLoader.Work;
var
  Job: TThumbnailJob;
  Generation: LongWord;
  CacheFile: string;
begin
  while True do
  begin
    EnterCriticalSection(FLock);
    if FStopping then
    begin
      LeaveCriticalSection(FLock);
      Exit;
    end;
    Job := nil;
    if FQueue.Count > 0 then
    begin
      Job := TThumbnailJob(FQueue[0]);
      FQueue.Delete(0);
    end;
    Generation := FGeneration;
    LeaveCriticalSection(FLock);
    if Job = nil then
    begin
      if FThread < 0 then
        Exit;
      WaitForHandle(FWake, WaitForever);
      Continue;
    end;
    CacheFile := ThumbnailCacheFile(Job.Path, Job.ModificationTime, Job.Size);
    if not ReadCachedThumbnail(CacheFile, Job.Picture, Job.OriginalWidth, Job.OriginalHeight) then
      if MakeThumbnail(Job.Path, ThumbnailSize, Job.Picture, Job.OriginalWidth, Job.OriginalHeight) then
        WriteCachedThumbnail(CacheFile, Job.Picture, Job.OriginalWidth, Job.OriginalHeight);
    EnterCriticalSection(FLock);
    if Generation <> FGeneration then
    begin
      { Cleared meanwhile: nobody wants it. }
      FreeSurface(Job.Picture);
      Job.Free;
      LeaveCriticalSection(FLock);
      Continue;
    end;
    FDone.Add(Job);
    if not FMessagePosted then
      FMessagePosted := PostMessage(Self, MessageThumbnailReady);
    LeaveCriticalSection(FLock);
    if FThread < 0 then
      DeliverDone;
  end;
end;

procedure TThumbnailLoader.DeliverDone;
var
  Ready: TList;
  Index: LongInt;
  Job: TThumbnailJob;
begin
  Ready := TList.Create;
  try
    EnterCriticalSection(FLock);
    Ready.Assign(FDone);
    FDone.Clear;
    FMessagePosted := False;
    LeaveCriticalSection(FLock);
    for Index := 0 to Ready.Count - 1 do
    begin
      Job := TThumbnailJob(Ready[Index]);
      FKept.Add(Job);
      if Assigned(FOnThumbnail) then
        FOnThumbnail(Self, Job.Path, Job.Picture, Job.OriginalWidth, Job.OriginalHeight);
    end;
  finally
    Ready.Free;
  end;
end;

procedure TThumbnailLoader.ReceiveMessage(var Message: TPostedMessage);
begin
  if Message.Code = MessageThumbnailReady then
  begin
    DeliverDone;
    Exit;
  end;
  inherited ReceiveMessage(Message);
end;

end.
