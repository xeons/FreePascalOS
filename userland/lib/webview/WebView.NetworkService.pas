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
  The browser's network service: what its content processes ask of the
  network, local files, cookies and storage, answered with the
  program's one network context (WebView.Network: the HTTP client and
  its connections, the cookie jar, the HTTP cache, HSTS) and its local
  storage, and its storage service (IndexedDB, the Cache API,
  navigator.storage: WebView.Network's SharedIndexedDb, a client per
  script context of the process). It runs on the browser's IPC thread (WebView.ContentIo) and
  on a thread per HTTP exchange, never on the GUI thread, so a busy
  window does not hold pages' loads up.

  A renderer is not trusted with what it says of itself. The service
  knows the site each process is locked to (WebView.Sites) and
  refuses: document.cookie, local storage and IndexedDB of any other
  site; local
  files to a process that is not the local files' one; anything but
  http and https exchanges. Whether a request is same-site for its
  cookies it decides itself from the process's site. HSTS is applied
  here (an http:// request to a known host gets a 307 to https://, as
  an internal redirect the renderer's fetcher follows) and learned from
  every response. CORS, mixed content and the rest stay the renderer's
  decisions about what its own page may see.
}
unit WebView.NetworkService;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebIpc.Messages,
  WebView.ContentProcess;

