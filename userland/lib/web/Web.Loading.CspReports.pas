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
  A document's CSP: the policies of its response (Content-Security-
  Policy and Content-Security-Policy-Report-Only), the Reporting API's
  endpoints (Reporting-Endpoints), and what happens on a violation (CSP
  5.3 "report a violation"), in a task of the DOM manipulation source:

  - a securitypolicyviolation event (SecurityPolicyViolationEvent,
    bubbling and composed) at the element the violation is about if it
    is still in the document, else at the document;
  - with report-to and an endpoint of that name: a POST of
    application/reports+json (a "csp-violation" report) to it;
    otherwise with report-uri: a POST of application/csp-report (the
    older serialization) to each URL.

  Reports go through the fetcher as the document's (no cookies across
  origins, no referrer), not grouped with it so they outlive it. Each
  violation is reported once per policy and directive and blocked URL
  (at most 100 reports a document).

  A document without policies of its own (about:blank, srcdoc, data:)
  takes its creator's (InheritCsp).
}
unit Web.Loading.CspReports;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Web.Fetch.ContentSecurityPolicy,
  Web.Fetch.Requests,
  Web.Loading.Contexts;

type
  TDocumentCspReporter = class(TCspViolationReporter)
  private
    FLoader: TLoadingContext;
    FEndpointNames: TStringList;
    FSent: TStringList;
    procedure DispatchTask(Data: TObject);
    procedure SendReports(constref Violation: TCspViolation);
    procedure Post(constref Url: TUrlRecord; const ContentType, Body: string);
  public
    constructor Create(Loader: TLoadingContext);
    destructor Destroy; override;
    procedure ViolationOccurred(constref Violation: TCspViolation); override;
    { Reporting-Endpoints (an RFC 8941 dictionary of URL strings). }
    procedure SetEndpoints(const FieldValue: string);
    function EndpointUrl(const Name: string; out Url: TUrlRecord): Boolean;
  end;

