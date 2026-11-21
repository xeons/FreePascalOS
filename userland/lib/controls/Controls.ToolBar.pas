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
  Toolbars: a strip of flat buttons along the top of a window.

  A tool button shows its picture from its own image list or the
  toolbar's (Images, ImageIndex), IconSize logical units across, and
  its text beside it or below it (CaptionBelow; either may be left out,
  or OnPaint may draw it); a hint (Hint) says what it does. It looks
  raised while the pointer is over it, pressed while held, and clicks
  when let go on it, or on Alt and its mnemonic ("&Bold"). A toggle
  button stays down until clicked again (Down). Separators are gaps
  with an etched line.

  A button may drop a menu down (DropDownMenu, filled in OnDropDown):
  DropDownOnHold clicks as usual but opens the menu when held for a
  moment or right-clicked (a browser's Back and Forward with their
  history); DropDownArrow is a split button whose narrow arrow part
  opens it; DropDownWhole opens it on any press (a menu button, a
  bookmarks folder).
}
unit Controls.ToolBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.ImageList,
  Controls.Menus,
  Controls.Timers;

type
  TToolDropDownKind = (DropDownNone, DropDownOnHold, DropDownArrow, DropDownWhole);

  TToolButton = class(TControl)
  private
    FHovered: Boolean;
    FHeld: Boolean;
    FIsToggle: Boolean;
    FDown: Boolean;
    FIsSeparator: Boolean;
    FImageIndex: LongInt;
    FImages: TImageList;
    FIconSize: LongInt;
    FCaptionBelow: Boolean;
    FDropDownKind: TToolDropDownKind;
    FDropDownMenu: TMenuItem;
    FOnDropDown: TControlEvent;
    FHoldTimer: TTimer;
    procedure SetDown(Value: Boolean);
    procedure SetImageIndex(Value: LongInt);
    procedure SetImages(Value: TImageList);
    procedure SetIconSize(Value: LongInt);
    procedure SetCaptionBelow(Value: Boolean);
    procedure SetDropDownKind(Value: TToolDropDownKind);
    procedure SetIsSeparator(Value: Boolean);
    function PictureList: TImageList;
    function ArrowWidth: LongInt;
    function InArrow(X: LongInt): Boolean;
    procedure HoldTimerFired(Sender: TTimer);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure ContextMenu(X, Y: LongInt; FromKeyboard: Boolean); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    { What its picture, text and arrow need (logical units). }
    function PreferredSize: TSize; override;
    { Opens its menu under it (after OnDropDown), as a press would. }
    procedure OpenDropDown;
    property IsToggle: Boolean read FIsToggle write FIsToggle;
    property Down: Boolean read FDown write SetDown;
    property IsSeparator: Boolean read FIsSeparator write SetIsSeparator;
    { Its picture in Images (-1, the default: none). }
    property ImageIndex: LongInt read FImageIndex write SetImageIndex;
    { Its own pictures (shared, not owned); nil: the toolbar's. }
    property Images: TImageList read FImages write SetImages;
    { How large its picture is drawn, logical units (16 unless set). }
    property IconSize: LongInt read FIconSize write SetIconSize;
    { The text under the picture rather than beside it. }
    property CaptionBelow: Boolean read FCaptionBelow write SetCaptionBelow;
    property DropDownKind: TToolDropDownKind read FDropDownKind write SetDropDownKind;
    { The menu it drops down (not owned). }
    property DropDownMenu: TMenuItem read FDropDownMenu write FDropDownMenu;
    { The menu is about to drop down: fill it. }
    property OnDropDown: TControlEvent read FOnDropDown write FOnDropDown;
  end;

  TToolBar = class(TControl)
  private
    FNextLeft: LongInt;
    FImages: TImageList;
    procedure SetImages(Value: TImageList);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { A button of Width logical units after the last (0: as wide as its
      text needs). }
    function AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent = nil): TToolButton;
    { The same with picture ImageIndex of Images, and a hint. }
    function AddImageButton(ImageIndex: LongInt; const AText, AHint: string; Width: LongInt;
      AOnClick: TControlEvent = nil): TToolButton;
    procedure AddSeparator;
    function PreferredSize: TSize; override;
    { The buttons' pictures (shared: the toolbar does not own it). }
    property Images: TImageList read FImages write SetImages;
  end;

implementation

uses
  Math,
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Icons,
  Controls.Text,
  Controls.Window,
  Controls.LayoutRules,
  Controls.Painting;

const
  { Logical units either side of a text button's caption. }
  TextButtonPadding = 16;
  ToolBarHeight = 26;
  ButtonHeight = 22;
  SeparatorWidth = 8;
  { The arrow part of a split button, and the gap around a picture. }
  ArrowPartWidth = 13;
  PictureGap = 3;
  { How long a press is held before the menu of DropDownOnHold opens. }
  HoldMilliseconds = 450;

constructor TToolButton.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FImageIndex := -1;
  FIconSize := SmallIconSize;
end;

destructor TToolButton.Destroy;
begin
  FHoldTimer.Free;
  inherited Destroy;
end;

procedure TToolButton.SetDown(Value: Boolean);
begin
  if FDown = Value then
    Exit;
  FDown := Value;
  Invalidate;
  Changed;
end;

procedure TToolButton.SetImageIndex(Value: LongInt);
begin
  FImageIndex := Value;
  Invalidate;
end;

procedure TToolButton.SetImages(Value: TImageList);
begin
  FImages := Value;
  Invalidate;
end;

procedure TToolButton.SetIconSize(Value: LongInt);
begin
  if FIconSize = Value then
    Exit;
  FIconSize := Value;
  RequestLayout;
  Invalidate;
end;

procedure TToolButton.SetCaptionBelow(Value: Boolean);
begin
  if FCaptionBelow = Value then
    Exit;
  FCaptionBelow := Value;
  RequestLayout;
  Invalidate;
end;

procedure TToolButton.SetDropDownKind(Value: TToolDropDownKind);
begin
  FDropDownKind := Value;
  RequestLayout;
  Invalidate;
end;

procedure TToolButton.SetIsSeparator(Value: Boolean);
begin
  FIsSeparator := Value;
  Invalidate;
end;

function TToolButton.PictureList: TImageList;
begin
  Result := FImages;
  if (Result = nil) and (Parent is TToolBar) then
    Result := TToolBar(Parent).Images;
  if (Result <> nil) and not Result.ValidIndex(FImageIndex) then
    Result := nil;
end;

{ Pixels. }
function TToolButton.ArrowWidth: LongInt;
begin
  if FDropDownKind in [DropDownArrow, DropDownWhole] then
    Result := Scaled(ArrowPartWidth)
  else
    Result := 0;
end;

function TToolButton.InArrow(X: LongInt): Boolean;
begin
  Result := (FDropDownKind = DropDownArrow) and (X >= RectangleWidth(PixelBounds) - ArrowWidth);
end;

function TToolButton.PreferredSize: TSize;
var
  TextPart: LongInt;
begin
  if FIsSeparator then
    Exit(MakeSize(SeparatorWidth, ButtonHeight));
  TextPart := 0;
  if Text <> '' then
    TextPart := PixelsToLogicalCeiling(MnemonicTextWidth(ControlFace, Text));
  if FCaptionBelow and (Text <> '') then
  begin
    Result.Width := Max(FIconSize, TextPart) + 2 * PictureGap + 4;
    Result.Height := FIconSize + PixelsToLogicalCeiling(TextHeight(ControlFace)) + 3 * PictureGap;
  end
  else
  begin
    Result.Width := 2 * PictureGap + 2;
    if (FImageIndex >= 0) or (Text = '') then
      Result.Width := Result.Width + FIconSize;
    if Text <> '' then
      Result.Width := Result.Width + TextPart + PictureGap * 2;
    Result.Height := Max(FIconSize + 2 * PictureGap, ButtonHeight);
  end;
  if FDropDownKind in [DropDownArrow, DropDownWhole] then
    Result.Width := Result.Width + ArrowPartWidth;
end;

procedure TToolButton.Paint(var Canvas: TCanvas);
var
  Box, Face, ImageBox, TextBox, ArrowBox: TRectangle;
  Shift, ImageSize, Arrow: LongInt;
  Pictures: TImageList;
  State: TImageDrawState;
  Pressed: Boolean;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if FIsSeparator then
  begin
    DrawEtchedVerticalLine(Canvas, RectangleWidth(Box) div 2 - BevelLine, 2, RectangleHeight(Box) - 2);
    Exit;
  end;
  Arrow := ArrowWidth;
  Shift := 0;
  Pressed := (FHeld and FHovered) or FDown;
  if Pressed then
  begin
    if FDown and not FHeld then
      FillRectangle(Canvas, Box, Theme.Light);
    DrawSunkenEdge(Canvas, Box);
    Shift := 1;
  end
  else if FHovered and Enabled then
  begin
    FillRectangle(Canvas, Box, Theme.HotButtonFace);
    DrawRaisedEdge(Canvas, Box);
    if FDropDownKind = DropDownArrow then
      DrawEtchedVerticalLine(Canvas, Box.Right - Arrow, Scaled(2), Box.Bottom - Scaled(2));
  end;
  Face := Box;
  Dec(Face.Right, Arrow);
  if Arrow > 0 then
  begin
    ArrowBox := MakeRectangle(Box.Right - Arrow + Shift, Box.Top + Shift, Arrow, RectangleHeight(Box));
    if Enabled then
      DrawArrowGlyph(Canvas, ArrowBox, ArrowDown, Max(2, Scaled(3)), Theme.FaceText)
    else
      DrawArrowGlyph(Canvas, ArrowBox, ArrowDown, Max(2, Scaled(3)), Theme.DisabledText);
  end;
  Pictures := PictureList;
  State := ImageDrawNormal;
  if not Enabled then
    State := ImageDrawDisabled;
  ImageSize := Scaled(FIconSize);
  if FCaptionBelow and (Text <> '') then
  begin
    ImageBox := MakeRectangle((RectangleWidth(Face) - ImageSize) div 2, Scaled(PictureGap), ImageSize, ImageSize);
    if Pictures <> nil then
      Pictures.DrawInBox(Canvas, FImageIndex, OffsetRectangle(ImageBox, Shift, Shift), State);
    TextBox := MakeRectangle(Face.Left, ImageBox.Bottom + Scaled(1), RectangleWidth(Face),
      Face.Bottom - ImageBox.Bottom - Scaled(1));
  end
  else
  begin
    TextBox := Face;
    if Pictures <> nil then
    begin
      { The picture at the left (in the middle without a text), the text
        in what is left. }
      if Text = '' then
        ImageBox := MakeRectangle((RectangleWidth(Face) - ImageSize) div 2, (RectangleHeight(Face) - ImageSize) div 2,
          ImageSize, ImageSize)
      else
        ImageBox := MakeRectangle(Scaled(PictureGap), (RectangleHeight(Face) - ImageSize) div 2, ImageSize, ImageSize);
      Pictures.DrawInBox(Canvas, FImageIndex, OffsetRectangle(ImageBox, Shift, Shift), State);
      TextBox.Left := ImageBox.Right;
    end;
  end;
  if Text = '' then
    Exit;
  if Enabled then
    DrawMnemonicTextInBox(Canvas, ControlFace, Text, OffsetRectangle(InflateRectangle(TextBox, -Scaled(2)), Shift,
      Shift), AlignTextCenter, Theme.FaceText)
  else
    DrawDisabledMnemonicText(Canvas, ControlFace, Text, TextBox.Left + (RectangleWidth(TextBox) -
      MnemonicTextWidth(ControlFace, Text)) div 2, TextBox.Top + (RectangleHeight(TextBox) -
      TextHeight(ControlFace)) div 2);
end;

function TToolButton.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := not FIsSeparator and TextMatchesMnemonic(Character);
end;

procedure TToolButton.ActivateMnemonic(Character: LongWord);
begin
  if FDropDownKind = DropDownWhole then
  begin
    OpenDropDown;
    Exit;
  end;
  if FIsToggle then
    Down := not FDown;
  Click;
end;

procedure TToolButton.PointerEnter;
begin
  FHovered := True;
  Invalidate;
end;

procedure TToolButton.PointerLeave;
begin
  FHovered := False;
  Invalidate;
end;

procedure TToolButton.OpenDropDown;
var
  Window: TControlWindow;
begin
  if FHoldTimer <> nil then
    FHoldTimer.Enabled := False;
  FHeld := False;
  Invalidate;
  if Assigned(FOnDropDown) then
    FOnDropDown(Self);
  if (FDropDownMenu = nil) or (FDropDownMenu.Count = 0) or (Host = nil) or
     not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, FDropDownMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Bottom));
