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
  A page's WebSocket connections: libhttp's TWebSocketConnection over
  the network context's client when the network is in this process, or
  the transport's (the browser's network service) when it is not.
  Whatever comes from the connections' threads is copied into tasks of
  the page's event loop (the networking task source), so the page sees
  every event on its own thread, in order, and never after it let go of
  a channel.

  An aborted in-process connection is freed on a thread of its own
  (its reader may still be waiting for a host to answer), so a page
  going away never waits for the network.
}
unit Web.Fetch.WebSockets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Http.Cookies,
  Http.WebSocketHandshake,
  Http.WebSockets,
  Web.EventLoop.Tasks,
  Web.EventLoop,
  Web.Fetch.Transports,
  Web.Fetch.NetworkContexts;

type
  { What one channel's owner hears, on the page thread. }
  TWebSocketChannelEvents = class
  public
    procedure ChannelOpened(const Protocol, Extensions: string); virtual; abstract;
    procedure ChannelMessage(IsText: Boolean; const Data: TBytes); virtual; abstract;
    procedure ChannelBytesSent(Count: QWord); virtual; abstract;
    procedure ChannelCloseReceived; virtual; abstract;
    procedure ChannelClosed(WasClean: Boolean; Code: Word; const Reason: string; Failed: Boolean); virtual; abstract;
  end;

  TWebSocketChannels = class(TWebSocketEventSink)
  private
    FLoop: TEventLoop;
    FNetwork: TNetworkContext;
    FLock: TRTLCriticalSection;
    FChannels: TList;
    FNextId: QWord;
    function IndexOf(Id: QWord): Integer;
    procedure Deliver(Data: TObject);
    procedure Post(Id: QWord; Kind: Integer; IsText: Boolean; const Data: TBytes; Count: QWord; WasClean: Boolean;
      Code: Word; const Text, Extra: string; Failed: Boolean);
    procedure Drop(Index: Integer);
  public
    constructor Create(Loop: TEventLoop; Network: TNetworkContext);
    { Aborts every connection. }
    destructor Destroy; override;
    { Opens a connection (Request.Url is ws: or wss:); events go to
      Events until Abort or its close. Returns the channel's id. }
    function Open(constref Request: TWebSocketOpenRequest; Events: TWebSocketChannelEvents): QWord;
    procedure Send(Id: QWord; IsText: Boolean; const Data: TBytes);
    procedure Close(Id: QWord; Code: Word; const Reason: string);
    { The owner lets go: the connection is dropped, no more events. }
    procedure Abort(Id: QWord);
    function Count: Integer;
    { TWebSocketEventSink: from the transport or the connections. }
    procedure SocketOpened(SocketId: QWord; const Protocol, Extensions: string); override;
    procedure SocketMessage(SocketId: QWord; IsText: Boolean; const Data: TBytes); override;
    procedure SocketBytesSent(SocketId: QWord; Count_: QWord); override;
    procedure SocketCloseReceived(SocketId: QWord); override;
    procedure SocketClosed(SocketId: QWord; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean); override;
  end;

implementation

uses
  Url.Parser,
  Web.Fetch.ReferrerPolicy;

const
  EventOpened = 0;
  EventMessage = 1;
  EventSent = 2;
  EventCloseReceived = 3;
  EventClosed = 4;

type
  TChannelEvent = class
  public
    Id: QWord;
    Kind: Integer;
    IsText: Boolean;
    Data: TBytes;
    Count: QWord;
    WasClean: Boolean;
    Code: Word;
    Text, Extra: string;
    Failed: Boolean;
  end;

  { An in-process connection's observer: passes everything on to the
    channels until it is cut off. }
  TChannelObserver = class(TWebSocketObserver)
  private
    FLock: TRTLCriticalSection;
    FChannels: TWebSocketChannels;
    FId: QWord;
  public
    constructor Create(Channels: TWebSocketChannels; Id: QWord);
    destructor Destroy; override;
    procedure CutOff;
    function Target: TWebSocketChannels;
    procedure Opened(Connection: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome); override;
    procedure MessageReceived(Connection: TWebSocketConnection; IsText: Boolean; const Data: TBytes); override;
    procedure BytesSent(Connection: TWebSocketConnection; Count: QWord); override;
    procedure CloseReceived(Connection: TWebSocketConnection; Code: Word; const Reason: string); override;
    procedure Closed(Connection: TWebSocketConnection; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean; const ErrorText: string); override;
  end;

  TChannelRecord = class
  public
    Id: QWord;
    Events: TWebSocketChannelEvents;
    Connection: TWebSocketConnection;
    Observer: TChannelObserver;
  end;

  { Frees an aborted connection once its threads are over. }
  TConnectionReaper = class(TThread)
  private
    FConnection: TWebSocketConnection;
    FObserver: TChannelObserver;
  protected
    procedure Execute; override;
  public
    constructor Create(Connection: TWebSocketConnection; Observer: TChannelObserver);
  end;

constructor TConnectionReaper.Create(Connection: TWebSocketConnection; Observer: TChannelObserver);
begin
  FConnection := Connection;
  FObserver := Observer;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TConnectionReaper.Execute;
begin
  FConnection.Free;
  FObserver.Free;
end;

{ ---- TChannelObserver ---- }

constructor TChannelObserver.Create(Channels: TWebSocketChannels; Id: QWord);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FChannels := Channels;
  FId := Id;
end;

destructor TChannelObserver.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TChannelObserver.CutOff;
begin
  EnterCriticalSection(FLock);
  FChannels := nil;
  LeaveCriticalSection(FLock);
end;

function TChannelObserver.Target: TWebSocketChannels;
begin
  EnterCriticalSection(FLock);
  Result := FChannels;
  LeaveCriticalSection(FLock);
end;

{ Each call holds the observer's lock while it posts, so CutOff (and
  the channels going) waits for a post under way. }

procedure TChannelObserver.Opened(Connection: TWebSocketConnection; constref Outcome: TWebSocketHandshakeOutcome);
begin
  EnterCriticalSection(FLock);
  try
    if FChannels <> nil then
      FChannels.SocketOpened(FId, Outcome.Protocol, Outcome.Extensions);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChannelObserver.MessageReceived(Connection: TWebSocketConnection; IsText: Boolean; const Data: TBytes);
begin
  EnterCriticalSection(FLock);
  try
    if FChannels <> nil then
      FChannels.SocketMessage(FId, IsText, Data);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChannelObserver.BytesSent(Connection: TWebSocketConnection; Count: QWord);
begin
  EnterCriticalSection(FLock);
  try
    if FChannels <> nil then
      FChannels.SocketBytesSent(FId, Count);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChannelObserver.CloseReceived(Connection: TWebSocketConnection; Code: Word; const Reason: string);
begin
  EnterCriticalSection(FLock);
  try
    if FChannels <> nil then
      FChannels.SocketCloseReceived(FId);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TChannelObserver.Closed(Connection: TWebSocketConnection; WasClean: Boolean; Code: Word;
  const Reason: string; Failed: Boolean; const ErrorText: string);
begin
  EnterCriticalSection(FLock);
  try
    if FChannels <> nil then
      FChannels.SocketClosed(FId, WasClean, Code, Reason, Failed);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ ---- TWebSocketChannels ---- }

