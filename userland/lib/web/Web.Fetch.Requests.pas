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
  Fetch requests and the environment they come from (Fetch Standard
  section 2.2.5; HTML's environment settings and policy container):

  - TFetchClient: what a request is made for - the document's URL and
    origin, its policy container (referrer policy, CSP list), whether it
    is a secure context, and the top-level site (for SameSite cookies).
  - TFetchRequest: method, URL, header list and body, the destination,
    mode (navigate, same-origin, no-cors, cors), credentials mode,
    redirect mode, cache mode, referrer and its policy, the initiator
    type and parser metadata, the priority (fetchpriority and the RFC
    9218 urgency it becomes), and the state the fetch keeps (URL list,
    redirect count, response tainting, origin).
}
unit Web.Fetch.Requests;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Url.Origins,
  Http.HeaderFields,
  Http.Messages,
  Http.Priorities,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.ContentSecurityPolicy;

type
  TFetchDestination = (
    DestinationEmpty,
    DestinationDocument,
    DestinationIframe,
    DestinationScript,
    DestinationStyle,
    DestinationImage,
    DestinationFont,
    DestinationAudio,
    DestinationVideo,
    DestinationTrack,
    DestinationManifest,
    DestinationWorker,
    DestinationObject,
    DestinationReport);

  TFetchMode = (FetchModeNavigate, FetchModeSameOrigin, FetchModeNoCors, FetchModeCors);
  TFetchCredentials = (FetchCredentialsOmit, FetchCredentialsSameOrigin, FetchCredentialsInclude);
  TFetchRedirect = (FetchRedirectFollow, FetchRedirectError, FetchRedirectManual);
  TFetchCacheMode = (FetchCacheDefault, FetchCacheNoStore, FetchCacheReload, FetchCacheNoCache, FetchCacheForceCache,
    FetchCacheOnlyIfCached);
  TResponseTainting = (TaintingBasic, TaintingCors, TaintingOpaque);
  TFetchPriorityHint = (FetchPriorityAuto, FetchPriorityHigh, FetchPriorityLow);
  TReferrerKind = (ReferrerClient, ReferrerNone, ReferrerUrl);
  TParserMetadata = (ParserMetadataNone, ParserMetadataInserted, ParserMetadataNotInserted);

  { The environment a request is made for: a document (or the browser
    itself, with an opaque origin and no URL, for typed addresses). }
  TFetchClient = class
  public
    CreationUrl: TUrlRecord;
    HasCreationUrl: Boolean;
    Origin: TUrlOrigin;
    ReferrerPolicy: TReferrerPolicy;
    Csp: TCspList;
    IsSecureContext: Boolean;
    { The top-level document's origin (its site, for cookies). }
    TopLevelOrigin: TUrlOrigin;
    HasTopLevelOrigin: Boolean;
    constructor Create;
    destructor Destroy; override;
    { A client for a document at Url (its own origin unless Origin given). }
    class function ForDocument(constref Url: TUrlRecord): TFetchClient;
    procedure SetDocumentUrl(constref Url: TUrlRecord);
  end;

  TFetchRequest = class
  private
    FHeaders: THttpHeaders;
  public
    Method: string;
    Url: TUrlRecord;
    Body: TBytes;
    HasBody: Boolean;
    Destination: TFetchDestination;
    Mode: TFetchMode;
    Credentials: TFetchCredentials;
    Redirect: TFetchRedirect;
    CacheMode: TFetchCacheMode;
    { Not owned; nil: the browser itself (a typed address). }
    Client: TFetchClient;
    Origin: TUrlOrigin;
    ReferrerKind: TReferrerKind;
    ReferrerUrl: TUrlRecord;
    ReferrerPolicy: TReferrerPolicy;
    { "img", "link", "script", "css", "fetch", "navigation", ... }
    InitiatorType: string;
    ParserMetadata: TParserMetadata;
    PriorityHint: TFetchPriorityHint;
    Priority: THttpPriority;
    { A navigation the user started (typed, bookmark): same-site cookies. }
    UserInitiated: Boolean;
    Integrity: string;
    CryptographicNonce: string;
    { State the fetch keeps. }
    UrlList: array of TUrlRecord;
    RedirectCount: Integer;
    ResponseTainting: TResponseTainting;
    { The upgrade-insecure-requests or mixed content upgrade happened. }
    Upgraded: Boolean;
    { Sniff the first bytes before the response is handed on. }
    SniffContent: Boolean;
    constructor Create(const AMethod: string; constref AUrl: TUrlRecord);
    destructor Destroy; override;
    function CurrentUrl: TUrlRecord;
    property Headers: THttpHeaders read FHeaders;
  end;

function DestinationName(Destination: TFetchDestination): string;
{ Script-like destinations (script, worker...). }
function IsScriptLikeDestination(Destination: TFetchDestination): Boolean;
function SameOriginUrl(constref First, Second: TUrlRecord): Boolean;
function HttpCacheModeOf(Mode: TFetchCacheMode): THttpCacheMode;

implementation

constructor TFetchClient.Create;
begin
  inherited Create;
  Csp := TCspList.Create;
  Origin := NewOpaqueOrigin;
  ReferrerPolicy := ReferrerPolicyEmpty;
end;

destructor TFetchClient.Destroy;
begin
  Csp.Free;
  inherited Destroy;
end;

class function TFetchClient.ForDocument(constref Url: TUrlRecord): TFetchClient;
begin
  Result := TFetchClient.Create;
  Result.SetDocumentUrl(Url);
end;

procedure TFetchClient.SetDocumentUrl(constref Url: TUrlRecord);
begin
  CreationUrl := Url;
  HasCreationUrl := True;
  Origin := OriginOfUrl(Url);
  IsSecureContext := UrlIsPotentiallyTrustworthy(Url);
  if not HasTopLevelOrigin then
  begin
    TopLevelOrigin := Origin;
    HasTopLevelOrigin := True;
  end;
end;

constructor TFetchRequest.Create(const AMethod: string; constref AUrl: TUrlRecord);
begin
  inherited Create;
  FHeaders := THttpHeaders.Create;
  Method := AMethod;
  Url := AUrl;
  Mode := FetchModeNoCors;
  Credentials := FetchCredentialsSameOrigin;
  Redirect := FetchRedirectFollow;
  CacheMode := FetchCacheDefault;
  ReferrerKind := ReferrerClient;
  ReferrerPolicy := ReferrerPolicyEmpty;
  Priority := DefaultPriority;
  Origin := NewOpaqueOrigin;
  SetLength(UrlList, 1);
  UrlList[0] := AUrl;
end;

destructor TFetchRequest.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TFetchRequest.CurrentUrl: TUrlRecord;
begin
  Result := UrlList[High(UrlList)];
end;

function DestinationName(Destination: TFetchDestination): string;
const
  Names: array[TFetchDestination] of string = ('', 'document', 'iframe', 'script', 'style', 'image', 'font', 'audio',
    'video', 'track', 'manifest', 'worker', 'object', 'report');
begin
  Result := Names[Destination];
end;

function IsScriptLikeDestination(Destination: TFetchDestination): Boolean;
begin
  Result := Destination in [DestinationScript, DestinationWorker];
end;

function SameOriginUrl(constref First, Second: TUrlRecord): Boolean;
begin
  Result := SameOrigin(OriginOfUrl(First), OriginOfUrl(Second));
end;

function HttpCacheModeOf(Mode: TFetchCacheMode): THttpCacheMode;
const
  Modes: array[TFetchCacheMode] of THttpCacheMode = (CacheModeDefault, CacheModeNoStore, CacheModeReload,
    CacheModeNoCache, CacheModeForceCache, CacheModeOnlyIfCached);
begin
  Result := Modes[Mode];
end;

end.
