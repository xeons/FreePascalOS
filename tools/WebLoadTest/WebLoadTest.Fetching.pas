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
  The fetcher against the in-process site: the fields it sends,
  redirects, CORS with and without preflights (and the preflight cache),
  mixed content, HSTS, no-cors opaque responses, sniffing, nosniff,
  data: and about:blank, file: URLs, bodies arriving in pieces,
  cancelling, and consumers freed while their jobs still run.
}
unit WebLoadTest.Fetching;

{$mode objfpc}
{$H+}

interface

procedure RunFetchingTests;

implementation

uses
  Classes,
  SysUtils,
  SyncObjs,
  TestChecks,
  Url.Records,
  Url.Parser,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Jobs,
  Web.Fetch.ContentSecurityPolicy,
  WebLoadTest.Server;

type
  TRecordingConsumer = class(TFetchConsumer)
  public
    Log: string;
    Body: string;
    ResponseType: TFetchResponseType;
    Status: Integer;
    Essence: string;
    ErrorText: string;
    UrlCount: Integer;
    FinalUrl: string;
    Ended: Boolean;
    Succeeded: Boolean;
    Pieces: Integer;
    CancelOnResponse: Boolean;
    Fetcher: TObject;
    procedure ProcessResponse(Job: TFetchJob; Response: TFetchResponse); override;
    procedure ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt); override;
    procedure ProcessEndOfBody(Job: TFetchJob; Success: Boolean); override;
    function IsEnded: Boolean;
    function HasPiece: Boolean;
  end;

  { Frees itself when a network error reaches it (as a script fetch's
    consumer may, from inside the call); counts what it heard. }
  TSelfFreeingConsumer = class(TFetchConsumer)
  public
    procedure ProcessResponse(Job: TFetchJob; Response: TFetchResponse); override;
    procedure ProcessEndOfBody(Job: TFetchJob; Success: Boolean); override;
  end;

var
  Environment: TTestEnvironment;
  SelfFreeingResponses: Integer;
  SelfFreeingEnds: Integer;

procedure TSelfFreeingConsumer.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
  Inc(SelfFreeingResponses);
  if Response.IsNetworkError then
    Free;
end;

procedure TSelfFreeingConsumer.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
  Inc(SelfFreeingEnds);
end;

type
  TFreedConsumerWatch = class
  public
    Key: string;
    function RequestSeen: Boolean;
    function SelfFreeingHeard: Boolean;
  end;

function TFreedConsumerWatch.RequestSeen: Boolean;
begin
  Result := Environment.Site.RequestCount(Key) > 0;
end;

function TFreedConsumerWatch.SelfFreeingHeard: Boolean;
begin
  Result := SelfFreeingResponses > 0;
end;

procedure TRecordingConsumer.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
  Log := Log + 'response ';
  ResponseType := Response.ResponseType;
  Status := Response.Status;
  Essence := Response.ComputedEssence;
  ErrorText := Response.ErrorText;
  UrlCount := Length(Response.UrlList);
  if Response.HasUrl then
    FinalUrl := SerializeUrl(Response.Url);
  if CancelOnResponse then
  begin
    Environment.Fetcher.Cancel(Job);
    Ended := True;
  end;
end;

procedure TRecordingConsumer.ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
var
  Text: string;
begin
  SetString(Text, PChar(Data), Count);
  Body := Body + Text;
  Inc(Pieces);
end;

procedure TRecordingConsumer.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
  Log := Log + 'end';
  Ended := True;
  Succeeded := Success;
end;

function TRecordingConsumer.IsEnded: Boolean;
begin
  Result := Ended;
end;

function TRecordingConsumer.HasPiece: Boolean;
begin
  Result := Body <> '';
end;

function MakeUrl(const Text: string): TUrlRecord;
begin
  if not ParseUrl(Text, Result) then
    raise Exception.Create('bad test URL ' + Text);
end;

function NewRequest(const Text: string; Client: TFetchClient; Mode: TFetchMode;
  Destination: TFetchDestination): TFetchRequest;
begin
  Result := TFetchRequest.Create('GET', MakeUrl(Text));
  Result.Client := Client;
  Result.Mode := Mode;
  Result.Destination := Destination;
end;

{ Runs a request to its end; the consumer has the results. }
function RunFetch(Request: TFetchRequest): TRecordingConsumer;
begin
  Result := TRecordingConsumer.Create;
  Environment.Fetcher.Fetch(Request, Result);
  if not Environment.RunUntil(@Result.IsEnded) then
    Result.Log := Result.Log + ' (timed out)';
