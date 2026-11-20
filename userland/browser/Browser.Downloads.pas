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
  Downloads: what a page cannot show (an attachment, a type the engine
  does not render) is saved to ~/Downloads under the name the server
  or the URL gave (with " (2)" and so on when the name is taken). Each
  download runs on a thread of its own over the browser's shared HTTP
  client (a local file is copied); it tells the window how it goes with
  a posted message (Notify, Code; Parameter1 the item), at most four
  times a second, and when it ends. Cancel stops one.
}
unit Browser.Downloads;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Windowing.Messages;

type
  TDownloadState = (DownloadRunning, DownloadDone, DownloadFailed, DownloadCancelled);

  TDownloadManager = class;

  TDownloadItem = class
  public
    Url: string;
    FileName: string;
    Path: string;
    State: TDownloadState;
    Received: Int64;
    { -1 when the server did not say. }
    Total: Int64;
    ErrorText: string;
    CancelWanted: Boolean;
    { The window told of its end already. }
    EndReported: Boolean;
    Worker: TThread;
  end;

  TDownloadManager = class
  private
    FItems: TList;
    FNotify: TMessageReceiver;
    FCode: LongWord;
    function GetItem(Index: Integer): TDownloadItem;
    function GetCount: Integer;
  public
    constructor Create(Notify: TMessageReceiver; Code: LongWord);
    destructor Destroy; override;
    { Starts saving Url as FileName (made unique) in the downloads folder. }
    function Start(const Url, FileName: string): TDownloadItem;
    procedure Cancel(Item: TDownloadItem);
    { Frees the threads of downloads that ended. }
    procedure Reap;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TDownloadItem read GetItem;
  end;

{ ~/Downloads (made if missing; /tmp without a home). }
function DownloadsFolder: string;
{ A name of Folder not taken yet, from Name ("file (2).zip" ...). }
function UniqueFilePath(const Folder, Name: string): string;
{ A file name safe to use: no slashes or control characters. }
function SafeFileName(const Name: string): string;

implementation

uses
  Url.Records,
  Url.Parser,
  Http.Messages,
  Http.Client,
  Http.BodySinks,
  Http.Results,
  Configuration.Locations,
  Web.Fetch.LocalFiles,
  WebView.Network;

const
  NotifyIntervalMilliseconds = 250;

type
  TDownloadThread = class(TThread)
  private
    FItem: TDownloadItem;
    FManager: TDownloadManager;
    FLastNotice: QWord;
    procedure Tell(Force: Boolean);
    procedure CopyLocalFile(constref Url: TUrlRecord);
    procedure FetchOverHttp(constref Url: TUrlRecord);
  protected
    procedure Execute; override;
  public
    constructor Create(Manager: TDownloadManager; Item: TDownloadItem);
  end;

  TDownloadSink = class(THttpBodySink)
  private
    FStream: TStream;
    FThread: TDownloadThread;
  public
    constructor Create(Stream: TStream; Thread: TDownloadThread);
    function Write(Data: Pointer; Count: PtrUInt): Boolean; override;
  end;

function DownloadsFolder: string;
var
  Home: string;
begin
  Home := CurrentHome;
  if Home = '' then
    Result := '/tmp'
  else
    Result := ExcludeTrailingPathDelimiter(Home) + '/Downloads';
  ForceDirectories(Result);
end;

function SafeFileName(const Name: string): string;
var
  Index: Integer;
