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
  Script fetches (fetch(), XMLHttpRequest, sendBeacon) over the document
  loader's fetch layer: the script's request becomes a TFetchRequest of
  the document (its client: origin, referrer policy, CSP, cookies' site),
  and the response is filtered as the Fetch Standard filters what script
  sees - a basic response without Set-Cookie, a CORS one with only the
  safelisted and exposed headers, an opaque one with status 0 and no
  headers.

  TScriptFetches keeps the fetches of a page: each one's consumer, freed
  after its end or when it is cancelled, at the next Start or with the
  page. That can be inside the fetcher's call into the consumer (a
  script's error handler starting another fetch); freeing a consumer
  cancels and detaches its job, so the fetcher calls it no more.
}
unit Web.Script.PageFetch;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Jobs,
  Web.Fetch.Fetcher,
  Web.Loading.Contexts,
  Web.ScriptEnvironment;

type
  TScriptFetches = class
  private
    FActive: TList;
    FDone: TList;
    procedure FreeDone;
  public
    constructor Create;
    destructor Destroy; override;
    { Starts Request for the loader's document; nil when it is not a URL
      the document may fetch. }
    function Start(Loader: TLoadingContext; const Request: TScriptFetchRequest; Sink: TScriptFetchSink): TObject;
    procedure Cancel(Handle: TObject);
    { Cancels every fetch of Loader (its document went). }
    procedure CancelLoader(Loader: TLoadingContext);
    { A beacon: a keepalive POST nobody waits for. }
    procedure SendBeacon(Fetcher: TFetcher; Client: TFetchClient; const Url: string; const Body: TBytes;
      const ContentType: string);
  end;

{ The script's request as the fetch layer's (nil when the URL does not
  parse). }
function ScriptRequestToFetch(Client: TFetchClient; const Request: TScriptFetchRequest): TFetchRequest;

implementation

uses
  Url.Records,
  Url.Parser,
  Http.HeaderFields,
  Web.Fetch.ReferrerPolicy;

type
  TScriptFetchConsumer = class(TFetchConsumer)
  public
    Owner: TScriptFetches;
    Sink: TScriptFetchSink;
    Loader: TLoadingContext;
    Job: TFetchJob;
    Finished: Boolean;
  protected
    procedure JobReleased(Job_: TFetchJob); override;
  public
    procedure ProcessResponse(Job_: TFetchJob; Response: TFetchResponse); override;
    procedure ProcessBody(Job_: TFetchJob; Data: Pointer; Count: PtrUInt); override;
    procedure ProcessEndOfBody(Job_: TFetchJob; Success: Boolean); override;
  end;

  { Beacons are not waited for. }
  TBeaconConsumer = class(TFetchConsumer)
  end;

var
  BeaconConsumer: TBeaconConsumer;

function ModeOf(const Text: string): TFetchMode;
begin
  if Text = 'same-origin' then
    Result := FetchModeSameOrigin
  else if Text = 'no-cors' then
    Result := FetchModeNoCors
  else
    Result := FetchModeCors;
end;

function CredentialsOf(const Text: string): TFetchCredentials;
begin
  if Text = 'omit' then
    Result := FetchCredentialsOmit
  else if Text = 'include' then
    Result := FetchCredentialsInclude
  else
    Result := FetchCredentialsSameOrigin;
end;

function CacheOf(const Text: string): TFetchCacheMode;
begin
  if Text = 'no-store' then
    Result := FetchCacheNoStore
  else if Text = 'reload' then
    Result := FetchCacheReload
  else if Text = 'no-cache' then
    Result := FetchCacheNoCache
  else if Text = 'force-cache' then
    Result := FetchCacheForceCache
  else if Text = 'only-if-cached' then
    Result := FetchCacheOnlyIfCached
  else
    Result := FetchCacheDefault;
end;

function RedirectOf(const Text: string): TFetchRedirect;
begin
  if Text = 'error' then
    Result := FetchRedirectError
  else if Text = 'manual' then
    Result := FetchRedirectManual
  else
    Result := FetchRedirectFollow;
