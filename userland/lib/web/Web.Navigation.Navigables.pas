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
  A navigable (HTML Standard 7.3, a top-level traversable here): what
  a browser tab or a web view shows - its active document and window,
  its session history, and navigation (7.4):

  - Navigate: a URL that differs from the document's only in the
    fragment scrolls (fragment navigation: a new history entry of the
    same document, :target, hashchange); otherwise beforeunload is
    fired (a page that asks is confirmed through the observer), the
    navigation request is fetched (mode navigate, credentials included,
    redirects followed, the content sniffed), and its response becomes
    the new document: HTML parsed as it streams, text in a <pre>, an
    image in an image document, a network error as an error page, 204
    and 205 doing nothing, attachments and types that cannot be shown
    handed to the observer as downloads. The old document gets pagehide
    and unload and its timers and fetches stop.
  - History: push (new entries drop the forward ones) or replace;
    Back, Forward and Traverse go between entries (same-document ones
    without loading: popstate and hashchange; others load again
    preferring the cache), Reload revalidates, Stop cancels the
    navigation and stops the document's loading.
  - The observer (the browser or the web view) hears the location,
    title, favicon, loading state, document and history changes, where
    to scroll (a fragment's element, or a saved position), confirm
    requests and downloads.
  - <meta http-equiv=refresh> navigates (replacing the entry) after its
    delay once the document has loaded.
  - Child navigables (7.3.1, Web.Navigation.Navigables.Frames.inc): each
    iframe and frame element of the active document gets one, with its
    own documents, loaders, windows and session history; made when the
    element becomes connected (its initial about:blank document at
    once, so script sees contentWindow), navigated by its src or srcdoc,
    dropped when the element leaves or the document goes. Its entries
    join the top-level navigable's history.
}
unit Web.Navigation.Navigables;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Url.Origins,
  Image.Model,
  Web.Atoms,
  Web.Dom,
  Web.EventLoop,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Jobs,
  Web.Fetch.Fetcher,
  Web.Fetch.ReferrerPolicy,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Loading.Scripts,
  Web.Loading.Documents,
  Web.Navigation.Windows,
  Web.Navigation.SessionHistory,
  Web.Navigation.FramePolicy;