constructor TWebSocketChannels.Create(Loop: TEventLoop; Network: TNetworkContext);
begin
  inherited Create;
  FLoop := Loop;
  FNetwork := Network;
  InitCriticalSection(FLock);
  FChannels := TList.Create;
end;

destructor TWebSocketChannels.Destroy;
begin
  while FChannels.Count > 0 do
    Drop(FChannels.Count - 1);
  FLoop.DiscardTasks(Self);
  FChannels.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TWebSocketChannels.IndexOf(Id: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FChannels.Count - 1 do
    if TChannelRecord(FChannels[Index]).Id = Id then
      Exit(Index);
  Result := -1;
end;

function TWebSocketChannels.Count: Integer;
begin
  Result := FChannels.Count;
end;

{ Removes a channel, dropping its connection (on the page thread). }
procedure TWebSocketChannels.Drop(Index: Integer);
var
  Channel: TChannelRecord;
begin
  Channel := TChannelRecord(FChannels[Index]);
  FChannels.Delete(Index);
  if Channel.Connection <> nil then
  begin
    Channel.Observer.CutOff;
    Channel.Connection.Abort;
    TConnectionReaper.Create(Channel.Connection, Channel.Observer);
  end
  else if FNetwork.Transport <> nil then
    FNetwork.Transport.AbortWebSocket(Self, Channel.Id);
  Channel.Free;
end;

function TWebSocketChannels.Open(constref Request: TWebSocketOpenRequest; Events: TWebSocketChannelEvents): QWord;
var
  Channel: TChannelRecord;
  Options: TWebSocketOptions;
  Url: TUrlRecord;
begin
  Inc(FNextId);
  Result := FNextId;
  Channel := TChannelRecord.Create;
  Channel.Id := Result;
  Channel.Events := Events;
  FChannels.Add(Channel);
  if FNetwork.Transport <> nil then
  begin
    FNetwork.Transport.OpenWebSocket(Request, Result, Self);
    Exit;
  end;
  if not ParseUrl(Request.Url, Url) or (FNetwork.Client = nil) then
  begin
    Post(Result, EventClosed, False, nil, 0, False, 1006, '', '', True);
    Exit;
  end;
  Options := Default(TWebSocketOptions);
  Options.Url := WebSocketFetchUrl(Url);
  Options.Protocols := Request.Protocols;
  Options.Origin := Request.Origin;
  Options.OfferDeflate := True;
  Options.SendCookies := True;
  Options.CookieContext.IsSecure := UrlIsPotentiallyTrustworthy(Options.Url);
  Options.CookieContext.SameSite := Request.SameSite;
  Options.CookieContext.SafeMethod := True;
  Options.CookieContext.HttpApi := True;
  if FNetwork.AcceptLanguage <> '' then
  begin
    SetLength(Options.ExtraFields, 1);
    Options.ExtraFields[0] := 'Accept-Language: ' + FNetwork.AcceptLanguage;
  end;
  Channel.Observer := TChannelObserver.Create(Self, Result);
  Channel.Connection := TWebSocketConnection.Create(FNetwork.Client, Options, Channel.Observer);
end;

procedure TWebSocketChannels.Send(Id: QWord; IsText: Boolean; const Data: TBytes);
var
  Index: Integer;
  Channel: TChannelRecord;
  Text: string;
begin
  Index := IndexOf(Id);
  if Index < 0 then
    Exit;
  Channel := TChannelRecord(FChannels[Index]);
  if Channel.Connection = nil then
  begin
    if FNetwork.Transport <> nil then
      FNetwork.Transport.SendWebSocket(Self, Id, IsText, Data);
    Exit;
  end;
  if IsText then
  begin
    SetString(Text, PChar(PByte(Data)), Length(Data));
    Channel.Connection.SendText(Text);
  end
  else
    Channel.Connection.SendBinary(PByte(Data), Length(Data));
end;

procedure TWebSocketChannels.Close(Id: QWord; Code: Word; const Reason: string);
var
  Index: Integer;
  Channel: TChannelRecord;
begin
  Index := IndexOf(Id);
  if Index < 0 then
    Exit;
  Channel := TChannelRecord(FChannels[Index]);
  if Channel.Connection <> nil then
    Channel.Connection.Close(Code, Reason)
  else if FNetwork.Transport <> nil then
    FNetwork.Transport.CloseWebSocket(Self, Id, Code, Reason);
end;

procedure TWebSocketChannels.Abort(Id: QWord);
var
  Index: Integer;
begin
  Index := IndexOf(Id);
  if Index >= 0 then
    Drop(Index);
end;

procedure TWebSocketChannels.Post(Id: QWord; Kind: Integer; IsText: Boolean; const Data: TBytes; Count: QWord;
  WasClean: Boolean; Code: Word; const Text, Extra: string; Failed: Boolean);
var
  Event: TChannelEvent;
begin
  Event := TChannelEvent.Create;
  Event.Id := Id;
  Event.Kind := Kind;
  Event.IsText := IsText;
  Event.Data := Data;
  Event.Count := Count;
  Event.WasClean := WasClean;
  Event.Code := Code;
  Event.Text := Text;
  Event.Extra := Extra;
  Event.Failed := Failed;
  FLoop.PostMethod(@Deliver, Event, TaskSourceNetworking, Self);
end;

procedure TWebSocketChannels.Deliver(Data: TObject);
var
  Event: TChannelEvent;
  Index: Integer;
  Channel: TChannelRecord;
  Events: TWebSocketChannelEvents;
begin
  Event := TChannelEvent(Data);
  Index := IndexOf(Event.Id);
  if Index < 0 then
    Exit;
  Channel := TChannelRecord(FChannels[Index]);
  Events := Channel.Events;
  case Event.Kind of
    EventOpened: Events.ChannelOpened(Event.Text, Event.Extra);
    EventMessage: Events.ChannelMessage(Event.IsText, Event.Data);
    EventSent: Events.ChannelBytesSent(Event.Count);
    EventCloseReceived: Events.ChannelCloseReceived;
    EventClosed:
      begin
        { The connection is over: forget the channel first (its owner
          may free itself in the call). }
        Index := IndexOf(Event.Id);
        if Index >= 0 then
          Drop(Index);
        Events.ChannelClosed(Event.WasClean, Event.Code, Event.Text, Event.Failed);
      end;
  end;
end;

procedure TWebSocketChannels.SocketOpened(SocketId: QWord; const Protocol, Extensions: string);
begin
  Post(SocketId, EventOpened, False, nil, 0, False, 0, Protocol, Extensions, False);
end;

procedure TWebSocketChannels.SocketMessage(SocketId: QWord; IsText: Boolean; const Data: TBytes);
begin
  Post(SocketId, EventMessage, IsText, Data, 0, False, 0, '', '', False);
end;

procedure TWebSocketChannels.SocketBytesSent(SocketId: QWord; Count_: QWord);
begin
  Post(SocketId, EventSent, False, nil, Count_, False, 0, '', '', False);
end;

procedure TWebSocketChannels.SocketCloseReceived(SocketId: QWord);
begin
  Post(SocketId, EventCloseReceived, False, nil, 0, False, 0, '', '', False);
end;

procedure TWebSocketChannels.SocketClosed(SocketId: QWord; WasClean: Boolean; Code: Word; const Reason: string;
  Failed: Boolean);
begin
  Post(SocketId, EventClosed, False, nil, 0, WasClean, Code, Reason, '', Failed);
end;

end.
