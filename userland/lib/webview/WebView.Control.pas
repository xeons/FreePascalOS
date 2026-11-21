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
  controls (libcontrols). It owns a page (libweb's TWebPage: event
  loop, fetcher over the program's shared network, navigable), the
  resource sink that hands loaded sheets, images and fonts to layout,
  and the active document's layout and painter.

    View := TWebView.Create(Root);
    View.Align := AlignClient;
    View.OnTitleChanged := @TitleChanged;
    View.Navigate('https://example.com/');
    View.LoadHtml('<p>Hello</p>', 'about:blank');

  - The event loop runs on the GUI thread: other threads wake it with a
    posted message, its timers on a TTimer, rendering on a frame timer
    (layout, then a repaint when what is painted changed).
  - Painting: the viewport is painted into a surface of its own and
    copied to the window; only what changed is painted again (a scroll
    moves the pixels and paints the strip that came into view, unless
    the page has fixed boxes or the step is not whole pixels).
  - Scrolling: the theme's scroll bars for the viewport; the wheel, the
    arrow keys, Page Up and Down, Space, Home and End; the wheel scrolls
    a scroll container under the pointer first (with a thin bar of the
    theme's colours drawn in it).
  - The pointer: :hover and :active states, the CSS cursor (the hand
    over links, the text beam over text), links followed on a click
    (OnLinkClicked first: the host may handle it, as a new tab for a
    middle click or Ctrl+click), the hovered link's URL in
    OnStatusText; text selected by dragging (a double click selects a
    word), copied with Ctrl+C (the system clipboard).
  - The keyboard: Tab and Shift+Tab move the page's focus between links
    and form controls (:focus, :focus-visible), Enter follows a link or
    presses a button, Space toggles a check box.
  - Form controls: typing into text fields and text areas, check boxes,
    radio buttons, buttons (a submit button submits its form, GET or
    POST), selects (a pop-up menu of the options).
  - Find in page (FindText), zoom (Ctrl+plus, Ctrl+minus, Ctrl+0,
    Ctrl+wheel: the CSS-to-device scale is the display's times the
    zoom), context menus (OnContextMenu, else a menu of its own).
  - Scripting: libweb's TPageScriptExecutor (the DOM bindings over the
    page's loop) unless ScriptingEnabled is False, or the executor
    ScriptExecutorFactory (or DefaultScriptExecutorFactory) makes; the
    page's prompts come to OnScriptAlert, OnScriptConfirm and
    OnScriptPrompt (the page's tasks wait meanwhile), its console to
    OnConsoleMessage.
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
  Drawing.Regions,
  Image.Model,
  Css.ElementAdapter,
  Windowing.Messages,
  Controls.Base,
  Controls.ScrollBar,
  Controls.Timers,
  Controls.Menus,
  Web.Dom,
  Web.Layout.Boxes,
  Web.Navigation.Navigables,
  Web.Navigation.Pages,
  Web.Loading.Scripts,
  Web.Loading.LayoutSink,
  Web.Layout.Document,
  Web.Paint.Painter,
  Web.Frames.Views,
  WebView.TextIndex,
  WebView.SelectionMapping,
  WebView.FieldEditing,
  WebView.Elements,
  WebView.MouseEvents;

const
  { The web view's own messages (below MessageUser: a library's). }
  MessageWebViewWake = $0F01;

type
  TWebView = class;

  { Makes the script engine for a view's page (the DOM bindings). }
  TScriptExecutorFactory = function(View: TWebView; Page: TWebPage): TScriptExecutor;

  { Background: a middle click or Ctrl+click; a new tab: a target. }
  TLinkDisposition = (LinkInView, LinkInNewTab, LinkInBackgroundTab, LinkInNewWindow);

  { An element and its ancestors (each retained while listed). }
  TElementChain = array of TElement;

  TWebContextInfo = record
    { The control's own pixels. }
    X, Y: LongInt;
    FromKeyboard: Boolean;
    LinkUrl: string;
    LinkText: string;
    ImageUrl: string;
    SelectedText: string;
    InTextField: Boolean;
  end;

  TWebViewEvent = procedure(Sender: TWebView) of object;
  TWebViewTextEvent = procedure(Sender: TWebView; const Text: string) of object;
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
  TWebViewConsoleEvent = procedure(Sender: TWebView; const Level, Text: string) of object;

  TWebView = class(TControl)
  private
    FPage: TWebPage;
    FSink: TLayoutResourceSink;
    FObserver: TNavigableObserver;
    FExecutor: TScriptExecutor;
    FScriptExecutorFactory: TScriptExecutorFactory;
    FScriptingEnabled: Boolean;
    { Script prompts (modal dialogs) are open: the page waits. }
    FModalDepth: Integer;
    FOnScriptAlert: TWebViewTextEvent;
    FOnScriptConfirm: TWebViewScriptConfirmEvent;
    FOnScriptPrompt: TWebViewScriptPromptEvent;
    FOnConsoleMessage: TWebViewConsoleEvent;
    FDocument: TDocument;
    FLayout: TDocumentLayout;
    FPainter: TDocumentPainter;
    { Painting. }
    FBacking: TSurface;
    FBackingVersion: LongWord;
    FBackingValid: Boolean;
    { How long the last layout took and when it ended (milliseconds):
      a slow page is laid out again only after the GUI had twice that
      to itself (UpdateLayout). }
    FLayoutCost: QWord;
    FLayoutDoneAt: QWord;
    FBackingDirty: TRectangle;
    FListHasFixed: Boolean;
    FFixedCheckedVersion: LongWord;
    FFixedChecked: Boolean;
    { Scrolling. }
    FVerticalBar: TScrollBar;
    FHorizontalBar: TScrollBar;
    FSyncingBars: Boolean;
    FHasPendingRestore: Boolean;
    FPendingRestoreX, FPendingRestoreY: Double;
    FPendingFragment: TElement;
    FHasPendingFragment: Boolean;
    { The loop. }
    FWakePending: LongInt;
    FLoopTimer: TTimer;
    FFrameTimer: TTimer;
    { State told to the host. }
    FUrl: string;
    FTitle: string;
    FState: TLoadingState;
    FFavicon: TImage;
    FStatusText: string;
    FZoom: Double;
    { The pointer and the focus. }
    FHoverChain: TElementChain;
    FActiveChain: TElementChain;
    FFocusedElement: TElement;
    FFocusVisible: Boolean;
    { The value a focused text control had when it got the focus (change
      fires when it leaves with another). }
    FFocusValue: string;
    { Hears the document's focus changes (script's focus() too). }
    FDocumentObserver: TDocumentObserver;
    { Script's layout questions (getBoundingClientRect ...). }
    FScriptLayout: TObject;
    { The character each key typed when pressed (keyup's key). }
    FKeyCharacters: array[0..511] of LongWord;
    FPressedLink: TElement;
    FPressedControl: TElement;
    { The element the left button went down on (click goes to it when it
      comes up there), the buttons held (MouseEvent.buttons). }
    FPressedTarget: TElement;
    FButtonsHeld: Word;
    FPressButton: LongWord;
    FPressX, FPressY: LongInt;
    FDragged: Boolean;
    FLastPointerX, FLastPointerY: LongInt;
    FLastClickTime: QWord;
    FLastClickX, FLastClickY: LongInt;
    { Selection and find. }
    FTextIndex: TPageTextIndex;
    FTextIndexVersion: LongWord;
    FTextIndexValid: Boolean;
    FSelecting: Boolean;
    FSelectionAnchor, FSelectionFocus: TTextPosition;
    { The document's selection changed without the view (script): the
      painted selection is taken from it before it is next used. }
    FSelectionFromDocument: Boolean;
    { The view is setting the document's selection itself. }
    FSettingDocumentSelection: Boolean;
    FFindText: string;
    { Typing into the focused text field. }
    FFieldEditor: TTextFieldEditor;
    { A select's pop-up. }
    FSelectMenu: TMenuItem;
    FSelectElement: TElement;
    FOwnMenu: TMenuItem;
    FMenuLink: string;
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
    procedure SetScriptingEnabled(Value: Boolean);
    procedure ScriptAlert(const Message: string);
    function ScriptConfirm(const Message: string): Boolean;
    function ScriptPrompt(const Message, Default: string; out Answer: string): Boolean;
    procedure ScriptConsole(const Level, Line: string);
    { The page and its document. }
    procedure EnsurePage;
    procedure AdoptDocument(Document: TDocument);
    procedure ReleaseDocument;
    procedure ForgetElements;
    { The loop. }
    procedure PageWake(Sender: TObject);
    procedure PostWake;
    procedure PumpEventLoop;
    procedure LoopTimerFired(Sender: TTimer);
    procedure FrameTimerFired(Sender: TTimer);
    procedure RenderingRequested(Sender: TObject);
    procedure RequestFrame;
    procedure RenderFrame;
    { Geometry. }
    function DeviceScale: Double;
    function ViewportPixelWidth: LongInt;
    function ViewportPixelHeight: LongInt;
    function ViewportCssWidth: Double;
    function ViewportCssHeight: Double;
    { Shown, with a size: a hidden view is not laid out. }
    function HasRoom: Boolean;
    procedure ApplyViewport;
    procedure UpdateLayout(Force: Boolean = False);
    function LayoutDue: Boolean;
    procedure UpdateLayoutRounds;
    { Painting (WebView.Control.Painting.inc). }
    procedure EnsureBacking;
    procedure PaintBacking;
    procedure InvalidateViewport;
    function PageHasFixedBoxes: Boolean;
    procedure PaintSelection(var Canvas: TCanvas);
    procedure PaintCaret(var Canvas: TCanvas);
    function ShowsAt(Container: TNode; X, Y: Single): Boolean;
    procedure PaintInnerScrollBars(var Canvas: TCanvas);
    { Scrolling (WebView.Control.Scrolling.inc). }
    procedure UpdateScrollBars;
    procedure ScrollBarMoved(Bar: TScrollBar);
    procedure ScrollViewportTo(X, Y: Double);
    function ScrollInnerContainer(CssX, CssY, DeltaX, DeltaY: Double): Boolean;
    procedure ApplyPendingScroll;
    procedure ScrollRectangleIntoView(X, Y, Width, Height: Double);
    procedure ScrollToElement(Element: TElement);
    { The pointer (WebView.Control.Pointer.inc). }
    procedure UpdateHover(CssX, CssY: Double);
    procedure ClearHover;
    procedure SetChain(var Chain: TElementChain; Element: TElement);
    procedure ApplyStates(Element: TElement);
    function StatesOf(Element: TElement): TCssElementStates;
    procedure SetStatus(const Value: string);
    function ResolveLink(Link: TElement): string;
    procedure ActivateLink(Link: TElement; Disposition: TLinkDisposition);
    function DispositionFor(Button, Modifiers: LongWord; Link: TElement): TLinkDisposition;
    procedure SetFocusedElement(Element: TElement; ShowFocus: Boolean);
    { Script scrolled the viewport or a scroll container. }
    procedure ScriptScrolled;
    { The document's focus moved to Element (nil: the viewport). }
    procedure FocusMoved(Element: TElement);
    { A KeyboardEvent at the focused element (or the body); False when the
      page cancelled it. }
    function DispatchKeyboardEvent(const EventType: string; Code, Character, Modifiers: LongWord): Boolean;
    { An InputEvent after an edit of a text control. }
    procedure FireInputEvent(Element: TElement; const InputType, Data: string);
    { Implicit submission (Enter in a field): the form's default button,
      else the form. }
    procedure SubmitImplicitly(Field: TElement);
    { Frames (WebView.Control.Frames.inc). }
    function HitTestDeep(CssX, CssY: Double; out Path: TFramePath): THitTestResult;
    function LayoutForDocument(Document: TDocument): TDocumentLayout;
    function NavigableForNode(Node: TNode): TNavigable;
    function ViewportOriginOf(Document: TDocument; out X, Y: Single): Boolean;
    procedure FillMouseInit(Target: TNode; out Init: TMouseEventInit);
    function FireMouse(Target: TNode; const EventType: string; Button: SmallInt; Detail: LongInt): Boolean;
    { A trusted click (a MouseEvent) at Element; False when cancelled. }
    function FireClick(Element: TElement): Boolean;
    function ScrollThroughFrames(CssX, CssY, DeltaX, DeltaY: Double): Boolean;
    function ScrollBoxChain(DocumentLayout: TDocumentLayout; Box: TLayoutBox; DeltaX, DeltaY: Double): Boolean;
    { Form controls (WebView.Control.Forms.inc). }
    procedure ClickElement(Element: TElement);
    procedure ActOnClick(Element: TElement);
    procedure ActivateControl(Control: TElement);
    procedure SubmitForm(Form, Submitter: TElement);
    procedure OpenSelectMenu(Select: TElement);
    procedure SelectOptionChosen(Item: TMenuItem);
    function TypeIntoField(Code, Character, Modifiers: LongWord): Boolean;
    procedure FieldSelectionMoved(Element: TElement);
    function ReadClipboard: string;
    procedure WriteClipboard(const Value: string);
    procedure ControlEdited(Element: TElement);
    { Selection (WebView.Control.Selection.inc). }
    procedure EnsureTextIndex;
    function TextPositionAt(X, Y: LongInt): TTextPosition;
    procedure SetSelection(constref Anchor, Focus: TTextPosition);
    { The user's selection to the document's, and the document's to the
      painted one. }
    procedure PushSelectionToDocument;
    procedure PullSelectionFromDocument;
    procedure DocumentSelectionChanged;
    { Context menus. }
    procedure ShowOwnContextMenu(constref Info: TWebContextInfo);
    procedure OwnMenuChosen(Item: TMenuItem);
    function GetCanGoBack: Boolean;
    function GetCanGoForward: Boolean;
    procedure SetZoom(Value: Double);
    function GetNavigable: TNavigable;
    { What the navigable tells (through the observer). }
    procedure NavigableLocationChanged(const Url: string);
    procedure NavigableTitleChanged(const Title: string);
    procedure NavigableLoadingStateChanged(State: TLoadingState);
    procedure NavigableFaviconChanged(Image: TImage);
    procedure NavigableHistoryChanged;
    procedure NavigableScrollToFragment(Element: TElement);
    procedure NavigableRestoreScrollPosition(X, Y: Double);
    function NavigableConfirmUnload: Boolean;
    procedure NavigableDownloadRequested(constref Download: TDownloadInfo);
    procedure NavigableFailed(const Url, Reason: string);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure Layout; override;
    procedure PlaceChildren(const Area: TRectangle); override;
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
    { Finds Text after the selection (or before it), selects it and
      scrolls to it; False when the page has no such text. }
    function FindText(const Needle: string; Forward: Boolean = True; MatchCase: Boolean = False): Boolean;
    procedure ClearSelection;
    procedure SelectAll;
    function SelectedText: string;
    function HasSelection: Boolean;
    procedure CopySelection;
    { The page's whole text as shown. }
    function PageText: string;
    property Page: TWebPage read FPage;
    property Navigable: TNavigable read GetNavigable;
    property Document: TDocument read FDocument;
    property DocumentLayout: TDocumentLayout read FLayout;
    property Url: string read FUrl;
    property Title: string read FTitle;
    property LoadingState: TLoadingState read FState;
    { The page's icon, nil when it has none (the view owns it). }
    property Favicon: TImage read FFavicon;
    property StatusText: string read FStatusText;
    property CanGoBack: Boolean read GetCanGoBack;
    property CanGoForward: Boolean read GetCanGoForward;
    property Zoom: Double read FZoom write SetZoom;
    { Set before the first navigation (the page is made then). }
    property ScriptExecutorFactory: TScriptExecutorFactory read FScriptExecutorFactory write FScriptExecutorFactory;
    { JavaScript (on unless set): a change applies from the next document. }
    property ScriptingEnabled: Boolean read FScriptingEnabled write SetScriptingEnabled;
    { window.alert, confirm and prompt (unanswered: confirm is False and
      prompt gives nothing). }
    property OnScriptAlert: TWebViewTextEvent read FOnScriptAlert write FOnScriptAlert;
    property OnScriptConfirm: TWebViewScriptConfirmEvent read FOnScriptConfirm write FOnScriptConfirm;
    property OnScriptPrompt: TWebViewScriptPromptEvent read FOnScriptPrompt write FOnScriptPrompt;
    { The page's console (console.log, uncaught errors). }
    property OnConsoleMessage: TWebViewConsoleEvent read FOnConsoleMessage write FOnConsoleMessage;
    property OnTitleChanged: TWebViewTextEvent read FOnTitleChanged write FOnTitleChanged;
    property OnLocationChanged: TWebViewTextEvent read FOnLocationChanged write FOnLocationChanged;
    property OnLoadingStateChanged: TWebViewLoadingEvent read FOnLoadingStateChanged write FOnLoadingStateChanged;
    property OnFaviconChanged: TWebViewEvent read FOnFaviconChanged write FOnFaviconChanged;
    { The URL of the link under the pointer ('' when it leaves). }
    property OnStatusText: TWebViewTextEvent read FOnStatusText write FOnStatusText;
    property OnHistoryChanged: TWebViewEvent read FOnHistoryChanged write FOnHistoryChanged;
    property OnZoomChanged: TWebViewEvent read FOnZoomChanged write FOnZoomChanged;
    { A link was clicked: Handled stops the view from following it. }
    property OnLinkClicked: TWebViewLinkEvent read FOnLinkClicked write FOnLinkClicked;
    property OnDownloadRequested: TWebViewDownloadEvent read FOnDownloadRequested write FOnDownloadRequested;
    property OnNavigationFailed: TWebViewFailureEvent read FOnNavigationFailed write FOnNavigationFailed;
    { A context menu is wanted: Handled stops the view's own menu. }
    property OnContextMenuRequested: TWebViewContextEvent read FOnContextMenuRequested write FOnContextMenuRequested;
    { The page asked to stay (beforeunload): True leaves it. }
    property OnConfirmUnload: TWebViewConfirmEvent read FOnConfirmUnload write FOnConfirmUnload;
  end;

var
  { A program's own script engine for every view (nil: libweb's
    TPageScriptExecutor while ScriptingEnabled). }
  DefaultScriptExecutorFactory: TScriptExecutorFactory = nil;

implementation

uses
  Math,
  Web.Dom.Exceptions,
  Abi.SystemCalls,
  Url.Records,
  Url.Parser,
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Protocol,
  Controls.Window,
  Controls.Keys,
  Controls.Clipboard,
  Controls.Painting,
  Web.Atoms,
  Web.Navigation.Events,
  Web.Navigation.Windows,
  Web.Layout.Resources,
  Web.Paint.DisplayList,
  Web.Text.FontInstances,
  Web.Script.PageScripting,
  Web.Layout.AnimationEvents,
  Web.Dom.Focus,
  Web.Dom.FormControls,
  WebView.Network,
  WebView.Zoom,
  WebView.Forms,
  WebView.KeyNames,
  WebView.TextEditing,
  Web.Script.Layout;

type
  { The view's ear on its document. }
  TViewDocumentObserver = class(TDocumentObserver)
  public
    View: TWebView;
    procedure FocusChanged(Old, New: TElement); override;
    procedure SelectionChanged(Document: TDocument); override;
  end;

procedure TViewDocumentObserver.FocusChanged(Old, New: TElement);
begin
  View.FocusMoved(New);
end;

procedure TViewDocumentObserver.SelectionChanged(Document: TDocument);
begin
  View.DocumentSelectionChanged;
end;

{$I WebView.Control.Frames.inc}
{$I WebView.Control.Observer.inc}
{$I WebView.Control.Core.inc}
{$I WebView.Control.Painting.inc}
{$I WebView.Control.Scrolling.inc}
{$I WebView.Control.Pointer.inc}
{$I WebView.Control.Keyboard.inc}
{$I WebView.Control.Forms.inc}
{$I WebView.Control.Selection.inc}

end.
