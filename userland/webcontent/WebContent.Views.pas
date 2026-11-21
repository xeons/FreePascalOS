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
  One of the browser's views, hosted in this content process: a page
  engine (WebView.Engine) in a control host without a window
  (WebContent.Host). It does what the browser's messages say (navigate,
  resize, input, find...), tells the browser what the page does (title,
  location, loading, links, dialogs, menus), and paints frames into a
  section shared with the browser: what changed, once the browser took
  the last frame (IpcFrameAck), never more often.

  A top-level navigation to another site is not this process's: the
  engine hands it to the browser (IpcOpenUrl), which moves the view to
  that site's process.
}
unit WebContent.Views;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Drawing.Rectangles,
  Controls.Base,
  Controls.Menus,
  Url.Records,
  Web.Navigation.Navigables,
  Web.Fetch.NetworkContexts,
  Web.Storage,
  WebIpc.Messages,
  WebIpc.ViewMessages,
  WebIpc.SharedSurfaces,
  WebView.Types,
  WebView.Engine,
  WebContent.Connection,
  WebContent.Host;

type
  { What every view of the process shares. }
  TContentContext = class
  public
    Connection: TContentConnection;
    Network: TNetworkContext;
    Storage: TWebStorageRegistry;
    { The site the browser locked this process to (WebView.Sites). }
    Site: string;
    { A view asked for a crash or a hang (tests). }
    CrashRequested: Boolean;
    HangRequested: Boolean;
  end;

  TContentView = class
  private
    FContext: TContentContext;
    FViewId: LongWord;
    FHost: TContentControlHost;
    FRoot: TControl;
    FEngine: TWebEngineView;
    FSurface: TSharedSurface;
    FSurfaceId: LongWord;
    FFrameNumber: LongWord;
    FAwaitingAck: Boolean;
    FWidth, FHeight: LongInt;
    FInputHandled: LongWord;
    FLastCursor: LongWord;
    FSelectionDirty: Boolean;
    FVisible: Boolean;
    FMenu: TMenuItem;
    FMenuId: LongWord;
    FMenuChosen: TMenuItemEvent;
    procedure Send(Kind: Word; const Payload: TBytes);
    function Call(Kind: Word; const Payload: TBytes; Timeout: Int64): TIpcMessage;
    procedure ApplyGeometry(constref Geometry: TIpcViewGeometry);
    procedure SetVisible(Value: Boolean);
    procedure SetFocused(Value: Boolean);
    procedure HandleInput(constref Input: TIpcInputEvent);
    procedure PointerMoved(X, Y: LongInt; Buttons: LongWord);
    procedure HandleKeyDown(constref Input: TIpcInputEvent);
    procedure HandleCommand(Command: LongInt);
    procedure ChooseMenuItem(MenuId: LongWord; Tag: LongInt);
    procedure NavigateTo(const Payload: TBytes);
    procedure Find(Message: TIpcMessage);
    procedure SendHistory;
    procedure CheckCursor;
    { What the engine tells. }
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
    function EnginePopupMenu(Sender: TWebEngineView; Menu: TMenuItem; X, Y: LongInt; OnChosen: TMenuItemEvent): Boolean;
    function EngineReadClipboard(Sender: TWebEngineView): string;
    procedure EngineWriteClipboard(Sender: TWebEngineView; const Value: string);
    procedure EngineSelectionChanged(Sender: TWebEngineView);
    function EngineNavigationRequest(Sender: TWebEngineView; constref Url: TUrlRecord;
      constref Options: TNavigateOptions; AtResponse: Boolean): Boolean;
    function ProvideAboutPage(const Path: string; out Html: string): Boolean;
  public
    constructor Create(Context: TContentContext; ViewId: LongWord; constref Setup: TIpcViewSetup);
    destructor Destroy; override;
    { A message for this view (the caller frees it). }
    procedure Handle(Message: TIpcMessage);
    { After each turn of the loop: a frame if something changed and the
      browser took the last one; the selection and the pointer's shape
      if they changed. }
    procedure FinishTurn;
    procedure ScriptInterrupted;
    property ViewId: LongWord read FViewId;
    property Visible: Boolean read FVisible;
  end;

