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
  The network when it is in another process. A browser's content
  process (a renderer) never opens a socket or a file itself: its
  network context (Web.Fetch.NetworkContexts) has a transport instead
  of an HTTP client, which hands each HTTP exchange ("hop": one request,
  its redirects decided by the fetcher here), each local file and each
  document.cookie to the browser's network service and brings the
  answers back. Everything the fetcher decides (CORS, mixed content,
  CSP, referrers, redirects, sniffing) is still decided here; the
  browser keeps the cookie jar, the HTTP cache, the connections and the
  HSTS list, and refuses what the process's site may not have.

  WebSocket connections go the same way: the page's checks (mixed
  content, CSP connect-src, HSTS) are made here, the connection itself
  is the browser's (its cookies, its sockets); its events come back to
  a TWebSocketEventSink.
}
unit Web.Fetch.Transports;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Http.Messages,
  Http.HeaderFields,
  Http.Results;

type
  { Hears one hop's results, from any thread (THopRunner). }
  THopResultSink = class
  public
    procedure HopHead(HopId: QWord; Status: Integer; const Reason: string; const Fields: THttpHeaderFieldArray;
      constref Url: TUrlRecord; FromCache: Boolean; const Protocol: string); virtual; abstract;
    procedure HopData(HopId: QWord; Data: Pointer; Count: PtrUInt); virtual; abstract;
    procedure HopDone(HopId: QWord; constref Outcome: THttpResult); virtual; abstract;
  end;

  { What a page asks for when it opens a WebSocket (the URL ws: or wss:,
    checked already). }
  TWebSocketOpenRequest = record
    Url: string;
    Protocols: array of string;
    { The serialized origin of the page. }
    Origin: string;
    { Whether the page's top-level site is the URL's (SameSite cookies);
      a browser decides this itself. }
    SameSite: Boolean;
  end;

  { Hears one page's WebSocket connections, from any thread. Closed comes
    once, last (Failed: the connection failed rather than closed). }
  TWebSocketEventSink = class
  public
    procedure SocketOpened(SocketId: QWord; const Protocol, Extensions: string); virtual; abstract;
    procedure SocketMessage(SocketId: QWord; IsText: Boolean; const Data: TBytes); virtual; abstract;
    procedure SocketBytesSent(SocketId: QWord; Count: QWord); virtual; abstract;
    procedure SocketCloseReceived(SocketId: QWord); virtual; abstract;
    procedure SocketClosed(SocketId: QWord; WasClean: Boolean; Code: Word; const Reason: string;
      Failed: Boolean); virtual; abstract;
  end;

  TNetworkTransport = class
  public
    { WebSockets (by default none: the connection fails at once). }
    procedure OpenWebSocket(constref Request: TWebSocketOpenRequest; SocketId: QWord; Sink: TWebSocketEventSink);
      virtual;
    procedure SendWebSocket(Sink: TWebSocketEventSink; SocketId: QWord; IsText: Boolean; const Data: TBytes); virtual;
    { Starts the closing handshake (Code 0: none). }
    procedure CloseWebSocket(Sink: TWebSocketEventSink; SocketId: QWord; Code: Word; const Reason: string); virtual;
    { Drops the connection; nothing more is told of it. }
    procedure AbortWebSocket(Sink: TWebSocketEventSink; SocketId: QWord); virtual;
    { Sends Request (taken over) as Sink's hop HopId. Its head, body and
      outcome come to Sink; the outcome always comes, once. }
    procedure StartHop(Request: THttpRequest; HopId: QWord; Urgent: Boolean; Sink: THopResultSink); virtual; abstract;
    { Stops the hop: its outcome (canceled) comes at once, nothing after. }
    procedure CancelHop(Sink: THopResultSink; HopId: QWord); virtual; abstract;
    { Sink is going: nothing more is told to it. }
    procedure ForgetSink(Sink: THopResultSink); virtual; abstract;
    { document.cookie for a document at Url. }
    function DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string; virtual; abstract;
    procedure SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean); virtual; abstract;
    { A file: URL's contents (a folder: the folder's index page as HTML);
      False with Error when it cannot be read or may not be. }
    function ReadLocalFile(constref Url: TUrlRecord; out Contents: TBytes; out IsFolder: Boolean;
      out Error: string): Boolean; virtual; abstract;
  end;

implementation

procedure TNetworkTransport.OpenWebSocket(constref Request: TWebSocketOpenRequest; SocketId: QWord;
  Sink: TWebSocketEventSink);
begin
  Sink.SocketClosed(SocketId, False, 1006, '', True);
end;

procedure TNetworkTransport.SendWebSocket(Sink: TWebSocketEventSink; SocketId: QWord; IsText: Boolean;
  const Data: TBytes);
begin
end;

procedure TNetworkTransport.CloseWebSocket(Sink: TWebSocketEventSink; SocketId: QWord; Code: Word;
  const Reason: string);
begin
end;

procedure TNetworkTransport.AbortWebSocket(Sink: TWebSocketEventSink; SocketId: QWord);
begin
end;

end.
