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
  libhttp's HTTP/1.1 and HTTP/2 connections against the small servers
  (HttpTest.Http1Server, HttpTest.Http2Server) over in-memory pipes:
  bodies of every framing, interim responses, request content of known
  and unknown length, keep-alive, HEAD; for HTTP/2 flow control both
  ways (a 3 MiB response, a 200 KB upload into a 64 KB window), several
  threads sharing one connection, out-of-order answers, trailers,
  CONTINUATION, a refused stream, a malformed response, priorities and
  GOAWAY.
}
unit HttpTest.Loopback;

{$mode objfpc}
{$H+}

interface

procedure TestLoopback;

implementation

uses
  Classes,
  SysUtils,
  StrUtils,
  TestChecks,
  HttpTest.Http1Server,
  HttpTest.Http2Server,
  HttpTest.Pipes,
  Http.Connections,
  Http.HeaderFields,
  Http.Http1Connections,
  Http.Http2Connections,
  Http.Priorities,
  Http.RequestBodies,
  Http.Results;

type
  TExchangeOutcome = record
    Result: THttpResult;
    Head: THttpResponseHeadInfo;
    Body: string;
    Complete: Boolean;
    Trailers: THttpHeaderFieldArray;
  end;

function MakeHead(const Method, Target: string; Body: THttpRequestBody = nil): THttpRequestHead;
begin
  Result := Default(THttpRequestHead);
  Result.Method := Method;
  Result.Scheme := 'https';
  Result.Authority := 'test.example';
  Result.Target := Target;
  Result.Priority := DefaultPriority;
  Result.Body := Body;
end;

function RunExchange(Connection: THttpConnection; constref Head: THttpRequestHead): TExchangeOutcome;
var
  Exchange: THttpExchange;
  Buffer: array[0..8191] of Char;
  Count: Int64;
  Piece: string;
begin
  Result := Default(TExchangeOutcome);
  Exchange := Connection.StartExchange;
  if Exchange = nil then
  begin
    Result.Result := HttpFailure(HttpProtocolError, 'no exchange');
    Exit;
  end;
  try
    Result.Result := Exchange.Send(Head);
    if HttpSucceeded(Result.Result) then
      Result.Result := Exchange.ReceiveHead(Result.Head);
    if HttpSucceeded(Result.Result) then
    begin
      repeat
        Count := Exchange.ReadBody(@Buffer[0], SizeOf(Buffer));
        if Count > 0 then
        begin
          SetString(Piece, PChar(@Buffer[0]), Count);
          Result.Body := Result.Body + Piece;
        end;
      until Count <= 0;
      if Count < 0 then
        Result.Result := Exchange.LastResult;
      Result.Complete := Exchange.BodyComplete;
      Result.Trailers := Exchange.Trailers;
    end;
    Exchange.Finish;
  finally
    Exchange.Free;
  end;
end;

{ A body that does not say its length (HTTP/1.1 chunks it). }
function ProduceUnknown(Context: Pointer; Buffer: Pointer; Count: Integer): Integer;
var
  Remaining: PInteger;
begin
  Remaining := Context;
  if Remaining^ = 0 then
    Exit(0);
  Result := 3;
  Move(PChar('abc')^, Buffer^, 3);
  Dec(Remaining^);
end;

procedure TestHttp1;
var
  Pair: TPipePair;
  Server: THttp1TestServer;
  Connection: THttp1Connection;
  Outcome: TExchangeOutcome;
  Body: THttpRequestBody;
  Pieces: Integer;
  Head: THttpRequestHead;
