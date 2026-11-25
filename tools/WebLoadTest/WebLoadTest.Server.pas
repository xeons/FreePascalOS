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
  An in-process web site for the loading tests: a libhttp connector
  whose connections are in-memory pipes to a small HTTP/1.1 server
  thread each. Routes ("host/path?query", any scheme) give the status,
  fields and body; a body can come in pieces, with a pause or a gate
  the test opens between them, so documents arrive bit by bit. Every
  request is logged ("METHOD scheme://host/target") with its head.

  The test environment joins the site to an event loop, a client, a
  network context and a fetcher, and runs the loop until a condition
  holds.
}
unit WebLoadTest.Server;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  HttpTest.Pipes,
  Http.Client,
  Http.Connectors,
  Http.Observers,
  Http.Results,
  Http.Transports,
  Url.Records,
  Web.EventLoop,
  Web.Fetch.NetworkContexts,
  Web.Fetch.Fetcher;

type
  TTestRoute = class
  public
    Key: string;
    Status: Integer;
    Fields: string;
    Body: string;
    { More than 1: the body is sent chunked in this many pieces. }
    Pieces: Integer;
    { Milliseconds between pieces. }
    PieceDelay: Integer;
    { When set, the server waits for it after the first piece. }
    Gate: TEvent;
    { When set, the server waits for it before sending the head. }
    HeadGate: TEvent;
    destructor Destroy; override;
  end;

  TTestSite = class(THttpConnector)
  private
    FLock: TRTLCriticalSection;
    FRoutes: TList;
    FPairs: TList;
    FServers: TList;
    FLog: TStringList;
    FHeads: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
    function AddRoute(const Key: string; Status: Integer; const Fields, Body: string): TTestRoute;
    function FindRoute(const Key: string): TTestRoute;
    procedure LogRequest(const Line, Head: string);
    { How many logged requests contain Text. }
    function RequestCount(const Text: string): Integer;
    { The head of the last request whose log line contains Text. }
    function LastHead(const Text: string): string;
    function LogText: string;
    procedure ClearLog;
  end;

  TTestCondition = function: Boolean of object;

  TTestEnvironment = class
  public
    Site: TTestSite;
    Loop: TEventLoop;
    Client: THttpClient;
    Network: TNetworkContext;
    Fetcher: TFetcher;
    constructor Create;
    destructor Destroy; override;
    { Runs the loop until Condition is true or TimeoutMilliseconds pass. }
    function RunUntil(Condition: TTestCondition; TimeoutMilliseconds: Integer = 5000): Boolean;
    { Runs the loop for a while (lets late results arrive). }
    procedure RunFor(Milliseconds: Integer);
  end;

{ A field of a raw head ('' when missing). }
function HeadField(const Head, Name: string): string;

implementation

type
  TTestServer = class(TThread)
  private
    FSite: TTestSite;
    FTransport: THttpTransport;
    FScheme: string;
    FPending: string;
    function Fill: Boolean;
    procedure Send(const Text: string);
    procedure Serve(const Head, Body: string);
  protected
    procedure Execute; override;
  public
    constructor Create(Site: TTestSite; Transport: THttpTransport; const Scheme: string);
  end;

function HeadField(const Head, Name: string): string;
var
  Lines: TStringArray;
  Index, Colon: Integer;
