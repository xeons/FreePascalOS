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
  Push buttons.

  Pressed with the left button (it looks pressed while the pointer
  stays on it; let go there and it clicks) or with Space while it has
  the focus, or with Alt and its mnemonic ("&OK"). The window's default
  button (Enter) has a dark outline; a button lights up (the theme's
  hot face) while the pointer is over it.

  A flat button (Flat) has no edge until the pointer is over it. A
  split button (Kind ButtonSplit) has an arrow part at its right,
  separated by an etched line, that opens its DropDownMenu below it
  (the rest clicks as usual); a drop-down button (ButtonDropDown) opens
  the menu wherever it is pressed (Space, Enter, its mnemonic and Alt
  with Down do too; Alt with Down also opens a split button's menu).
}
unit Controls.Buttons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base,
  Controls.Menus;

type
  { How a button looks: as it is, lit under the pointer, or held down. }
  TButtonLook = (ButtonLookNormal, ButtonLookHot, ButtonLookPressed);
  TButtonKind = (ButtonPush, ButtonSplit, ButtonDropDown);

  TButton = class(TControl)
  private
    FHeld: Boolean;
    FPointerInside: Boolean;
    FHot: Boolean;
    FIsDefault: Boolean;
    FFlat: Boolean;
    FKind: TButtonKind;
    FDropDownMenu: TMenuItem;
    FOnDropDownChoose: TMenuItemEvent;
    procedure SetIsDefault(Value: Boolean);
    procedure SetFlat(Value: Boolean);
    procedure SetKind(Value: TButtonKind);
    function ArrowPartLeft: LongInt;
    function OnArrowPart(X: LongInt): Boolean;
    function Inside(X, Y: LongInt): Boolean;
    function CurrentLook: TButtonLook;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
    procedure EnabledChanged; override;
  public
    constructor Create(AParent: TControl); override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    function PreferredSize: TSize; override;
    { Opens DropDownMenu below the button (nothing without one). }
    procedure DropDown;
    { Drawn with the default outline (whether Enter presses it is the
      window's DefaultControl). }
    property IsDefault: Boolean read FIsDefault write SetIsDefault;
    property Flat: Boolean read FFlat write SetFlat;
    property Kind: TButtonKind read FKind write SetKind;
    { The menu a split or drop-down button opens (not owned), and what
      runs when one of its items is chosen (besides the item's own
      OnClick). }
    property DropDownMenu: TMenuItem read FDropDownMenu write FDropDownMenu;
    property OnDropDownChoose: TMenuItemEvent read FOnDropDownChoose write FOnDropDownChoose;
  end;

{ The pressed or raised look of a button in Box. }
procedure DrawButtonFace(const Canvas: TCanvas; const Box: TRectangle; Pressed, Outlined: Boolean);
{ The same in any of the looks. }
procedure DrawButtonFaceLook(const Canvas: TCanvas; const Box: TRectangle; Look: TButtonLook; Outlined: Boolean);
{ A flat button's look: the face, with a thin raised edge when hot and a
  sunken one when pressed. }
procedure DrawFlatButtonFace(const Canvas: TCanvas; const Box: TRectangle; Look: TButtonLook);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.Painting,
  Controls.Window,
  Controls.LayoutRules;

const
  { Logical units: the arrow part of a split or drop-down button. }
  ArrowPartWidth = 18;

function ButtonFaceColor(Look: TButtonLook): TColor;
begin
  case Look of
    ButtonLookHot: Result := Theme.HotButtonFace;
    ButtonLookPressed: Result := Theme.PressedButtonFace;
  else
    Result := Theme.Face;
  end;
end;

procedure DrawButtonFaceLook(const Canvas: TCanvas; const Box: TRectangle; Look: TButtonLook; Outlined: Boolean);
var
  Inner: TRectangle;
  Outline: LongInt;
begin
  Inner := Box;
  FillRectangle(Canvas, Box, ButtonFaceColor(Look));
  if Outlined then
  begin
    Outline := Theme.DefaultButtonOutline * BevelLine;
    DrawThickOutline(Canvas, Box, Outline, Theme.DarkShadow);
    Inner := InflateRectangle(Box, -Outline);
  end;
  if Look = ButtonLookPressed then
    DrawThickOutline(Canvas, Inner, BevelLine, Theme.Shadow)
  else
    DrawRaisedBevel(Canvas, Inner);
end;

procedure DrawButtonFace(const Canvas: TCanvas; const Box: TRectangle; Pressed, Outlined: Boolean);
begin
  if Pressed then
    DrawButtonFaceLook(Canvas, Box, ButtonLookPressed, Outlined)
  else
    DrawButtonFaceLook(Canvas, Box, ButtonLookNormal, Outlined);
end;

procedure DrawFlatButtonFace(const Canvas: TCanvas; const Box: TRectangle; Look: TButtonLook);
begin
  FillRectangle(Canvas, Box, ButtonFaceColor(Look));
  case Look of
    ButtonLookHot: DrawRaisedEdge(Canvas, Box);
    ButtonLookPressed: DrawSunkenEdge(Canvas, Box);
  end;
end;

constructor TButton.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
end;

procedure TButton.SetIsDefault(Value: Boolean);
begin
  FIsDefault := Value;
  Invalidate;
end;

procedure TButton.SetFlat(Value: Boolean);
begin
  FFlat := Value;
  Invalidate;
end;

procedure TButton.SetKind(Value: TButtonKind);
begin
  FKind := Value;
  Invalidate;
end;

function TButton.ArrowPartLeft: LongInt;
begin
  Result := RectangleWidth(PixelBounds) - Scaled(ArrowPartWidth);
end;

function TButton.OnArrowPart(X: LongInt): Boolean;
begin
  Result := (FKind = ButtonDropDown) or ((FKind = ButtonSplit) and (X >= ArrowPartLeft));
end;

function TButton.Inside(X, Y: LongInt): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
end;

{ Held with the pointer on it: pressed; under the pointer (and not held
  elsewhere): lit. }
function TButton.CurrentLook: TButtonLook;
begin
  Result := ButtonLookNormal;
  if FHeld then
  begin
    if FPointerInside then
      Result := ButtonLookPressed;
  end
  else if FHot and Enabled then
    Result := ButtonLookHot;
end;

procedure TButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  TextBox: TRectangle;
  ArrowBox: TRectangle;
  Look: TButtonLook;
  Shift: LongInt;
  ArrowColor: TColor;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Look := CurrentLook;
  if FFlat then
    DrawFlatButtonFace(Canvas, Box, Look)
  else
    DrawButtonFaceLook(Canvas, Box, Look, FIsDefault or Focused);
  Shift := 0;
  if Look = ButtonLookPressed then
    Shift := 1;
  TextBox := OffsetRectangle(InflateRectangle(Box, -Scaled(4)), Shift, Shift);
  if FKind <> ButtonPush then
  begin
    { The arrow part: an etched line (split buttons) and a down arrow. }
    ArrowBox := MakeRectangle(ArrowPartLeft, 0, Scaled(ArrowPartWidth), RectangleHeight(Box));
    if FKind = ButtonSplit then
      DrawEtchedVerticalLine(Canvas, ArrowBox.Left, Scaled(4), RectangleHeight(Box) - Scaled(4));
    ArrowColor := Theme.FaceText;
    if not Enabled then
      ArrowColor := Theme.DisabledText;
    DrawArrowGlyph(Canvas, OffsetRectangle(ArrowBox, Shift, Shift), ArrowDown, Scaled(4), ArrowColor);
    TextBox.Right := ArrowBox.Left - Scaled(2);
  end;
  if Enabled then
    DrawMnemonicTextInBox(Canvas, ControlFace, Text, TextBox, AlignTextCenter, Theme.FaceText)
  else
    DrawDisabledMnemonicText(Canvas, ControlFace, Text, TextBox.Left + (RectangleWidth(TextBox) -
      MnemonicTextWidth(ControlFace, Text)) div 2, TextBox.Top + (RectangleHeight(TextBox) - TextHeight(ControlFace)) div 2);
  if Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Box, -Scaled(4)), Theme.FaceText);