end;

function PriorityOf(const Text: string): TFetchPriorityHint;
begin
  if Text = 'high' then
    Result := FetchPriorityHigh
  else if Text = 'low' then
    Result := FetchPriorityLow
  else
    Result := FetchPriorityAuto;
end;

function ScriptRequestToFetch(Client: TFetchClient; const Request: TScriptFetchRequest): TFetchRequest;
var
  Url, Referrer: TUrlRecord;
  Index: Integer;
  Policy: TReferrerPolicy;
begin
  Result := nil;
  if not ParseUrl(Request.Url, Url) then
    Exit;
  Result := TFetchRequest.Create(Request.Method, Url);
  Result.Client := Client;
  Result.Destination := DestinationEmpty;
  Result.Mode := ModeOf(Request.Mode);
  Result.Credentials := CredentialsOf(Request.Credentials);
  Result.CacheMode := CacheOf(Request.Cache);
  Result.Redirect := RedirectOf(Request.Redirect);
  Result.PriorityHint := PriorityOf(Request.Priority);
  Result.Integrity := Request.Integrity;
  Result.InitiatorType := 'fetch';
  if Request.Referrer = 'no-referrer' then
    Result.ReferrerKind := ReferrerNone
  else if (Request.Referrer <> '') and (Request.Referrer <> 'about:client') and ParseUrl(Request.Referrer, Referrer) then
  begin
    Result.ReferrerKind := ReferrerUrl;
    Result.ReferrerUrl := Referrer;
  end;
  if (Request.ReferrerPolicy <> '') and ReferrerPolicyFromToken(Request.ReferrerPolicy, Policy) then
    Result.ReferrerPolicy := Policy;
  for Index := 0 to High(Request.Headers) do
    Result.Headers.Add(LowerCase(Request.Headers[Index].Name), Request.Headers[Index].Value);
  if Request.HasBody then
  begin
    Result.Body := Request.Body;
    Result.HasBody := True;
  end;
end;

{ The headers script sees of a response (Fetch 4.1, filtered responses). }
function VisibleHeaders(Response: TFetchResponse): TScriptFetchHeaders;
var
  Index, Count, Exposed: Integer;
  Name: string;
  Visible: Boolean;
begin
  Result := nil;
  if Response.ResponseType = ResponseTypeOpaque then
    Exit;
  SetLength(Result, Response.Headers.Count);
  Count := 0;
  for Index := 0 to Response.Headers.Count - 1 do
  begin
    Name := LowerCase(Response.Headers[Index].Name);
    if (Name = 'set-cookie') or (Name = 'set-cookie2') then
      Continue;
    Visible := Response.ResponseType <> ResponseTypeCors;
    if not Visible then
      for Exposed := 0 to High(Response.ExposedHeaderNames) do
        if LowerCase(Response.ExposedHeaderNames[Exposed]) = Name then
        begin
          Visible := True;
          Break;
        end;
    if not Visible then
      Continue;
    Result[Count].Name := Response.Headers[Index].Name;
    Result[Count].Value := Response.Headers[Index].Value;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

{ TScriptFetchConsumer }

procedure TScriptFetchConsumer.JobReleased(Job_: TFetchJob);
begin
  if Job_ = Job then
    Job := nil;
end;

procedure TScriptFetchConsumer.ProcessResponse(Job_: TFetchJob; Response: TFetchResponse);
var
  Status: Integer;
  Url: string;
begin
  if Finished then
    Exit;
  if Response.IsNetworkError then
  begin
    Finished := True;
    Owner.FActive.Remove(Self);
    Owner.FDone.Add(Self);
    Sink.Finished(False, Response.ErrorText);
    Exit;
  end;
  Status := Response.Status;
  if Response.ResponseType in [ResponseTypeOpaque, ResponseTypeOpaqueRedirect] then
    Status := 0;
  if Response.HasUrl and (Response.ResponseType <> ResponseTypeOpaque) then
    Url := SerializeUrl(Response.Url)
  else
    Url := '';
  Sink.ResponseArrived(Status, Response.StatusText, Url, ResponseTypeName(Response.ResponseType),
    Length(Response.UrlList) > 1, VisibleHeaders(Response));