begin
  Result := '';
  Lines := Head.Split([#13#10]);
  for Index := 1 to High(Lines) do
  begin
    Colon := Pos(':', Lines[Index]);
    if (Colon > 0) and SameText(Trim(Copy(Lines[Index], 1, Colon - 1)), Name) then
      Exit(Trim(Copy(Lines[Index], Colon + 1, MaxInt)));
  end;
end;

destructor TTestRoute.Destroy;
begin
  Gate.Free;
  HeadGate.Free;
  inherited Destroy;
end;

constructor TTestServer.Create(Site: TTestSite; Transport: THttpTransport; const Scheme: string);
begin
  FSite := Site;
  FTransport := Transport;
  FScheme := Scheme;
  inherited Create(False);
end;

function TTestServer.Fill: Boolean;
var
  Buffer: array[0..4095] of Char;
  Count: Int64;
  Text: string;
begin
  Count := FTransport.Read(@Buffer[0], SizeOf(Buffer));
  if Count <= 0 then
    Exit(False);
  SetString(Text, PChar(@Buffer[0]), Count);
  FPending := FPending + Text;
  Result := True;
end;

procedure TTestServer.Send(const Text: string);
begin
  if Text <> '' then
    FTransport.Write(PChar(Text), Length(Text));
end;

procedure TTestServer.Serve(const Head, Body: string);
var
  RequestLine, Target, Host, Method, Key, Piece: string;
  Parts: TStringArray;
  Route: TTestRoute;
  Status, Index, PieceLength, Offset: Integer;
  Fields, Content: string;
begin
  RequestLine := Copy(Head, 1, Pos(#13#10, Head) - 1);
  Parts := RequestLine.Split([' ']);
  Method := Parts[0];
  Target := Parts[1];
  Host := HeadField(Head, 'Host');
  Key := Host + Target;
  FSite.LogRequest(Method + ' ' + FScheme + '://' + Key, Head);
  Route := FSite.FindRoute(Key);
  if Route = nil then
  begin
    Status := 404;
    Fields := 'Content-Type: text/plain'#13#10;
    Content := 'not found: ' + Key;
  end
  else
  begin
    Status := Route.Status;
    Fields := Route.Fields;
    Content := Route.Body;
  end;
  if Method = 'HEAD' then
    Content := '';
  if (Route <> nil) and (Route.HeadGate <> nil) then
    Route.HeadGate.WaitFor(10000);
  if (Route = nil) or (Route.Pieces <= 1) then
  begin
    Send('HTTP/1.1 ' + IntToStr(Status) + ' X'#13#10 + Fields + 'Content-Length: ' + IntToStr(Length(Content)) +
      #13#10#13#10 + Content);
    Exit;
  end;
  Send('HTTP/1.1 ' + IntToStr(Status) + ' X'#13#10 + Fields + 'Transfer-Encoding: chunked'#13#10#13#10);
  PieceLength := (Length(Content) + Route.Pieces - 1) div Route.Pieces;
  Offset := 1;
  for Index := 1 to Route.Pieces do
  begin
    Piece := Copy(Content, Offset, PieceLength);
    Inc(Offset, PieceLength);
    if Piece <> '' then
      Send(IntToHex(Length(Piece), 1) + #13#10 + Piece + #13#10);
    if (Index = 1) and (Route.Gate <> nil) then
      Route.Gate.WaitFor(10000)
    else if Route.PieceDelay > 0 then
      Sleep(Route.PieceDelay);
  end;
  Send('0'#13#10#13#10);
end;

procedure TTestServer.Execute;
var
  Ending, BodyLength: Integer;
  Head, Body: string;
begin
  while True do
  begin
    Ending := Pos(#13#10#13#10, FPending);
    while Ending = 0 do
    begin
      if not Fill then
        Exit;
      Ending := Pos(#13#10#13#10, FPending);
    end;
    Head := Copy(FPending, 1, Ending + 1);
    Delete(FPending, 1, Ending + 3);
    BodyLength := StrToIntDef(HeadField(Head, 'Content-Length'), 0);
    while Length(FPending) < BodyLength do
      if not Fill then
        Exit;
    Body := Copy(FPending, 1, BodyLength);
    Delete(FPending, 1, BodyLength);
    Serve(Head, Body);
  end;
end;

constructor TTestSite.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FRoutes := TList.Create;
  FPairs := TList.Create;
  FServers := TList.Create;
  FLog := TStringList.Create;
  FHeads := TStringList.Create;
end;

destructor TTestSite.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FRoutes.Count - 1 do
    if TTestRoute(FRoutes[Index]).Gate <> nil then
      TTestRoute(FRoutes[Index]).Gate.SetEvent;
  for Index := 0 to FServers.Count - 1 do
  begin
    TPipePair(FPairs[Index]).ToServer.CloseWriting;
    TThread(FServers[Index]).WaitFor;
    TThread(FServers[Index]).Free;
  end;
  for Index := 0 to FPairs.Count - 1 do
    TPipePair(FPairs[Index]).Free;
  for Index := 0 to FRoutes.Count - 1 do
    TTestRoute(FRoutes[Index]).Free;
  FRoutes.Free;
  FPairs.Free;
  FServers.Free;
  FLog.Free;
  FHeads.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TTestSite.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
var
  Pair: TPipePair;
  Server: TThread;
begin
  Pair := TPipePair.Create('http/1.1');
  Pair.Server.TimeoutMilliseconds := 0;
  Server := TTestServer.Create(Self, Pair.Server, Url.Scheme);
  EnterCriticalSection(FLock);
  FPairs.Add(Pair);
  FServers.Add(Server);
  LeaveCriticalSection(FLock);
  Transport := Pair.Client;
  Result := HttpOk;
end;

function TTestSite.AddRoute(const Key: string; Status: Integer; const Fields, Body: string): TTestRoute;
var
  Lines: TStringArray;
  Index: Integer;
begin
  Result := TTestRoute.Create;
  Result.Key := Key;
  Result.Status := Status;
  Result.Fields := '';
  Lines := Fields.Split(['|']);
  for Index := 0 to High(Lines) do
    if Lines[Index] <> '' then
      Result.Fields := Result.Fields + Lines[Index] + #13#10;
  Result.Body := Body;
  EnterCriticalSection(FLock);
  FRoutes.Add(Result);
  LeaveCriticalSection(FLock);
end;

function TTestSite.FindRoute(const Key: string): TTestRoute;
var
  Index: Integer;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    for Index := FRoutes.Count - 1 downto 0 do
      if TTestRoute(FRoutes[Index]).Key = Key then
        Exit(TTestRoute(FRoutes[Index]));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TTestSite.LogRequest(const Line, Head: string);
begin
  EnterCriticalSection(FLock);
  FLog.Add(Line);
  FHeads.Add(StringReplace(Head, #13#10, #1, [rfReplaceAll]));
  LeaveCriticalSection(FLock);
end;

function TTestSite.RequestCount(const Text: string): Integer;
var
  Index: Integer;
begin
  Result := 0;
  EnterCriticalSection(FLock);
  for Index := 0 to FLog.Count - 1 do
    if Pos(Text, FLog[Index]) > 0 then
      Inc(Result);
  LeaveCriticalSection(FLock);
end;

function TTestSite.LastHead(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  EnterCriticalSection(FLock);
  for Index := FLog.Count - 1 downto 0 do
    if Pos(Text, FLog[Index]) > 0 then
    begin
      Result := StringReplace(FHeads[Index], #1, #13#10, [rfReplaceAll]);
      Break;
    end;
  LeaveCriticalSection(FLock);
end;

function TTestSite.LogText: string;
begin
  EnterCriticalSection(FLock);
  Result := Trim(StringReplace(FLog.Text, LineEnding, ' | ', [rfReplaceAll]));
  LeaveCriticalSection(FLock);
end;

procedure TTestSite.ClearLog;
begin
  EnterCriticalSection(FLock);
  FLog.Clear;
  FHeads.Clear;
  LeaveCriticalSection(FLock);
end;

constructor TTestEnvironment.Create;
var
  Settings: THttpClientSettings;
begin
  inherited Create;
  Site := TTestSite.Create;
  Loop := TEventLoop.Create;
  Settings := DefaultClientSettings;
  Settings.AcceptEncoding := '';
  Client := THttpClient.Create(Settings, Site, False);
  Network := TNetworkContext.Create(Client, False);
  Fetcher := TFetcher.Create(Loop, Network);
end;

destructor TTestEnvironment.Destroy;
begin
  Fetcher.Free;
  Network.Free;
  Client.Free;
  Site.Free;
  Loop.Free;
  inherited Destroy;
end;

function TTestEnvironment.RunUntil(Condition: TTestCondition; TimeoutMilliseconds: Integer): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while True do
  begin
    Loop.RunPendingTasks;
    if Condition() then
      Exit(True);
    if GetTickCount64 - Started > QWord(TimeoutMilliseconds) then
      Exit(False);
    Loop.WaitForWork(20);
  end;
end;

procedure TTestEnvironment.RunFor(Milliseconds: Integer);
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while GetTickCount64 - Started < QWord(Milliseconds) do
  begin
    Loop.WaitForWork(10);
    Loop.RunPendingTasks;
  end;
end;

end.