end;

procedure TToolButton.HoldTimerFired(Sender: TTimer);
begin
  Sender.Enabled := False;
  if FHeld and FHovered then
    OpenDropDown;
end;

procedure TToolButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if FIsSeparator or not Enabled then
    Exit;
  if (Button = ButtonRight) and (FDropDownKind in [DropDownOnHold, DropDownArrow]) then
  begin
    OpenDropDown;
    Exit;
  end;
  if Button <> ButtonLeft then
    Exit;
  if (FDropDownKind = DropDownWhole) or InArrow(X) then
  begin
    OpenDropDown;
    Exit;
  end;
  FHeld := True;
  if FDropDownKind = DropDownOnHold then
  begin
    if FHoldTimer = nil then
    begin
      FHoldTimer := TTimer.Create(Self);
      FHoldTimer.Interval := HoldMilliseconds;
      FHoldTimer.OnTimer := @HoldTimerFired;
    end;
    FHoldTimer.Enabled := False;
    FHoldTimer.Enabled := True;
  end;
  Invalidate;
end;

procedure TToolButton.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Inside: Boolean;
begin
  if FHoldTimer <> nil then
    FHoldTimer.Enabled := False;
  if not FHeld then
    Exit;
  FHeld := False;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  FHovered := Inside;
  Invalidate;
  if not Inside then
    Exit;
  if FIsToggle then
    Down := not FDown;
  Click;
