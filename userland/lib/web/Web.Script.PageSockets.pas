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
  A page's WebSockets (WebSockets Standard, "establish a WebSocket
  connection" through Fetch): the request is the document's, so what
  Fetch decides for it is decided here before the connection is made -
  upgrade-insecure-requests, HSTS (ws: becoming wss:), mixed content
  (a ws: connection from a secure context is blocked) and CSP
  connect-src (a violation is reported). A blocked one fails in a later
  task, as a network error does. The connections are the page's
  TWebSocketChannels (Web.Fetch.WebSockets): in this process, or the
  browser's network service's.

  When a document is left its sockets close with 1001 (going away) and
  their events are dropped.
}
unit Web.Script.PageSockets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.EventLoop,
  Web.Fetch.WebSockets,
  Web.Loading.Contexts,
  Web.ScriptEnvironment;

type
  TScriptWebSockets = class
  private
    FLoop: TEventLoop;
    FChannels: TWebSocketChannels;
    FSockets: TList;
  public
    constructor Create(Loop: TEventLoop);
    destructor Destroy; override;
    { A socket of the loader's document to Url (ws: or wss:); nil when
      there is no document to open it for. }
    function Open(Loader: TLoadingContext; const Url: string; const Protocols: TStringArray;
      Sink: TScriptWebSocketSink): TObject;
    procedure Send(Handle: TObject; IsText: Boolean; const Data: TBytes);
    procedure Close(Handle: TObject; Code: Word; const Reason: string);
    procedure Forget(Handle: TObject);
    { The loader's document was left: its sockets close (1001). }
    procedure CancelLoader(Loader: TLoadingContext);
    function Count: Integer;
  end;

implementation

uses
  Url.Records,
  Url.Parser,
  Url.Origins,
  Http.PublicSuffixes,
  Http.WebSocketFrames,
  Web.EventLoop.Tasks,
  Web.Fetch.Requests,
  Web.Fetch.Transports,
  Web.Fetch.MixedContent,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.CspChecks;

type
  TPageSocket = class(TWebSocketChannelEvents)
  public
    Owner: TScriptWebSockets;
    Loader: TLoadingContext;
    Sink: TScriptWebSocketSink;
    ChannelId: QWord;
    HasChannel: Boolean;
    procedure FailTask;
    procedure ChannelOpened(const Protocol, Extensions: string); override;
    procedure ChannelMessage(IsText: Boolean; const Data: TBytes); override;
    procedure ChannelBytesSent(Count: QWord); override;
    procedure ChannelCloseReceived; override;
    procedure ChannelClosed(WasClean: Boolean; Code: Word; const Reason: string; Failed: Boolean); override;
  end;

procedure TPageSocket.FailTask;
begin
  if Sink <> nil then
    Sink.Closed(False, WebSocketCloseAbnormal, '', True);
end;

procedure TPageSocket.ChannelOpened(const Protocol, Extensions: string);
begin
  if Sink <> nil then
    Sink.Opened(Protocol, Extensions);
end;

procedure TPageSocket.ChannelMessage(IsText: Boolean; const Data: TBytes);
begin
  if Sink <> nil then
    Sink.MessageArrived(IsText, Data);
end;

procedure TPageSocket.ChannelBytesSent(Count: QWord);
begin
  if Sink <> nil then
    Sink.BytesSent(Count);
end;

procedure TPageSocket.ChannelCloseReceived;
begin
  if Sink <> nil then
    Sink.CloseReceived;
end;

procedure TPageSocket.ChannelClosed(WasClean: Boolean; Code: Word; const Reason: string; Failed: Boolean);
begin
  HasChannel := False;
  if Sink <> nil then
    Sink.Closed(WasClean, Code, Reason, Failed);
end;

constructor TScriptWebSockets.Create(Loop: TEventLoop);
begin
  inherited Create;
  FLoop := Loop;
  FSockets := TList.Create;
end;

destructor TScriptWebSockets.Destroy;
var
  Index: Integer;
begin
  FChannels.Free;
  for Index := 0 to FSockets.Count - 1 do
  begin
    FLoop.DiscardTasks(FSockets[Index]);
    TPageSocket(FSockets[Index]).Free;
  end;
  FSockets.Free;
  inherited Destroy;
end;

function TScriptWebSockets.Count: Integer;
begin
  Result := FSockets.Count;
end;

{ Whether the page's top-level site is the URL's, as the fetcher decides
  it for cookies. }
function SameSiteFor(Client: TFetchClient; constref Url: TUrlRecord): Boolean;
var
  TopHost, Scheme: string;
begin
  Result := False;
  if (Client = nil) or not Client.HasTopLevelOrigin or Client.TopLevelOrigin.Opaque or
     (Url.Host.Kind <> UrlHostDomain) then
    Exit;
  TopHost := SerializeHost(Client.TopLevelOrigin.Host);
  Scheme := Url.Scheme;
  if Scheme = 'wss' then
    Scheme := 'https'
  else if Scheme = 'ws' then
    Scheme := 'http';
  Result := HostsAreSameSite(TopHost, Url.Host.Name) and (Client.TopLevelOrigin.Scheme = Scheme);
end;

function TScriptWebSockets.Open(Loader: TLoadingContext; const Url: string; const Protocols: TStringArray;
  Sink: TScriptWebSocketSink): TObject;
var
  Socket: TPageSocket;
  Parsed, HttpForm: TUrlRecord;
  Probe: TFetchRequest;
  Blocked: Boolean;
  Request: TWebSocketOpenRequest;
begin
  Result := nil;
  if (Loader = nil) or not ParseUrl(Url, Parsed) then
    Exit;
  Socket := TPageSocket.Create;
  Socket.Owner := Self;
  Socket.Loader := Loader;
  Socket.Sink := Sink;
  FSockets.Add(Socket);
  Result := Socket;
  { Fetch's main fetch for the handshake's request: upgrades, mixed
    content, CSP. }
  Probe := TFetchRequest.Create('GET', Parsed);
  try
    Probe.Client := Loader.Client;
    Probe.Destination := DestinationEmpty;
    Probe.Mode := FetchModeCors;
    UpgradeMixedContentRequest(Probe);
    Parsed := Probe.CurrentUrl;
    HttpForm := Parsed;
    if HttpForm.Scheme = 'ws' then
      HttpForm.Scheme := 'http';
    if (Parsed.Scheme = 'ws') and Loader.Fetcher.Network.Hsts.UpgradeUrl(HttpForm) then
    begin
      UpgradeUrlToSecure(Parsed);
      Probe.UrlList[High(Probe.UrlList)] := Parsed;
    end;
    Blocked := ShouldBlockMixedContent(Probe) or
      CspBlocksRequest(Loader.Client, Parsed, DestinationEmpty, '', '', False, 0);
  finally
    Probe.Free;
  end;
  if Blocked then
  begin
    FLoop.QueueMethod(@Socket.FailTask, TaskSourceNetworking, Socket);
    Exit;
  end;
  if FChannels = nil then
    FChannels := TWebSocketChannels.Create(FLoop, Loader.Fetcher.Network);
  Request := Default(TWebSocketOpenRequest);
  Request.Url := SerializeUrl(Parsed);
  Request.Protocols := Protocols;
  Request.Origin := SerializeOrigin(Loader.Client.Origin);
  Request.SameSite := SameSiteFor(Loader.Client, Parsed);
  Socket.ChannelId := FChannels.Open(Request, Socket);
  Socket.HasChannel := True;
end;

procedure TScriptWebSockets.Send(Handle: TObject; IsText: Boolean; const Data: TBytes);
var
  Socket: TPageSocket;
begin
  if FSockets.IndexOf(Handle) < 0 then
    Exit;
  Socket := TPageSocket(Handle);
  if Socket.HasChannel then
    FChannels.Send(Socket.ChannelId, IsText, Data);
end;

procedure TScriptWebSockets.Close(Handle: TObject; Code: Word; const Reason: string);
var
  Socket: TPageSocket;
begin
  if FSockets.IndexOf(Handle) < 0 then
    Exit;
  Socket := TPageSocket(Handle);
  if Socket.HasChannel then
    FChannels.Close(Socket.ChannelId, Code, Reason);
end;

procedure TScriptWebSockets.Forget(Handle: TObject);
var
  Socket: TPageSocket;
begin
  if FSockets.IndexOf(Handle) < 0 then
    Exit;
  Socket := TPageSocket(Handle);
  FSockets.Remove(Socket);
  FLoop.DiscardTasks(Socket);
  if Socket.HasChannel then
    FChannels.Abort(Socket.ChannelId);
  Socket.Free;
end;

procedure TScriptWebSockets.CancelLoader(Loader: TLoadingContext);
var
  Index: Integer;
  Socket: TPageSocket;
begin
  for Index := FSockets.Count - 1 downto 0 do
  begin
    Socket := TPageSocket(FSockets[Index]);
    if Socket.Loader <> Loader then
      Continue;
    if Socket.HasChannel then
      FChannels.Close(Socket.ChannelId, WebSocketCloseGoingAway, '');
    { The script's object goes with its document: no more events. }
    Socket.Sink := nil;
  end;
end;

end.