begin
  Pair := TPipePair.Create('http/1.1');
  Server := THttp1TestServer.Create(Pair.Server);
  Connection := THttp1Connection.Create(Pair.Client, 'https://test.example');
  try
    Outcome := RunExchange(Connection, MakeHead('GET', '/hello'));
    Check(HttpSucceeded(Outcome.Result) and (Outcome.Head.Status = 200) and (Outcome.Body = 'hello') and
      Outcome.Complete and (Outcome.Head.ContentLength = 5), 'HTTP/1.1: a body with Content-Length');
    Check((Outcome.Head.Reason = 'OK') and (Outcome.Head.Version = 11) and
      (FieldsValue(Outcome.Head.Fields, 'content-type') = 'text/plain'), 'HTTP/1.1: the head''s fields');
    Check(Connection.IsUsable and Connection.IsIdle, 'HTTP/1.1: the connection kept');
    Outcome := RunExchange(Connection, MakeHead('HEAD', '/hello'));
    Check((Outcome.Head.Status = 200) and (Outcome.Body = '') and Outcome.Complete, 'HTTP/1.1: HEAD has no body');
    Outcome := RunExchange(Connection, MakeHead('GET', '/chunked'));
    Check((Outcome.Body = 'Wikipedia') and Outcome.Complete, 'HTTP/1.1: a chunked body');
    Outcome := RunExchange(Connection, MakeHead('GET', '/interim'));
    Check((Outcome.Head.Status = 200) and (Outcome.Body = 'ok') and (Pos('100 Continue', Outcome.Head.RawHead) > 0),
      'HTTP/1.1: an interim response skipped, kept in the raw head');
    Body := THttpBytesBody.Create('form=data', 'application/x-www-form-urlencoded');
    Outcome := RunExchange(Connection, MakeHead('POST', '/echo', Body));
    Body.Free;
    Check(Outcome.Body = 'POST form=data', 'HTTP/1.1: content with a length');
    Pieces := 4;
    Body := THttpCallbackBody.Create(@ProduceUnknown, nil, @Pieces, -1);
    Outcome := RunExchange(Connection, MakeHead('PUT', '/echo', Body));
    Body.Free;
    Check(Outcome.Body = 'PUT abcabcabcabc', 'HTTP/1.1: content of unknown length, chunked');
    Outcome := RunExchange(Connection, MakeHead('GET', '/count'));
    Check(Outcome.Body = '7', 'HTTP/1.1: seven requests over one connection');
    Outcome := RunExchange(Connection, MakeHead('GET', '/until-close'));
    Check((Outcome.Body = 'all of it') and Outcome.Complete and not Connection.IsUsable,
      'HTTP/1.1: a body to the end of the connection, which is then closed');
    Check(Connection.StartExchange = nil, 'HTTP/1.1: a closed connection takes no exchange');
  finally
    Connection.Free;
    Server.WaitFor;
    Server.Free;
    Pair.Free;
  end;
  Pair := TPipePair.Create('http/1.1');
  Server := THttp1TestServer.Create(Pair.Server);
  Connection := THttp1Connection.Create(Pair.Client, 'https://test.example');
  try
    Head := MakeHead('GET', '/hello');
    Head.CloseConnection := True;
    Outcome := RunExchange(Connection, Head);
    Check((Outcome.Body = 'hello') and not Connection.IsUsable, 'HTTP/1.1: Connection: close ends the connection');
  finally
    Connection.Free;
    Server.WaitFor;
    Server.Free;
    Pair.Free;
  end;
end;

type
  TParallelFetch = class(TThread)
  public
    Connection: THttpConnection;
    Path: string;
    Repeats: Integer;
    Bodies: string;
    Failures: Integer;
  protected
    procedure Execute; override;
  end;

procedure TParallelFetch.Execute;
var
  Index: Integer;
  Outcome: TExchangeOutcome;
begin
  for Index := 1 to Repeats do
  begin
    Outcome := RunExchange(Connection, MakeHead('GET', Path));
    if not HttpSucceeded(Outcome.Result) then
      Inc(Failures);
    Bodies := Bodies + Outcome.Body + ';';
  end;
end;

function StartFetch(Connection: THttpConnection; const Path: string; Repeats: Integer): TParallelFetch;
begin
  Result := TParallelFetch.Create(True);
  Result.Connection := Connection;
  Result.Path := Path;
  Result.Repeats := Repeats;
  Result.Start;
end;

procedure TestHttp2Parallel(Connection: THttp2Connection);
var
  Fetches: array[0..3] of TParallelFetch;
  Index: Integer;
  AllGood: Boolean;
  Hold, Release: TParallelFetch;
begin
  for Index := 0 to High(Fetches) do
    Fetches[Index] := StartFetch(Connection, '/hello', 10);
  AllGood := True;
  for Index := 0 to High(Fetches) do
  begin
    Fetches[Index].WaitFor;
    if (Fetches[Index].Failures <> 0) or (Fetches[Index].Bodies <> DupeString('hello;', 10)) then
      AllGood := False;
    Fetches[Index].Free;
  end;
  Check(AllGood, 'HTTP/2: four threads, forty requests on one connection');
  Hold := StartFetch(Connection, '/hold', 1);
  Sleep(100);
  Release := StartFetch(Connection, '/release', 1);
  Release.WaitFor;
  Hold.WaitFor;
  Check((Hold.Bodies = 'held;') and (Release.Bodies = 'released;'), 'HTTP/2: an answer that comes after a later one');
  Hold.Free;
  Release.Free;