end;

procedure TToolButton.ContextMenu(X, Y: LongInt; FromKeyboard: Boolean);
begin
  { A right press opened the menu already. }
  if FDropDownKind in [DropDownOnHold, DropDownArrow] then
  begin
    if FromKeyboard then
      OpenDropDown;
    Exit;
  end;
  inherited ContextMenu(X, Y, FromKeyboard);
end;

{ Its buttons in a row, and its own height. }
function TToolBar.PreferredSize: TSize;
begin
  Result := MakeSize(FNextLeft + 2, ToolBarHeight);
end;

constructor TToolBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  SetBounds(0, 0, 0, ToolBarHeight);
  Align := AlignTop;
  FNextLeft := 2;
end;

procedure TToolBar.SetImages(Value: TImageList);
var
  Index: LongInt;
begin
  FImages := Value;
  for Index := 0 to ChildCount - 1 do
    Children[Index].Invalidate;
end;

function TToolBar.AddImageButton(ImageIndex: LongInt; const AText, AHint: string; Width: LongInt;
  AOnClick: TControlEvent): TToolButton;
begin
  Result := AddButton(AText, Width, AOnClick);
  Result.ImageIndex := ImageIndex;
  Result.Hint := AHint;
end;

function TToolBar.AddButton(const AText: string; Width: LongInt; AOnClick: TControlEvent): TToolButton;
begin
  if Width <= 0 then
    Width := Unscaled(MnemonicTextWidth(ControlFace, AText)) + TextButtonPadding;
  Result := TToolButton.Create(Self);
  Result.Text := AText;
  Result.OnClick := AOnClick;
  Result.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, Width, ButtonHeight);
  FNextLeft := FNextLeft + Width + 1;
end;

procedure TToolBar.AddSeparator;
var
  Separator: TToolButton;
begin
  Separator := TToolButton.Create(Self);
  Separator.FIsSeparator := True;
  Separator.SetBounds(FNextLeft, (ToolBarHeight - ButtonHeight) div 2, SeparatorWidth, ButtonHeight);
  FNextLeft := FNextLeft + SeparatorWidth;
end;

procedure TToolBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawEtchedHorizontalLine(Canvas, 0, Box.Right, Box.Bottom - 2 * BevelLine);
end;

end.