type
  TNavigable = class;

  TLoadingState = (LoadingIdle, LoadingRequesting, LoadingReceiving, LoadingInteractive, LoadingComplete);

  THistoryHandling = (HistoryPush, HistoryReplace, HistoryReload, HistoryTraverse);

  TNavigateOptions = record
    { Replace the current entry instead of adding one. }
    Replace: Boolean;
    { Typed, a bookmark, a link the user clicked: same-site cookies. }
    UserInitiated: Boolean;
    { The document asking (its URL and policy are the referrer); nil:
      the browser itself. }
    Source: TDocumentLoader;
    ReferrerPolicy: TReferrerPolicy;
    { A form's POST. }
    Method: string;
    Body: TBytes;
    ContentType: string;
  end;

  TDownloadInfo = record
    Url: string;
    MimeType: string;
    { From Content-Disposition, or the URL's last segment. }
    FileName: string;
  end;

  TNavigableObserver = class
  public
    procedure LocationChanged(Navigable: TNavigable; const Url: string); virtual;
    procedure TitleChanged(Navigable: TNavigable; const Title: string); virtual;
    procedure LoadingStateChanged(Navigable: TNavigable; State: TLoadingState); virtual;
    { A new active document (the web view lays it out from now on). }
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); virtual;
    { The icon (the observer owns it), nil when there is none. }
    procedure FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage); virtual;
    procedure HistoryChanged(Navigable: TNavigable); virtual;
    { Scroll Element into view (nil: to the top). }
    procedure ScrollToFragment(Navigable: TNavigable; Element: TElement); virtual;
    procedure RestoreScrollPosition(Navigable: TNavigable; X, Y: Double); virtual;
    { The page asked to stay (beforeunload); True leaves it. }
    function ConfirmUnload(Navigable: TNavigable): Boolean; virtual;
    procedure DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo); virtual;
    procedure NavigationFailed(Navigable: TNavigable; const Url, Reason: string); virtual;
  end;

  TNavigationConsumer = class(TFetchConsumer)
  public
    Navigable: TNavigable;
    procedure ProcessResponse(Job: TFetchJob; Response: TFetchResponse); override;
    procedure ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt); override;
    procedure ProcessEndOfBody(Job: TFetchJob; Success: Boolean); override;
  end;

  TNavigable = class
  private
    FLoop: TEventLoop;
    FFetcher: TFetcher;
    FSink: TResourceSink;
    FSettings: TLoadingSettings;
    FExecutor: TScriptExecutor;
    FObserver: TNavigableObserver;
    FHistory: TSessionHistory;
    FWindow: TWebWindow;
    FLoader: TDocumentLoader;
    FConsumer: TNavigationConsumer;
    FNavigationJob: TFetchJob;
    FNavigationHandling: THistoryHandling;
    { Navigation Timing of the navigation in progress. }
    FNavigationTimes: TDocumentTimes;
    FTraverseIndex: Integer;
    FNextDocumentId: QWord;
    FCurrentDocumentId: QWord;
    FState: TLoadingState;
    FGarbage: TList;
    FRefreshHandle: QWord;
    FRefreshUrl: TUrlRecord;
    FHasRefresh: Boolean;
    FRefreshDelay: Double;
    FInitialAboutBlank: Boolean;
    { Child navigables (Web.Navigation.Navigables.Frames.inc). }
    FParent: TNavigable;
    FContainer: TElement;
    FChildren: TList;
    FFrameName: string;
    FOwnsSink: Boolean;
    FId: QWord;
    FAllowances: TFrameAllowances;
    FSandboxed: Boolean;
    FAllowAttribute: string;
    FDelayedLoader: TDocumentLoader;
    FLazyPending: Boolean;
    FLazyUrl: TUrlRecord;
    FDetached: Boolean;
    FChildOrigin: TUrlOrigin;
    FHasChildOrigin: Boolean;
    procedure SetState(State: TLoadingState);
    procedure CreateInitialDocument;
    function PromptToUnload: Boolean;
    procedure UnloadActiveDocument;
    procedure CommitDocument(constref Url: TUrlRecord; Kind: TDocumentContentKind; const Charset: string);
    procedure CommitHistory(constref Url: TUrlRecord);
    procedure ShowErrorPage(constref Url: TUrlRecord; const Html: string);
    procedure StartNavigation(constref Url: TUrlRecord; constref Options: TNavigateOptions;
      Handling: THistoryHandling; CacheMode: TFetchCacheMode);
    procedure CancelNavigation;
    procedure NavigateToFragment(constref Url: TUrlRecord; Handling: THistoryHandling);
    procedure ScrollToIndicatedPart;
    function IndicatedElement(constref Url: TUrlRecord; out ToTop: Boolean): TElement;
    procedure HandleResponse(Job: TFetchJob; Response: TFetchResponse);
    procedure HandleBody(Data: Pointer; Count: PtrUInt);
    procedure HandleEnd(Success: Boolean);
    procedure LoaderTitleChanged(Loader: TDocumentLoader; const Title: string);
    procedure LoaderDomContentLoaded(Loader: TDocumentLoader);
    procedure LoaderLoaded(Loader: TDocumentLoader);
    procedure LoaderRefresh(Loader: TDocumentLoader; DelaySeconds: Double; constref Url: TUrlRecord);
    procedure LoaderIcon(Loader: TDocumentLoader; const Url: string; Image: TImage);
    procedure ScheduleRefresh;
    procedure RunRefresh;
    procedure CancelRefresh;
    procedure CollectGarbage;
    procedure Discard(Thing: TObject);
    procedure HookLoader(Loader: TDocumentLoader);
    { Frames (Web.Navigation.Navigables.Frames.inc). }
    procedure LoaderFrameInserted(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
    procedure LoaderFrameChanged(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
    procedure LoaderFrameRemoved(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom);
    procedure DetachChildren;
    procedure Detach;
    procedure ProcessFrameAttributes(Initial: Boolean);
    procedure NavigateToSrcdoc(const Html: string);
    procedure FireContainerLoad;
    procedure DelayParentLoad;
    procedure UndelayParentLoad;
    procedure StartLazyFrames;
    procedure TakeContainerSandbox;
    function FrameHistoryHandling(Requested: THistoryHandling): THistoryHandling;
    function ResponseMayBeFramed(Response: TFetchResponse; constref Url: TUrlRecord): Boolean;
    function HostObserver: TNavigableObserver;
    procedure AddFrameEntry(Frame: TNavigable);
    function FindById(Id: QWord): TNavigable;
    function TraverseFrames(TargetIndex: Integer): Boolean;
    procedure TraverseToIndex(TargetIndex: Integer);
    function DocumentOriginForCommit(constref Url: TUrlRecord; out Origin: TUrlOrigin): Boolean;
  public
    constructor Create(Fetcher: TFetcher; Sink: TResourceSink; constref Settings: TLoadingSettings;
      Executor: TScriptExecutor = nil);
    { A child navigable for a frame element of AParent's active
      document (AParent makes them). }
    constructor CreateChild(AParent: TNavigable; AContainer: TElement);
    destructor Destroy; override;
    { The navigable showing Document (through its loader), nil if none. }
    class function OfDocument(Document: TDocument): TNavigable;
    function Top: TNavigable;
    function ChildCount: Integer;
    function Child(Index: Integer): TNavigable;
    { The child navigable of a frame element of the active document. }
    function ChildFor(Element: TElement): TNavigable;
    { A navigable of the page by its target name (an iframe's name), nil
      if none. }
    function FindByName(const Name: string): TNavigable;
    { The navigable a link or form with this target navigates, as the
      HTML Standard's "rules for choosing a navigable" say ('', _self:
      this one; _parent, _top; a name); nil for a new one (_blank, a
      name not found). }
    function ChooseNavigable(const Target: string): TNavigable;
    { Starts a navigation; False when Text is not a URL. }
    function NavigateTo(const Text: string; UserInitiated: Boolean = True): Boolean;
    procedure Navigate(constref Url: TUrlRecord; constref Options: TNavigateOptions);
    { Shows Html as a new document at Url (its base URL and origin), in a
      new history entry: for programs showing HTML of their own. Going
      back to the entry later loads Url itself. False when the page
      asked to stay (beforeunload). }
    function LoadHtml(const Html: string; constref Url: TUrlRecord): Boolean;
    { history.pushState / replaceState: the document's URL becomes Url
      (same origin, checked by the caller) in a new entry of the same
      document, or the current one. }
    procedure ChangeUrlFromScript(constref Url: TUrlRecord; ReplaceEntry: Boolean);
    procedure Back;
    procedure Forward;
    procedure Traverse(Delta: Integer);
    procedure Reload(BypassCache: Boolean = False);
    procedure Stop;
    { The web view tells where the current entry is scrolled to. }
    procedure SaveScrollPosition(X, Y: Double);
    function CurrentUrl: TUrlRecord;
    function CurrentUrlText: string;
    function Title: string;
    function ActiveDocument: TDocument;
    property Window: TWebWindow read FWindow;
    property Loader: TDocumentLoader read FLoader;
    property History: TSessionHistory read FHistory;
    property State: TLoadingState read FState;
    property Loop: TEventLoop read FLoop;
    property Fetcher: TFetcher read FFetcher;
    property Sink: TResourceSink read FSink write FSink;
    property Executor: TScriptExecutor read FExecutor write FExecutor;
    property Settings: TLoadingSettings read FSettings write FSettings;
    { Not owned. }
    property ObserverObject: TNavigableObserver read FObserver write FObserver;
    { A child navigable's parent and frame element (nil for a top-level
      one). }
    property Parent: TNavigable read FParent;
    property Container: TElement read FContainer;
    property FrameName: string read FFrameName write FFrameName;
    property Id: QWord read FId;
    { The frame's sandbox (as of its last navigation): whether it is
      sandboxed, and what it still allows. }
    property Sandboxed: Boolean read FSandboxed;
    property Allowances: TFrameAllowances read FAllowances;
    { The iframe's allow attribute (Permissions Policy; kept, not
      enforced). }
    property AllowAttribute: string read FAllowAttribute;
  end;