end;

procedure TestHttp2;
var
  Pair: TPipePair;
  Server: THttp2TestServer;
  Connection: THttp2Connection;
  Outcome: TExchangeOutcome;
  Body: THttpRequestBody;
  Upload: string;
  Head: THttpRequestHead;
  Index: Integer;
begin
  Pair := TPipePair.Create('h2');
  Server := THttp2TestServer.Create(Pair.Server);
  Connection := THttp2Connection.Create(Pair.Client, 'https://test.example');
  try
    Check(HttpSucceeded(Connection.Open), 'HTTP/2: preface and SETTINGS sent');
    Outcome := RunExchange(Connection, MakeHead('GET', '/hello'));
    Check(HttpSucceeded(Outcome.Result) and (Outcome.Head.Status = 200) and (Outcome.Body = 'hello') and
      Outcome.Complete and (Outcome.Head.Version = 20), 'HTTP/2: a GET');
    Check(Pos('HTTP/2 200'#13#10, Outcome.Head.RawHead) = 1, 'HTTP/2: a raw head made up for showing');
    Check(Connection.PeerMaximumConcurrentStreams = 16, 'HTTP/2: the server''s SETTINGS applied');
    Outcome := RunExchange(Connection, MakeHead('HEAD', '/hello'));
    Check((Outcome.Head.Status = 200) and (Outcome.Body = '') and Outcome.Complete, 'HTTP/2: HEAD');
    Outcome := RunExchange(Connection, MakeHead('GET', '/big'));
    Check(HttpSucceeded(Outcome.Result) and (Length(Outcome.Body) = 3 * 1024 * 1024) and
      (Outcome.Body[3 * 1024 * 1024] = Chr(Ord('a') + (3 * 1024 * 1024) mod 26)),
      'HTTP/2: 3 MiB through a 1 MiB stream window');
    SetLength(Upload, 200000);
    for Index := 1 to Length(Upload) do
      Upload[Index] := Chr(Ord('0') + Index mod 10);
    Body := THttpBytesBody.Create(Upload);
    Outcome := RunExchange(Connection, MakeHead('POST', '/echo', Body));
    Body.Free;
    Check(Outcome.Body = 'POST ' + Upload, 'HTTP/2: a 200 KB upload into a 64 KB window');
    Outcome := RunExchange(Connection, MakeHead('GET', '/trailers'));
    Check((Outcome.Body = 'body') and (FieldsValue(Outcome.Trailers, 'x-checksum') = 'abc'), 'HTTP/2: trailers');
    Outcome := RunExchange(Connection, MakeHead('GET', '/continuation'));
    Check((Outcome.Body = 'ok') and (Length(FieldsValue(Outcome.Head.Fields, 'x-large')) = 30000),
      'HTTP/2: a head in HEADERS and CONTINUATION frames');
    Outcome := RunExchange(Connection, MakeHead('GET', '/reset'));
    Check((Outcome.Result.Code = HttpStreamReset) and Outcome.Result.Retryable, 'HTTP/2: REFUSED_STREAM is retryable');
    Outcome := RunExchange(Connection, MakeHead('GET', '/malformed'));
    Check(Outcome.Result.Code = HttpMalformedResponse, 'HTTP/2: an upper case field name refused');
    Head := MakeHead('GET', '/priority');
    Head.Priority := MakePriority(1, True);
    Outcome := RunExchange(Connection, Head);
    Check(Outcome.Body = 'u=1, i', 'HTTP/2: the Priority field sent');
    Check(Connection.IsUsable, 'HTTP/2: stream errors leave the connection usable');
    TestHttp2Parallel(Connection);
    Outcome := RunExchange(Connection, MakeHead('GET', '/count'));
    Check(Outcome.Body = '52', 'HTTP/2: every request on the one connection');
    Outcome := RunExchange(Connection, MakeHead('GET', '/goaway'));
    Check((Outcome.Result.Code = HttpStreamReset) and Outcome.Result.Retryable and not Connection.IsUsable,
      'HTTP/2: GOAWAY: the stream past its last id is retryable, the connection takes no more');
  finally
    Connection.Free;
    Server.WaitFor;
    Server.Free;
    Pair.Free;
  end;
end;

procedure TestLoopback;
begin
  TestHttp1;
  TestHttp2;
end;

end.
