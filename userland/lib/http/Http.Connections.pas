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
  What every HTTP version offers the rest of the library, so requests
  do not care which one carries them:

    THttpConnection  a connection to one origin; starts exchanges (one
                     at a time for HTTP/1.1, many at once for HTTP/2
                     and HTTP/3);
    THttpExchange    one request and its response on a connection:
                     Send (head and content), ReceiveHead (interim 1xx
                     responses skipped), ReadBody (the content as sent,
                     framing removed), Finish (the connection kept or
                     closed), Abort (from any thread).

  HTTP/1.1 (Http.Http1Connections) and HTTP/2 (Http.Http2Connections)
  are here; HTTP/3 (libquic's Http3 units) plugs in with a connection
  class of its own, made by the factory registered for "h3"
  (Http.AltServices).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Connections;

{$mode objfpc}
{$H+}

interface

uses
  Http.HeaderFields,
  Http.Priorities,
  Http.RequestBodies,
  Http.Results;

type
  THttpProtocol = (HttpProtocol11, HttpProtocol2, HttpProtocol3);
  THttpProtocols = set of THttpProtocol;

  { A request as it goes out, the same for every version. }
  THttpRequestHead = record
    Method: string;
    Scheme: string;
    { host[:port] as the Host field or :authority carries it. }
    Authority: string;
    { The path and query ("*" for OPTIONS * ). }
    Target: string;
    { Lower case names; no Host, no connection-specific fields. }
    Fields: THttpHeaderFieldArray;
    Priority: THttpPriority;
    { nil: no content. Not owned. }
    Body: THttpRequestBody;
    { HTTP/1.1: "Connection: close" (the connection ends with this one). }
    CloseConnection: Boolean;
  end;

  { A response head, the same for every version. }
  THttpResponseHeadInfo = record
    Status: Integer;
    { HTTP/1.x's reason phrase; '' over HTTP/2 and HTTP/3. }
    Reason: string;
    { 10 or 11 for HTTP/1.x, 20, 30. }
    Version: Integer;
    Fields: THttpHeaderFieldArray;
    { The head as received (HTTP/1.x), or as HTTP/2 and HTTP/3 would
      show it ("HTTP/2 200" and "name: value" lines), for -S. }
    RawHead: string;
    { -1 when unknown. }
    ContentLength: Int64;
  end;

  THttpExchange = class
  protected
    FLastResult: THttpResult;
    function Failed(Code: THttpResultCode; const Text: string; ErrorCode: LongInt = 0): THttpResult;
  public
    function Send(constref Head: THttpRequestHead): THttpResult; virtual; abstract;
    function ReceiveHead(out Head: THttpResponseHeadInfo): THttpResult; virtual; abstract;
    { Content bytes; 0 at the end; -1 on a failure (LastResult). }
    function ReadBody(Buffer: Pointer; Count: PtrUInt): Int64; virtual; abstract;
    { The body was read to its end (the connection can go on). }
    function BodyComplete: Boolean; virtual; abstract;
    { Trailer fields (after the body), if any came. }
    function Trailers: THttpHeaderFieldArray; virtual;
    { Ends the exchange. The connection stays for more only when the body
      was read whole and the server lets it. Frees nothing. }
    procedure Finish; virtual; abstract;
    { Stops the exchange from any thread: a blocked read returns. }
    procedure Abort; virtual; abstract;
    { Changes the priority while the response comes (RFC 9218). }
    procedure Reprioritize(constref Priority: THttpPriority); virtual;
    property LastResult: THttpResult read FLastResult;
  end;

  THttpConnection = class
  protected
    FProtocol: THttpProtocol;
    FOriginKey: string;
    FIdleSince: QWord;
    FExchangesStarted: Integer;
  public
    { A new exchange, or nil when the connection cannot take one now
      (busy, closing or closed). The caller frees it after Finish. }
    function StartExchange: THttpExchange; virtual; abstract;
    { Can take a request now or soon (not closed, not going away). }
    function IsUsable: Boolean; virtual; abstract;
    { No exchange in progress. }
    function IsIdle: Boolean; virtual; abstract;
    { Several exchanges at once. }
    function IsMultiplexed: Boolean; virtual;
    procedure Close; virtual; abstract;
    property Protocol: THttpProtocol read FProtocol;
    { "https://host:port" }
    property OriginKey: string read FOriginKey write FOriginKey;
    { UptimeMilliseconds when it last became idle (set by the pool). }
    property IdleSince: QWord read FIdleSince write FIdleSince;
    { How many exchanges it has carried. }
    property ExchangesStarted: Integer read FExchangesStarted;
  end;

function ProtocolName(Protocol: THttpProtocol): string;

implementation

function ProtocolName(Protocol: THttpProtocol): string;
begin
  case Protocol of
    HttpProtocol2: Result := 'h2';
    HttpProtocol3: Result := 'h3';
  else
    Result := 'http/1.1';
  end;
end;

function THttpExchange.Failed(Code: THttpResultCode; const Text: string; ErrorCode: LongInt): THttpResult;
begin
  FLastResult := HttpFailure(Code, Text, ErrorCode);
  Result := FLastResult;
end;

function THttpExchange.Trailers: THttpHeaderFieldArray;
begin
  Result := nil;
end;

procedure THttpExchange.Reprioritize(constref Priority: THttpPriority);
begin
end;

function THttpConnection.IsMultiplexed: Boolean;
begin
  Result := False;
end;

end.
