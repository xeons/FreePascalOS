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
  The network service's WebSockets: a content process's connections
  (libhttp's TWebSocketConnection over the program's network context:
  its sockets, TLS, cookie jar and HSTS), each numbered by the process.
  The page's own checks (mixed content, CSP connect-src) were made in
  the renderer; the service does not take its word for the rest:

  - only ws: and wss: URLs; an http host HSTS knows is reached over wss:;
  - the Origin sent is the page's only when it is of the site the
    process is locked to (or the opaque "null"); otherwise the
    connection is refused;
  - whether the handshake is same-site for its cookies is decided from
    the process's site;
  - at most MaximumSocketsPerProcess connections at once, messages of
    at most MaximumServiceMessageBytes.

  Events go back as messages from the connections' threads; connections
  that ended are freed by Reap on the IPC thread, dropped ones on
  threads of their own.
}
unit WebView.NetworkSockets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  WebIpc.Messages,
  WebView.ContentProcess;

const
  MaximumSocketsPerProcess = 200;
  MaximumServiceMessageBytes = 64 * 1024 * 1024;

type
  TContentSockets = class
  private
    FProcess: TContentProcess;
    FSockets: TList;
    function IndexOf(WireId: QWord): Integer;
    procedure Open(Message: TIpcMessage);
    procedure Send(Message: TIpcMessage);
    procedure Close(Message: TIpcMessage);
    procedure Abort(Message: TIpcMessage);
    procedure Drop(Index: Integer);
  public
    constructor Create(Process: TContentProcess);
    { Drops every connection. }
    destructor Destroy; override;
    { One of the WebSocket messages (not freed here): True. }
    function Handle(Message: TIpcMessage): Boolean;
    { Frees the connections that ended. }
    procedure Reap;
  end;

implementation

uses
  Url.Records,
  Url.Parser,
  Http.WebSocketHandshake,
  Http.WebSockets,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.MixedContent,
  WebIpc.NetworkMessages,
  WebView.Sites,
  WebView.Network;

type
  TServiceSocket = class(TWebSocketObserver)
  public
    WireId: QWord;
    Process: TContentProcess;
    Connection: TWebSocketConnection;
    Finished: Boolean;
    procedure Opened(Connection_: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome); override;
    procedure MessageReceived(Connection_: TWebSocketConnection; IsText: Boolean; const Data: TBytes); override;
    procedure BytesSent(Connection_: TWebSocketConnection; Count: QWord); override;
    procedure CloseReceived(Connection_: TWebSocketConnection; Code: Word; const Reason: string); override;
    procedure Closed(Connection_: TWebSocketConnection; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean; const ErrorText: string); override;
  end;

procedure SendClosed(Process: TContentProcess; WireId: QWord; WasClean: Boolean; Code: Word; const Reason: string;
  Failed: Boolean);
var
  Wire: TIpcWebSocketClosed;
begin
  Wire.SocketId := WireId;
  Wire.WasClean := WasClean;
  Wire.Code := Code;
  Wire.Reason := Reason;
  Wire.Failed := Failed;
  Process.Send(IpcWebSocketClosed, 0, 0, EncodeWebSocketClosed(Wire));
end;