function DefaultNavigateOptions: TNavigateOptions;

implementation

uses
  Math,
  Url.Parser,
  Url.PercentEncoding,
  Http.Priorities,
  Web.EventLoop.Tasks,
  Web.Fetch.MimeTypes,
  Web.Loading.Priorities,
  Web.Loading.Srcset,
  Web.Navigation.Events,
  Web.Navigation.ErrorPages,
  Web.Origins;

function DefaultNavigateOptions: TNavigateOptions;
begin
  Result := Default(TNavigateOptions);
  Result.Method := 'GET';
  Result.ReferrerPolicy := ReferrerPolicyEmpty;
end;

var
  LastNavigableId: QWord = 0;

function NewNavigableId: QWord;
begin
  Inc(LastNavigableId);
  Result := LastNavigableId;
end;

{ ---- the observer's defaults ---- }

procedure TNavigableObserver.LocationChanged(Navigable: TNavigable; const Url: string);
begin
end;

procedure TNavigableObserver.TitleChanged(Navigable: TNavigable; const Title: string);
begin
end;

procedure TNavigableObserver.LoadingStateChanged(Navigable: TNavigable; State: TLoadingState);
begin
end;

procedure TNavigableObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
end;

procedure TNavigableObserver.FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage);
begin
  Image.Free;
end;

procedure TNavigableObserver.HistoryChanged(Navigable: TNavigable);
begin
end;

procedure TNavigableObserver.ScrollToFragment(Navigable: TNavigable; Element: TElement);
begin
end;

procedure TNavigableObserver.RestoreScrollPosition(Navigable: TNavigable; X, Y: Double);
begin
end;

function TNavigableObserver.ConfirmUnload(Navigable: TNavigable): Boolean;
begin
  Result := True;
end;

procedure TNavigableObserver.DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo);
begin
end;

procedure TNavigableObserver.NavigationFailed(Navigable: TNavigable; const Url, Reason: string);
begin
end;

{ ---- the consumer ---- }

procedure TNavigationConsumer.ProcessResponse(Job: TFetchJob; Response: TFetchResponse);
begin
  Navigable.HandleResponse(Job, Response);
end;

procedure TNavigationConsumer.ProcessBody(Job: TFetchJob; Data: Pointer; Count: PtrUInt);
begin
  Navigable.HandleBody(Data, Count);
end;

procedure TNavigationConsumer.ProcessEndOfBody(Job: TFetchJob; Success: Boolean);
begin
  Navigable.HandleEnd(Success);
end;

{ ---- the navigable ---- }

constructor TNavigable.Create(Fetcher: TFetcher; Sink: TResourceSink; constref Settings: TLoadingSettings;
  Executor: TScriptExecutor);
begin
  inherited Create;
  FFetcher := Fetcher;
  FLoop := Fetcher.Loop;
  FSink := Sink;
  FSettings := Settings;
  FExecutor := Executor;
  FHistory := TSessionHistory.Create;
  FConsumer := TNavigationConsumer.Create;
  FConsumer.Navigable := Self;
  FGarbage := TList.Create;
  FTraverseIndex := -1;
  FChildren := TList.Create;
  FId := NewNavigableId;
  FAllowances := AllFrameAllowances;
  CreateInitialDocument;
end;

destructor TNavigable.Destroy;
begin
  CancelNavigation;
  CancelRefresh;
  DetachChildren;
  if FParent <> nil then
    Detach;
  FLoop.DiscardTasks(Self);
  FLoader.Free;
  FWindow.Free;
  CollectGarbage;
  FGarbage.Free;
  FChildren.Free;
  FConsumer.Free;
  FHistory.Free;
  if FOwnsSink then
    FSink.Free;
  if FContainer <> nil then
    FContainer.Release;
  inherited Destroy;
end;

procedure TNavigable.SetState(State: TLoadingState);
begin
  if FState = State then
    Exit;
  FState := State;
  if FObserver <> nil then
    FObserver.LoadingStateChanged(Self, State);
end;

