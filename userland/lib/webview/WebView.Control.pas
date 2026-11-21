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
  TWebView: a control that shows web pages, for any program with
  controls (libcontrols).

    View := TWebView.Create(Root);
    View.Align := AlignClient;
    View.OnTitleChanged := @TitleChanged;
    View.Navigate('https://example.com/');
    View.LoadHtml('<p>Hello</p>', 'about:blank');

  The pages run in content processes (ProcessModel = ProcessModelSeparate,
  the default): one per site (WebView.ContentProcesses), sandboxed, each
  hosting a page engine (WebView.Engine) for this view. The view paints
  the frames its process puts in a shared section, sends it the input,
  and tells its host what the page tells (title, location, loading,
  dialogs, links, downloads). A page that crashes shows "This tab
  crashed" with Reload; one that stops answering gets a bar with Wait
  and Stop; the program and its other views go on. A navigation to
  another site moves the view to that site's process. While the page
  is busy, the wheel scrolls the last frame (async scrolling).

  ProcessModelInProcess (or no /bin/webcontent) runs the engine in the
  program as a child control: what simple programs showing their own
  HTML may prefer; then Page, Navigable, Document and DocumentLayout
  reach the engine's objects (nil in a separate process).

  Answers that used to be immediate come back later from a content
  process: FindText's (OnFindResult; FindText returns the last answer),
  SelectedText and PageText (the last the process told). The page's
  alert, confirm, prompt and beforeunload come to OnScriptAlert,
  OnScriptConfirm, OnScriptPrompt and OnConfirmUnload when set (modal as
  the host makes them), else to a sheet across the top of the view,
  modal for this view only.
}
unit WebView.Control;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Drawing.Canvas,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Image.Model,
  Windowing.Messages,
  Controls.Base,
  Controls.Timers,
  Controls.Menus,
  Web.Dom,
  Web.Navigation.Navigables,
  Web.Navigation.Pages,
  Web.Loading.Scripts,
  Web.Layout.Document,
  Web.Fetch.Fetcher,
  WebIpc.Messages,
  WebIpc.ViewMessages,
  WebIpc.SharedSurfaces,
  WebView.Types,
  WebView.Engine,
  WebView.ContentProcess,
  WebView.PromptSheet,
  WebView.RecoveryPanels;

const
  { A sheet that was answered is freed (posted to the view). }
  MessageWebViewReleaseSheet = $0F03;