{ ---- TServiceSocket: on the connection's threads ---- }

procedure TServiceSocket.Opened(Connection_: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome);
var
  Wire: TIpcWebSocketOpened;
begin
  Wire.SocketId := WireId;
  Wire.Protocol := Outcome.Protocol;
  Wire.Extensions := Outcome.Extensions;
  Process.Send(IpcWebSocketOpened, 0, 0, EncodeWebSocketOpened(Wire));
end;

procedure TServiceSocket.MessageReceived(Connection_: TWebSocketConnection; IsText: Boolean; const Data: TBytes);
var
  Wire: TIpcWebSocketData;
begin
  Wire.SocketId := WireId;
  Wire.IsText := IsText;
  Wire.Data := Data;
  Process.Send(IpcWebSocketMessage, 0, 0, EncodeWebSocketData(Wire));
end;

procedure TServiceSocket.BytesSent(Connection_: TWebSocketConnection; Count: QWord);
begin
  Process.Send(IpcWebSocketSent, 0, 0, EncodeWebSocketSent(WireId, Count));
end;

procedure TServiceSocket.CloseReceived(Connection_: TWebSocketConnection; Code: Word; const Reason: string);
begin
  Process.Send(IpcWebSocketCloseReceived, 0, 0, EncodeHopId(WireId));
end;

procedure TServiceSocket.Closed(Connection_: TWebSocketConnection; WasClean: Boolean; Code: Word;
  const Reason: string; Failed: Boolean; const ErrorText: string);
begin
  if Failed and (ErrorText <> '') then
    WriteLn(StdErr, '[network] websocket ', WireId, ' of ', Process.Site, ' failed: ', ErrorText);
  SendClosed(Process, WireId, WasClean, Code, Reason, Failed);
  Finished := True;
end;

{ ---- TContentSockets: on the IPC thread ---- }

constructor TContentSockets.Create(Process: TContentProcess);
begin
  inherited Create;
  FProcess := Process;
  FSockets := TList.Create;
end;

destructor TContentSockets.Destroy;
begin
  while FSockets.Count > 0 do
    Drop(FSockets.Count - 1);
  FSockets.Free;
  inherited Destroy;
end;

function TContentSockets.IndexOf(WireId: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FSockets.Count - 1 do
    if TServiceSocket(FSockets[Index]).WireId = WireId then
      Exit(Index);
  Result := -1;
end;

procedure TContentSockets.Drop(Index: Integer);
var
  Socket: TServiceSocket;
begin
  Socket := TServiceSocket(FSockets[Index]);
  FSockets.Delete(Index);
  DiscardWebSocketConnection(Socket.Connection, Socket);
end;

function TContentSockets.Handle(Message: TIpcMessage): Boolean;
begin
  Result := True;
  case Message.Kind of
    IpcWebSocketOpen: Open(Message);
    IpcWebSocketSend: Send(Message);
    IpcWebSocketClose: Close(Message);
    IpcWebSocketAbort: Abort(Message);
  else
    Result := False;
  end;
end;

procedure TContentSockets.Open(Message: TIpcMessage);
var
  Wire: TIpcWebSocketOpen;
  Url, HttpForm: TUrlRecord;
  Options: TWebSocketOptions;
  Socket: TServiceSocket;
  Index: Integer;
begin
  Wire := DecodeWebSocketOpen(Message.Payload);
  if (IndexOf(Wire.SocketId) >= 0) or not ParseUrl(Wire.Url, Url) or ((Url.Scheme <> 'ws') and (Url.Scheme <> 'wss')) or
     (FSockets.Count >= MaximumSocketsPerProcess) then
  begin
    SendClosed(FProcess, Wire.SocketId, False, 1006, '', True);
    Exit;
  end;
  if (Wire.Origin <> 'null') and ((FProcess.Site = '') or (SiteOfText(Wire.Origin) <> FProcess.Site)) then
  begin
    WriteLn(StdErr, '[network] refused a websocket with the origin ', Wire.Origin, ' to a page of ', FProcess.Site);
    SendClosed(FProcess, Wire.SocketId, False, 1006, '', True);
    Exit;
  end;
  HttpForm := WebSocketFetchUrl(Url);
  if (Url.Scheme = 'ws') and SharedNetworkContext.Hsts.UpgradeUrl(HttpForm) then
    UpgradeUrlToSecure(Url);
  for Index := 0 to High(Wire.Protocols) do
    if not IsProtocolToken(Wire.Protocols[Index]) then
    begin
      SendClosed(FProcess, Wire.SocketId, False, 1006, '', True);
      Exit;
    end;
  Options := Default(TWebSocketOptions);
  Options.Url := WebSocketFetchUrl(Url);
  Options.Protocols := Wire.Protocols;
  Options.Origin := Wire.Origin;
  Options.OfferDeflate := True;
  Options.SendCookies := True;
  Options.CookieContext.IsSecure := UrlIsPotentiallyTrustworthy(Options.Url);
  Options.CookieContext.SameSite := (FProcess.Site <> '') and (SiteOfUrl(Options.Url) = FProcess.Site);
  Options.CookieContext.SafeMethod := True;
  Options.CookieContext.HttpApi := True;
  Options.MaximumMessageBytes := MaximumServiceMessageBytes;
  if SharedNetworkContext.AcceptLanguage <> '' then
  begin
    SetLength(Options.ExtraFields, 1);
    Options.ExtraFields[0] := 'Accept-Language: ' + SharedNetworkContext.AcceptLanguage;
  end;
  Socket := TServiceSocket.Create;
  Socket.WireId := Wire.SocketId;
  Socket.Process := FProcess;
  FSockets.Add(Socket);
  Socket.Connection := TWebSocketConnection.Create(SharedNetworkContext.Client, Options, Socket);
end;

procedure TContentSockets.Send(Message: TIpcMessage);
var
  Wire: TIpcWebSocketData;
  Index: Integer;
  Text: string;
  Socket: TServiceSocket;
begin
  Wire := DecodeWebSocketData(Message.Payload);
  Index := IndexOf(Wire.SocketId);
  if Index < 0 then
    Exit;
  Socket := TServiceSocket(FSockets[Index]);
  if Wire.IsText then
  begin
    SetString(Text, PChar(PByte(Wire.Data)), Length(Wire.Data));
    Socket.Connection.SendText(Text);
  end
  else
    Socket.Connection.SendBinary(PByte(Wire.Data), Length(Wire.Data));
end;

procedure TContentSockets.Close(Message: TIpcMessage);
var
  Wire: TIpcWebSocketClose;
  Index: Integer;
begin
  Wire := DecodeWebSocketClose(Message.Payload);
  Index := IndexOf(Wire.SocketId);
  if Index >= 0 then
    TServiceSocket(FSockets[Index]).Connection.Close(Wire.Code, Wire.Reason);
end;

procedure TContentSockets.Abort(Message: TIpcMessage);
var
  Index: Integer;
begin
  Index := IndexOf(DecodeHopId(Message.Payload));
  if Index >= 0 then
    Drop(Index);
end;

procedure TContentSockets.Reap;
var
  Index: Integer;
begin
  for Index := FSockets.Count - 1 downto 0 do
    if TServiceSocket(FSockets[Index]).Finished then
      Drop(Index);
end;

end.