begin
  Result := Trim(Name);
  for Index := 1 to Length(Result) do
    if (Result[Index] in ['/', '\']) or (Ord(Result[Index]) < 32) then
      Result[Index] := '_';
  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := 'download';
end;

function UniqueFilePath(const Folder, Name: string): string;
var
  Stem, Extension: string;
  Number: Integer;
begin
  Result := Folder + '/' + Name;
  if not FileExists(Result) then
    Exit;
  Extension := ExtractFileExt(Name);
  Stem := Copy(Name, 1, Length(Name) - Length(Extension));
  Number := 2;
  repeat
    Result := Folder + '/' + Stem + ' (' + IntToStr(Number) + ')' + Extension;
    Inc(Number);
  until not FileExists(Result);
end;

{ ---- the sink and the thread ---- }

constructor TDownloadSink.Create(Stream: TStream; Thread: TDownloadThread);
begin
  inherited Create;
  FStream := Stream;
  FThread := Thread;
end;

function TDownloadSink.Write(Data: Pointer; Count: PtrUInt): Boolean;
begin
  if FThread.FItem.CancelWanted then
    Exit(False);
  FStream.WriteBuffer(Data^, Count);
  Inc(FWritten, Count);
  FThread.FItem.Received := FWritten;
  FThread.Tell(False);
  Result := True;
end;

constructor TDownloadThread.Create(Manager: TDownloadManager; Item: TDownloadItem);
begin
  FManager := Manager;
  FItem := Item;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDownloadThread.Tell(Force: Boolean);
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if not Force and (Now - FLastNotice < NotifyIntervalMilliseconds) then
    Exit;
  FLastNotice := Now;
  PostMessage(FManager.FNotify, FManager.FCode, PtrInt(FItem));
end;

procedure TDownloadThread.CopyLocalFile(constref Url: TUrlRecord);
var
  SourcePath: string;
  Source, Target: TFileStream;
  Buffer: array[0..65535] of Byte;
  Count: LongInt;
begin
  if not LocalPathOfUrl(Url, SourcePath) then
  begin
    FItem.ErrorText := 'not a local file';
    FItem.State := DownloadFailed;
    Exit;
  end;
  Source := TFileStream.Create(SourcePath, fmOpenRead or fmShareDenyNone);
  try
    FItem.Total := Source.Size;
    Target := TFileStream.Create(FItem.Path, fmCreate);
    try
      repeat
        if FItem.CancelWanted then
        begin
          FItem.State := DownloadCancelled;
          Exit;
        end;
        Count := Source.Read(Buffer[0], SizeOf(Buffer));
        if Count > 0 then
        begin
          Target.WriteBuffer(Buffer[0], Count);
          Inc(FItem.Received, Count);
          Tell(False);
        end;
      until Count <= 0;
    finally
      Target.Free;
    end;
  finally
    Source.Free;
  end;
  FItem.State := DownloadDone;
end;

procedure TDownloadThread.FetchOverHttp(constref Url: TUrlRecord);
var
  Request: THttpRequest;
  Response: THttpResponse;
  Target: TFileStream;
  Sink: TDownloadSink;
  Outcome: THttpResult;
begin
  Response := nil;
  Target := TFileStream.Create(FItem.Path, fmCreate);
  Sink := TDownloadSink.Create(Target, Self);
  Request := THttpRequest.Create('GET', Url);
  try
    Outcome := SharedNetworkContext.Client.Fetch(Request, Sink, Response);
    if FItem.CancelWanted then
      FItem.State := DownloadCancelled
    else if not HttpSucceeded(Outcome) then
    begin
      FItem.ErrorText := Outcome.Text;
      FItem.State := DownloadFailed;
    end
    else if (Response <> nil) and ((Response.Status < 200) or (Response.Status > 299)) then
    begin
      FItem.ErrorText := 'the server answered ' + IntToStr(Response.Status);
      FItem.State := DownloadFailed;
    end
    else
      FItem.State := DownloadDone;
  finally
    Response.Free;
    Request.Free;
    Sink.Free;
    Target.Free;
  end;
end;

procedure TDownloadThread.Execute;
var
  Url: TUrlRecord;
begin
  try
    if not ParseUrl(FItem.Url, Url) then
    begin
      FItem.ErrorText := 'not a URL';
      FItem.State := DownloadFailed;
    end
    else if Url.Scheme = 'file' then
      CopyLocalFile(Url)
    else if (Url.Scheme = 'http') or (Url.Scheme = 'https') then
      FetchOverHttp(Url)
    else
    begin
      FItem.ErrorText := 'cannot download ' + Url.Scheme + ': URLs';
      FItem.State := DownloadFailed;
    end;
  except
    on Error: Exception do
    begin
      FItem.ErrorText := Error.Message;
      FItem.State := DownloadFailed;
    end;
  end;
  if FItem.State in [DownloadFailed, DownloadCancelled] then
    DeleteFile(FItem.Path);
  Tell(True);
end;

{ ---- the manager ---- }

constructor TDownloadManager.Create(Notify: TMessageReceiver; Code: LongWord);
begin
  inherited Create;
  FItems := TList.Create;
  FNotify := Notify;
  FCode := Code;
end;

destructor TDownloadManager.Destroy;
var
  Index: Integer;
  Item: TDownloadItem;
begin
  for Index := 0 to FItems.Count - 1 do
    TDownloadItem(FItems[Index]).CancelWanted := True;
  for Index := 0 to FItems.Count - 1 do
  begin
    Item := TDownloadItem(FItems[Index]);
    if Item.Worker <> nil then
    begin
      Item.Worker.WaitFor;
      Item.Worker.Free;
    end;
    Item.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;

function TDownloadManager.GetItem(Index: Integer): TDownloadItem;
begin
  Result := TDownloadItem(FItems[Index]);
end;

function TDownloadManager.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TDownloadManager.Start(const Url, FileName: string): TDownloadItem;
begin
  Result := TDownloadItem.Create;
  Result.Url := Url;
  Result.FileName := SafeFileName(FileName);
  Result.Path := UniqueFilePath(DownloadsFolder, Result.FileName);
  Result.FileName := ExtractFileName(Result.Path);
  Result.Total := -1;
  Result.State := DownloadRunning;
  FItems.Add(Result);
  Result.Worker := TDownloadThread.Create(Self, Result);
end;

procedure TDownloadManager.Cancel(Item: TDownloadItem);
begin
  Item.CancelWanted := True;
end;

procedure TDownloadManager.Reap;
var
  Index: Integer;
  Item: TDownloadItem;
begin
  for Index := 0 to FItems.Count - 1 do
  begin
    Item := TDownloadItem(FItems[Index]);
    if (Item.Worker <> nil) and Item.Worker.Finished then
    begin
      Item.Worker.WaitFor;
      FreeAndNil(Item.Worker);
    end;
  end;
end;

end.