end;

procedure TScriptFetchConsumer.ProcessBody(Job_: TFetchJob; Data: Pointer; Count: PtrUInt);
begin
  if not Finished then
    Sink.DataArrived(Data, Count);
end;

procedure TScriptFetchConsumer.ProcessEndOfBody(Job_: TFetchJob; Success: Boolean);
begin
  if Finished then
    Exit;
  Finished := True;
  Owner.FActive.Remove(Self);
  Owner.FDone.Add(Self);
  Sink.Finished(Success, '');
end;

{ TScriptFetches }

constructor TScriptFetches.Create;
begin
  inherited Create;
  FActive := TList.Create;
  FDone := TList.Create;
end;

destructor TScriptFetches.Destroy;
var
  Index: Integer;
begin
  for Index := FActive.Count - 1 downto 0 do
    Cancel(TObject(FActive[Index]));
  FreeDone;
  FActive.Free;
  FDone.Free;
  inherited Destroy;
end;

procedure TScriptFetches.FreeDone;
var
  Index: Integer;
begin
  for Index := 0 to FDone.Count - 1 do
    TObject(FDone[Index]).Free;
  FDone.Clear;
end;

function TScriptFetches.Start(Loader: TLoadingContext; const Request: TScriptFetchRequest;
  Sink: TScriptFetchSink): TObject;
var
  FetchRequest: TFetchRequest;
  Consumer: TScriptFetchConsumer;
begin
  FreeDone;
  Result := nil;
  if Loader = nil then
    Exit;
  FetchRequest := ScriptRequestToFetch(Loader.Client, Request);
  if FetchRequest = nil then
    Exit;
  Consumer := TScriptFetchConsumer.Create;
  Consumer.Owner := Self;
  Consumer.Sink := Sink;
  Consumer.Loader := Loader;
  FActive.Add(Consumer);
  Consumer.Job := Loader.Fetch(FetchRequest, Consumer);
  Result := Consumer;
end;

procedure TScriptFetches.Cancel(Handle: TObject);
var
  Consumer: TScriptFetchConsumer;
begin
  if (Handle = nil) or (FActive.IndexOf(Handle) < 0) then
    Exit;
  Consumer := TScriptFetchConsumer(Handle);
  FActive.Remove(Consumer);
  Consumer.Finished := True;
  if Consumer.Job <> nil then
    Consumer.Job.Cancel;
  FDone.Add(Consumer);
end;

procedure TScriptFetches.CancelLoader(Loader: TLoadingContext);
var
  Index: Integer;
begin
  for Index := FActive.Count - 1 downto 0 do
    if TScriptFetchConsumer(FActive[Index]).Loader = Loader then
      Cancel(TObject(FActive[Index]));
end;

procedure TScriptFetches.SendBeacon(Fetcher: TFetcher; Client: TFetchClient; const Url: string; const Body: TBytes;
  const ContentType: string);
var
  Request: TScriptFetchRequest;
  FetchRequest: TFetchRequest;
begin
  Request := Default(TScriptFetchRequest);
  Request.Method := 'POST';
  Request.Url := Url;
  Request.Mode := 'no-cors';
  Request.Credentials := 'include';
  Request.Keepalive := True;
  Request.Body := Body;
  Request.HasBody := True;
  if ContentType <> '' then
  begin
    SetLength(Request.Headers, 1);
    Request.Headers[0].Name := 'content-type';
    Request.Headers[0].Value := ContentType;
  end;
  FetchRequest := ScriptRequestToFetch(Client, Request);
  if FetchRequest = nil then
    Exit;
  FetchRequest.InitiatorType := 'beacon';
  { Not grouped with the document: it outlives the page. }
  Fetcher.Fetch(FetchRequest, BeaconConsumer, nil);
end;

initialization
  BeaconConsumer := TBeaconConsumer.Create;
finalization
  FreeAndNil(BeaconConsumer);
end.
