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
  A request and its response, whatever version carries them.

  THttpRequest: method, URL, header fields, content, priority, and how
  the client is to treat it (redirects, the cache, credentials, its
  cookie circumstances, decoding).

  THttpResponse: status, fields, the final URL and the URLs it was
  redirected through, the version and whether the connection was
  reused or the cache answered; its content is read with Read (as sent:
  still content-coded) until 0. Freeing a response ends its exchange:
  the connection goes back to the pool when the content was read whole,
  and is closed (HTTP/1.1) or the stream reset (HTTP/2) otherwise.
  Discard reads a small unread content away first so the connection
  can be kept. Abort stops it from another thread.

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.Messages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http.ConnectionPool,
  Http.Connections,
  Http.Cookies,
  Http.HeaderFields,
  Http.Priorities,
  Http.RequestBodies,
  Http.Results,
  Url.Records;

const
  { A larger unwanted body is not read: the connection is closed. }
  MaximumDiscardedBody = 1024 * 1024;

type
  THttpRedirectMode = (RedirectFollow, RedirectError, RedirectManual);
  THttpCacheMode = (CacheModeDefault, CacheModeNoStore, CacheModeReload, CacheModeNoCache, CacheModeForceCache,
    CacheModeOnlyIfCached);
  THttpCredentialsMode = (CredentialsOmit, CredentialsSameOrigin, CredentialsInclude);

  THttpRequest = class
  private
    FHeaders: THttpHeaders;
    FBody: THttpRequestBody;
    FOwnsBody: Boolean;
  public
    Method: string;
    Url: TUrlRecord;
    Priority: THttpPriority;
    RedirectMode: THttpRedirectMode;
    { -1: the client's setting. }
    MaximumRedirects: Integer;
    CacheMode: THttpCacheMode;
    CredentialsMode: THttpCredentialsMode;
    CookieContext: TCookieRequestContext;
    { Fetch undoes content codings (Accept-Encoding is sent). }
    DecodeContent: Boolean;
    { "Connection: close" over HTTP/1.1. }
    CloseConnection: Boolean;
    constructor Create(const AMethod: string; constref AUrl: TUrlRecord);
    { False if Text is not a URL. }
    class function FromText(const AMethod, Text: string; out Request: THttpRequest): Boolean;
    destructor Destroy; override;
    procedure SetBody(Body: THttpRequestBody; OwnsBody: Boolean = True);
    property Headers: THttpHeaders read FHeaders;
    property Body: THttpRequestBody read FBody;
  end;

  THttpResponse = class
  private
    FHeaders: THttpHeaders;
    FExchange: THttpExchange;
    FConnection: THttpConnection;
    FPool: THttpConnectionPool;
    FLastResult: THttpResult;
    FCachedBody: TBytes;
    FCachedPosition: Integer;
    FFromCache: Boolean;
    FFinished: Boolean;
    FLock: TRTLCriticalSection;
  public
    Status: Integer;
    Reason: string;
    { 10, 11, 20 or 30. }
    Version: Integer;
    Protocol: THttpProtocol;
    RawHead: string;
    { The URL that answered (after redirects). }
    Url: TUrlRecord;
    { Every URL of the request, the first one first. }
    UrlList: array of TUrlRecord;
    { -1 when unknown. }
    ContentLength: Int64;
    ConnectionReused: Boolean;
    { The request that got this response carried an Authorization. }
    SentAuthorization: Boolean;
    constructor Create;
    destructor Destroy; override;
    { Ties the response to an exchange (released into Pool when done). }
    procedure Attach(Exchange: THttpExchange; Connection: THttpConnection; Pool: THttpConnectionPool);
    { Content from the cache instead of a connection. }
    procedure AttachCachedBody(const Body: TBytes);
    procedure ApplyHead(constref Head: THttpResponseHeadInfo);
    { Content bytes (still content-coded); 0 at the end; -1 on a failure. }
    function Read(Buffer: Pointer; Count: PtrUInt): Int64;
    { All the content (up to Limit bytes; 0: no limit) as a string. }
    function ReadAll(out Text: string; Limit: Int64 = 0): Boolean;
    { Reads an unwanted content away (when it is short) so the connection
      can carry more; True if it could. }
    function Discard: Boolean;
    function BodyComplete: Boolean;
    function Trailers: THttpHeaderFieldArray;
    { Ends the exchange now (freeing does it too). }
    procedure Finish;
    procedure Abort;
    procedure Reprioritize(constref NewPriority: THttpPriority);
    property Headers: THttpHeaders read FHeaders;
    property LastResult: THttpResult read FLastResult;
    property FromCache: Boolean read FFromCache;
  end;

implementation

uses
  Http.StatusCodes,
  Url.Parser;

{ THttpRequest }

constructor THttpRequest.Create(const AMethod: string; constref AUrl: TUrlRecord);
begin
  inherited Create;
  Method := AMethod;
  Url := AUrl;
  FHeaders := THttpHeaders.Create;
  Priority := DefaultPriority;
  MaximumRedirects := -1;
  CredentialsMode := CredentialsInclude;
  CookieContext := DirectRequestContext((AUrl.Scheme = 'https') or (AUrl.Scheme = 'wss'));
  DecodeContent := True;
end;

class function THttpRequest.FromText(const AMethod, Text: string; out Request: THttpRequest): Boolean;
var
  Parsed: TUrlRecord;
begin
  Request := nil;
  Result := ParseUrl(Text, Parsed);
  if Result then
    Request := THttpRequest.Create(AMethod, Parsed);
end;

destructor THttpRequest.Destroy;
begin
  if FOwnsBody then
    FBody.Free;
  FHeaders.Free;
  inherited Destroy;
end;

procedure THttpRequest.SetBody(Body: THttpRequestBody; OwnsBody: Boolean);
begin
  if FOwnsBody and (FBody <> Body) then
    FBody.Free;
  FBody := Body;
  FOwnsBody := OwnsBody;
end;

{ THttpResponse }

constructor THttpResponse.Create;
begin
  inherited Create;
  FHeaders := THttpHeaders.Create;
  ContentLength := -1;
  InitCriticalSection(FLock);
end;

destructor THttpResponse.Destroy;
begin
  Finish;
  FHeaders.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure THttpResponse.Attach(Exchange: THttpExchange; Connection: THttpConnection; Pool: THttpConnectionPool);
begin
  FExchange := Exchange;
  FConnection := Connection;
  FPool := Pool;
  if Connection <> nil then
    Protocol := Connection.Protocol;
end;

procedure THttpResponse.AttachCachedBody(const Body: TBytes);
begin
  FCachedBody := Body;
  FCachedPosition := 0;
  FFromCache := True;
  ContentLength := Length(Body);
end;

procedure THttpResponse.ApplyHead(constref Head: THttpResponseHeadInfo);
var
  Field: THttpHeaderField;
begin
  Status := Head.Status;
  Reason := Head.Reason;
  if (Reason = '') and (Head.Version >= 20) then
    Reason := ReasonPhrase(Head.Status);
  Version := Head.Version;
  RawHead := Head.RawHead;
  ContentLength := Head.ContentLength;
  FHeaders.Clear;
  for Field in Head.Fields do
    FHeaders.Add(Field.Name, Field.Value);
end;

function THttpResponse.Read(Buffer: Pointer; Count: PtrUInt): Int64;
var
  Available: Integer;
begin
  if FFromCache then
  begin
    Available := Length(FCachedBody) - FCachedPosition;
    if Int64(Available) > Int64(Count) then
      Available := Count;
    if Available > 0 then
    begin
      Move(FCachedBody[FCachedPosition], Buffer^, Available);
      Inc(FCachedPosition, Available);
    end;
    Exit(Available);
  end;
  if (FExchange = nil) or FFinished then
    Exit(0);
  Result := FExchange.ReadBody(Buffer, Count);
  if Result < 0 then
    FLastResult := FExchange.LastResult;
end;

function THttpResponse.ReadAll(out Text: string; Limit: Int64): Boolean;
var
  Buffer: array[0..16383] of Char;
  Count: Int64;
  Piece: string;
begin
  Text := '';
  repeat
    Count := Read(@Buffer[0], SizeOf(Buffer));
    if Count > 0 then
    begin
      SetString(Piece, PChar(@Buffer[0]), Count);
      Text := Text + Piece;
      if (Limit > 0) and (Length(Text) > Limit) then
        Exit(False);
    end;
  until Count <= 0;
  Result := Count = 0;
end;

function THttpResponse.Discard: Boolean;
var
  Buffer: array[0..16383] of Byte;
  Count, Total: Int64;
begin
  if FFromCache or (FExchange = nil) then
    Exit(True);
  if StatusHasNoBody(Status) then
    Exit(FExchange.BodyComplete);
  if (ContentLength > MaximumDiscardedBody) or ((ContentLength < 0) and (Protocol = HttpProtocol11) and
     not FHeaders.Has('transfer-encoding')) then
    Exit(False);
  Total := 0;
  repeat
    Count := Read(@Buffer[0], SizeOf(Buffer));
    if Count > 0 then
      Inc(Total, Count);
    if Total > MaximumDiscardedBody then
      Exit(False);
  until Count <= 0;
  Result := (Count = 0) and FExchange.BodyComplete;
end;

function THttpResponse.BodyComplete: Boolean;
begin
  if FFromCache then
    Result := FCachedPosition >= Length(FCachedBody)
  else
    Result := (FExchange <> nil) and FExchange.BodyComplete;
end;

function THttpResponse.Trailers: THttpHeaderFieldArray;
begin
  if FExchange <> nil then
    Result := FExchange.Trailers
  else
    Result := nil;
end;

procedure THttpResponse.Finish;
var
  Exchange: THttpExchange;
begin
  EnterCriticalSection(FLock);
  try
    if FFinished then
      Exit;
    FFinished := True;
    Exchange := FExchange;
    FExchange := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Exchange <> nil then
  begin
    Exchange.Finish;
    Exchange.Free;
    if (FPool <> nil) and (FConnection <> nil) then
      FPool.Release(FConnection);
  end;
end;

procedure THttpResponse.Abort;
begin
  EnterCriticalSection(FLock);
  try
    if FExchange <> nil then
      FExchange.Abort;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THttpResponse.Reprioritize(constref NewPriority: THttpPriority);
begin
  if FExchange <> nil then
    FExchange.Reprioritize(NewPriority);
end;

end.