procedure TNavigable.HookLoader(Loader: TDocumentLoader);
begin
  Loader.OnTitleChanged := @LoaderTitleChanged;
  Loader.OnDomContentLoaded := @LoaderDomContentLoaded;
  Loader.OnLoaded := @LoaderLoaded;
  Loader.OnRefresh := @LoaderRefresh;
  Loader.OnIconChanged := @LoaderIcon;
  Loader.OnFrameInserted := @LoaderFrameInserted;
  Loader.OnFrameChanged := @LoaderFrameChanged;
  Loader.OnFrameRemoved := @LoaderFrameRemoved;
end;

procedure TNavigable.CreateInitialDocument;
var
  Document: TDocument;
  Url: TUrlRecord;
  Entry: TSessionHistoryEntry;
  DocumentExecutor: TScriptExecutor;
begin
  ParseUrl('about:blank', Url);
  Document := TDocument.CreateDocument(True);
  FWindow := TWebWindow.Create(FLoop, Document);
  FWindow.Navigable := Self;
  { A frame's initial about:blank has its creator's origin. }
  if FParent <> nil then
    SetDocumentOrigin(Document, DocumentOrigin(FContainer.NodeDocument));
  DocumentExecutor := FExecutor;
  if FSandboxed and not (AllowScripts in FAllowances) then
    DocumentExecutor := nil;
  FLoader := TDocumentLoader.Create(Document, FWindow, FFetcher, FSink, Url, FSettings, DocumentExecutor);
  if FParent <> nil then
  begin
    FLoader.SetOrigin(DocumentOrigin(FContainer.NodeDocument));
    HookLoader(FLoader);
  end;
  Document.Release;
  FLoader.BeginContent(ContentHtml, 'utf-8');
  FLoader.EndOfInput;
  Inc(FNextDocumentId);
  FCurrentDocumentId := FNextDocumentId;
  Entry := TSessionHistoryEntry.Create;
  Entry.Url := Url;
  Entry.DocumentId := FCurrentDocumentId;
  FHistory.Push(Entry);
  FInitialAboutBlank := True;
  if FObserver <> nil then
    FObserver.DocumentChanged(Self, Document, FWindow);
end;

procedure TNavigable.Discard(Thing: TObject);
begin
  if Thing = nil then
    Exit;
  FGarbage.Add(Thing);
  if FGarbage.Count = 1 then
    FLoop.QueueMethod(@CollectGarbage, TaskSourceNavigation, Self);
end;

procedure TNavigable.CollectGarbage;
var
  Index: Integer;
  Items, Others: TList;
begin
  Items := FGarbage;
  FGarbage := TList.Create;
  Others := TList.Create;
  try
    { Loaders before the windows that their documents point at (sorted
      out first: a freed loader cannot be asked its class). }
    for Index := 0 to Items.Count - 1 do
      if not (TObject(Items[Index]) is TDocumentLoader) then
        Others.Add(Items[Index]);
    for Index := 0 to Items.Count - 1 do
      if Others.IndexOf(Items[Index]) < 0 then
        TObject(Items[Index]).Free;
    for Index := 0 to Others.Count - 1 do
      TObject(Others[Index]).Free;
  finally
    Others.Free;
    Items.Free;
  end;
end;

function TNavigable.CurrentUrl: TUrlRecord;
begin
  Result := FLoader.DocumentUrl;
end;

function TNavigable.CurrentUrlText: string;
begin
  Result := SerializeUrl(FLoader.DocumentUrl);
end;

function TNavigable.Title: string;
begin
  Result := FLoader.Document.Title;
end;

function TNavigable.ActiveDocument: TDocument;
begin
  Result := FLoader.Document;
end;

function TNavigable.NavigateTo(const Text: string; UserInitiated: Boolean): Boolean;
var
  Url: TUrlRecord;
  Options: TNavigateOptions;
begin
  Result := ParseUrl(Text, Url);
  if not Result then
    Exit;
  Options := DefaultNavigateOptions;
  Options.UserInitiated := UserInitiated;
  Navigate(Url, Options);
end;

procedure TNavigable.Navigate(constref Url: TUrlRecord; constref Options: TNavigateOptions);
var
  Handling: THistoryHandling;
  Current: TUrlRecord;
begin
  if Url.Scheme = 'javascript' then
    Exit;
  if Options.Replace or FInitialAboutBlank then
    Handling := HistoryReplace
  else
    Handling := HistoryPush;
  if FParent <> nil then
  begin
    Handling := FrameHistoryHandling(Handling);
    FLazyPending := False;
  end;
  Current := FLoader.DocumentUrl;
  if Url.HasFragment and ((Options.Method = '') or (Options.Method = 'GET')) and
     (SerializeUrl(Url, True) = SerializeUrl(Current, True)) and not FInitialAboutBlank then
  begin
    CancelNavigation;
    NavigateToFragment(Url, Handling);
    Exit;
  end;
  StartNavigation(Url, Options, Handling, FetchCacheDefault);
end;

function TNavigable.PromptToUnload: Boolean;
var
  Event: TBeforeUnloadEvent;
  Asked: Boolean;
begin
  Result := True;
  if (FWindow = nil) or FInitialAboutBlank then
    Exit;
  Event := TBeforeUnloadEvent.Create('beforeunload', False, True);
  try
    Event.IsTrusted := True;
    FWindow.DispatchEvent(Event);
    Asked := Event.DefaultPrevented or (Event.UnloadReturnValue <> '');
  finally
    Event.Free;
  end;
  if Asked and (HostObserver <> nil) then
    Result := HostObserver.ConfirmUnload(Self);
end;

