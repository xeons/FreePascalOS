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
  What every loader of a document shares (the document loader, style
  sheets, images, scripts, icons, fonts, the preload scanner): the
  document and its window, the event loop and fetcher, the resource
  sink, the document's fetch client (URL, origin, policy container),
  the document base URL (the first <base href>, kept up to date), the
  settings, and the load event delay count: anything that delays the
  load event calls DelayLoad and later UndelayLoad.

  Requests are made here so they all carry the document's client,
  referrer policy and group (cancelled together when the document goes).
}
unit Web.Loading.Contexts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Http.Priorities,
  Web.Dom,
  Web.EventLoop,
  Web.Fetch.Requests,
  Web.Fetch.Jobs,
  Web.Fetch.Fetcher,
  Web.Fetch.ReferrerPolicy,
  Web.Loading.ResourceSink,
  Web.Navigation.Windows;

type
  TLoadingSettings = record
    LoadImages: Boolean;
    { Decode images on worker threads (False: on the page thread). }
    DecodeImagesOnThreads: Boolean;
    { Pixels larger than this many times what is needed are scaled down. }
    DownscaleFactor: Double;
    { No decoded image side above this many device pixels. }
    MaximumImageSide: Integer;
    { Fetch favicons (the browser shows them; a web view may not). }
    LoadIcons: Boolean;
    { Fetch @font-face sources as soon as their sheet is loaded. }
    LoadFontsEagerly: Boolean;
    { Most nested @import levels. }
    MaximumImportDepth: Integer;
  end;

  { The moments of a document's navigation and loading (Navigation
    Timing), as GetTickCount64 milliseconds; 0 for not yet. }
  TDocumentTimes = record
    { 'navigate', 'reload' or 'back_forward'. }
    Kind: string;
    RedirectCount: Integer;
    NavigationStart, FetchStart, ResponseStart, ResponseEnd: QWord;
    DomInteractive, DomContentLoadedStart, DomContentLoadedEnd, DomComplete, LoadEventStart, LoadEventEnd: QWord;
    Protocol: string;
    Status: Integer;
    BytesReceived: Int64;
  end;

  TLoadingContext = class
  private
    FBaseUrl: TUrlRecord;
    FBaseUrlValid: Boolean;
    FLoadDelays: Integer;
    FOnLoadDelaysGone: TDocumentNotifyEvent;
  protected
    FDocument: TDocument;
    FWindow: TWebWindow;
    FLoop: TEventLoop;
    FFetcher: TFetcher;
    FSink: TResourceSink;
    FClient: TFetchClient;
    FDocumentUrl: TUrlRecord;
    FSettings: TLoadingSettings;
  public
    { Filled by the navigable and the loader as the document loads. }
    Times: TDocumentTimes;
    { The document URL as parsed. }
    property DocumentUrl: TUrlRecord read FDocumentUrl;
    procedure DelayLoad;
    procedure UndelayLoad;
    { The document's URL changed (fragment navigation, pushState). }
    procedure ChangeDocumentUrl(constref Url: TUrlRecord);
    { The document base URL (HTML 2.4.1). }
    function BaseUrl: TUrlRecord;
    procedure InvalidateBaseUrl;
    { Url against the base URL; False when it is not a URL. }
    function ResolveUrl(const Text: string; out Url: TUrlRecord): Boolean;
    { A request of the document for Url. }
    function NewRequest(constref Url: TUrlRecord; Destination: TFetchDestination; Mode: TFetchMode;
      Credentials: TFetchCredentials): TFetchRequest;
    { CORS settings attribute (crossorigin) as mode and credentials. }
    procedure ApplyCorsSettings(Request: TFetchRequest; Element: TElement; DefaultMode: TFetchMode);
    { The referrerpolicy attribute of Element, if any. }
    procedure ApplyReferrerPolicyAttribute(Request: TFetchRequest; Element: TElement);
    function Fetch(Request: TFetchRequest; Consumer: TFetchConsumer): TFetchJob;
    procedure CancelFetch(Job: TFetchJob);
    property Document: TDocument read FDocument;
    property Window: TWebWindow read FWindow;
    property Loop: TEventLoop read FLoop;
    property Fetcher: TFetcher read FFetcher;
    property Sink: TResourceSink read FSink;
    property Client: TFetchClient read FClient;
    property Settings: TLoadingSettings read FSettings write FSettings;
    property LoadDelays: Integer read FLoadDelays;
    property OnLoadDelaysGone: TDocumentNotifyEvent read FOnLoadDelaysGone write FOnLoadDelaysGone;
  end;

function DefaultLoadingSettings: TLoadingSettings;

implementation

uses
  Url.Parser,
  Web.Atoms,
  Web.Fetch.CspChecks;

function DefaultLoadingSettings: TLoadingSettings;
begin
  Result.LoadImages := True;
  Result.DecodeImagesOnThreads := True;
  Result.DownscaleFactor := 2;
  Result.MaximumImageSide := 8192;
  Result.LoadIcons := True;
  Result.LoadFontsEagerly := True;
  Result.MaximumImportDepth := 16;
end;

procedure TLoadingContext.DelayLoad;
begin
  Inc(FLoadDelays);
end;

procedure TLoadingContext.UndelayLoad;
begin
  if FLoadDelays <= 0 then
    Exit;
  Dec(FLoadDelays);
  if (FLoadDelays = 0) and Assigned(FOnLoadDelaysGone) then
    FOnLoadDelaysGone(Self);
end;

procedure TLoadingContext.ChangeDocumentUrl(constref Url: TUrlRecord);
begin
  FDocumentUrl := Url;
  FDocument.Url := SerializeUrl(Url);
  FClient.CreationUrl := Url;
  InvalidateBaseUrl;
end;

procedure TLoadingContext.InvalidateBaseUrl;
begin
  FBaseUrlValid := False;
end;

function TLoadingContext.BaseUrl: TUrlRecord;
var
  Node: TNode;
  Element: TElement;
  Parsed: TUrlRecord;
begin
  if FBaseUrlValid then
    Exit(FBaseUrl);
  FBaseUrl := FDocumentUrl;
  Node := FDocument.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if Element.IsHtmlElement(AtomBase) and Element.HasAttributeAtom(AtomHref) then
      begin
        { The frozen base URL: the href against the document's URL. }
        { CSP's base-uri may refuse it (the document's URL stays the
          base). }
        if ParseUrl(Element.AttributeValueOf(AtomHref), FDocumentUrl, Parsed) and (Parsed.Scheme <> 'data') and
           (Parsed.Scheme <> 'javascript') and not CspBlocksBaseUrl(FClient, Parsed, nil) then
          FBaseUrl := Parsed;
        Break;
      end;
    end;
    Node := Node.NextInTree(FDocument);
  end;
  FBaseUrlValid := True;
  Result := FBaseUrl;
end;

function TLoadingContext.ResolveUrl(const Text: string; out Url: TUrlRecord): Boolean;
var
  Base: TUrlRecord;
begin
  Base := BaseUrl;
  Result := ParseUrl(Text, Base, Url);
end;

function TLoadingContext.NewRequest(constref Url: TUrlRecord; Destination: TFetchDestination; Mode: TFetchMode;
  Credentials: TFetchCredentials): TFetchRequest;
begin
  Result := TFetchRequest.Create('GET', Url);
  Result.Client := FClient;
  Result.Destination := Destination;
  Result.Mode := Mode;
  Result.Credentials := Credentials;
end;

procedure TLoadingContext.ApplyCorsSettings(Request: TFetchRequest; Element: TElement; DefaultMode: TFetchMode);
var
  Value: string;
begin
  Request.Mode := DefaultMode;
  if not Element.HasAttributeAtom(AtomCrossorigin) then
    Exit;
  Value := AsciiLowerCase(Element.AttributeValueOf(AtomCrossorigin));
  Request.Mode := FetchModeCors;
  if Value = 'use-credentials' then
    Request.Credentials := FetchCredentialsInclude
  else
    Request.Credentials := FetchCredentialsSameOrigin;
end;

procedure TLoadingContext.ApplyReferrerPolicyAttribute(Request: TFetchRequest; Element: TElement);
var
  Policy: TReferrerPolicy;
begin
  Policy := ReferrerPolicyFromAttribute(Element.AttributeValueOf(Atomize('referrerpolicy')));
  if Policy <> ReferrerPolicyEmpty then
    Request.ReferrerPolicy := Policy;
end;

function TLoadingContext.Fetch(Request: TFetchRequest; Consumer: TFetchConsumer): TFetchJob;
begin
  Result := FFetcher.Fetch(Request, Consumer, Self);
end;

procedure TLoadingContext.CancelFetch(Job: TFetchJob);
begin
  if Job <> nil then
    FFetcher.Cancel(Job);
end;

end.