end;

const
  { The smallest button (a dialog's OK), and the room around its text. }
  MinimumButtonWidth = 75;
  MinimumButtonHeight = 23;
  ButtonTextRoomAcross = 24;
  ButtonTextRoomDown = 8;

function TButton.PreferredSize: TSize;
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := PixelsToLogicalCeiling(MnemonicTextWidth(ControlFace, Text)) + ButtonTextRoomAcross;
  if FKind <> ButtonPush then
    Width := Width + ArrowPartWidth;
  if Width < MinimumButtonWidth then
    Width := MinimumButtonWidth;
  Height := PixelsToLogicalCeiling(TextHeight(ControlFace)) + ButtonTextRoomDown;
  if Height < MinimumButtonHeight then
    Height := MinimumButtonHeight;
  Result := MakeSize(Width, Height);
end;

procedure TButton.DropDown;
var
  Window: TControlWindow;
begin
  if (FDropDownMenu = nil) or (Host = nil) or not (Host.OwnerWindow is TControlWindow) then
    Exit;
  Window := TControlWindow(Host.OwnerWindow);
  ShowPopupMenu(Window, FDropDownMenu, Window.ScreenLeft + Unscaled(PixelBounds.Left),
    Window.ScreenTop + Unscaled(PixelBounds.Bottom), FOnDropDownChoose);
end;

procedure TButton.PointerEnter;
begin
  FHot := True;
  Invalidate;
end;

procedure TButton.PointerLeave;
begin
  FHot := False;
  Invalidate;
end;

procedure TButton.EnabledChanged;
begin
  inherited EnabledChanged;
  FHeld := False;
  Invalidate;
end;

procedure TButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  if OnArrowPart(X) then
  begin
    { The menu opens at once; the button does not stay held. }
    DropDown;
    Exit;
  end;
  FHeld := True;
  FPointerInside := True;
  Invalidate;
end;

procedure TButton.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  IsInside: Boolean;
begin
  if not FHeld then
    Exit;
  IsInside := Inside(X, Y);
  if IsInside <> FPointerInside then
  begin
    FPointerInside := IsInside;
    Invalidate;
  end;
end;

procedure TButton.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or not FHeld then
    Exit;
  FHeld := False;
  Invalidate;
  if Inside(X, Y) then
    Click;
end;

function TButton.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := TextMatchesMnemonic(Character);
end;

procedure TButton.ActivateMnemonic(Character: LongWord);
begin
  if FKind = ButtonDropDown then
    DropDown
  else
    Click;
end;

function TButton.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  if (FKind <> ButtonPush) and (Code = KeyArrowDown) and ((Modifiers and ModifierAlt) <> 0) then
  begin
    DropDown;
    Exit(True);
  end;
  Result := (Code = KeySpace) or IsEnterKey(Code);
  if not Result then
    Exit;
  if FKind = ButtonDropDown then
    DropDown
  else
    Click;
end;

end.