procedure TNavigable.CancelNavigation;
begin
  if FNavigationJob <> nil then
  begin
    FFetcher.Cancel(FNavigationJob);
    FNavigationJob := nil;
  end;
end;

procedure TNavigable.StartNavigation(constref Url: TUrlRecord; constref Options: TNavigateOptions;
  Handling: THistoryHandling; CacheMode: TFetchCacheMode);
var
  Request: TFetchRequest;
  Method: string;
begin
  if not PromptToUnload then
    Exit;
  CancelNavigation;
  CancelRefresh;
  Method := Options.Method;
  if Method = '' then
    Method := 'GET';
  Request := TFetchRequest.Create(Method, Url);
  Request.Mode := FetchModeNavigate;
  Request.Destination := DestinationDocument;
  if FParent <> nil then
  begin
    if FContainer.IsHtmlElement(AtomFrame) then
      Request.Destination := DestinationFrame
    else
      Request.Destination := DestinationIframe;
    TakeContainerSandbox;
    DelayParentLoad;
  end;
  Request.Credentials := FetchCredentialsInclude;
  Request.Redirect := FetchRedirectFollow;
  Request.CacheMode := CacheMode;
  Request.SniffContent := True;
  Request.UserInitiated := Options.UserInitiated;
  Request.InitiatorType := 'navigation';
  Request.Priority := PriorityFor(ResourceDocument);
  Request.ReferrerPolicy := Options.ReferrerPolicy;
  if (Options.Source <> nil) and not Options.UserInitiated then
    Request.Client := Options.Source.Client
  else
    Request.ReferrerKind := ReferrerNone;
  if Length(Options.Body) > 0 then
  begin
    Request.Body := Options.Body;
    Request.HasBody := True;
    if Options.ContentType <> '' then
      Request.Headers.SetValue('content-type', Options.ContentType);
  end;
  FNavigationHandling := Handling;
  FNavigationTimes := Default(TDocumentTimes);
  FNavigationTimes.NavigationStart := GetTickCount64;
  FNavigationTimes.FetchStart := FNavigationTimes.NavigationStart;
  case Handling of
    HistoryReload: FNavigationTimes.Kind := 'reload';
    HistoryTraverse: FNavigationTimes.Kind := 'back_forward';
  else
    FNavigationTimes.Kind := 'navigate';
  end;
  FNavigationJob := FFetcher.Fetch(Request, FConsumer, Self);
  SetState(LoadingRequesting);
end;

procedure TNavigable.UnloadActiveDocument;
var
  Hide: TPageTransitionEvent;
  OldWindow: TWebWindow;
  OldLoader: TDocumentLoader;
begin
  OldWindow := FWindow;
  OldLoader := FLoader;
  if OldWindow <> nil then
  begin
    Hide := TPageTransitionEvent.Create('pagehide');
    Hide.Persisted := False;
    FireTrustedEvent(OldWindow, Hide);
    FireEvent(OldWindow, 'unload');
    OldWindow.StopActivity;
  end;
  if OldLoader <> nil then
    OldLoader.Abort;
  DetachChildren;
  FWindow := nil;
  FLoader := nil;
  Discard(OldLoader);
  Discard(OldWindow);
end;

procedure TNavigable.CommitHistory(constref Url: TUrlRecord);
var
  Entry: TSessionHistoryEntry;
begin
  Inc(FNextDocumentId);
  FCurrentDocumentId := FNextDocumentId;
  case FNavigationHandling of
    HistoryTraverse:
      begin
        FHistory.Index := FTraverseIndex;
        Entry := FHistory.Current;
        Entry.Url := Url;
        { The other entries of the document that went are of no document
          now: going to them loads again. }
        Entry.DocumentId := FCurrentDocumentId;
      end;
    HistoryReload:
      begin
        Entry := FHistory.Current;
        Entry.Url := Url;
        Entry.DocumentId := FCurrentDocumentId;
      end;
  else
    Entry := TSessionHistoryEntry.Create;
    Entry.Url := Url;
    Entry.DocumentId := FCurrentDocumentId;
    if FNavigationHandling = HistoryReplace then
      FHistory.ReplaceCurrent(Entry)
    else
    begin
      FHistory.Push(Entry);
      if FParent <> nil then
        Top.AddFrameEntry(Self);
    end;
  end;
  FInitialAboutBlank := False;
end;

procedure TNavigable.CommitDocument(constref Url: TUrlRecord; Kind: TDocumentContentKind; const Charset: string);
var
  Document: TDocument;
  TopOrigin, Origin: TUrlOrigin;
  DocumentExecutor: TScriptExecutor;
  HasOrigin: Boolean;
begin
  UnloadActiveDocument;
  Document := TDocument.CreateDocument(True);
  FWindow := TWebWindow.Create(FLoop, Document);
  FWindow.Navigable := Self;
  if FParent <> nil then
    TopOrigin := DocumentOrigin(Top.ActiveDocument)
  else
    TopOrigin := OriginOfUrl(Url);
  HasOrigin := DocumentOriginForCommit(Url, Origin);
  if HasOrigin then
    SetDocumentOrigin(Document, Origin);
  DocumentExecutor := FExecutor;
  if FSandboxed and not (AllowScripts in FAllowances) then
    DocumentExecutor := nil;
  FLoader := TDocumentLoader.Create(Document, FWindow, FFetcher, FSink, Url, FSettings, DocumentExecutor, @TopOrigin);
  if HasOrigin then
    FLoader.SetOrigin(Origin);
  FLoader.Times := FNavigationTimes;
  if FLoader.Times.NavigationStart = 0 then
  begin
    FLoader.Times.NavigationStart := GetTickCount64;
    FLoader.Times.FetchStart := FLoader.Times.NavigationStart;
    FLoader.Times.ResponseStart := FLoader.Times.NavigationStart;
    FLoader.Times.Kind := 'navigate';
  end;
  FNavigationTimes := Default(TDocumentTimes);
  if FExecutor <> nil then
    FExecutor.DocumentTimed(FLoader);
  Document.Release;
  HookLoader(FLoader);
  CommitHistory(Url);
  if FObserver <> nil then
  begin
    FObserver.DocumentChanged(Self, Document, FWindow);
    FObserver.LocationChanged(Self, SerializeUrl(Url));
    FObserver.TitleChanged(Self, '');
    FObserver.HistoryChanged(Self);
  end;
  SetState(LoadingReceiving);
  FLoader.BeginContent(Kind, Charset);
