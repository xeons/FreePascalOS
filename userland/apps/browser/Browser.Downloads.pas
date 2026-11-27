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
  does not render) and what the user saves (Save Page As, Save Link
  As, Save Image As) is fetched on a thread of its own over the
  browser's shared HTTP client (a local file is copied) into the
  downloads folder under the name the server or the URL gave (with
  " (2)" and so on when the name is taken), or to the path chosen.

  Each download tells the window how it goes with a posted message
  (Code; Parameter1 the item), at most four times a second, and when it
  ends. It can be paused (the part fetched is kept) and resumed (asking
  the server for the rest with a Range header; one that answers with the
  whole file starts again), cancelled, retried, removed from the list.
  The list is kept in downloads.txt in the profile (when the Privacy
  settings remember downloads): URL, path, state, bytes, total, time.
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
  TDownloadState = (DownloadRunning, DownloadDone, DownloadFailed, DownloadCancelled, DownloadPaused);

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
    PauseWanted: Boolean;
    { The window told of its end already. }
    EndReported: Boolean;
    { Unix time it started; for the speed: when and how much at the
      last measure, and the bytes a second then. }
    StartedAt: Int64;
    MeasuredAt: QWord;
    MeasuredBytes: Int64;
    BytesPerSecond: Int64;
    Worker: TThread;
    { Asks for the rest of a paused download. }
    Resuming: Boolean;
  end;

  TDownloadManager = class
  private
    FItems: TList;
    FNotify: TMessageReceiver;
    FCode: LongWord;
    FListPath: string;
    FFolder: string;
    function GetItem(Index: Integer): TDownloadItem;
    function GetCount: Integer;
    procedure StartWorker(Item: TDownloadItem);
  public
    constructor Create(Notify: TMessageReceiver; Code: LongWord);
    destructor Destroy; override;
    { Starts saving Url as FileName (made unique) in the downloads folder,
      or to TargetPath when one is given (replacing what is there). }
    function Start(const Url, FileName: string; const TargetPath: string = ''): TDownloadItem;
    procedure Cancel(Item: TDownloadItem);
    procedure Pause(Item: TDownloadItem);
    procedure Resume(Item: TDownloadItem);
    { A failed or cancelled download again, from the start. }
    procedure Retry(Item: TDownloadItem);
    { Takes an item that is not running off the list. }
    procedure Remove(Item: TDownloadItem);
    { Takes every finished, failed and cancelled item off the list. }
    procedure ClearFinished;
    { Frees the threads of downloads that ended; notes their speed. }
    procedure Reap;
    function IndexOf(Item: TDownloadItem): Integer;
    function RunningCount: Integer;
    { The list from and to ListPath ('' keeps nothing). }
    procedure LoadList;
    procedure SaveList;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TDownloadItem read GetItem;
    property ListPath: string read FListPath write FListPath;
    { Where downloads go ('' the user's Downloads folder). }
    property Folder: string read FFolder write FFolder;
  end;

{ ~/Downloads (made if missing; /tmp without a home). }
function DownloadsFolder: string;
{ A name of Folder not taken yet, from Name ("file (2).zip" ...). }
function UniqueFilePath(const Folder, Name: string): string;
{ A file name safe to use: no slashes or control characters. }
function SafeFileName(const Name: string): string;
{ The file name a URL suggests ("download" for none). }
function FileNameOfUrl(const Url: string): string;
{ "1.5 MB", "300 KB", "12 bytes". }
function SizeText(Bytes: Int64): string;

implementation

uses
  DateUtils,
  Url.Records,
  Url.Parser,
  Http.Messages,
  Http.Client,
  Http.BodySinks,
  Http.Results,
  Configuration.Locations,
  Web.Fetch.LocalFiles,
  WebView.Network,
  Browser.TextFiles;

const
  NotifyIntervalMilliseconds = 250;
  StateNames: array[TDownloadState] of string = ('running', 'done', 'failed', 'cancelled', 'paused');

type
  TDownloadThread = class(TThread)
  private
    FItem: TDownloadItem;
    FManager: TDownloadManager;
    FLastNotice: QWord;
    FAppend: Boolean;
    procedure Tell(Force: Boolean);
    procedure CopyLocalFile(constref Url: TUrlRecord);
    procedure FetchOverHttp(constref Url: TUrlRecord);
    function HeadArrived(Response: THttpResponse): Boolean;
    procedure Stopped;
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

function FileNameOfUrl(const Url: string): string;
var
  Path: string;
  Cut: Integer;
begin
  Path := Url;
  Cut := Pos('?', Path);
  if Cut > 0 then
    Path := Copy(Path, 1, Cut - 1);
  Cut := Pos('#', Path);
  if Cut > 0 then
    Path := Copy(Path, 1, Cut - 1);
  if (Pos('://', Path) > 0) and (Pos('/', Copy(Path, Pos('://', Path) + 3, MaxInt)) = 0) then
    Exit('index.html');
  Result := Copy(Path, LastDelimiter('/', Path) + 1, MaxInt);
  if Result = '' then
    Result := 'index.html';
  Result := SafeFileName(Result);
end;

function SizeText(Bytes: Int64): string;
begin
  if Bytes < 1024 then
    Result := IntToStr(Bytes) + ' bytes'
  else if Bytes < 1024 * 1024 then
    Result := IntToStr(Bytes div 1024) + ' KB'
  else
    Result := FormatFloat('0.0', Bytes / (1024 * 1024)) + ' MB';
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
  if FThread.FItem.CancelWanted or FThread.FItem.PauseWanted then
    Exit(False);
  FStream.WriteBuffer(Data^, Count);
  Inc(FWritten, Count);
  Inc(FThread.FItem.Received, Count);
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
  if FItem.MeasuredAt = 0 then
  begin
    FItem.MeasuredAt := Now;
    FItem.MeasuredBytes := FItem.Received;
  end
  else if Now - FItem.MeasuredAt >= 1000 then
  begin
    FItem.BytesPerSecond := (FItem.Received - FItem.MeasuredBytes) * 1000 div Int64(Now - FItem.MeasuredAt);
    FItem.MeasuredAt := Now;
    FItem.MeasuredBytes := FItem.Received;
  end;
  PostMessage(FManager.FNotify, FManager.FCode, PtrInt(FItem));
end;

procedure TDownloadThread.Stopped;
begin
  if FItem.PauseWanted then
    FItem.State := DownloadPaused
  else
    FItem.State := DownloadCancelled;
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
  FItem.Received := 0;
  Source := TFileStream.Create(SourcePath, fmOpenRead or fmShareDenyNone);
  try
    FItem.Total := Source.Size;
    Target := TFileStream.Create(FItem.Path, fmCreate);
    try
      repeat
        if FItem.CancelWanted or FItem.PauseWanted then
        begin
          Stopped;
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

{ The whole file came instead of the rest: start again from nothing. }
function TDownloadThread.HeadArrived(Response: THttpResponse): Boolean;
var
  Length: Int64;
begin
  Result := True;
  if FAppend and (Response.Status <> 206) then
  begin
    FAppend := False;
    FItem.Received := 0;
  end;
  Length := StrToInt64Def(Response.Headers.Value('content-length'), -1);
  if Length >= 0 then
    FItem.Total := FItem.Received + Length;
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
  FAppend := FItem.Resuming and (FItem.Received > 0) and FileExists(FItem.Path);
  if not FAppend then
    FItem.Received := 0;
  Request := THttpRequest.Create('GET', Url);
  if FAppend then
    Request.Headers.SetValue('Range', 'bytes=' + IntToStr(FItem.Received) + '-');
  { Written to memory first would cost too much: the file is opened at
    once and set back if the server sends everything. }
  if FAppend then
  begin
    Target := TFileStream.Create(FItem.Path, fmOpenReadWrite);
    Target.Seek(0, soEnd);
  end
  else
    Target := TFileStream.Create(FItem.Path, fmCreate);
  Sink := TDownloadSink.Create(Target, Self);
  try
    Outcome := SharedNetworkContext.Client.Fetch(Request, Sink, Response, @HeadArrived);
    if FItem.CancelWanted or FItem.PauseWanted then
      Stopped
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
    begin
      FItem.State := DownloadDone;
      if FItem.Total < FItem.Received then
        FItem.Total := FItem.Received;
    end;
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
  FItem.BytesPerSecond := 0;
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
  { What is still running is paused, so it can go on next time. }
  for Index := 0 to FItems.Count - 1 do
    TDownloadItem(FItems[Index]).PauseWanted := True;
  for Index := 0 to FItems.Count - 1 do
  begin
    Item := TDownloadItem(FItems[Index]);
    if Item.Worker <> nil then
    begin
      Item.Worker.WaitFor;
      FreeAndNil(Item.Worker);
    end;
  end;
  SaveList;
  for Index := 0 to FItems.Count - 1 do
    TDownloadItem(FItems[Index]).Free;
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

function TDownloadManager.IndexOf(Item: TDownloadItem): Integer;
begin
  Result := FItems.IndexOf(Item);
end;

function TDownloadManager.RunningCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FItems.Count - 1 do
    if Items[Index].State = DownloadRunning then
      Inc(Result);
end;

procedure TDownloadManager.StartWorker(Item: TDownloadItem);
begin
  Item.CancelWanted := False;
  Item.PauseWanted := False;
  Item.EndReported := False;
  Item.ErrorText := '';
  Item.State := DownloadRunning;
  Item.MeasuredAt := 0;
  Item.BytesPerSecond := 0;
  if Item.Worker <> nil then
  begin
    Item.Worker.WaitFor;
    FreeAndNil(Item.Worker);
  end;
  Item.Worker := TDownloadThread.Create(Self, Item);
end;

function TDownloadManager.Start(const Url, FileName: string; const TargetPath: string): TDownloadItem;
var
  Target: string;
begin
  Result := TDownloadItem.Create;
  Result.Url := Url;
  if TargetPath <> '' then
    Result.Path := TargetPath
  else
  begin
    Target := FFolder;
    if Target = '' then
      Target := DownloadsFolder;
    ForceDirectories(Target);
    Result.Path := UniqueFilePath(ExcludeTrailingPathDelimiter(Target), SafeFileName(FileName));
  end;
  Result.FileName := ExtractFileName(Result.Path);
  Result.Total := -1;
  Result.StartedAt := DateTimeToUnix(LocalTimeToUniversal(Now));
  FItems.Insert(0, Result);
  StartWorker(Result);
  SaveList;
end;

procedure TDownloadManager.Cancel(Item: TDownloadItem);
begin
  if Item.State = DownloadRunning then
    Item.CancelWanted := True
  else if Item.State = DownloadPaused then
  begin
    DeleteFile(Item.Path);
    Item.State := DownloadCancelled;
    PostMessage(FNotify, FCode, PtrInt(Item));
  end;
end;

procedure TDownloadManager.Pause(Item: TDownloadItem);
begin
  if Item.State = DownloadRunning then
    Item.PauseWanted := True;
end;

procedure TDownloadManager.Resume(Item: TDownloadItem);
begin
  if Item.State <> DownloadPaused then
    Exit;
  Item.Resuming := True;
  StartWorker(Item);
end;

procedure TDownloadManager.Retry(Item: TDownloadItem);
begin
  if not (Item.State in [DownloadFailed, DownloadCancelled]) then
    Exit;
  Item.Resuming := False;
  Item.Received := 0;
  Item.Total := -1;
  StartWorker(Item);
end;

procedure TDownloadManager.Remove(Item: TDownloadItem);
begin
  if Item.State = DownloadRunning then
    Exit;
  if Item.Worker <> nil then
  begin
    Item.Worker.WaitFor;
    FreeAndNil(Item.Worker);
  end;
  FItems.Remove(Item);
  Item.Free;
  SaveList;
end;

procedure TDownloadManager.ClearFinished;
var
  Index: Integer;
begin
  for Index := FItems.Count - 1 downto 0 do
    if Items[Index].State in [DownloadDone, DownloadFailed, DownloadCancelled] then
      Remove(Items[Index]);
  SaveList;
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
  SaveList;
end;

procedure TDownloadManager.LoadList;
var
  Lines: TStringList;
  Index: Integer;
  Fields: TStringArray;
  Item: TDownloadItem;
  State: TDownloadState;
begin
  if FListPath = '' then
    Exit;
  Lines := ReadLines(FListPath);
  try
    for Index := 0 to Lines.Count - 1 do
    begin
      Fields := Lines[Index].Split([#9]);
      if Length(Fields) < 6 then
        Continue;
      Item := TDownloadItem.Create;
      Item.Url := Fields[0];
      Item.Path := Fields[1];
      Item.FileName := ExtractFileName(Item.Path);
      Item.State := DownloadFailed;
      for State := Low(TDownloadState) to High(TDownloadState) do
        if StateNames[State] = Fields[2] then
          Item.State := State;
      { One running when the browser ended is paused now. }
      if Item.State = DownloadRunning then
        Item.State := DownloadPaused;
      Item.Received := StrToInt64Def(Fields[3], 0);
      Item.Total := StrToInt64Def(Fields[4], -1);
      Item.StartedAt := StrToInt64Def(Fields[5], 0);
      Item.EndReported := True;
      FItems.Add(Item);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TDownloadManager.SaveList;
var
  Lines: TStringList;
  Index: Integer;
  Item: TDownloadItem;
begin
  if FListPath = '' then
    Exit;
  Lines := TStringList.Create;
  try
    for Index := 0 to FItems.Count - 1 do
    begin
      Item := Items[Index];
      Lines.Add(JoinFields([Item.Url, Item.Path, StateNames[Item.State], IntToStr(Item.Received),
        IntToStr(Item.Total), IntToStr(Item.StartedAt)]));
    end;
    WriteLines(Lines, FListPath);
  finally
    Lines.Free;
  end;
end;

end.
