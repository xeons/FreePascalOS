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
  button (Enter) has a dark outline.
}
unit Controls.Buttons;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Base;

type
  TButton = class(TControl)
  private
    FHeld: Boolean;
    FPointerInside: Boolean;
    FIsDefault: Boolean;
    procedure SetIsDefault(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    function MatchesMnemonic(Character: LongWord): Boolean; override;
    procedure ActivateMnemonic(Character: LongWord); override;
    function PreferredSize: TSize; override;
    { Drawn with the default outline (whether Enter presses it is the
      window's DefaultControl). }
    property IsDefault: Boolean read FIsDefault write SetIsDefault;
  end;

{ The pressed or raised look of a button in Box. }
procedure DrawButtonFace(const Canvas: TCanvas; const Box: TRectangle; Pressed, Outlined: Boolean);

implementation

uses
  Abi.SystemCalls,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.LayoutRules;

procedure DrawButtonFace(const Canvas: TCanvas; const Box: TRectangle; Pressed, Outlined: Boolean);
var
  Inner: TRectangle;
begin
  Inner := Box;
  FillRectangle(Canvas, Box, Theme.Face);
  if Outlined then
  begin
    DrawRectangleOutline(Canvas, Box, Theme.DarkShadow);
    Inner := InflateRectangle(Box, -1);
  end;
  if Pressed then
  begin
    DrawRectangleOutline(Canvas, Inner, Theme.Shadow);
  end
  else
    DrawBevel(Canvas, Inner, RaisedThemeBevel);
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

procedure TButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  TextBox: TRectangle;
  Pressed: Boolean;
  Shift: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Pressed := FHeld and FPointerInside;
  DrawButtonFace(Canvas, Box, Pressed, FIsDefault or Focused);
  Shift := 0;
  if Pressed then
    Shift := 1;
  TextBox := OffsetRectangle(InflateRectangle(Box, -Scaled(4)), Shift, Shift);
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
  if Width < MinimumButtonWidth then
    Width := MinimumButtonWidth;
  Height := PixelsToLogicalCeiling(TextHeight(ControlFace)) + ButtonTextRoomDown;
  if Height < MinimumButtonHeight then
    Height := MinimumButtonHeight;
  Result := MakeSize(Width, Height);
end;

procedure TButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FHeld := True;
  FPointerInside := True;
  Invalidate;
end;

procedure TButton.PointerMove(X, Y: LongInt; Buttons: LongWord);
var
  Inside: Boolean;
begin
  if not FHeld then
    Exit;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  if Inside <> FPointerInside then
  begin
    FPointerInside := Inside;
    Invalidate;
  end;
end;

procedure TButton.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  if (Button <> ButtonLeft) or not FHeld then
    Exit;
  FHeld := False;
  Invalidate;
  if (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds)) then
    Click;
end;

function TButton.MatchesMnemonic(Character: LongWord): Boolean;
begin
  Result := TextMatchesMnemonic(Character);
end;

procedure TButton.ActivateMnemonic(Character: LongWord);
begin
  Click;
end;

function TButton.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := (Code = KeySpace) or IsEnterKey(Code);
  if Result then
    Click;
end;

end.
