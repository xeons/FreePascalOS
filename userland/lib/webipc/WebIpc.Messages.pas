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
  The browser's message protocol between its process (the browser:
  windows, tabs, the network, storage) and its content processes (the
  renderers: /bin/webcontent, one page engine per view).

  Every message has a kind, the view it is about (0: the process as a
  whole), a request id (0 for an event; a request's reply carries the
  request's id with the kind IpcReply) and a payload written with
  WebIpc.Wire. The kinds are grouped by who sends them:

    1..99     either side: hello, ping and pong, replies
    100..199  the browser to a content process: views, navigation,
              input, the frame acknowledgements, answers to menus
    200..299  a content process to the browser: what a view shows and
              asks for (frames, title, location, dialogs, the
              clipboard, cross-site navigations, menus)
    300..399  the network service: a content process's HTTP exchanges,
              local files, cookies and storage, and their answers

  A message is carried in one or more channel messages (fragments, see
  WebIpc.Fragments), so a payload has no size limit but memory.
}
unit WebIpc.Messages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  { Changed whenever a message's payload changes: the content process
    refuses a browser of another version (they come from one build). }
  WebIpcProtocolVersion = 2;

  { ---- either side ---- }
  { Content process to browser, first: protocol version, process id. }
  IpcHello = 1;
  { Payload: a sequence number; answered with IpcPong carrying it. }
  IpcPing = 2;
  IpcPong = 3;
  { The answer to a request (RequestId is the request's). }
  IpcReply = 4;
  { The browser asks the content process to end (it has no views left). }
  IpcShutdown = 5;

  { ---- browser to content process ---- }
  { Makes view ViewId (TIpcViewSetup). }
  IpcCreateView = 100;
  IpcDestroyView = 101;
  { URL; user initiated. }
  IpcNavigate = 102;
  { Html, base URL. }
  IpcLoadHtml = 103;
  IpcGoBack = 104;
  IpcGoForward = 105;
  { Bypass the cache. }
  IpcReload = 106;
  IpcStop = 107;
  { TIpcViewGeometry: size in pixels, display scale and DPI. }
  IpcResize = 108;
  { Shown (a foreground tab) or hidden. }
  IpcSetVisible = 109;
  { The view has the keyboard focus. }
  IpcSetFocus = 110;
  IpcSetZoom = 111;
  { TIpcInputEvent. }
  IpcInput = 112;
  { TIpcFindRequest (a request: the reply is a TIpcFindResult). }
  IpcFind = 113;
  IpcSelectAll = 114;
  IpcCopySelection = 115;
  IpcClearSelection = 116;
  { Delta X, delta Y (CSS pixels). }
  IpcScrollBy = 117;
  IpcScrollTo = 118;
  { The browser took the frame out of the surface: the next may be
    painted. Payload: the frame's number. }
  IpcFrameAck = 119;
  { A pop-up menu's answer: menu id, the item's tag (-1: dismissed). }
  IpcMenuChosen = 120;
  IpcSetScripting = 121;
  { A command of the view's own context menu (WebView.Types). }
  IpcViewCommand = 122;
  { Payload: an offset in the session history (-2: two back). }
  IpcGoToHistoryOffset = 123;
  { TIpcHistoryState (the flags unused): the view's history becomes
    these entries and the current one is loaded (session restore). }
  IpcRestoreHistory = 124;
  { TIpcFindRequest (Forward unused): every match painted highlighted
    ('' clears). }
  IpcSetFindHighlight = 125;
  { A request: the reply is a TIpcPageInfo. }
  IpcRequestPageInfo = 126;
  { TIpcDisplayOptions: images, text-only zoom, author styles, pop-ups,
    the encoding override. }
  IpcSetDisplayOptions = 127;
  { Flag: the browser left fullscreen (or refused it): the page hears
    fullscreenchange. }
  IpcFullscreenChanged = 130;
  { Flag: the pointer is locked to the view's window now, or not (any
    more, or refused). }
  IpcPointerLockChanged = 131;

  { ---- content process to browser ---- }
  { A new surface (a section handle comes with it): TIpcSurfaceInfo. }
  IpcSurfaceCreated = 200;
  { A frame is in the surface: TIpcFrameInfo. }
  IpcFramePresented = 201;
  IpcTitleChanged = 202;
  IpcLocationChanged = 203;
  IpcLoadingStateChanged = 204;
  { Width, height, then the pixels (32-bit ARGB), or 0 x 0 for none. }
  IpcFaviconChanged = 205;
  IpcStatusText = 206;
  { TIpcHistoryState: can go back and forward, the entries, the current
    one (sent when the history or the current entry's title changed). }
  IpcHistoryState = 207;
  IpcZoomChanged = 208;
  { The pointer shape over the view. }
  IpcCursorChanged = 209;
  { URL, disposition (a request: the reply says whether the browser
    took it). }
  IpcLinkClicked = 210;
  IpcDownloadRequested = 211;
  { URL, reason. }
  IpcNavigationFailed = 212;
  { TIpcContextInfo (a request: the reply says whether the browser
    showed its own menu). }
  IpcContextMenu = 213;
  { TIpcPopupMenu: the browser shows it and answers IpcMenuChosen. }
  IpcPopupMenu = 214;
  { Level, text. }
  IpcConsoleMessage = 215;
  { Kind, message, default (a request: the reply has the answer). }
  IpcScriptDialog = 216;
  { beforeunload (a request: the reply says whether to leave). }
  IpcConfirmUnload = 217;
  IpcClipboardWrite = 218;
  { A request: the reply has the text. }
  IpcClipboardRead = 219;
  { The selected text (cut to SelectionTextLimit). }
  IpcSelectionChanged = 220;
  { A top-level navigation to another site: TIpcOpenUrl. The browser
    moves the view to a process of that site. }
  IpcOpenUrl = 221;
  { The slow script watchdog ended a script. }
  IpcScriptInterrupted = 222;
  { Input up to this sequence number was handled. }
  IpcInputHandled = 223;
  { A key the page did not use: TIpcInputEvent (the browser's own
    shortcuts). }
  IpcKeyUnhandled = 224;
  { The text of the whole page (a reply to IpcViewCommand PageText). }
  IpcPageText = 225;
  { A pop-up the page asked for without a user gesture was refused:
    its URL. }
  IpcPopupBlocked = 226;
  { Flag: the page asks to go fullscreen (True) or to leave it. }
  IpcFullscreenRequest = 230;
  { Flag: the page asks for the pointer to be locked (True) or let go. }
  IpcPointerLockRequest = 231;

  { ---- the network service ---- }
  { Content to browser: TIpcHopRequest (HopId is the content process's). }
  IpcHopStart = 300;
  IpcHopCancel = 301;
  { Browser to content: TIpcHopHead, then IpcHopData pieces, then
    IpcHopDone (TIpcHopOutcome). }
  IpcHopHead = 302;
  IpcHopData = 303;
  IpcHopDone = 304;
  { A request: path; the reply: found, is folder, contents, error. }
  IpcReadLocalFile = 305;
  { A request: URL, context flags; the reply: the cookie string. }
  IpcCookieGet = 306;
  { URL, cookie, context flags. }
  IpcCookieSet = 307;
  { A request: origin; the reply: the pairs of its local storage. }
  IpcStorageLoad = 308;
  { Origin, key, value. }
  IpcStorageSet = 309;
  { Origin, key. }
  IpcStorageRemove = 310;
  { Origin. }
  IpcStorageClear = 311;
  { A request: about:PATH; the reply: found, HTML (the browser's own
    pages, only for a process locked to about:). }
  IpcAboutPage = 312;
  { WebSockets. Content to browser: open (TIpcWebSocketOpen), send
    (TIpcWebSocketData), close (TIpcWebSocketClose), abort (the id).
    Browser to content: opened (TIpcWebSocketOpened), a message
    (TIpcWebSocketData), bytes sent (id and count), the server's close
    frame (the id), closed (TIpcWebSocketClosed, last). }
  IpcWebSocketOpen = 350;
  IpcWebSocketSend = 351;
  IpcWebSocketClose = 352;
  IpcWebSocketAbort = 353;
  IpcWebSocketOpened = 354;
  IpcWebSocketMessage = 355;
  IpcWebSocketSent = 356;
  IpcWebSocketCloseReceived = 357;
  IpcWebSocketClosed = 358;
  { IndexedDB, the Cache API and navigator.storage (the browser's
    storage service, Web.IndexedDb.Service). A request: the renderer's
    client id, the origin, the request bytes; the reply: the service's
    reply bytes. }
  IpcIndexedDbRequest = 340;
  { The client id: its script context is gone. }
  IpcIndexedDbClientClosed = 341;
  { Browser to renderer: the client id and a notice of the service (a
    versionchange for one of its connections). }
  IpcIndexedDbNotice = 342;
  { Per-origin records kept for the content process (service worker
    registrations: Web.Storage.OriginData). A
    request: TIpcOriginData without data; the reply: the record's bytes.
    Then TIpcOriginData with the whole new record (empty: removed). }
  IpcOriginDataLoad = 343;
  IpcOriginDataSave = 344;

  { The most of the selected text IpcSelectionChanged carries. }
  SelectionTextLimit = 256 * 1024;

type
  { One protocol message, whole (after its fragments are joined). }
  TIpcMessage = class
  public
    Kind: Word;
    ViewId: LongWord;
    RequestId: LongWord;
    Payload: TBytes;
    { Handles that came with it (the receiver's to close). }
    Handles: array of Int64;
    function IsReply: Boolean;
  end;

{ A name for a kind, for logs. }
function IpcKindName(Kind: Word): string;

implementation

function TIpcMessage.IsReply: Boolean;
begin
  Result := Kind = IpcReply;
end;

function IpcKindName(Kind: Word): string;
begin
  case Kind of
    IpcHello: Result := 'hello';
    IpcPing: Result := 'ping';
    IpcPong: Result := 'pong';
    IpcReply: Result := 'reply';
    IpcShutdown: Result := 'shutdown';
    IpcCreateView: Result := 'create-view';
    IpcDestroyView: Result := 'destroy-view';
    IpcNavigate: Result := 'navigate';
    IpcLoadHtml: Result := 'load-html';
    IpcInput: Result := 'input';
    IpcResize: Result := 'resize';
    IpcFramePresented: Result := 'frame';
    IpcSurfaceCreated: Result := 'surface';
    IpcOpenUrl: Result := 'open-url';
    IpcFind: Result := 'find';
    IpcGoToHistoryOffset: Result := 'go-to-history-offset';
    IpcRestoreHistory: Result := 'restore-history';
    IpcSetFindHighlight: Result := 'set-find-highlight';
    IpcRequestPageInfo: Result := 'request-page-info';
    IpcSetDisplayOptions: Result := 'set-display-options';
    IpcHistoryState: Result := 'history-state';
    IpcContextMenu: Result := 'context-menu';
    IpcPopupBlocked: Result := 'popup-blocked';
    IpcOriginDataLoad: Result := 'origin-data-load';
    IpcOriginDataSave: Result := 'origin-data-save';
    IpcHopStart: Result := 'hop-start';
    IpcHopHead: Result := 'hop-head';
    IpcHopData: Result := 'hop-data';
    IpcHopDone: Result := 'hop-done';
    IpcWebSocketOpen: Result := 'websocket-open';
    IpcWebSocketSend: Result := 'websocket-send';
    IpcWebSocketClose: Result := 'websocket-close';
    IpcWebSocketAbort: Result := 'websocket-abort';
    IpcWebSocketOpened: Result := 'websocket-opened';
    IpcWebSocketMessage: Result := 'websocket-message';
    IpcWebSocketSent: Result := 'websocket-sent';
    IpcWebSocketCloseReceived: Result := 'websocket-close-received';
    IpcWebSocketClosed: Result := 'websocket-closed';
    IpcIndexedDbRequest: Result := 'indexeddb-request';
    IpcIndexedDbClientClosed: Result := 'indexeddb-client-closed';
    IpcIndexedDbNotice: Result := 'indexeddb-notice';
  else
    Result := 'kind ' + IntToStr(Kind);
  end;
end;

end.