type
  TWebView = class;

  { Makes the script engine for a view's page (in the program only). }
  TScriptExecutorFactory = function(View: TWebView; Page: TWebPage): TScriptExecutor;

  TLinkDisposition = WebView.Types.TLinkDisposition;
  TWebContextInfo = WebView.Types.TWebContextInfo;
  TWebViewProcessModel = WebView.Types.TWebViewProcessModel;

const
  { The values of the types above, for programs that use only this unit. }
  LinkInView = WebView.Types.LinkInView;
  LinkInNewTab = WebView.Types.LinkInNewTab;
  LinkInBackgroundTab = WebView.Types.LinkInBackgroundTab;
  LinkInNewWindow = WebView.Types.LinkInNewWindow;
  ProcessModelSeparate = WebView.Types.ProcessModelSeparate;
  ProcessModelInProcess = WebView.Types.ProcessModelInProcess;

type

  TWebViewEvent = procedure(Sender: TWebView) of object;
  TWebViewTextEvent = procedure(Sender: TWebView; const Value: string) of object;
  TWebViewLoadingEvent = procedure(Sender: TWebView; State: TLoadingState) of object;
  TWebViewLinkEvent = procedure(Sender: TWebView; const Url: string; Disposition: TLinkDisposition;
    var Handled: Boolean) of object;
  TWebViewDownloadEvent = procedure(Sender: TWebView; constref Download: TDownloadInfo) of object;
  TWebViewFailureEvent = procedure(Sender: TWebView; const Url, Reason: string) of object;
  TWebViewContextEvent = procedure(Sender: TWebView; constref Info: TWebContextInfo; var Handled: Boolean) of object;
  TWebViewConfirmEvent = function(Sender: TWebView): Boolean of object;
  TWebViewScriptConfirmEvent = function(Sender: TWebView; const Message: string): Boolean of object;
  TWebViewScriptPromptEvent = function(Sender: TWebView; const Message, Default: string; out Answer: string): Boolean
    of object;
  TWebViewConsoleEvent = procedure(Sender: TWebView; const Level, Value: string) of object;
  TWebViewFindEvent = procedure(Sender: TWebView; const Needle: string; Found: Boolean) of object;
  { Kind: 'alert', 'confirm', 'prompt' or 'leave'. }
  TWebViewDialogEvent = procedure(Sender: TWebView; const Kind, Message: string) of object;
  { Crashed: the process ended (ExitCode); Hung: stopped answering
    (True) or answers again (False); Started: a new process (its id). }
  TWebViewProcessEvent = procedure(Sender: TWebView; const What: string; Value: Int64) of object;

  TWebView = class(TControl)
  private
    FModel: TWebViewProcessModel;
    FModelChosen: Boolean;
    { In the program. }
    FEngine: TWebEngineView;
    FScriptExecutorFactory: TScriptExecutorFactory;
    { In a content process. }
    FProcess: TContentProcess;
    FLink: TContentClient;
    FShared: TSharedSurface;
    FSharedId: LongWord;
    FFrame: TSurface;
    FHasFrame: Boolean;
    FFrameInfo: TIpcFrameInfo;
    FSentGeometry: TIpcViewGeometry;
    FSentVisible: Boolean;
    FSentFocused: Boolean;
    FInputSequence: LongWord;
    FInputSentAt: QWord;
    FFrameAt: QWord;
    { Async scrolling: how far the last frame is shown moved up (device
      pixels), and the input that will have scrolled it by then. }
    FScrollShift: Double;
    FShiftUntilInput: LongWord;
    FStateTimer: TTimer;
    FNextRequestId: LongWord;
    FFindRequestId: LongWord;
    FFindNeedle: string;
    FLastFindResult: Boolean;
    FPopupMenu: TMenuItem;
    FPopupMenuId: LongWord;
    FDefaultMenu: TMenuItem;
    FDefaultMenuLink: string;
    { A dialog the page waits for. }
    FSheet: TPromptSheet;
    FSheetRequestId: LongWord;
    FSheetRequestKind: Word;
    FCrashPanel: TCrashPanel;
    FHangBar: THangBar;
    FHangWaitUntil: QWord;
    FInterruptTimes: array of QWord;
    { Sites left behind by navigations to other sites (back and
      forward across processes). }
    FBackUrls: TStringList;
    FForwardUrls: TStringList;
    FRemoteCanGoBack: Boolean;
    FRemoteCanGoForward: Boolean;
    FSelectedText: string;
    FPageText: string;
    FScriptingEnabled: Boolean;
    FAboutPageProvider: TAboutPageProvider;
    { State told to the host. }
    FUrl: string;
    FTitle: string;
    FState: TLoadingState;
    FFavicon: TImage;
    FStatusText: string;
    FZoom: Double;
    { Events. }
    FOnTitleChanged: TWebViewTextEvent;
    FOnLocationChanged: TWebViewTextEvent;
    FOnLoadingStateChanged: TWebViewLoadingEvent;
    FOnFaviconChanged: TWebViewEvent;
    FOnStatusText: TWebViewTextEvent;
    FOnHistoryChanged: TWebViewEvent;
    FOnZoomChanged: TWebViewEvent;
    FOnLinkClicked: TWebViewLinkEvent;
    FOnDownloadRequested: TWebViewDownloadEvent;
    FOnNavigationFailed: TWebViewFailureEvent;
    FOnContextMenuRequested: TWebViewContextEvent;
    FOnConfirmUnload: TWebViewConfirmEvent;
    FOnScriptAlert: TWebViewTextEvent;
    FOnScriptConfirm: TWebViewScriptConfirmEvent;
    FOnScriptPrompt: TWebViewScriptPromptEvent;
    FOnConsoleMessage: TWebViewConsoleEvent;
    FOnFindResult: TWebViewFindEvent;
    FOnScriptDialog: TWebViewDialogEvent;
    FOnProcessEvent: TWebViewProcessEvent;
    function GetPage: TWebPage;
    function GetNavigable: TNavigable;
    function GetDocument: TDocument;
    function GetDocumentLayout: TDocumentLayout;
    function GetCanGoBack: Boolean;
    function GetCanGoForward: Boolean;
    function GetContentProcessId: Int64;
    procedure SetZoom(Value: Double);
    procedure SetScriptingEnabled(Value: Boolean);
    procedure SetProcessModel(Value: TWebViewProcessModel);
    procedure SetAboutPageProvider(Value: TAboutPageProvider);
    { Which way the pages run, decided at the first page. }
    function RunsInProcess: Boolean;
    function RemoteSite: string;
    { Told to the host. }
    procedure TellLocation(const Url: string);
    procedure TellTitle(const Title: string);
    procedure TellLoadingState(State: TLoadingState);
    procedure TellFavicon(Image: TImage);
    procedure TellStatus(const Value: string);
    procedure TellHistory;
    procedure TellZoom(Value: Double);
    procedure TellLink(const Url: string; Disposition: TLinkDisposition; var Handled: Boolean);
    procedure TellDownload(constref Download: TDownloadInfo);
    procedure TellFailure(const Url, Reason: string);
    procedure TellConsole(const Level, Value: string);
    procedure TellFindResult(const Needle: string; Found: Boolean);
    procedure TellProcessEvent(const What: string; Value: Int64);
    { In the program (WebView.Control.Local.inc). }
    procedure EnsureEngine;
    procedure EngineTitleChanged(Sender: TWebEngineView; const Value: string);
    procedure EngineLocationChanged(Sender: TWebEngineView; const Value: string);
    procedure EngineLoadingStateChanged(Sender: TWebEngineView; State: TLoadingState);
    procedure EngineFaviconChanged(Sender: TWebEngineView);
    procedure EngineStatusText(Sender: TWebEngineView; const Value: string);
    procedure EngineHistoryChanged(Sender: TWebEngineView);
    procedure EngineZoomChanged(Sender: TWebEngineView);
    procedure EngineLinkClicked(Sender: TWebEngineView; const Url: string; Disposition: TLinkDisposition;
      var Handled: Boolean);
    procedure EngineDownloadRequested(Sender: TWebEngineView; constref Download: TDownloadInfo);
    procedure EngineNavigationFailed(Sender: TWebEngineView; const Url, Reason: string);
    procedure EngineContextMenu(Sender: TWebEngineView; constref Info: TWebContextInfo; var Handled: Boolean);
    function EngineConfirmUnload(Sender: TWebEngineView): Boolean;
    procedure EngineScriptAlert(Sender: TWebEngineView; const Value: string);
    function EngineScriptConfirm(Sender: TWebEngineView; const Message: string): Boolean;
    function EngineScriptPrompt(Sender: TWebEngineView; const Message, Default: string; out Answer: string): Boolean;
    procedure EngineConsole(Sender: TWebEngineView; const Level, Value: string);
    { In a content process (WebView.Control.Remote.inc). }
    function EnsureProcessFor(const Site: string): Boolean;
    procedure LeaveProcess;
    procedure SendToProcess(Kind: Word; const Payload: TBytes; RequestId: LongWord = 0);
    function NextRequestId: LongWord;
    procedure SendGeometryIfChanged;
    function CurrentGeometry: TIpcViewGeometry;
    function IsShown: Boolean;
    procedure RemoteReceived(Message: TIpcMessage);
    procedure RemoteEnded(Crashed: Boolean; ExitCode: LongInt);
    procedure RemoteResponsive(Responsive: Boolean);
    procedure TakeSurface(Message: TIpcMessage);
    procedure TakeFrame(Message: TIpcMessage);
    procedure TakeFavicon(Message: TIpcMessage);
    procedure TakeContextMenu(Message: TIpcMessage);
    procedure TakePopupMenu(Message: TIpcMessage);
    procedure TakeOpenUrl(Message: TIpcMessage);
    procedure TakeDialog(Message: TIpcMessage);
    procedure TakeLinkClicked(Message: TIpcMessage);
    procedure TakeDownload(Message: TIpcMessage);
    procedure AnswerAboutPage(Message: TIpcMessage);
    procedure AnswerClipboardRead(Message: TIpcMessage);
    procedure PopupItemChosen(Item: TMenuItem);
    procedure ShowDefaultMenu(constref Info: TWebContextInfo);
    procedure DefaultMenuChosen(Item: TMenuItem);
    procedure NavigateRemote(constref Open: TIpcOpenUrl);
    procedure StateTimerFired(Sender: TTimer);
    { Input (WebView.Control.RemoteInput.inc). }
    procedure SendInput(var Input: TIpcInputEvent);
    function RendererBusy: Boolean;
    procedure ShiftLastFrame(Pixels: Double);
    { Crashes, hangs and dialogs (WebView.Control.Recovery.inc). }
    procedure ShowCrashPanel(const Reason: string);
    procedure HideCrashPanel;
    procedure CrashReloadClicked(Sender: TControl);
    procedure ShowHangBar(const Value: string);
    procedure HideHangBar;
    procedure HangWaitClicked(Sender: TControl);
    procedure HangStopClicked(Sender: TControl);
    procedure NoteScriptInterrupted;
    procedure OpenSheet(Kind: TPromptSheetKind; const Message, Default: string; RequestId: LongWord; RequestKind: Word);
    procedure SheetAnswered(Sheet: TPromptSheet; Accepted: Boolean; const Value: string);
    procedure CloseSheet;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Layout; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure PointerLeave; override;
    procedure Wheel(Steps: LongInt); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure KeyUp(Code, Modifiers: LongWord); override;
    procedure FocusChanged; override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    procedure ReceiveMessage(var Message: TPostedMessage); override;
    { Navigates to a URL (False when Text is not one). }
    function Navigate(const Address: string): Boolean;
    { Shows Html as a document at BaseUrl (its base for relative URLs). }
    procedure LoadHtml(const Html, BaseUrl: string);
    procedure GoBack;
    procedure GoForward;
    procedure Reload(BypassCache: Boolean = False);
    procedure Stop;
    { Scrolls the viewport by CSS pixels. }
    procedure ScrollBy(DeltaX, DeltaY: Double);
    procedure ScrollTo(X, Y: Double);
    procedure ZoomIn;
    procedure ZoomOut;
    procedure ResetZoom;
    { Finds Needle after the selection (or before it), selects it and
      scrolls to it. The answer comes to OnFindResult; in a content
      process this returns the last answer. }
    function FindText(const Needle: string; Forward: Boolean = True; MatchCase: Boolean = False): Boolean;
    procedure ClearSelection;
    procedure SelectAll;
    function SelectedText: string;
    function HasSelection: Boolean;
    procedure CopySelection;
    { The page's whole text as shown (in a content process: the last
      the process told; asking refreshes it). }
    function PageText: string;
    { Ends the page's content process at once (Stop on a hung page; the
      browser's about:crash): the view shows that the tab crashed. }
    procedure TerminateContentProcess;
    { Test only: the content process crashes, or hangs. }
    procedure CrashContentProcess;
    procedure HangContentProcess;
    property Page: TWebPage read GetPage;
    property Navigable: TNavigable read GetNavigable;
    property Document: TDocument read GetDocument;
    property DocumentLayout: TDocumentLayout read GetDocumentLayout;
    property Url: string read FUrl;
    property Title: string read FTitle;
    property LoadingState: TLoadingState read FState;
    { The page's icon, nil when it has none (the view owns it). }
    property Favicon: TImage read FFavicon;
    property StatusText: string read FStatusText;
    property CanGoBack: Boolean read GetCanGoBack;
    property CanGoForward: Boolean read GetCanGoForward;
    property Zoom: Double read FZoom write SetZoom;
    { Set before the first navigation. }
    property ProcessModel: TWebViewProcessModel read FModel write SetProcessModel;
    { The content process's id (0 in the program or before a page). }
    property ContentProcessId: Int64 read GetContentProcessId;
    { The program's own script engine (in the program only). }
    property ScriptExecutorFactory: TScriptExecutorFactory read FScriptExecutorFactory write FScriptExecutorFactory;
    { JavaScript (on unless set): a change applies from the next document. }
    property ScriptingEnabled: Boolean read FScriptingEnabled write SetScriptingEnabled;
    { The browser's own pages (about:home ...), for navigations the host
      starts; in a content process asked for only by one locked to them. }
    property AboutPageProvider: TAboutPageProvider read FAboutPageProvider write SetAboutPageProvider;
    property OnScriptAlert: TWebViewTextEvent read FOnScriptAlert write FOnScriptAlert;
    property OnScriptConfirm: TWebViewScriptConfirmEvent read FOnScriptConfirm write FOnScriptConfirm;
    property OnScriptPrompt: TWebViewScriptPromptEvent read FOnScriptPrompt write FOnScriptPrompt;
    { A dialog the view shows itself (no handler above): for a log. }
    property OnScriptDialog: TWebViewDialogEvent read FOnScriptDialog write FOnScriptDialog;
    property OnConsoleMessage: TWebViewConsoleEvent read FOnConsoleMessage write FOnConsoleMessage;
    property OnTitleChanged: TWebViewTextEvent read FOnTitleChanged write FOnTitleChanged;
    property OnLocationChanged: TWebViewTextEvent read FOnLocationChanged write FOnLocationChanged;
    property OnLoadingStateChanged: TWebViewLoadingEvent read FOnLoadingStateChanged write FOnLoadingStateChanged;
    property OnFaviconChanged: TWebViewEvent read FOnFaviconChanged write FOnFaviconChanged;
    property OnStatusText: TWebViewTextEvent read FOnStatusText write FOnStatusText;
    property OnHistoryChanged: TWebViewEvent read FOnHistoryChanged write FOnHistoryChanged;
    property OnZoomChanged: TWebViewEvent read FOnZoomChanged write FOnZoomChanged;
    { A link was clicked: Handled stops the view from following it (a
      link for this view goes on in a content process: it is told). }
    property OnLinkClicked: TWebViewLinkEvent read FOnLinkClicked write FOnLinkClicked;
    property OnDownloadRequested: TWebViewDownloadEvent read FOnDownloadRequested write FOnDownloadRequested;
    property OnNavigationFailed: TWebViewFailureEvent read FOnNavigationFailed write FOnNavigationFailed;
    { A context menu is wanted: Handled stops the view's own menu. }
    property OnContextMenuRequested: TWebViewContextEvent read FOnContextMenuRequested write FOnContextMenuRequested;
    { The page asked to stay (beforeunload): True leaves it. }
    property OnConfirmUnload: TWebViewConfirmEvent read FOnConfirmUnload write FOnConfirmUnload;
    property OnFindResult: TWebViewFindEvent read FOnFindResult write FOnFindResult;
    property OnProcessEvent: TWebViewProcessEvent read FOnProcessEvent write FOnProcessEvent;
  end;

var
  { A program's own script engine for every view in the program (nil:
    libweb's). }
  DefaultScriptExecutorFactory: TScriptExecutorFactory = nil;
  { How new views run their pages. }
  DefaultWebViewProcessModel: TWebViewProcessModel = ProcessModelSeparate;

implementation

uses
  Math,
  Abi.SystemCalls,
  Url.Records,
  Url.Parser,
  Drawing.Colors,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Theme,
  Controls.Window,
  Controls.Keys,
  Controls.Clipboard,
  WebIpc.Wire,
  WebView.Zoom,
  WebView.Sites,
  WebView.ContentProcesses;

type
  { The view's ear on its content process. }
  TViewContentLink = class(TContentClient)
  public
    View: TWebView;
    procedure Received(Message: TIpcMessage); override;
    procedure ProcessEnded(Crashed: Boolean; ExitCode: LongInt); override;
    procedure ProcessResponsive(Responsive: Boolean); override;
  end;

procedure TViewContentLink.Received(Message: TIpcMessage);
begin
  View.RemoteReceived(Message);
end;

procedure TViewContentLink.ProcessEnded(Crashed: Boolean; ExitCode: LongInt);
begin
  View.RemoteEnded(Crashed, ExitCode);
end;

procedure TViewContentLink.ProcessResponsive(Responsive: Boolean);
begin
  View.RemoteResponsive(Responsive);
end;

const
  StateTimerMilliseconds = 250;

constructor TWebView.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FModel := DefaultWebViewProcessModel;
  FScriptingEnabled := True;
  FZoom := 1;
  FState := LoadingIdle;
  FBackUrls := TStringList.Create;
  FForwardUrls := TStringList.Create;
  FStateTimer := TTimer.Create(Self);
  FStateTimer.Interval := StateTimerMilliseconds;
  FStateTimer.OnTimer := @StateTimerFired;
  FStateTimer.Enabled := False;
end;

destructor TWebView.Destroy;
begin
  FStateTimer.Free;
  LeaveProcess;
  FLink.Free;
  FShared.Free;
  FreeSurface(FFrame);
  FFavicon.Free;
  FPopupMenu.Free;
  FDefaultMenu.Free;
  FBackUrls.Free;
  FForwardUrls.Free;
  inherited Destroy;
end;

function TWebView.RunsInProcess: Boolean;
begin
  Result := FEngine <> nil;
end;

procedure TWebView.SetProcessModel(Value: TWebViewProcessModel);
begin
  if not FModelChosen then
    FModel := Value;
end;

function TWebView.GetPage: TWebPage;
begin
  if FEngine <> nil then
    Result := FEngine.Page
  else
    Result := nil;
end;

function TWebView.GetNavigable: TNavigable;
begin
  if (FEngine = nil) and not FModelChosen and (FModel = ProcessModelInProcess) then
    EnsureEngine;
  if FEngine <> nil then
    Result := FEngine.Navigable
  else
    Result := nil;
end;

function TWebView.GetDocument: TDocument;
begin
  if FEngine <> nil then
    Result := FEngine.Document
  else
    Result := nil;
end;

function TWebView.GetDocumentLayout: TDocumentLayout;
begin
  if FEngine <> nil then
    Result := FEngine.DocumentLayout
  else
    Result := nil;
end;

function TWebView.GetContentProcessId: Int64;
begin
  if FProcess <> nil then
    Result := FProcess.ProcessId
  else
    Result := 0;
end;

function TWebView.GetCanGoBack: Boolean;
begin
  if FEngine <> nil then
    Result := FEngine.CanGoBack
  else
    Result := FRemoteCanGoBack or (FBackUrls.Count > 0);
end;

function TWebView.GetCanGoForward: Boolean;
begin
  if FEngine <> nil then
    Result := FEngine.CanGoForward
  else
    Result := FRemoteCanGoForward or (FForwardUrls.Count > 0);
end;

procedure TWebView.SetAboutPageProvider(Value: TAboutPageProvider);
begin
  FAboutPageProvider := Value;
  if FEngine <> nil then
    FEngine.Navigable.Fetcher.AboutPageProvider := Value;
end;

procedure TWebView.SetScriptingEnabled(Value: Boolean);
begin
  FScriptingEnabled := Value;
  if FEngine <> nil then
    FEngine.ScriptingEnabled := Value
  else if FProcess <> nil then
    SendToProcess(IpcSetScripting, EncodeFlag(Value));
end;

{ ---- told to the host ---- }

procedure TWebView.TellLocation(const Url: string);
begin
  FUrl := Url;
  if Assigned(FOnLocationChanged) then
    FOnLocationChanged(Self, Url);
end;

procedure TWebView.TellTitle(const Title: string);
begin
  FTitle := Title;
  if Assigned(FOnTitleChanged) then
    FOnTitleChanged(Self, Title);
end;

procedure TWebView.TellLoadingState(State: TLoadingState);
begin
  FState := State;
  if Assigned(FOnLoadingStateChanged) then
    FOnLoadingStateChanged(Self, State);
end;

procedure TWebView.TellFavicon(Image: TImage);
begin
  FFavicon.Free;
  FFavicon := Image;
  if Assigned(FOnFaviconChanged) then
    FOnFaviconChanged(Self);
end;

procedure TWebView.TellStatus(const Value: string);
begin
  FStatusText := Value;
  if Assigned(FOnStatusText) then
    FOnStatusText(Self, Value);
end;

procedure TWebView.TellHistory;
begin
  if Assigned(FOnHistoryChanged) then
    FOnHistoryChanged(Self);
end;

procedure TWebView.TellZoom(Value: Double);
begin
  FZoom := Value;
  if Assigned(FOnZoomChanged) then
    FOnZoomChanged(Self);
end;

procedure TWebView.TellLink(const Url: string; Disposition: TLinkDisposition; var Handled: Boolean);
begin
  if Assigned(FOnLinkClicked) then
    FOnLinkClicked(Self, Url, Disposition, Handled);
end;

procedure TWebView.TellDownload(constref Download: TDownloadInfo);
begin
  if Assigned(FOnDownloadRequested) then
    FOnDownloadRequested(Self, Download);
end;

procedure TWebView.TellFailure(const Url, Reason: string);
begin
  if Assigned(FOnNavigationFailed) then
    FOnNavigationFailed(Self, Url, Reason);
end;

procedure TWebView.TellConsole(const Level, Value: string);
begin
  if Assigned(FOnConsoleMessage) then
    FOnConsoleMessage(Self, Level, Value);
end;

procedure TWebView.TellFindResult(const Needle: string; Found: Boolean);
begin
  FLastFindResult := Found;
  if Assigned(FOnFindResult) then
    FOnFindResult(Self, Needle, Found);
end;

procedure TWebView.TellProcessEvent(const What: string; Value: Int64);
begin
  if Assigned(FOnProcessEvent) then
    FOnProcessEvent(Self, What, Value);
end;

{ ---- what the host asks ---- }

function TWebView.Navigate(const Address: string): Boolean;
var
  Parsed: TUrlRecord;
  Open: TIpcOpenUrl;
begin
  Result := ParseUrl(Address, Parsed);
  if not Result then
    Exit;
  if (FModel = ProcessModelInProcess) or RunsInProcess then
  begin
    EnsureEngine;
    Result := FEngine.Navigate(Address);
    Exit;
  end;
  Open := Default(TIpcOpenUrl);
  Open.Url := SerializeUrl(Parsed);
  Open.Method := 'GET';
  Open.UserInitiated := True;
  NavigateRemote(Open);
end;

procedure TWebView.LoadHtml(const Html, BaseUrl: string);
var
  Site: string;
begin
  if (FModel = ProcessModelInProcess) or RunsInProcess then
  begin
    EnsureEngine;
    FEngine.LoadHtml(Html, BaseUrl);
    Exit;
  end;
  Site := SiteOfText(BaseUrl);
  if (FProcess = nil) or ((Site <> '') and (Site <> FProcess.Site)) then
    if not EnsureProcessFor(Site) then
    begin
      EnsureEngine;
      FEngine.LoadHtml(Html, BaseUrl);
      Exit;
    end;
  SendToProcess(IpcLoadHtml, EncodeTexts(Html, BaseUrl));
end;

procedure TWebView.GoBack;
var
  Open: TIpcOpenUrl;
begin
  if FEngine <> nil then
  begin
    FEngine.GoBack;
    Exit;
  end;
  if FRemoteCanGoBack then
  begin
    SendToProcess(IpcGoBack, nil);
    Exit;
  end;
  if FBackUrls.Count = 0 then
    Exit;
  { Back to the page of another site this view came from. }
  Open := Default(TIpcOpenUrl);
  Open.Url := FBackUrls[FBackUrls.Count - 1];
  FBackUrls.Delete(FBackUrls.Count - 1);
  if FUrl <> '' then
    FForwardUrls.Add(FUrl);
  Open.Method := 'GET';
  Open.UserInitiated := True;
  Open.Replace := True;
  NavigateRemote(Open);
end;

procedure TWebView.GoForward;
var
  Open: TIpcOpenUrl;
begin
  if FEngine <> nil then
  begin
    FEngine.GoForward;
    Exit;
  end;
  if FRemoteCanGoForward then
  begin
    SendToProcess(IpcGoForward, nil);
    Exit;
  end;
  if FForwardUrls.Count = 0 then
    Exit;
  Open := Default(TIpcOpenUrl);
  Open.Url := FForwardUrls[FForwardUrls.Count - 1];
  FForwardUrls.Delete(FForwardUrls.Count - 1);
  if FUrl <> '' then
    FBackUrls.Add(FUrl);
  Open.Method := 'GET';
  Open.UserInitiated := True;
  Open.Replace := True;
  NavigateRemote(Open);
end;

procedure TWebView.Reload(BypassCache: Boolean);
var
  Open: TIpcOpenUrl;
begin
  if FEngine <> nil then
  begin
    FEngine.Reload(BypassCache);
    Exit;
  end;
  if (FProcess = nil) and (FUrl <> '') then
  begin
    { After a crash: the page again, in a new process. }
    Open := Default(TIpcOpenUrl);
    Open.Url := FUrl;
    Open.Method := 'GET';
    Open.UserInitiated := True;
    Open.Replace := True;
    NavigateRemote(Open);
    Exit;
  end;
  SendToProcess(IpcReload, EncodeFlag(BypassCache));
end;

procedure TWebView.Stop;
begin
  if FEngine <> nil then
    FEngine.Stop
  else
    SendToProcess(IpcStop, nil);
end;

procedure TWebView.ScrollBy(DeltaX, DeltaY: Double);
begin
  if FEngine <> nil then
    FEngine.ScrollBy(DeltaX, DeltaY)
  else
    SendToProcess(IpcScrollBy, EncodeReals(DeltaX, DeltaY));
end;

procedure TWebView.ScrollTo(X, Y: Double);
begin
  if FEngine <> nil then
    FEngine.ScrollTo(X, Y)
  else
    SendToProcess(IpcScrollTo, EncodeReals(X, Y));
end;

procedure TWebView.SetZoom(Value: Double);
begin
  if FEngine <> nil then
  begin
    FEngine.Zoom := Value;
    Exit;
  end;
  Value := ClampZoom(Value);
  if FProcess = nil then
  begin
    TellZoom(Value);
    Exit;
  end;
  SendToProcess(IpcSetZoom, EncodeReal(Value));
end;

procedure TWebView.ZoomIn;
begin
  SetZoom(ZoomedIn(FZoom));
end;

procedure TWebView.ZoomOut;
begin
  SetZoom(ZoomedOut(FZoom));
end;

procedure TWebView.ResetZoom;
begin
  SetZoom(1);
end;

function TWebView.FindText(const Needle: string; Forward: Boolean; MatchCase: Boolean): Boolean;
var
  Writer: TIpcWriter;
begin
  if FEngine <> nil then
  begin
    Result := FEngine.FindText(Needle, Forward, MatchCase);
    TellFindResult(Needle, Result);
    Exit;
  end;
  Result := FLastFindResult;
  if FProcess = nil then
    Exit;
  FFindRequestId := NextRequestId;
  FFindNeedle := Needle;
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Needle);
    Writer.WriteBoolean(Forward);
    Writer.WriteBoolean(MatchCase);
    SendToProcess(IpcFind, Writer.Data, FFindRequestId);
  finally
    Writer.Free;
  end;
end;

procedure TWebView.ClearSelection;
begin
  if FEngine <> nil then
    FEngine.ClearSelection
  else
    SendToProcess(IpcClearSelection, nil);
end;

procedure TWebView.SelectAll;
begin
  if FEngine <> nil then
    FEngine.SelectAll
  else
    SendToProcess(IpcSelectAll, nil);
end;

function TWebView.SelectedText: string;
begin
  if FEngine <> nil then
    Result := FEngine.SelectedText
  else
    Result := FSelectedText;
end;

function TWebView.HasSelection: Boolean;
begin
  if FEngine <> nil then
    Result := FEngine.HasSelection
  else
    Result := FSelectedText <> '';
end;

procedure TWebView.CopySelection;
begin
  if FEngine <> nil then
    FEngine.CopySelection
  else
    SendToProcess(IpcCopySelection, nil);
end;

function TWebView.PageText: string;
begin
  if FEngine <> nil then
    Exit(FEngine.PageText);
  SendToProcess(IpcViewCommand, EncodeNumber(ViewCommandPageText));
  Result := FPageText;
end;

procedure TWebView.TerminateContentProcess;
begin
  if FProcess <> nil then
    ContentProcesses.Terminate(FProcess);
end;

procedure TWebView.CrashContentProcess;
begin
  SendToProcess(IpcViewCommand, EncodeNumber(ViewCommandCrash));
end;

procedure TWebView.HangContentProcess;
begin
  SendToProcess(IpcViewCommand, EncodeNumber(ViewCommandHang));
end;

{$I WebView.Control.Local.inc}
{$I WebView.Control.Remote.inc}
{$I WebView.Control.RemoteInput.inc}
{$I WebView.Control.Recovery.inc}

end.