end;

procedure CheckBasicFetch(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Head: string;
  Started: Integer;
begin
  Environment.Site.AddRoute('a.test/style.css', 200, 'Content-Type: text/css; charset=utf-8', 'p { color: red }');
  Consumer := TRecordingConsumer.Create;
  Environment.Fetcher.Fetch(NewRequest('https://a.test/style.css', Client, FetchModeNoCors, DestinationStyle),
    Consumer);
  Started := Length(Consumer.Log);
  Check(Started = 0, 'fetch: nothing happens inside Fetch');
  Environment.RunUntil(@Consumer.IsEnded);
  Check((Consumer.Log = 'response end') and Consumer.Succeeded, 'fetch: response, body, end (' + Consumer.Log + ')');
  Check((Consumer.Status = 200) and (Consumer.Body = 'p { color: red }') and (Consumer.Essence = 'text/css') and
    (Consumer.ResponseType = ResponseTypeBasic), 'fetch: same origin basic response');
  Head := Environment.Site.LastHead('a.test/style.css');
  Check(HeadField(Head, 'Accept') = 'text/css,*/*;q=0.1', 'fetch: Accept for a style sheet');
  Check(HeadField(Head, 'Referer') = 'https://a.test/page.html', 'fetch: Referer');
  Check((HeadField(Head, 'Sec-Fetch-Dest') = 'style') and (HeadField(Head, 'Sec-Fetch-Mode') = 'no-cors') and
    (HeadField(Head, 'Sec-Fetch-Site') = 'same-origin'), 'fetch: Sec-Fetch fields');
  Check(HeadField(Head, 'Origin') = '', 'fetch: no Origin on a no-cors GET');
  Check(HeadField(Head, 'Accept-Language') <> '', 'fetch: Accept-Language');
  Consumer.Free;
end;

procedure CheckRedirects(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Request: TFetchRequest;
begin
  Environment.Site.AddRoute('a.test/old', 301, 'Location: /middle', '');
  Environment.Site.AddRoute('a.test/middle', 302, 'Location: https://b.test/new|Referrer-Policy: no-referrer', 'x');
  Environment.Site.AddRoute('b.test/new', 200, 'Content-Type: text/plain', 'arrived');
  Consumer := RunFetch(NewRequest('https://a.test/old', Client, FetchModeNoCors, DestinationImage));
  Check((Consumer.Body = 'arrived') and (Consumer.UrlCount = 3) and (Consumer.FinalUrl = 'https://b.test/new'),
    'redirects: followed, URL list (' + Consumer.Log + ' ' + Consumer.FinalUrl + ')');
  Check(Consumer.ResponseType = ResponseTypeOpaque, 'redirects: cross-origin no-cors is opaque');
  Check(HeadField(Environment.Site.LastHead('b.test/new'), 'Referer') = '', 'redirects: Referrer-Policy applied');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/form', 303, 'Location: /done', '');
  Environment.Site.AddRoute('a.test/done', 200, 'Content-Type: text/plain', 'ok');
  Request := NewRequest('https://a.test/form', Client, FetchModeSameOrigin, DestinationEmpty);
  Request.Method := 'POST';
  Request.Body := TEncoding.UTF8.GetAnsiBytes('a=1');
  Request.HasBody := True;
  Request.Headers.SetValue('content-type', 'application/x-www-form-urlencoded');
  Consumer := RunFetch(Request);
  Check((Consumer.Body = 'ok') and (Environment.Site.RequestCount('POST https://a.test/form') = 1) and
    (Environment.Site.RequestCount('GET https://a.test/done') = 1), 'redirects: 303 turns POST into GET');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/loop', 302, 'Location: /loop', '');
  Consumer := RunFetch(NewRequest('https://a.test/loop', Client, FetchModeNoCors, DestinationEmpty));
  Check((Consumer.ResponseType = ResponseTypeError) and (Pos('too many', Consumer.ErrorText) > 0) and
    not Consumer.Succeeded, 'redirects: at most 20');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/tofile', 302, 'Location: file:///etc/passwd', '');
  Consumer := RunFetch(NewRequest('https://a.test/tofile', Client, FetchModeNoCors, DestinationEmpty));
  Check(Consumer.ResponseType = ResponseTypeError, 'redirects: not to file:');
  Consumer.Free;
end;

procedure CheckCors(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Request: TFetchRequest;
  Head: string;
begin
  Environment.Site.AddRoute('api.test/closed', 200, 'Content-Type: text/plain', 'secret');
  Consumer := RunFetch(NewRequest('https://api.test/closed', Client, FetchModeCors, DestinationEmpty));
  Check((Consumer.ResponseType = ResponseTypeError) and (Consumer.Body = ''), 'cors: no ACAO is a network error');
  Head := Environment.Site.LastHead('api.test/closed');
  Check(HeadField(Head, 'Origin') = 'https://a.test', 'cors: Origin sent');
  Consumer.Free;

  Environment.Site.AddRoute('api.test/open', 200, 'Content-Type: text/plain|Access-Control-Allow-Origin: *', 'public');
  Consumer := RunFetch(NewRequest('https://api.test/open', Client, FetchModeCors, DestinationEmpty));
  Check((Consumer.ResponseType = ResponseTypeCors) and (Consumer.Body = 'public'), 'cors: * allows it');
  Consumer.Free;

  Request := NewRequest('https://api.test/open', Client, FetchModeCors, DestinationEmpty);
  Request.Credentials := FetchCredentialsInclude;
  Consumer := RunFetch(Request);
  Check(Consumer.ResponseType = ResponseTypeError, 'cors: * with credentials fails');
  Consumer.Free;

  Environment.Site.AddRoute('api.test/put', 204, 'Access-Control-Allow-Origin: https://a.test|' +
    'Access-Control-Allow-Methods: PUT|Access-Control-Allow-Headers: x-token|Access-Control-Max-Age: 60', '');
  Request := NewRequest('https://api.test/put', Client, FetchModeCors, DestinationEmpty);
  Request.Method := 'PUT';
  Request.Headers.SetValue('X-Token', 'abc');
  Consumer := RunFetch(Request);
  Check((Consumer.Status = 204) and (Consumer.ResponseType = ResponseTypeCors), 'cors: PUT after a preflight (' +
    Consumer.ErrorText + ')');
  Head := Environment.Site.LastHead('OPTIONS https://api.test/put');
  Check((HeadField(Head, 'Access-Control-Request-Method') = 'PUT') and
    (HeadField(Head, 'Access-Control-Request-Headers') = 'x-token'), 'cors: preflight asks for the method and header');
  Check(HeadField(Environment.Site.LastHead('PUT https://api.test/put'), 'X-Token') = 'abc', 'cors: header sent');
  Consumer.Free;
  Request := NewRequest('https://api.test/put', Client, FetchModeCors, DestinationEmpty);
  Request.Method := 'PUT';
  Request.Headers.SetValue('X-Token', 'abc');
  Consumer := RunFetch(Request);
  Check((Environment.Site.RequestCount('OPTIONS https://api.test/put') = 1) and
    (Environment.Site.RequestCount('PUT https://api.test/put') = 2), 'cors: preflight cached');
  Consumer.Free;

  Environment.Site.AddRoute('api.test/nopatch', 204, 'Access-Control-Allow-Origin: https://a.test', '');
  Request := NewRequest('https://api.test/nopatch', Client, FetchModeCors, DestinationEmpty);
  Request.Method := 'PATCH';
  Consumer := RunFetch(Request);
  Check((Consumer.ResponseType = ResponseTypeError) and
    (Environment.Site.RequestCount('PATCH https://api.test/nopatch') = 0), 'cors: refused preflight, no request');
  Consumer.Free;

  Consumer := RunFetch(NewRequest('https://api.test/open', Client, FetchModeSameOrigin, DestinationEmpty));
  Check(Consumer.ResponseType = ResponseTypeError, 'cors: same-origin mode refuses other origins');
  Consumer.Free;
end;

procedure CheckMixedContentAndHsts(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
begin
  Environment.Site.ClearLog;
  Environment.Site.AddRoute('cdn.test/lib.js', 200, 'Content-Type: text/javascript', 'x()');
  Consumer := RunFetch(NewRequest('http://cdn.test/lib.js', Client, FetchModeNoCors, DestinationScript));
  Check((Consumer.ResponseType = ResponseTypeError) and (Environment.Site.RequestCount('cdn.test') = 0),
    'mixed: http script on an https page blocked before any request');
  Consumer.Free;

  Environment.Site.AddRoute('cdn.test/pic.png', 200, 'Content-Type: image/png', #$89'PNG'#13#10#26#10);
  Consumer := RunFetch(NewRequest('http://cdn.test/pic.png', Client, FetchModeNoCors, DestinationImage));
  Check((Consumer.Status = 200) and (Environment.Site.RequestCount('GET https://cdn.test/pic.png') = 1),
    'mixed: http image upgraded to https');
  Consumer.Free;

  Environment.Site.AddRoute('strict.test/', 200, 'Strict-Transport-Security: max-age=1000', 'hi');
  Consumer := RunFetch(NewRequest('https://strict.test/', nil, FetchModeNavigate, DestinationDocument));
  Consumer.Free;
  Consumer := RunFetch(NewRequest('http://strict.test/', nil, FetchModeNavigate, DestinationDocument));
  Check((Consumer.FinalUrl = 'https://strict.test/') and (Environment.Site.RequestCount('GET http://strict.test') = 0),
    'hsts: later http navigation upgraded');
  Consumer.Free;
end;

procedure CheckSchemesAndSniffing(Client, FileClient: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Request: TFetchRequest;
  FileName: string;
  Stream: TFileStream;
  Text: string;
begin
  Consumer := RunFetch(NewRequest('data:text/html;base64,PHA+aGk=', Client, FetchModeNoCors, DestinationEmpty));
  Check((Consumer.Body = '<p>hi') and (Consumer.Essence = 'text/html') and (Consumer.Log = 'response end'),
    'scheme: data: URL');
  Consumer.Free;
  Consumer := RunFetch(NewRequest('about:blank', nil, FetchModeNavigate, DestinationDocument));
  Check((Consumer.Body = '') and (Consumer.Essence = 'text/html') and Consumer.Succeeded, 'scheme: about:blank');
  Consumer.Free;
  Consumer := RunFetch(NewRequest('gopher://x.test/', nil, FetchModeNavigate, DestinationDocument));
  Check(Consumer.ResponseType = ResponseTypeError, 'scheme: unknown schemes fail');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/untyped', 200, '', '  <!DOCTYPE html><title>x</title>' + StringOfChar(' ', 3000));
  Request := NewRequest('https://a.test/untyped', nil, FetchModeNavigate, DestinationDocument);
  Request.SniffContent := True;
  Consumer := RunFetch(Request);
  Check((Consumer.Essence = 'text/html') and (Length(Consumer.Body) = 3033), 'sniff: untyped HTML found, body whole');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/fake.js', 200, 'Content-Type: text/plain|X-Content-Type-Options: nosniff', 'x');
  Consumer := RunFetch(NewRequest('https://a.test/fake.js', Client, FetchModeNoCors, DestinationScript));
  Check(Consumer.ResponseType = ResponseTypeError, 'nosniff: text/plain script blocked');
  Consumer.Free;

  FileName := GetTempDir + 'webloadtest-local.html';
  Stream := TFileStream.Create(FileName, fmCreate);
  Text := '<p>local' + StringOfChar('.', 100000);
  Stream.WriteBuffer(Text[1], Length(Text));
  Stream.Free;
  Consumer := RunFetch(NewRequest('file://' + FileName, nil, FetchModeNavigate, DestinationDocument));
  Check((Consumer.Body = Text) and (Consumer.Essence = 'text/html') and (Consumer.Pieces >= 2),
    'scheme: file: read in pieces');
  Consumer.Free;
  Consumer := RunFetch(NewRequest('file://' + FileName, FileClient, FetchModeNoCors, DestinationImage));
  Check(Consumer.Status = 200, 'scheme: file: from a file: page');
  Consumer.Free;
  Consumer := RunFetch(NewRequest('file://' + FileName, Client, FetchModeNoCors, DestinationImage));
  Check(Consumer.ResponseType = ResponseTypeError, 'scheme: file: from an https page refused');
  Consumer.Free;
  Consumer := RunFetch(NewRequest('file://' + GetTempDir, nil, FetchModeNavigate, DestinationDocument));
  Check((Consumer.Essence = 'text/html') and (Pos('webloadtest-local.html', Consumer.Body) > 0),
    'scheme: file: folder index');
  Consumer.Free;
  DeleteFile(FileName);
end;

procedure CheckPiecesAndCancel(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Route: TTestRoute;
begin
  Route := Environment.Site.AddRoute('a.test/slow', 200, 'Content-Type: text/plain', 'first half|second half');
  Route.Pieces := 2;
  Route.Gate := TEvent.Create(nil, True, False, '');
  Consumer := TRecordingConsumer.Create;
  Environment.Fetcher.Fetch(NewRequest('https://a.test/slow', Client, FetchModeNoCors, DestinationEmpty), Consumer);
  Check(Environment.RunUntil(@Consumer.HasPiece) and not Consumer.Ended and (Consumer.Body = 'first half|'),
    'pieces: the first piece arrives before the rest (' + Consumer.Body + ' ' + Consumer.Log + ')');
  Route.Gate.SetEvent;
  Environment.RunUntil(@Consumer.IsEnded);
  Check(Consumer.Body = 'first half|second half', 'pieces: the rest after the gate');
  Consumer.Free;

  Environment.Site.AddRoute('a.test/cancelled', 200, 'Content-Type: text/plain', 'never seen');
  Consumer := TRecordingConsumer.Create;
  Consumer.CancelOnResponse := True;
  Environment.Fetcher.Fetch(NewRequest('https://a.test/cancelled', Client, FetchModeNoCors, DestinationEmpty),
    Consumer);
  Environment.RunUntil(@Consumer.IsEnded);
  Environment.RunFor(50);
  Check((Consumer.Log = 'response ') and (Consumer.Body = ''), 'cancel: nothing after the cancel');
  Check(Environment.Fetcher.ActiveJobCount = 0, 'cancel: no jobs left');
  Consumer.Free;
end;

{ A consumer freed while its job waits for the head, then a head that
  fails the CORS check; and a consumer that frees itself from inside
  the network error's ProcessResponse (the fetcher must not go on to
  its ProcessEndOfBody). }
procedure CheckFreedConsumers(Client: TFetchClient);
var
  Consumer: TRecordingConsumer;
  Route: TTestRoute;
  Watch: TFreedConsumerWatch;
  Job: TFetchJob;
begin
  Route := Environment.Site.AddRoute('api.test/late-closed', 200, 'Content-Type: text/plain', 'secret');
  Route.HeadGate := TEvent.Create(nil, True, False, '');
  Watch := TFreedConsumerWatch.Create;
  Watch.Key := 'GET https://api.test/late-closed';
  Consumer := TRecordingConsumer.Create;
  Job := Environment.Fetcher.Fetch(NewRequest('https://api.test/late-closed', Client, FetchModeCors,
    DestinationEmpty), Consumer);
  Check(Environment.RunUntil(@Watch.RequestSeen) and (Job.State = JobAwaitingResponse),
    'freed consumer: the request is waiting for its head');
  Consumer.Free;
  Check(not Job.Active and (Job.Consumer = nil), 'freed consumer: its job is cancelled and detached');
  Route.HeadGate.SetEvent;
  Environment.RunFor(200);
  Check(Environment.Fetcher.ActiveJobCount = 0, 'freed consumer: the late CORS failure reaches no one');

  SelfFreeingResponses := 0;
  SelfFreeingEnds := 0;
  Environment.Fetcher.Fetch(NewRequest('https://api.test/closed', Client, FetchModeCors, DestinationEmpty),
    TSelfFreeingConsumer.Create);
  Check(Environment.RunUntil(@Watch.SelfFreeingHeard), 'self-freeing consumer: the CORS failure arrives');
  Environment.RunFor(50);
  Check((SelfFreeingResponses = 1) and (SelfFreeingEnds = 0) and (Environment.Fetcher.ActiveJobCount = 0),
    'self-freeing consumer: nothing after it freed itself (' + IntToStr(SelfFreeingResponses) + ' ' +
    IntToStr(SelfFreeingEnds) + ')');
  Watch.Free;
end;

procedure RunFetchingTests;
var
  Client, FileClient: TFetchClient;
begin
  Environment := TTestEnvironment.Create;
  Client := TFetchClient.ForDocument(MakeUrl('https://a.test/page.html'));
  FileClient := TFetchClient.ForDocument(MakeUrl('file:///tmp/page.html'));
  try
    CheckBasicFetch(Client);
    CheckRedirects(Client);
    CheckCors(Client);
    CheckMixedContentAndHsts(Client);
    CheckSchemesAndSniffing(Client, FileClient);
    CheckPiecesAndCancel(Client);
    CheckFreedConsumers(Client);
  finally
    Environment.Free;
    Client.Free;
    FileClient.Free;
  end;
end;

end.