implementation

uses
  Drawing.Canvas,
  Image.Model,
  Windowing.Connection,
  Windowing.Windows,
  Url.Parser,
  WebIpc.Wire,
  WebView.Sites;

const
  DialogTimeout = -1;
  ClipboardTimeout = 5000;
  AboutTimeout = 10000;
  FaviconLimit = 256;

constructor TContentView.Create(Context: TContentContext; ViewId: LongWord; constref Setup: TIpcViewSetup);
begin
  inherited Create;
  FContext := Context;
  FViewId := ViewId;
  FHost := TContentControlHost.Create;
  FHost.Scale.ScalePercent := Setup.Geometry.ScalePercent;
  FHost.Scale.Dpi := Setup.Geometry.Dpi;
  UseScale(Setup.Geometry.ScalePercent, Setup.Geometry.Dpi);
  FRoot := CreateRootControl(FHost);
  FEngine := TWebEngineView.Create(FRoot);
  FEngine.Align := AlignClient;
  FEngine.NetworkContext := Context.Network;
  FEngine.LocalStorage := Context.Storage;
  FEngine.ScriptingEnabled := Setup.ScriptingEnabled;
  FEngine.OnTitleChanged := @EngineTitleChanged;
  FEngine.OnLocationChanged := @EngineLocationChanged;
  FEngine.OnLoadingStateChanged := @EngineLoadingStateChanged;
  FEngine.OnFaviconChanged := @EngineFaviconChanged;
  FEngine.OnStatusText := @EngineStatusText;
  FEngine.OnHistoryChanged := @EngineHistoryChanged;
  FEngine.OnZoomChanged := @EngineZoomChanged;
  FEngine.OnLinkClicked := @EngineLinkClicked;
  FEngine.OnDownloadRequested := @EngineDownloadRequested;
  FEngine.OnNavigationFailed := @EngineNavigationFailed;
  FEngine.OnContextMenuRequested := @EngineContextMenu;
  FEngine.OnConfirmUnload := @EngineConfirmUnload;
  FEngine.OnScriptAlert := @EngineScriptAlert;
  FEngine.OnScriptConfirm := @EngineScriptConfirm;
  FEngine.OnScriptPrompt := @EngineScriptPrompt;
  FEngine.OnConsoleMessage := @EngineConsole;
  FEngine.OnPopupMenu := @EnginePopupMenu;
  FEngine.OnReadClipboard := @EngineReadClipboard;
  FEngine.OnWriteClipboard := @EngineWriteClipboard;
  FEngine.OnSelectionChanged := @EngineSelectionChanged;
  FEngine.OnNavigationRequest := @EngineNavigationRequest;
  FEngine.Navigable.Fetcher.AboutPageProvider := @ProvideAboutPage;
  if Setup.Zoom <> 1 then
    FEngine.Zoom := Setup.Zoom;
  FVisible := True;
  ApplyGeometry(Setup.Geometry);
  SetVisible(Setup.Visible);
  SetFocused(Setup.Focused);
end;

destructor TContentView.Destroy;
begin
  FMenu.Free;
  FRoot.Free;
  FHost.Free;
  FSurface.Free;
  inherited Destroy;
end;

procedure TContentView.Send(Kind: Word; const Payload: TBytes);
begin
  FContext.Connection.Send(Kind, FViewId, Payload);
end;

function TContentView.Call(Kind: Word; const Payload: TBytes; Timeout: Int64): TIpcMessage;
begin
  Result := FContext.Connection.Call(Kind, FViewId, Payload, Timeout);
end;

procedure TContentView.ApplyGeometry(constref Geometry: TIpcViewGeometry);
var
  Info: TIpcSurfaceInfo;
  Section: Int64;