end;

procedure TNavigable.ChangeUrlFromScript(constref Url: TUrlRecord; ReplaceEntry: Boolean);
var
  Entry: TSessionHistoryEntry;
begin
  if FLoader = nil then
    Exit;
  if ReplaceEntry then
    FHistory.Current.Url := Url
  else
  begin
    Entry := TSessionHistoryEntry.Create;
    Entry.Url := Url;
    Entry.DocumentId := FCurrentDocumentId;
    FHistory.Push(Entry);
    if FParent <> nil then
      Top.AddFrameEntry(Self);
  end;
  FLoader.ChangeDocumentUrl(Url);
  if FObserver <> nil then
  begin
    FObserver.LocationChanged(Self, SerializeUrl(Url));
    FObserver.HistoryChanged(Self);
  end;
end;

function TNavigable.LoadHtml(const Html: string; constref Url: TUrlRecord): Boolean;
begin
  Result := PromptToUnload;
  if not Result then
    Exit;
  CancelNavigation;
  CancelRefresh;
  if FInitialAboutBlank then
    FNavigationHandling := HistoryReplace
  else
    FNavigationHandling := HistoryPush;
  CommitDocument(Url, ContentHtml, 'utf-8');
  FLoader.ReceiveBytes(PChar(Html), Length(Html));
  FLoader.EndOfInput;
end;

procedure TNavigable.ShowErrorPage(constref Url: TUrlRecord; const Html: string);
begin
  CommitDocument(Url, ContentHtml, 'utf-8');
  FLoader.ReceiveBytes(PChar(Html), Length(Html));
  FLoader.EndOfInput;
end;

function DispositionFileName(const Value, UrlPath: string): string;
var
  Position: Integer;
begin
  Result := '';
  Position := Pos('filename=', LowerCase(Value));
  if Position > 0 then
  begin
    Result := Trim(Copy(Value, Position + Length('filename='), MaxInt));
    if Pos(';', Result) > 0 then
      Result := Trim(Copy(Result, 1, Pos(';', Result) - 1));
    if (Length(Result) >= 2) and (Result[1] = '"') then
      Result := Copy(Result, 2, Length(Result) - 2);
  end;
  if Result = '' then
    Result := ExtractFileName(StringReplace(UrlPath, '/', PathDelim, [rfReplaceAll]));
  if Result = '' then
    Result := 'download';
end;

procedure TNavigable.HandleResponse(Job: TFetchJob; Response: TFetchResponse);
var
  Essence, Disposition: string;
  Download: TDownloadInfo;
  Kind: TDocumentContentKind;
  Url: TUrlRecord;