type
  { One content process's exchanges and requests. }
  TContentNetwork = class
  private
    FProcess: TContentProcess;
    FLock: TRTLCriticalSection;
    FHops: TList;
    FWaiting: TList;
    FDatabaseClients: TList;
    procedure StartHop(Message: TIpcMessage);
    procedure LaunchWaiting;
    procedure CancelHop(Message: TIpcMessage);
    procedure ReadLocalFile(Message: TIpcMessage);
    procedure GetCookie(Message: TIpcMessage);
    procedure SetCookie(Message: TIpcMessage);
    procedure LoadStorage(Message: TIpcMessage);
    procedure ChangeStorage(Message: TIpcMessage);
    procedure LoadOriginData(Message: TIpcMessage);
    procedure SaveOriginData(Message: TIpcMessage);
    procedure ExecuteIndexedDb(Message: TIpcMessage);
    procedure CloseIndexedDbClient(Message: TIpcMessage);
    procedure Reply(Message: TIpcMessage; const Payload: TBytes);
    function UrlOfOwnSite(const Url: string): Boolean;
  public
    constructor Create(Process: TContentProcess);
    { Cancels every exchange and waits for their threads. }
    destructor Destroy; override;
    { Handles Message if it is one of the network's (and frees it then):
      True, else False (the caller keeps it). }
    function Handle(Message: TIpcMessage): Boolean;
    { Frees the exchanges that ended (on the IPC thread). }
    procedure Reap;
  end;

{ Writes changed local storage and IndexedDB to their files (the
  browser's IPC thread calls it now and then). }
procedure SaveServiceStorage;

implementation

uses
  Url.Records,
  Url.Parser,
  Http.Client,
  Http.Messages,
  Http.Results,
  Http.HeaderFields,
  Http.Priorities,
  Http.RequestBodies,
  Http.FetchTasks,
  Http.PublicSuffixes,
  Web.Fetch.LocalFiles,
  Web.Fetch.HttpHops,
  Web.Fetch.NetworkContexts,
  Web.Storage,
  Web.Storage.OriginData,
  Web.IndexedDb.Wire,
  Web.IndexedDb.Service,
  WebIpc.ViewMessages,
  WebIpc.NetworkMessages,
  WebView.Sites,
  WebView.Network;

const
  { Exchanges of one process running at once; the rest wait. }
  RunningHopLimit = 16;
  { The most of a body one message carries. }
  DataPieceBytes = 60 * 1024;
  LocalFileLimit = 256 * 1024 * 1024;

type
  { A script context of a content process, as the storage service sees
    it; its notices go to the process. }
  TRemoteDatabaseClient = class(TIndexedDbClient)
  public
    Process: TContentProcess;
    ClientId: LongWord;
    Service: TIndexedDbService;
    procedure Notice(const Payload: TBytes); override;
  end;

  THopEntry = class
  public
    WireId: QWord;
    Task: THttpFetchTask;
    Request: THttpRequest;
    Finished: Boolean;
    Network: TContentNetwork;
    procedure TaskHead(Task_: THttpFetchTask; Response: THttpResponse);
    procedure TaskData(Task_: THttpFetchTask; Data: Pointer; Count: PtrUInt);
    procedure TaskDone(Task_: THttpFetchTask; constref Outcome: THttpResult);
  end;

procedure TRemoteDatabaseClient.Notice(const Payload: TBytes);
begin
  Process.Send(IpcIndexedDbNotice, 0, 0, EncodeIndexedDbNotice(ClientId, Payload));
end;

procedure SendOutcome(Process: TContentProcess; WireId: QWord; Code: THttpResultCode; const Text: string);
var
  Outcome: TIpcHopOutcome;
begin
  Outcome := Default(TIpcHopOutcome);
  Outcome.HopId := WireId;
  Outcome.Code := Ord(Code);
  Outcome.Text := Text;
  Process.Send(IpcHopDone, 0, 0, EncodeHopOutcome(Outcome));
end;

{ ---- THopEntry: on the exchange's thread ---- }

procedure THopEntry.TaskHead(Task_: THttpFetchTask; Response: THttpResponse);
var
  Head: TIpcHopHead;
  Fields: THttpHeaderFieldArray;
  Index: Integer;
begin
  SharedNetworkContext.Hsts.ProcessResponseField(Response.Url, Response.Headers.Value('strict-transport-security'));
  Head := Default(TIpcHopHead);
  Head.HopId := WireId;
  Head.Status := Response.Status;
  Head.Reason := Response.Reason;
  Fields := Response.Headers.FieldArray;
  SetLength(Head.Fields, Length(Fields));
  for Index := 0 to High(Fields) do
  begin
    Head.Fields[Index].Name := Fields[Index].Name;
    Head.Fields[Index].Value := Fields[Index].Value;
  end;
  Head.Url := SerializeUrl(Response.Url);
  Head.FromCache := Response.FromCache;
  Head.Protocol := ProtocolName(Response.Protocol);
  Network.FProcess.Send(IpcHopHead, 0, 0, EncodeHopHead(Head));
end;

procedure THopEntry.TaskData(Task_: THttpFetchTask; Data: Pointer; Count: PtrUInt);
var
  Piece: PtrUInt;
begin
  while Count > 0 do
  begin
    Piece := Count;
    if Piece > DataPieceBytes then
      Piece := DataPieceBytes;
    Network.FProcess.Send(IpcHopData, 0, 0, EncodeHopData(WireId, Data, Piece));
    Inc(PByte(Data), Piece);
    Dec(Count, Piece);
  end;
end;

procedure THopEntry.TaskDone(Task_: THttpFetchTask; constref Outcome: THttpResult);
var
  Done: TIpcHopOutcome;
begin
  Done := Default(TIpcHopOutcome);
  Done.HopId := WireId;
  Done.Code := Ord(Outcome.Code);
  Done.Text := Outcome.Text;
  Done.ErrorCode := Outcome.ErrorCode;
  Done.Retryable := Outcome.Retryable;
  Network.FProcess.Send(IpcHopDone, 0, 0, EncodeHopOutcome(Done));
  Finished := True;
end;

{ ---- TContentNetwork ---- }

constructor TContentNetwork.Create(Process: TContentProcess);
begin
  inherited Create;
  FProcess := Process;
  InitCriticalSection(FLock);
  FHops := TList.Create;
  FWaiting := TList.Create;
  FDatabaseClients := TList.Create;
end;

destructor TContentNetwork.Destroy;
var
  Index: Integer;
  Entry: THopEntry;
begin
  for Index := 0 to FHops.Count - 1 do
  begin
    Entry := THopEntry(FHops[Index]);
    Entry.Task.Free;
    Entry.Free;
  end;
  FHops.Free;
  for Index := 0 to FWaiting.Count - 1 do
  begin
    Entry := THopEntry(FWaiting[Index]);
    Entry.Request.Free;
    Entry.Free;
  end;
  FWaiting.Free;
  for Index := 0 to FDatabaseClients.Count - 1 do
  begin
    TRemoteDatabaseClient(FDatabaseClients[Index]).Service.ClientClosed(TRemoteDatabaseClient(FDatabaseClients[Index]));
    TRemoteDatabaseClient(FDatabaseClients[Index]).Free;
  end;
  FDatabaseClients.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TContentNetwork.Reply(Message: TIpcMessage; const Payload: TBytes);
begin
  FProcess.Send(IpcReply, Message.ViewId, Message.RequestId, Payload);
end;

function TContentNetwork.UrlOfOwnSite(const Url: string): Boolean;
begin
  Result := (FProcess.Site <> '') and (SiteOfText(Url) = FProcess.Site);
end;

function TContentNetwork.Handle(Message: TIpcMessage): Boolean;
begin
  Result := True;
  case Message.Kind of
    IpcHopStart: StartHop(Message);
    IpcHopCancel: CancelHop(Message);
    IpcReadLocalFile: ReadLocalFile(Message);
    IpcCookieGet: GetCookie(Message);
    IpcCookieSet: SetCookie(Message);
    IpcStorageLoad: LoadStorage(Message);
    IpcStorageSet, IpcStorageRemove, IpcStorageClear: ChangeStorage(Message);
    IpcOriginDataLoad: LoadOriginData(Message);
    IpcOriginDataSave: SaveOriginData(Message);
    IpcIndexedDbRequest: ExecuteIndexedDb(Message);
    IpcIndexedDbClientClosed: CloseIndexedDbClient(Message);
  else
    Exit(False);
  end;
  Message.Free;
end;

{ Same-site for cookies: the request goes to the site the process is
  locked to (what the renderer says of it is not taken). }
function RequestIsSameSite(const Site: string; constref Url: TUrlRecord): Boolean;
begin
  Result := (Site <> '') and (SiteOfUrl(Url) = Site);
end;

function BuildRequest(constref Wire: TIpcHopRequest; constref Url: TUrlRecord; const Site: string): THttpRequest;
var
  Index: Integer;
begin
  Result := THttpRequest.Create(Wire.Method, Url);
  for Index := 0 to High(Wire.Fields) do
    Result.Headers.Add(Wire.Fields[Index].Name, Wire.Fields[Index].Value);
  if Wire.HasBody then
    Result.SetBody(THttpBytesBody.Create(Wire.Body, Wire.BodyType));
  Result.Priority := MakePriority(Wire.PriorityUrgency, Wire.PriorityIncremental);
  if Wire.RedirectMode <= Ord(High(THttpRedirectMode)) then
    Result.RedirectMode := THttpRedirectMode(Wire.RedirectMode)
  else
    Result.RedirectMode := RedirectManual;
  Result.MaximumRedirects := Wire.MaximumRedirects;
  if Wire.CacheMode <= Ord(High(THttpCacheMode)) then
    Result.CacheMode := THttpCacheMode(Wire.CacheMode);
  if Wire.CredentialsMode <= Ord(High(THttpCredentialsMode)) then
    Result.CredentialsMode := THttpCredentialsMode(Wire.CredentialsMode)
  else
    Result.CredentialsMode := CredentialsOmit;
  Result.DecodeContent := Wire.DecodeContent;
  Result.CookieContext.IsSecure := Wire.CookieSecure;
  Result.CookieContext.SameSite := RequestIsSameSite(Site, Url);
  Result.CookieContext.TopLevelNavigation := Wire.CookieTopLevelNavigation;
  Result.CookieContext.SafeMethod := (Wire.Method = 'GET') or (Wire.Method = 'HEAD') or (Wire.Method = 'OPTIONS') or
    (Wire.Method = 'TRACE');
  Result.CookieContext.HttpApi := True;
end;

{ An http:// request to a host HSTS knows: a 307 to https://. }
function AnsweredByHsts(Process: TContentProcess; WireId: QWord; constref Url: TUrlRecord): Boolean;
var
  Upgraded: TUrlRecord;
  Head: TIpcHopHead;
begin
  Upgraded := Url;
  Result := (Url.Scheme = 'http') and SharedNetworkContext.Hsts.UpgradeUrl(Upgraded);
  if not Result then
    Exit;
  Head := Default(TIpcHopHead);
  Head.HopId := WireId;
  Head.Status := 307;
  Head.Reason := 'Internal Redirect';
  SetLength(Head.Fields, 1);
  Head.Fields[0].Name := 'location';
  Head.Fields[0].Value := SerializeUrl(Upgraded);
  Head.Url := SerializeUrl(Url);
  Process.Send(IpcHopHead, 0, 0, EncodeHopHead(Head));
  SendOutcome(Process, WireId, HttpSuccess, '');
end;

procedure TContentNetwork.StartHop(Message: TIpcMessage);
var
  Wire: TIpcHopRequest;
  Url: TUrlRecord;
  Entry: THopEntry;
begin
  Wire := DecodeHopRequest(Message.Payload);
  if not ParseUrl(Wire.Url, Url) or ((Url.Scheme <> 'http') and (Url.Scheme <> 'https')) then
  begin
    SendOutcome(FProcess, Wire.HopId, HttpUnsupportedScheme, 'the network service fetches only http and https');
    Exit;
  end;
  if AnsweredByHsts(FProcess, Wire.HopId, Url) then
    Exit;
  Entry := THopEntry.Create;
  Entry.WireId := Wire.HopId;
  Entry.Network := Self;
  Entry.Request := BuildRequest(Wire, Url, FProcess.Site);
  EnterCriticalSection(FLock);
  try
    if Wire.Urgent then
      FWaiting.Insert(0, Entry)
    else
      FWaiting.Add(Entry);
  finally
    LeaveCriticalSection(FLock);
  end;
  LaunchWaiting;
end;

procedure TContentNetwork.LaunchWaiting;
var
  Entry: THopEntry;
  Request: THttpRequest;
begin
  repeat
    EnterCriticalSection(FLock);
    try
      if (FWaiting.Count = 0) or (FHops.Count >= RunningHopLimit) then
        Exit;
      Entry := THopEntry(FWaiting[0]);
      FWaiting.Delete(0);
      FHops.Add(Entry);
    finally
      LeaveCriticalSection(FLock);
    end;
    Request := Entry.Request;
    Entry.Request := nil;
    try
      Entry.Task := THttpFetchTask.Create(SharedNetworkContext.Client, Request, @Entry.TaskHead, @Entry.TaskData,
        @Entry.TaskDone);
    except
      on Error: Exception do
      begin
        Request.Free;
        Entry.Finished := True;
        SendOutcome(FProcess, Entry.WireId, HttpConnectFailed, 'cannot start the request: ' + Error.Message);
      end;
    end;
  until False;
end;

procedure TContentNetwork.CancelHop(Message: TIpcMessage);
var
  WireId: QWord;
  Index: Integer;
  Entry: THopEntry;
begin
  WireId := DecodeHopId(Message.Payload);
  EnterCriticalSection(FLock);
  try
    for Index := 0 to FWaiting.Count - 1 do
      if THopEntry(FWaiting[Index]).WireId = WireId then
      begin
        Entry := THopEntry(FWaiting[Index]);
        FWaiting.Delete(Index);
        Entry.Request.Free;
        Entry.Free;
        Exit;
      end;
    for Index := 0 to FHops.Count - 1 do
    begin
      Entry := THopEntry(FHops[Index]);
      if (Entry.WireId = WireId) and (Entry.Task <> nil) then
        Entry.Task.Cancel;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TContentNetwork.Reap;
var
  Index: Integer;
  Entry: THopEntry;
  Done: TList;
begin
  Done := TList.Create;
  try
    EnterCriticalSection(FLock);
    try
      for Index := FHops.Count - 1 downto 0 do
        if THopEntry(FHops[Index]).Finished then
        begin
          Done.Add(FHops[Index]);
          FHops.Delete(Index);
        end;
    finally
      LeaveCriticalSection(FLock);
    end;
    for Index := 0 to Done.Count - 1 do
    begin
      Entry := THopEntry(Done[Index]);
      Entry.Task.Free;
      Entry.Free;
    end;
  finally
    Done.Free;
  end;
  LaunchWaiting;
end;

procedure TContentNetwork.ReadLocalFile(Message: TIpcMessage);
var
  Answer: TIpcLocalFile;
  Url: TUrlRecord;
  Path: string;
  Stream: TFileStream;
  Html: string;
begin
  Answer := Default(TIpcLocalFile);
  if FProcess.Site <> SiteLocalFiles then
    Answer.Error := 'local files are not this page''s to read'
  else if not ParseUrl(DecodeText(Message.Payload), Url) or (Url.Scheme <> 'file') or not LocalPathOfUrl(Url, Path) then
    Answer.Error := 'not a local file'
  else if DirectoryExists(Path) then
  begin
    Answer.Found := True;
    Answer.IsFolder := True;
    Html := FolderIndexPage(Path, Url);
    Answer.Contents := BytesOf(Html);
  end
  else
    try
      Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
      try
        if Stream.Size > LocalFileLimit then
          Answer.Error := 'too large'
        else
        begin
          SetLength(Answer.Contents, Stream.Size);
          if Stream.Size > 0 then
            Stream.ReadBuffer(Answer.Contents[0], Stream.Size);
          Answer.Found := True;
        end;
      finally
        Stream.Free;
      end;
    except
      on Error: Exception do
        Answer.Error := Error.Message;
    end;
  Reply(Message, EncodeLocalFile(Answer));
end;

procedure TContentNetwork.GetCookie(Message: TIpcMessage);
var
  UrlText, Cookie: string;
  Secure: Boolean;
  Url: TUrlRecord;
begin
  DecodeCookieAccess(Message.Payload, UrlText, Cookie, Secure);
  Cookie := '';
  if UrlOfOwnSite(UrlText) and ParseUrl(UrlText, Url) then
    Cookie := SharedNetworkContext.DocumentCookie(Url, Secure)
  else
    WriteLn(StdErr, '[network] refused the cookies of ', UrlText, ' to a page of ', FProcess.Site);
  Reply(Message, EncodeText(Cookie));
end;

procedure TContentNetwork.SetCookie(Message: TIpcMessage);
var
  UrlText, Cookie: string;
  Secure: Boolean;
  Url: TUrlRecord;
begin
  DecodeCookieAccess(Message.Payload, UrlText, Cookie, Secure);
  if UrlOfOwnSite(UrlText) and ParseUrl(UrlText, Url) then
    SharedNetworkContext.SetDocumentCookie(Url, Cookie, Secure)
  else
    WriteLn(StdErr, '[network] refused to set a cookie of ', UrlText, ' for a page of ', FProcess.Site);
end;

procedure TContentNetwork.LoadStorage(Message: TIpcMessage);
var
  Origin: string;
  Area: TWebStorageArea;
  Pairs: TIpcStoragePairs;
  Index: Integer;
  Value: string;
begin
  Origin := DecodeText(Message.Payload);
  Pairs := Default(TIpcStoragePairs);
  if UrlOfOwnSite(Origin) then
  begin
    EnterLocalStorage;
    try
      Area := SharedLocalStorage.LocalArea(Origin);
      SetLength(Pairs.Keys, Area.Count);
      SetLength(Pairs.Values, Area.Count);
      for Index := 0 to Area.Count - 1 do
      begin
        Pairs.Keys[Index] := Area.KeyAt(Index);
        Area.TryGet(Pairs.Keys[Index], Value);
        Pairs.Values[Index] := Value;
      end;
    finally
      LeaveLocalStorage;
    end;
  end;
  Reply(Message, EncodeStoragePairs(Pairs));
end;

{ Only the known kinds, only for origins of the process's own site. }
function OriginDataKindKnown(const Kind: string): Boolean;
begin
  Result := Kind = 'service-workers';
end;

procedure TContentNetwork.LoadOriginData(Message: TIpcMessage);
var
  Kind, Origin: string;
  Data: TBytes;
  Store: TOriginDataBackend;
begin
  DecodeOriginData(Message.Payload, Kind, Origin, Data);
  Data := nil;
  Store := SharedOriginData;
  if OriginDataKindKnown(Kind) and UrlOfOwnSite(Origin) and (Store <> nil) then
    Data := Store.Load(Kind, Origin)
  else if not UrlOfOwnSite(Origin) then
    WriteLn(StdErr, '[network] refused the ', Kind, ' of ', Origin, ' to a process of ', FProcess.Site);
  Reply(Message, EncodeOriginDataRecord(Data));
end;

procedure TContentNetwork.SaveOriginData(Message: TIpcMessage);
var
  Kind, Origin: string;
  Data: TBytes;
  Store: TOriginDataBackend;
begin
  DecodeOriginData(Message.Payload, Kind, Origin, Data);
  Store := SharedOriginData;
  if not OriginDataKindKnown(Kind) or not UrlOfOwnSite(Origin) then
  begin
    WriteLn(StdErr, '[network] refused to save the ', Kind, ' of ', Origin, ' for a process of ', FProcess.Site);
    Exit;
  end;
  if Store <> nil then
    Store.Save(Kind, Origin, Data);
end;

procedure TContentNetwork.ChangeStorage(Message: TIpcMessage);
var
  Origin, Key, Value: string;
  Area: TWebStorageArea;
begin
  DecodeStorageChange(Message.Payload, Origin, Key, Value);
  if not UrlOfOwnSite(Origin) then
    Exit;
  EnterLocalStorage;
  try
    Area := SharedLocalStorage.LocalArea(Origin);
    case Message.Kind of
      IpcStorageSet: Area.SetItem(Key, Value);
      IpcStorageRemove: Area.RemoveItem(Key);
      IpcStorageClear: Area.Clear;
    end;
  finally
    LeaveLocalStorage;
  end;
end;

procedure TContentNetwork.ExecuteIndexedDb(Message: TIpcMessage);
var
  ClientId: LongWord;
  Origin: string;
  Request: TBytes;
  Index: Integer;
  Client: TRemoteDatabaseClient;
  Writer: TIdbWriter;
begin
  DecodeIndexedDbRequest(Message.Payload, ClientId, Origin, Request);
  if not UrlOfOwnSite(Origin) then
  begin
    WriteLn(StdErr, '[network] refused IndexedDB of ', Origin, ' for a page of ', FProcess.Site);
    Writer := TIdbWriter.Create;
    try
      Writer.WriteByte(IdbStatusSecurity);
      Writer.WriteRaw('Access to the storage of another site is denied.');
      Reply(Message, Writer.Data);
    finally
      Writer.Free;
    end;
    Exit;
  end;
  Client := nil;
  for Index := 0 to FDatabaseClients.Count - 1 do
    if TRemoteDatabaseClient(FDatabaseClients[Index]).ClientId = ClientId then
      Client := TRemoteDatabaseClient(FDatabaseClients[Index]);
  if Client = nil then
  begin
    Client := TRemoteDatabaseClient.Create;
    Client.Process := FProcess;
    Client.ClientId := ClientId;
    { A page keeps the service it began with (private browsing may
      change the shared one). }
    Client.Service := SharedIndexedDb;
    FDatabaseClients.Add(Client);
  end;
  Reply(Message, Client.Service.Execute(Client, Origin, Request));
end;

procedure TContentNetwork.CloseIndexedDbClient(Message: TIpcMessage);
var
  ClientId: LongWord;
  Notice: TBytes;
  Index: Integer;
  Client: TRemoteDatabaseClient;
begin
  DecodeIndexedDbNotice(Message.Payload, ClientId, Notice);
  for Index := FDatabaseClients.Count - 1 downto 0 do
  begin
    Client := TRemoteDatabaseClient(FDatabaseClients[Index]);
    if Client.ClientId <> ClientId then
      Continue;
    FDatabaseClients.Delete(Index);
    Client.Service.ClientClosed(Client);
    Client.Free;
  end;
end;

procedure SaveServiceStorage;
begin
  SaveIndexedDb;
  EnterLocalStorage;
  try
    SharedLocalStorage.SaveAll;
  finally
    LeaveLocalStorage;
  end;
end;

end.