begin
  FHost.Scale.ScalePercent := Geometry.ScalePercent;
  FHost.Scale.Dpi := Geometry.Dpi;
  UseScale(Geometry.ScalePercent, Geometry.Dpi);
  FRoot.SetPixelBounds(MakeRectangle(0, 0, Geometry.Width, Geometry.Height));
  if (Geometry.Width <> FWidth) or (Geometry.Height <> FHeight) or (FSurface = nil) then
  begin
    FWidth := Geometry.Width;
    FHeight := Geometry.Height;
    FreeAndNil(FSurface);
    FSurface := TSharedSurface.CreateNew(FWidth, FHeight);
    if FSurface <> nil then
    begin
      Inc(FSurfaceId);
      Info.SurfaceId := FSurfaceId;
      Info.Width := FWidth;
      Info.Height := FHeight;
      Info.StrideBytes := FSurface.StrideBytes;
      Section := FSurface.DuplicateSection;
      if Section >= 0 then
        FContext.Connection.Send(IpcSurfaceCreated, FViewId, EncodeSurfaceInfo(Info), [Section]);
      { The old surface's frame is not waited for. }
      FAwaitingAck := False;
    end;
  end;
  FHost.DamageAll(FWidth, FHeight);
end;

procedure TContentView.SetVisible(Value: Boolean);
begin
  FVisible := Value;
  FEngine.Visible := Value;
  if Value then
    FHost.DamageAll(FWidth, FHeight);
end;

procedure TContentView.SetFocused(Value: Boolean);
begin
  if Value then
    FHost.FocusControl(FEngine)
  else
    FHost.FocusControl(nil);
end;

procedure TContentView.Handle(Message: TIpcMessage);
var
  X, Y: Double;
  First, Second: string;
  Number, Other: LongInt;
begin
  case Message.Kind of
    IpcNavigate: NavigateTo(Message.Payload);
    IpcLoadHtml:
      begin
        DecodeTexts(Message.Payload, First, Second);
        FEngine.LoadHtml(First, Second);
      end;
    IpcGoBack: FEngine.GoBack;
    IpcGoForward: FEngine.GoForward;
    IpcReload: FEngine.Reload(DecodeFlag(Message.Payload));
    IpcStop: FEngine.Stop;
    IpcResize: ApplyGeometry(DecodeGeometry(Message.Payload));
    IpcSetVisible: SetVisible(DecodeFlag(Message.Payload));
    IpcSetFocus: SetFocused(DecodeFlag(Message.Payload));
    IpcSetZoom: FEngine.Zoom := DecodeReal(Message.Payload);
    IpcInput: HandleInput(DecodeInputEvent(Message.Payload));
    IpcFind: Find(Message);
    IpcSelectAll: FEngine.SelectAll;
    IpcCopySelection: FEngine.CopySelection;
    IpcClearSelection: FEngine.ClearSelection;
    IpcScrollBy:
      begin
        DecodeReals(Message.Payload, X, Y);
        FEngine.ScrollBy(X, Y);
      end;
    IpcScrollTo:
      begin
        DecodeReals(Message.Payload, X, Y);
        FEngine.ScrollTo(X, Y);
      end;
    IpcFrameAck:
      if LongWord(DecodeNumber(Message.Payload)) = FFrameNumber then
        FAwaitingAck := False;
    IpcMenuChosen:
      begin
        DecodeNumbers(Message.Payload, Number, Other);
        ChooseMenuItem(LongWord(Number), Other);
      end;
    IpcSetScripting: FEngine.ScriptingEnabled := DecodeFlag(Message.Payload);
    IpcViewCommand: HandleCommand(DecodeNumber(Message.Payload));
  end;
end;

procedure TContentView.NavigateTo(const Payload: TBytes);
var
  Open: TIpcOpenUrl;
  Url: TUrlRecord;
  Options: TNavigateOptions;
begin
  Open := DecodeOpenUrl(Payload);
  if not ParseUrl(Open.Url, Url) then
    Exit;
  Options := DefaultNavigateOptions;
  Options.UserInitiated := Open.UserInitiated;
  Options.Replace := Open.Replace;
  if (Open.Method <> '') and (Open.Method <> 'GET') then
  begin
    Options.Method := Open.Method;
    Options.Body := Open.Body;
    Options.ContentType := Open.ContentType;
  end;
  FEngine.NavigateWith(Url, Options);
end;

procedure TContentView.Find(Message: TIpcMessage);
var
  Reader: TIpcReader;
  Needle: string;
  Forward, MatchCase: Boolean;
begin
  Reader := TIpcReader.Create(Message.Payload);
  try
    Needle := Reader.ReadString;
    Forward := Reader.ReadBoolean;
    MatchCase := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
  FContext.Connection.Reply(Message, EncodeFlag(FEngine.FindText(Needle, Forward, MatchCase)));
end;

procedure TContentView.HandleCommand(Command: LongInt);
begin
  case Command of
    ViewCommandBack: FEngine.GoBack;
    ViewCommandForward: FEngine.GoForward;
    ViewCommandReload: FEngine.Reload;
    ViewCommandCopy: FEngine.CopySelection;
    ViewCommandSelectAll: FEngine.SelectAll;
    ViewCommandPageText: Send(IpcPageText, EncodeText(FEngine.PageText));
    ViewCommandCrash: FContext.CrashRequested := True;
    ViewCommandHang: FContext.HangRequested := True;
  end;
end;

procedure TContentView.ChooseMenuItem(MenuId: LongWord; Tag: LongInt);
var
  Index: Integer;
  Item: TMenuItem;
begin
  if (FMenu = nil) or (MenuId <> FMenuId) or not Assigned(FMenuChosen) then
    Exit;
  for Index := 0 to FMenu.Count - 1 do
  begin
    Item := FMenu.Items[Index];
    if Item.Tag = Tag then
    begin
      FMenuChosen(Item);
      Exit;
    end;
  end;
end;

{ ---- input, as a window gives it to its controls ---- }

procedure TContentView.PointerMoved(X, Y: LongInt; Buttons: LongWord);
var
  Target: TControl;
begin
  if FHost.Pressed <> nil then
  begin
    FHost.Pressed.HandlePointerMove(X, Y, Buttons);
    Exit;
  end;
  Target := FRoot.ControlAt(X, Y);
  if Target <> FHost.Hovered then
  begin
    if FHost.Hovered <> nil then
      FHost.Hovered.HandlePointerLeave;
    FHost.Hovered := Target;
    if Target <> nil then
      Target.HandlePointerEnter;
  end;
  if Target <> nil then
    Target.HandlePointerMove(X, Y, Buttons);
end;

procedure TContentView.HandleKeyDown(constref Input: TIpcInputEvent);
var
  Control: TControl;
begin
  Control := FHost.FocusedControl;
  if Control = nil then
    Control := FEngine;
  while Control <> nil do
  begin
    if Control.HandleKeyDown(Input.Code, Input.Character, Input.Modifiers) then
      Exit;
    Control := Control.Parent;
  end;
  Send(IpcKeyUnhandled, EncodeInputEvent(Input));
end;

procedure TContentView.HandleInput(constref Input: TIpcInputEvent);
var
  Target: TControl;
  Point: TPoint;
begin
  SetHeldModifiers(Input.Modifiers);
  case Input.Kind of
    InputPointerDown:
      begin
        Target := FRoot.ControlAt(Input.X, Input.Y);
        FHost.Pressed := Target;
        if Target <> nil then
          Target.HandlePointerDown(Input.X, Input.Y, Input.Button);
      end;
    InputPointerMove: PointerMoved(Input.X, Input.Y, Input.Button);
    InputPointerUp:
      begin
        Target := FHost.Pressed;
        FHost.Pressed := nil;
        if Target <> nil then
          Target.HandlePointerUp(Input.X, Input.Y, Input.Button);
      end;
    InputPointerLeave:
      begin
        if FHost.Hovered <> nil then
          FHost.Hovered.HandlePointerLeave;
        FHost.Hovered := nil;
      end;
    InputWheel:
      if FHost.Hovered <> nil then
        FHost.Hovered.HandleWheel(Input.Steps)
      else
        FEngine.HandleWheel(Input.Steps);
    InputKeyDown: HandleKeyDown(Input);
    InputKeyUp:
      if FHost.FocusedControl <> nil then
        FHost.FocusedControl.HandleKeyUp(Input.Code, Input.Modifiers);
    InputContextMenu:
      if Input.FromKeyboard then
      begin
        Point := FEngine.KeyboardContextPoint;
        FEngine.HandleContextMenu(FEngine.PixelBounds.Left + Point.X, FEngine.PixelBounds.Top + Point.Y, True);
      end
      else
        FEngine.HandleContextMenu(Input.X, Input.Y, False);
  end;
  FInputHandled := Input.Sequence;
  Send(IpcInputHandled, EncodeNumber(LongInt(FInputHandled)));
  CheckCursor;
end;

procedure TContentView.CheckCursor;
var
  Over: TControl;
begin
  Over := FHost.Hovered;
  if Over = nil then
    Over := FEngine;
  if Over.PointerShape = FLastCursor then
    Exit;
  FLastCursor := Over.PointerShape;
  Send(IpcCursorChanged, EncodeNumber(LongInt(FLastCursor)));
end;

{ ---- frames ---- }

procedure TContentView.FinishTurn;
var
  Area, Damage: TRectangle;
  Canvas: TCanvas;
  Info: TIpcFrameInfo;
  Text: string;
begin
  if FSelectionDirty then
  begin
    FSelectionDirty := False;
    Text := FEngine.SelectedText;
    if Length(Text) > SelectionTextLimit then
      SetLength(Text, SelectionTextLimit);
    Send(IpcSelectionChanged, EncodeText(Text));
  end;
  if (FSurface = nil) or FAwaitingAck or not FVisible then
    Exit;
  FHost.PerformPendingLayout;
  if not FHost.TakeDamage(Damage) then
    Exit;
  if not IntersectRectangles(Damage, MakeRectangle(0, 0, FWidth, FHeight), Area) then
    Exit;
  BeginCanvas(Canvas, FSurface.Surface);
  NarrowCanvasClip(Canvas, Area);
  FRoot.PaintAll(Canvas);
  Inc(FFrameNumber);
  Info := Default(TIpcFrameInfo);
  Info.FrameNumber := FFrameNumber;
  Info.SurfaceId := FSurfaceId;
  Info.Width := FWidth;
  Info.Height := FHeight;
  Info.DamageLeft := Area.Left;
  Info.DamageTop := Area.Top;
  Info.DamageRight := Area.Right;
  Info.DamageBottom := Area.Bottom;
  FEngine.GetScrollState(Info.ScrollX, Info.ScrollY, Info.DocumentWidth, Info.DocumentHeight, Info.ViewportWidth,
    Info.ViewportHeight, Info.HasFixedBoxes);
  Info.InputHandled := FInputHandled;
  Send(IpcFramePresented, EncodeFrameInfo(Info));
  FAwaitingAck := True;
end;

procedure TContentView.ScriptInterrupted;
begin
  Send(IpcScriptInterrupted, nil);
end;

{ ---- what the engine tells ---- }

procedure TContentView.SendHistory;
begin
  Send(IpcHistoryState, EncodeFlags(FEngine.CanGoBack, FEngine.CanGoForward));
end;

procedure TContentView.EngineTitleChanged(Sender: TWebEngineView; const Value: string);
begin
  Send(IpcTitleChanged, EncodeText(Value));
end;

procedure TContentView.EngineLocationChanged(Sender: TWebEngineView; const Value: string);
begin
  Send(IpcLocationChanged, EncodeText(Value));
  SendHistory;
end;

procedure TContentView.EngineLoadingStateChanged(Sender: TWebEngineView; State: TLoadingState);
begin
  Send(IpcLoadingStateChanged, EncodeNumber(Ord(State)));
end;

procedure TContentView.EngineFaviconChanged(Sender: TWebEngineView);
var
  Icon: TIpcFavicon;
  Image: TImage;
begin
  Icon := Default(TIpcFavicon);
  Image := Sender.Favicon;
  if (Image <> nil) and (Image.Width <= FaviconLimit) and (Image.Height <= FaviconLimit) then
  begin
    Icon.Width := Image.Width;
    Icon.Height := Image.Height;
    SetLength(Icon.Pixels, Image.Width * Image.Height);
    if Length(Icon.Pixels) > 0 then
      Move(Image.Line(0)^, Icon.Pixels[0], Length(Icon.Pixels) * 4);
  end;
  Send(IpcFaviconChanged, EncodeFavicon(Icon));
end;

procedure TContentView.EngineStatusText(Sender: TWebEngineView; const Value: string);
begin
  Send(IpcStatusText, EncodeText(Value));
end;

procedure TContentView.EngineHistoryChanged(Sender: TWebEngineView);
begin
  SendHistory;
end;

procedure TContentView.EngineZoomChanged(Sender: TWebEngineView);
begin
  Send(IpcZoomChanged, EncodeReal(Sender.Zoom));
end;

procedure TContentView.EngineLinkClicked(Sender: TWebEngineView; const Url: string; Disposition: TLinkDisposition;
  var Handled: Boolean);
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Url);
    Writer.WriteByte(Ord(Disposition));
    Send(IpcLinkClicked, Writer.Data);
  finally
    Writer.Free;
  end;
  { A new tab or window is the browser's to open. }
  Handled := Disposition <> LinkInView;
end;

procedure TContentView.EngineDownloadRequested(Sender: TWebEngineView; constref Download: TDownloadInfo);
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Download.Url);
    Writer.WriteString(Download.MimeType);
    Writer.WriteString(Download.FileName);
    Send(IpcDownloadRequested, Writer.Data);
  finally
    Writer.Free;
  end;