{ A local-scheme document's policies, its creator's (Source). }
procedure InheritCsp(Target, Source: TFetchClient);
{ JSON's string syntax (quotes included). }
function JsonQuote(const Text: string): string;

implementation

uses
  Url.Parser,
  Url.Origins,
  Web.Dom,
  Web.Dom.Events,
  Web.Dom.SecurityEvents,
  Web.EventLoop.Tasks,
  Web.Fetch.Jobs,
  Web.Fetch.ReferrerPolicy,
  Web.UserAgent;

const
  MaximumReports = 100;

type
  TViolationTask = class
  public
    Violation: TCspViolation;
    Element: TNode;
    destructor Destroy; override;
  end;

  { Reports are not waited for. }
  TReportConsumer = class(TFetchConsumer)
  end;

var
  ReportConsumer: TReportConsumer;

destructor TViolationTask.Destroy;
begin
  if Element <> nil then
    Element.Release;
  inherited Destroy;
end;

function JsonQuote(const Text: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '"';
  for Index := 1 to Length(Text) do
  begin
    Character := Text[Index];
    case Character of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31: Result := Result + '\u' + IntToHex(Ord(Character), 4);
    else
      Result := Result + Character;
    end;
  end;
  Result := Result + '"';
end;

function DispositionName(Disposition: TCspDisposition): string;
begin
  if Disposition = CspEnforce then
    Result := 'enforce'
  else
    Result := 'report';
end;

constructor TDocumentCspReporter.Create(Loader: TLoadingContext);
begin
  inherited Create;
  FLoader := Loader;
  FEndpointNames := TStringList.Create;
  FSent := TStringList.Create;
  FSent.Sorted := True;
end;

destructor TDocumentCspReporter.Destroy;
begin
  if (FLoader <> nil) and (FLoader.Loop <> nil) then
    FLoader.Loop.DiscardTasks(Self);
  if (FLoader <> nil) and (FLoader.Client <> nil) and (FLoader.Client.CspReporter = Self) then
    FLoader.Client.CspReporter := nil;
  FEndpointNames.Free;
  FSent.Free;
  inherited Destroy;
end;

procedure TDocumentCspReporter.SetEndpoints(const FieldValue: string);
var
  Members: TStringArray;
  Index, EqualsAt: Integer;
  Name, Value: string;
  Url: TUrlRecord;
begin
  FEndpointNames.Clear;
  Members := FieldValue.Split([',']);
  for Index := 0 to High(Members) do
  begin
    EqualsAt := Pos('=', Members[Index]);
    if EqualsAt = 0 then
      Continue;
    Name := Trim(Copy(Members[Index], 1, EqualsAt - 1));
    Value := Trim(Copy(Members[Index], EqualsAt + 1, MaxInt));
    { Parameters after ";" are ignored. }
    if Pos(';', Value) > 0 then
      Value := Trim(Copy(Value, 1, Pos(';', Value) - 1));
    if (Length(Value) < 2) or (Value[1] <> '"') or (Value[Length(Value)] <> '"') then
      Continue;
    Value := Copy(Value, 2, Length(Value) - 2);
    if not FLoader.ResolveUrl(Value, Url) or not UrlIsPotentiallyTrustworthy(Url) then
      Continue;
    FEndpointNames.Values[Name] := SerializeUrl(Url);
  end;
end;

function TDocumentCspReporter.EndpointUrl(const Name: string; out Url: TUrlRecord): Boolean;
var
  Text: string;
begin
  Text := FEndpointNames.Values[Name];
  Result := (Text <> '') and ParseUrl(Text, Url);
end;

procedure TDocumentCspReporter.ViolationOccurred(constref Violation: TCspViolation);
var
  Task: TViolationTask;
  Key: string;
begin
  Key := DispositionName(Violation.Disposition) + ' ' + Violation.EffectiveDirective + ' ' + Violation.BlockedUri +
    ' ' + Violation.OriginalPolicy;
  if Violation.Element = nil then
  begin
    if FSent.IndexOf(Key) >= 0 then
      Exit;
    if FSent.Count >= MaximumReports then
      Exit;
    FSent.Add(Key);
  end;
  Task := TViolationTask.Create;
  Task.Violation := Violation;
  if Violation.Element is TNode then
  begin
    Task.Element := TNode(Violation.Element);
    Task.Element.Retain;
  end;
  Task.Violation.Element := nil;
  FLoader.Loop.PostMethod(@DispatchTask, Task, TaskSourceDomManipulation, Self);
end;

procedure TDocumentCspReporter.DispatchTask(Data: TObject);
var
  Task: TViolationTask;
  Event: TSecurityPolicyViolationEvent;
  Target: TEventTarget;
begin
  Task := TViolationTask(Data);
  Event := TSecurityPolicyViolationEvent.Create('securitypolicyviolation', True, False);
  try
    Event.Composed := True;
    Event.IsTrusted := True;
    Event.DocumentUri := Task.Violation.DocumentUrl;
    Event.Referrer := Task.Violation.Referrer;
    Event.BlockedUri := Task.Violation.BlockedUri;
    Event.EffectiveDirective := Task.Violation.EffectiveDirective;
    Event.ViolatedDirective := Task.Violation.EffectiveDirective;
    Event.OriginalPolicy := Task.Violation.OriginalPolicy;
    Event.SourceFile := Task.Violation.SourceFile;
    Event.Sample := Task.Violation.Sample;
    Event.Disposition := DispositionName(Task.Violation.Disposition);
    Event.StatusCode := Task.Violation.StatusCode;
    Event.LineNumber := Task.Violation.LineNumber;
    Event.ColumnNumber := Task.Violation.ColumnNumber;
    if (Task.Element <> nil) and Task.Element.IsConnected and (Task.Element.NodeDocument = FLoader.Document) then
      Target := Task.Element
    else
      Target := FLoader.Document;
    Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
  SendReports(Task.Violation);
end;

procedure TDocumentCspReporter.Post(constref Url: TUrlRecord; const ContentType, Body: string);
var
  Request: TFetchRequest;
begin
  if (Url.Scheme <> 'http') and (Url.Scheme <> 'https') then
    Exit;
  Request := TFetchRequest.Create('POST', Url);
  Request.Destination := DestinationReport;
  Request.Mode := FetchModeNoCors;
  Request.Credentials := FetchCredentialsSameOrigin;
  Request.CacheMode := FetchCacheNoCache;
  Request.Redirect := FetchRedirectError;
  Request.ReferrerKind := ReferrerNone;
  Request.InitiatorType := 'other';
  { No client: the report outlives the document; its origin is still
    the document's. }
  Request.Origin := FLoader.Client.Origin;
  Request.Headers.SetValue('content-type', ContentType);
  Request.Body := BytesOf(Body);
  Request.HasBody := True;
  FLoader.Fetcher.Fetch(Request, ReportConsumer, nil);
end;

procedure TDocumentCspReporter.SendReports(constref Violation: TCspViolation);
var
  Url: TUrlRecord;
  Body, Common: string;
  Index: Integer;
begin
  if (Violation.ReportTo <> '') and EndpointUrl(Violation.ReportTo, Url) then
  begin
    Body := '[{"type":"csp-violation","age":0,"url":' + JsonQuote(Violation.DocumentUrl) + ',"user_agent":' +
      JsonQuote(EngineUserAgent) + ',"body":{' +
      '"documentURL":' + JsonQuote(Violation.DocumentUrl) +
      ',"referrer":' + JsonQuote(Violation.Referrer) +
      ',"blockedURL":' + JsonQuote(Violation.BlockedUri) +
      ',"effectiveDirective":' + JsonQuote(Violation.EffectiveDirective) +
      ',"originalPolicy":' + JsonQuote(Violation.OriginalPolicy) +
      ',"sourceFile":' + JsonQuote(Violation.SourceFile) +
      ',"sample":' + JsonQuote(Violation.Sample) +
      ',"disposition":' + JsonQuote(DispositionName(Violation.Disposition)) +
      ',"statusCode":' + IntToStr(Violation.StatusCode) +
      ',"lineNumber":' + IntToStr(Violation.LineNumber) +
      ',"columnNumber":' + IntToStr(Violation.ColumnNumber) + '}}]';
    Post(Url, 'application/reports+json', Body);
    Exit;
  end;
  if Length(Violation.ReportUris) = 0 then
    Exit;
  Common := '{"csp-report":{' +
    '"document-uri":' + JsonQuote(Violation.DocumentUrl) +
    ',"referrer":' + JsonQuote(Violation.Referrer) +
    ',"blocked-uri":' + JsonQuote(Violation.BlockedUri) +
    ',"effective-directive":' + JsonQuote(Violation.EffectiveDirective) +
    ',"violated-directive":' + JsonQuote(Violation.EffectiveDirective) +
    ',"original-policy":' + JsonQuote(Violation.OriginalPolicy) +
    ',"disposition":' + JsonQuote(DispositionName(Violation.Disposition)) +
    ',"status-code":' + IntToStr(Violation.StatusCode) +
    ',"script-sample":' + JsonQuote(Violation.Sample);
  if Violation.SourceFile <> '' then
    Common := Common + ',"source-file":' + JsonQuote(Violation.SourceFile) + ',"line-number":' +
      IntToStr(Violation.LineNumber) + ',"column-number":' + IntToStr(Violation.ColumnNumber);
  Body := Common + '}}';
  for Index := 0 to High(Violation.ReportUris) do
    if FLoader.ResolveUrl(Violation.ReportUris[Index], Url) then
      Post(Url, 'application/csp-report', Body);
end;

procedure InheritCsp(Target, Source: TFetchClient);
begin
  if (Target = nil) or (Source = nil) or (Target = Source) then
    Exit;
  Target.Csp.Assign(Source.Csp);
end;

initialization
  ReportConsumer := TReportConsumer.Create;
finalization
  FreeAndNil(ReportConsumer);
end.
