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
  Disclosure buttons: a flat button with a chevron that shows or hides
  more of a window ("More details" pointing down, "Fewer details"
  pointing up once expanded). A click, or Space or Enter while it has
  the focus, flips Expanded and announces it (OnChange, NotifyChanged).
}
unit Controls.DisclosureButton;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TDisclosureButton = class(TControl)
  private
    FExpanded: Boolean;
    FCollapsedText: string;
    FExpandedText: string;
    FHovered: Boolean;
    FHeld: Boolean;
    procedure SetExpanded(Value: Boolean);
    procedure SetCollapsedText(const Value: string);
    procedure SetExpandedText(const Value: string);
    procedure ShowState;
    procedure Toggle;
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerEnter; override;
    procedure PointerLeave; override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    function KeyDown(Code, Character, Modifiers: LongWord): Boolean; override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    { Setting it is not announced. }
    property Expanded: Boolean read FExpanded write SetExpanded;
    property CollapsedText: string read FCollapsedText write SetCollapsedText;
    property ExpandedText: string read FExpandedText write SetExpandedText;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Keys,
  Controls.Text,
  Controls.LayoutRules,
  Controls.Painting,
  Controls.PartPainting;

const
  { Logical units. }
  GlyphBox = 18;
  GlyphSize = 8;
  TextRoom = 8;
  ButtonHeight = 24;

constructor TDisclosureButton.Create(AParent: TControl);
begin
  inherited Create(AParent);
  CanFocus := True;
  FCollapsedText := 'More details';
  FExpandedText := 'Fewer details';
  ShowState;
end;

procedure TDisclosureButton.ShowState;
begin
  if FExpanded then
    Text := FExpandedText
  else
    Text := FCollapsedText;
  Invalidate;
end;

procedure TDisclosureButton.SetExpanded(Value: Boolean);
begin
  FExpanded := Value;
  ShowState;
end;

procedure TDisclosureButton.SetCollapsedText(const Value: string);
begin
  FCollapsedText := Value;
  ShowState;
end;

procedure TDisclosureButton.SetExpandedText(const Value: string);
begin
  FExpandedText := Value;
  ShowState;
end;

procedure TDisclosureButton.Toggle;
begin
  SetExpanded(not FExpanded);
  Changed;
end;

function TDisclosureButton.PreferredSize: TSize;
begin
  Result := MakeSize(GlyphBox + PixelsToLogicalCeiling(TextWidth(ControlFace, Text)) + 2 * TextRoom, ButtonHeight);
end;

procedure TDisclosureButton.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Glyph: TRectangle;
  Caption: TRectangle;
  Look: TPartLook;
  Direction: TArrowDirection;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Look := PartNormal;
  if FHeld and FHovered then
    Look := PartPressed
  else if FHovered then
    Look := PartHot;
  DrawPartFace(Canvas, Box, Look);
  Glyph := MakeRectangle(Box.Left + Scaled(4), Box.Top, Scaled(GlyphBox), RectangleHeight(Box));
  Direction := ArrowDown;
  if FExpanded then
    Direction := ArrowUp;
  DrawChevronGlyph(Canvas, Glyph, Direction, Scaled(GlyphSize), Theme.FaceText);
  Caption := MakeRectangle(Glyph.Right + Scaled(2), Box.Top, Box.Right - Glyph.Right - Scaled(4),
    RectangleHeight(Box));
  DrawTextInBox(Canvas, ControlFace, Text, Caption, AlignTextLeft, Theme.FaceText);
  if Focused then
    DrawFocusFrame(Canvas, InflateRectangle(Box, -Scaled(2)), Theme.FaceText);
end;

procedure TDisclosureButton.PointerEnter;
begin
  FHovered := True;
  Invalidate;
end;

procedure TDisclosureButton.PointerLeave;
begin
  FHovered := False;
  Invalidate;
end;

procedure TDisclosureButton.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if Button <> ButtonLeft then
    Exit;
  FHeld := True;
  SetFocus;
  Invalidate;
end;

procedure TDisclosureButton.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Inside: Boolean;
begin
  if not FHeld then
    Exit;
  FHeld := False;
  Inside := (X >= 0) and (Y >= 0) and (X < RectangleWidth(PixelBounds)) and (Y < RectangleHeight(PixelBounds));
  Invalidate;
  if Inside then
    Toggle;
end;

function TDisclosureButton.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
begin
  Result := (Code = KeySpace) or IsEnterKey(Code);
  if Result then
    Toggle;
end;

end.