end;

procedure TContentView.EngineNavigationFailed(Sender: TWebEngineView; const Url, Reason: string);
begin
  Send(IpcNavigationFailed, EncodeTexts(Url, Reason));
end;

procedure TContentView.EngineContextMenu(Sender: TWebEngineView; constref Info: TWebContextInfo;
  var Handled: Boolean);
var
  Wire: TIpcContextInfo;
begin
  Wire.X := Info.X;
  Wire.Y := Info.Y;
  Wire.FromKeyboard := Info.FromKeyboard;
  Wire.LinkUrl := Info.LinkUrl;
  Wire.LinkText := Info.LinkText;
  Wire.ImageUrl := Info.ImageUrl;
  Wire.SelectedText := Info.SelectedText;
  Wire.InTextField := Info.InTextField;
  Send(IpcContextMenu, EncodeContextInfo(Wire));
  { The browser shows its menu (or the view's own). }
  Handled := True;
end;

function TContentView.EngineConfirmUnload(Sender: TWebEngineView): Boolean;
var
  Answer: TIpcMessage;
begin
  Result := True;
  Answer := Call(IpcConfirmUnload, nil, DialogTimeout);
  if Answer = nil then
    Exit;
  try
    Result := DecodeDialogAnswer(Answer.Payload).Accepted;
  finally
    Answer.Free;
  end;
end;

function AskDialog(View: TContentView; Kind: Byte; const Message, Suggested: string): TIpcDialogAnswer;
var
  Request: TIpcDialogRequest;
  Answer: TIpcMessage;
begin
  Result := Default(TIpcDialogAnswer);
  Request.Kind := Kind;
  Request.Message := Message;
  Request.DefaultText := Suggested;
  Answer := View.Call(IpcScriptDialog, EncodeDialogRequest(Request), DialogTimeout);
  if Answer = nil then
    Exit;
  try
    Result := DecodeDialogAnswer(Answer.Payload);
  finally
    Answer.Free;
  end;
end;

procedure TContentView.EngineScriptAlert(Sender: TWebEngineView; const Value: string);
begin
  AskDialog(Self, DialogAlert, Value, '');
end;

function TContentView.EngineScriptConfirm(Sender: TWebEngineView; const Message: string): Boolean;
begin
  Result := AskDialog(Self, DialogConfirm, Message, '').Accepted;
end;

function TContentView.EngineScriptPrompt(Sender: TWebEngineView; const Message, Default: string;
  out Answer: string): Boolean;
var
  Reply: TIpcDialogAnswer;
begin
  Reply := AskDialog(Self, DialogPrompt, Message, Default);
  Answer := Reply.Text;
  Result := Reply.Accepted;
end;

procedure TContentView.EngineConsole(Sender: TWebEngineView; const Level, Value: string);
begin
  Send(IpcConsoleMessage, EncodeTexts(Level, Value));
end;

function TContentView.EnginePopupMenu(Sender: TWebEngineView; Menu: TMenuItem; X, Y: LongInt;
  OnChosen: TMenuItemEvent): Boolean;
var
  Wire: TIpcPopupMenu;
  Index: Integer;
  Item: TMenuItem;
begin
  Inc(FMenuId);
  FMenu := Menu;
  FMenuChosen := OnChosen;
  Wire.MenuId := FMenuId;
  Wire.X := X;
  Wire.Y := Y;
  Wire.Items := nil;
  SetLength(Wire.Items, Menu.Count);
  for Index := 0 to Menu.Count - 1 do
  begin
    Item := Menu.Items[Index];
    Wire.Items[Index] := Default(TIpcMenuItem);
    Wire.Items[Index].Caption := Item.Text;
    Wire.Items[Index].Shortcut := Item.ShortcutText;
    Wire.Items[Index].Tag := Item.Tag;
    Wire.Items[Index].Enabled := Item.Enabled;
    Wire.Items[Index].Checked := Item.Checked;
    Wire.Items[Index].Separator := Item.IsSeparator;
  end;
  Send(IpcPopupMenu, EncodePopupMenu(Wire));
  Result := True;
end;

function TContentView.EngineReadClipboard(Sender: TWebEngineView): string;
var
  Answer: TIpcMessage;
begin
  Result := '';
  Answer := Call(IpcClipboardRead, nil, ClipboardTimeout);
  if Answer = nil then
    Exit;
  try
    Result := DecodeText(Answer.Payload);
  finally
    Answer.Free;
  end;
end;

procedure TContentView.EngineWriteClipboard(Sender: TWebEngineView; const Value: string);
begin
  Send(IpcClipboardWrite, EncodeText(Value));
end;

procedure TContentView.EngineSelectionChanged(Sender: TWebEngineView);
begin
  FSelectionDirty := True;
end;

{ A top-level navigation (or where its redirects ended) to another site
  goes to the browser, which moves the view to that site's process. }
function TContentView.EngineNavigationRequest(Sender: TWebEngineView; constref Url: TUrlRecord;
  constref Options: TNavigateOptions; AtResponse: Boolean): Boolean;
var
  Site: string;
  Open: TIpcOpenUrl;
begin
  Site := SiteOfUrl(Url);
  if (Site = '') or (Site = FContext.Site) then
    Exit(True);
  Open := Default(TIpcOpenUrl);
  Open.Url := SerializeUrl(Url);
  Open.Disposition := Ord(LinkInView);
  Open.Method := Options.Method;
  Open.Body := Options.Body;
  Open.ContentType := Options.ContentType;
  Open.Replace := Options.Replace;
  Open.UserInitiated := Options.UserInitiated;
  Send(IpcOpenUrl, EncodeOpenUrl(Open));
  Result := False;
end;

function TContentView.ProvideAboutPage(const Path: string; out Html: string): Boolean;
var
  Answer: TIpcMessage;
  Reader: TIpcReader;
begin
  Html := '';
  Result := False;
  if FContext.Site <> SiteBrowserPages then
    Exit;
  Answer := Call(IpcAboutPage, EncodeText(Path), AboutTimeout);
  if Answer = nil then
    Exit;
  try
    Reader := TIpcReader.Create(Answer.Payload);
    try
      Result := Reader.ReadBoolean;
      Html := Reader.ReadString;
    finally
      Reader.Free;
    end;
  finally
    Answer.Free;
  end;
end;

end.