begin
  if Job <> FNavigationJob then
    Exit;
  if Response.HasUrl then
    Url := Response.Url
  else
    Url := Job.Request.Url;
  if Response.IsNetworkError then
  begin
    FNavigationJob := nil;
    FFetcher.Cancel(Job);
    if FObserver <> nil then
      FObserver.NavigationFailed(Self, SerializeUrl(Job.Request.Url), Response.ErrorText);
    ShowErrorPage(Job.Request.Url, NetworkErrorPage(SerializeUrl(Job.Request.Url), Response.ErrorText));
    Exit;
  end;
  if (Response.Status = 204) or (Response.Status = 205) then
  begin
    FNavigationJob := nil;
    FFetcher.Cancel(Job);
    SetState(LoadingComplete);
    UndelayParentLoad;
    Exit;
  end;
  if (FParent <> nil) and not ResponseMayBeFramed(Response, Url) then
  begin
    FNavigationJob := nil;
    FFetcher.Cancel(Job);
    ShowErrorPage(Url, NetworkErrorPage(SerializeUrl(Url), 'the page refuses to be shown in a frame of this site'));
    Exit;
  end;
  Essence := Response.ComputedEssence;
  Disposition := LowerCase(Response.Headers.Value('content-disposition'));
  if IsHtmlMimeType(Essence) or (Essence = 'application/xhtml+xml') then
    Kind := ContentHtml
  else if IsTextLikeMimeType(Essence) then
    Kind := ContentText
  else if IsSupportedImageType(Essence) then
    Kind := ContentImage
  else
    Kind := ContentPrepared;
  if (Copy(TrimHttpWhitespace(Disposition), 1, 10) = 'attachment') or (Kind = ContentPrepared) then
  begin
    FNavigationJob := nil;
    FFetcher.Cancel(Job);
    Download.Url := SerializeUrl(Url);
    Download.MimeType := Essence;
    Download.FileName := DispositionFileName(Response.Headers.Value('content-disposition'), Url.Path);
    if HostObserver <> nil then
      HostObserver.DownloadRequested(Self, Download);
    if FInitialAboutBlank and (FParent = nil) then
      ShowErrorPage(Url, CannotDisplayPage(SerializeUrl(Url), Essence))
    else
    begin
      SetState(LoadingComplete);
      UndelayParentLoad;
    end;
    Exit;
  end;
  FNavigationTimes.ResponseStart := GetTickCount64;
  FNavigationTimes.Protocol := Response.Protocol;
  FNavigationTimes.Status := Response.Status;
  FNavigationTimes.RedirectCount := Job.Request.RedirectCount;
  CommitDocument(Url, Kind, Response.Charset);
  if Kind = ContentImage then
  begin
    { The image document's img loads the image itself (from the cache). }
    FNavigationJob := nil;
    FFetcher.Cancel(Job);
    FLoader.EndOfInput;
  end;
end;

procedure TNavigable.HandleBody(Data: Pointer; Count: PtrUInt);
begin
  if FLoader <> nil then
    FLoader.ReceiveBytes(Data, Count);
end;

procedure TNavigable.HandleEnd(Success: Boolean);
begin
  FNavigationJob := nil;
  if FLoader <> nil then
    FLoader.EndOfInput;
end;

procedure TNavigable.LoaderTitleChanged(Loader: TDocumentLoader; const Title: string);
begin
  if Loader <> FLoader then
    Exit;
  if FHistory.Current <> nil then
    FHistory.Current.Title := Title;
  if FObserver <> nil then
    FObserver.TitleChanged(Self, Title);
end;

procedure TNavigable.LoaderDomContentLoaded(Loader: TDocumentLoader);
begin
  if Loader <> FLoader then
    Exit;
  SetState(LoadingInteractive);
  if (FNavigationHandling = HistoryTraverse) or (FNavigationHandling = HistoryReload) then
    Exit;
  ScrollToIndicatedPart;
end;

procedure TNavigable.LoaderLoaded(Loader: TDocumentLoader);
var
  Entry: TSessionHistoryEntry;
begin
  if Loader <> FLoader then
    Exit;
  SetState(LoadingComplete);
  StartLazyFrames;
  if FParent <> nil then
  begin
    if not FInitialAboutBlank then
      FireContainerLoad;
    UndelayParentLoad;
  end;
  Entry := FHistory.Current;
  if (FNavigationHandling in [HistoryTraverse, HistoryReload]) and (Entry <> nil) and Entry.HasScrollPosition and
     (FObserver <> nil) then
    FObserver.RestoreScrollPosition(Self, Entry.ScrollX, Entry.ScrollY);
  if FHasRefresh then
    ScheduleRefresh;
end;

procedure TNavigable.LoaderRefresh(Loader: TDocumentLoader; DelaySeconds: Double; constref Url: TUrlRecord);
begin
  if (Loader <> FLoader) or FHasRefresh then
    Exit;
  FHasRefresh := True;
  FRefreshUrl := Url;
  FRefreshDelay := DelaySeconds;
  if Loader.LoadFired then
    ScheduleRefresh;
end;

procedure TNavigable.ScheduleRefresh;
var
  Task: TMethodTask;
begin
  if FRefreshHandle <> 0 then
    Exit;
  Task := TMethodTask.Create(@RunRefresh);
  Task.Source := TaskSourceNavigation;
  Task.Group := Self;
  FRefreshHandle := FLoop.ScheduleTask(Task, FRefreshDelay * 1000);
end;

procedure TNavigable.RunRefresh;
var
  Options: TNavigateOptions;
  Target: TUrlRecord;
begin
  FRefreshHandle := 0;
  if not FHasRefresh then
    Exit;
  FHasRefresh := False;
  Target := FRefreshUrl;
  Options := DefaultNavigateOptions;
  Options.Replace := True;
  Options.Source := FLoader;
  StartNavigation(Target, Options, HistoryReplace, FetchCacheDefault);
end;

procedure TNavigable.CancelRefresh;
begin
  FHasRefresh := False;
  if FRefreshHandle <> 0 then
    FLoop.CancelScheduledTask(FRefreshHandle);
  FRefreshHandle := 0;
end;

procedure TNavigable.LoaderIcon(Loader: TDocumentLoader; const Url: string; Image: TImage);
begin
  if (Loader <> FLoader) or (FObserver = nil) then
  begin
    Image.Free;
    Exit;
  end;
  FObserver.FaviconChanged(Self, Url, Image);
end;

function TNavigable.IndicatedElement(constref Url: TUrlRecord; out ToTop: Boolean): TElement;
var
  Fragment, Decoded: string;
  Node: TNode;
  Document: TDocument;
begin
  Result := nil;
  ToTop := False;
  if not Url.HasFragment then
    Exit;
  Document := FLoader.Document;
  Fragment := Url.Fragment;
  if Fragment = '' then
  begin
    ToTop := True;
    Exit;
  end;
  Result := Document.GetElementById(Fragment);
  if Result <> nil then
    Exit;
  Decoded := PercentDecode(Fragment);
  Result := Document.GetElementById(Decoded);
  if Result <> nil then
    Exit;
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement and TElement(Node).IsHtmlElement(AtomA) and
       (TElement(Node).AttributeValueOf(AtomName) = Decoded) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Document);
  end;
  ToTop := AsciiLowerCase(Decoded) = 'top';
end;

procedure TNavigable.ScrollToIndicatedPart;
var
  Element: TElement;
  ToTop: Boolean;
begin
  if FLoader = nil then
    Exit;
  Element := IndicatedElement(FLoader.DocumentUrl, ToTop);
  FLoader.Document.TargetElement := Element;
  if (FObserver <> nil) and ((Element <> nil) or ToTop) then
    FObserver.ScrollToFragment(Self, Element);
end;

type
  THashChange = class
  public
    Window: TWebWindow;
    OldUrl, NewUrl: string;
  end;

  THashChangeFirer = class
  public
    procedure Fire(Data: TObject);
  end;

var
  HashChangeFirer: THashChangeFirer;

procedure THashChangeFirer.Fire(Data: TObject);
var
  Change: THashChange;
  Event: THashChangeEvent;
begin
  Change := THashChange(Data);
  Event := THashChangeEvent.Create('hashchange', True, False);
  Event.OldUrl := Change.OldUrl;
  Event.NewUrl := Change.NewUrl;
  FireTrustedEvent(Change.Window, Event);
end;

procedure TNavigable.NavigateToFragment(constref Url: TUrlRecord; Handling: THistoryHandling);
var
  Entry: TSessionHistoryEntry;
  Change: THashChange;
  OldUrl: string;
begin
  OldUrl := CurrentUrlText;
  if Handling <> HistoryTraverse then
  begin
    Entry := TSessionHistoryEntry.Create;
    Entry.Url := Url;
    Entry.DocumentId := FCurrentDocumentId;
    Entry.Title := FLoader.Document.Title;
    if Handling = HistoryReplace then
      FHistory.ReplaceCurrent(Entry)
    else
    begin
      FHistory.Push(Entry);
      if FParent <> nil then
        Top.AddFrameEntry(Self);
    end;
  end;
  FLoader.ChangeDocumentUrl(Url);
  if FObserver <> nil then
  begin
    FObserver.LocationChanged(Self, SerializeUrl(Url));
    FObserver.HistoryChanged(Self);
  end;
  ScrollToIndicatedPart;
  if OldUrl <> SerializeUrl(Url) then
  begin
    Change := THashChange.Create;
    Change.Window := FWindow;
    Change.OldUrl := OldUrl;
    Change.NewUrl := SerializeUrl(Url);
    FLoop.QueueTask(TDataTask.Create(@HashChangeFirer.Fire, Change), TaskSourceDomManipulation, FWindow);
  end;
end;

procedure TNavigable.Back;
begin
  Traverse(-1);
end;

procedure TNavigable.Forward;
begin
  Traverse(1);
end;

procedure TNavigable.Traverse(Delta: Integer);
var
  Target: TSessionHistoryEntry;
  TargetIndex: Integer;
  Options: TNavigateOptions;
  Pop: TPopStateEvent;
  OldUrl: string;
  Change: THashChange;
begin
  if not FHistory.CanTraverse(Delta) then
    Exit;
  TargetIndex := FHistory.Index + Delta;
  Target := FHistory[TargetIndex];
  { Steps of child navigables only: they traverse, this document stays. }
  if (FParent = nil) and TraverseFrames(TargetIndex) then
    Exit;
  if Target.DocumentId = FCurrentDocumentId then
  begin
    CancelNavigation;
    OldUrl := CurrentUrlText;
    FHistory.Index := TargetIndex;
    FLoader.ChangeDocumentUrl(Target.Url);
    if FObserver <> nil then
    begin
      FObserver.LocationChanged(Self, Target.UrlText);
      FObserver.HistoryChanged(Self);
      if Target.HasScrollPosition then
        FObserver.RestoreScrollPosition(Self, Target.ScrollX, Target.ScrollY)
      else
        ScrollToIndicatedPart;
    end;
    Pop := TPopStateEvent.Create('popstate');
    Pop.State := Target.State;
    FireTrustedEvent(FWindow, Pop);
    if OldUrl <> Target.UrlText then
    begin
      Change := THashChange.Create;
      Change.Window := FWindow;
      Change.OldUrl := OldUrl;
      Change.NewUrl := Target.UrlText;
      FLoop.QueueTask(TDataTask.Create(@HashChangeFirer.Fire, Change), TaskSourceDomManipulation, FWindow);
    end;
    Exit;
  end;
  FTraverseIndex := TargetIndex;
  Options := DefaultNavigateOptions;
  StartNavigation(Target.Url, Options, HistoryTraverse, FetchCacheForceCache);
end;

procedure TNavigable.Reload(BypassCache: Boolean);
var
  Options: TNavigateOptions;
  Mode: TFetchCacheMode;
begin
  Options := DefaultNavigateOptions;
  if BypassCache then
    Mode := FetchCacheReload
  else
    Mode := FetchCacheNoCache;
  StartNavigation(CurrentUrl, Options, HistoryReload, Mode);
end;

procedure TNavigable.Stop;
begin
  CancelNavigation;
  CancelRefresh;
  if (FLoader <> nil) and not FLoader.LoadFired then
  begin
    FLoader.Abort;
    SetState(LoadingComplete);
  end;
end;

procedure TNavigable.SaveScrollPosition(X, Y: Double);
var
  Entry: TSessionHistoryEntry;
begin
  Entry := FHistory.Current;
  if Entry = nil then
    Exit;
  Entry.HasScrollPosition := True;
  Entry.ScrollX := X;
  Entry.ScrollY := Y;
end;

{$I Web.Navigation.Navigables.Frames.inc}

initialization
  HashChangeFirer := THashChangeFirer.Create;
  SrcdocNavigator := TSrcdocNavigator.Create;

finalization
  HashChangeFirer.Free;
  SrcdocNavigator.Free;

end.
