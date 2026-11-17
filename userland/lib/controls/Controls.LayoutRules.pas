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
  Layout rules: the arithmetic of placing a control in its parent,
  apart from the controls themselves (so it builds and is checked on the
  host, tools/ControlsTest).

  Docking (TAlign): a control docked to a side takes a strip of what is
  left of its parent along that side, its margins kept clear around it;
  one docked to the client area takes what remains after every side.

  Anchors: a control that is not docked keeps its distance to each
  anchored edge of its parent's client area as the parent resizes. Left
  and right together stretch it, so do top and bottom; with neither of a
  pair its middle stays at the same share of the parent's extent.

  Constraints: a minimum and maximum width and height (a maximum of 0
  is none) that every way of sizing a control respects.

  Everything here is in pixels: the controls scale their logical units
  before asking.
}
unit Controls.LayoutRules;

{$mode objfpc}
{$H+}

interface

uses
  Types,
  Drawing.Rectangles;

type
  TSize = Types.TSize;

  TAlign = (AlignNone, AlignTop, AlignBottom, AlignLeft, AlignRight, AlignClient);

  TAnchorKind = (akLeft, akTop, akRight, akBottom);
  TAnchors = set of TAnchorKind;

  { Space on each side: around a control (its margin) or inside a
    container (its padding). }
  TSpacing = record
    Left: LongInt;
    Top: LongInt;
    Right: LongInt;
    Bottom: LongInt;
  end;

  { A maximum of 0 means no maximum. }
  TSizeConstraints = record
    MinWidth: LongInt;
    MinHeight: LongInt;
    MaxWidth: LongInt;
    MaxHeight: LongInt;
  end;

const
  DefaultAnchors: TAnchors = [akLeft, akTop];

function MakeSize(Width, Height: LongInt): TSize;
function MakeSpacing(Left, Top, Right, Bottom: LongInt): TSpacing;
function UniformSpacing(Amount: LongInt): TSpacing;
function SpacingsAreEqual(const First, Second: TSpacing): Boolean;
function SpacingWidth(const Spacing: TSpacing): LongInt;
function SpacingHeight(const Spacing: TSpacing): LongInt;
{ Area with Spacing taken off its sides (never smaller than nothing). }
function DeflateBySpacing(const Area: TRectangle; const Spacing: TSpacing): TRectangle;
function MakeConstraints(MinWidth, MinHeight, MaxWidth, MaxHeight: LongInt): TSizeConstraints;
{ Extent within Minimum and Maximum (0: none), and never below zero. }
function ConstrainExtent(Extent, Minimum, Maximum: LongInt): LongInt;
function ConstrainWidth(Width: LongInt; const Constraints: TSizeConstraints): LongInt;
function ConstrainHeight(Height: LongInt; const Constraints: TSizeConstraints): LongInt;
function ConstrainSize(const Size: TSize; const Constraints: TSizeConstraints): TSize;

{ Where an anchored control goes along one axis: it was placed at Start,
  Extent long, when its parent's extent was Reference; the parent is now
  Current long. LowAnchored and HighAnchored: anchored to the left (top)
  and right (bottom) edge. A size limited by Minimum and Maximum keeps
  the anchored edge (the low one if both, the middle if neither). }
procedure AnchorSpan(LowAnchored, HighAnchored: Boolean; Start, Extent, Reference, Current, Minimum,
  Maximum: LongInt; out NewStart, NewExtent: LongInt);
{ The control's rectangle, relative to the client area's top left: it
  was Placed (relative too) when the client area was ReferenceWidth x
  ReferenceHeight, which is now ClientWidth x ClientHeight. }
function AnchoredRectangle(Anchors: TAnchors; const Placed: TRectangle; ReferenceWidth, ReferenceHeight,
  ClientWidth, ClientHeight: LongInt; const Constraints: TSizeConstraints): TRectangle;

{ Docks a control to a side of Remaining (or to all of it: AlignClient),
  Margin kept clear around it, and takes its strip off Remaining
  (AlignClient leaves Remaining as it was). Size: the control's own
  width (left, right) or height (top, bottom); the other extent is the
  strip's. A size limited by the constraints stays at the docked side
  (or at the strip's top left). AlignNone gives an empty rectangle. }
function DockRectangle(Align: TAlign; var Remaining: TRectangle; const Margin: TSpacing; const Size: TSize;
  const Constraints: TSizeConstraints): TRectangle;

{ A control of Size placed in a Cell (a table's), Margin kept clear in
  it: left and right anchors together (or Fill) stretch it across, one
  of them puts it at that side, neither centres it; the same up and
  down. }
function PlaceInCell(const Cell: TRectangle; const Size: TSize; const Margin: TSpacing; Anchors: TAnchors;
  Fill: Boolean; const Constraints: TSizeConstraints): TRectangle;

implementation

function MakeSize(Width, Height: LongInt): TSize;
begin
  Result.cx := Width;
  Result.cy := Height;
end;

function MakeSpacing(Left, Top, Right, Bottom: LongInt): TSpacing;
begin
  Result.Left := Left;
  Result.Top := Top;
  Result.Right := Right;
  Result.Bottom := Bottom;
end;

function UniformSpacing(Amount: LongInt): TSpacing;
begin
  Result := MakeSpacing(Amount, Amount, Amount, Amount);
end;

function SpacingsAreEqual(const First, Second: TSpacing): Boolean;
begin
  Result := (First.Left = Second.Left) and (First.Top = Second.Top) and (First.Right = Second.Right) and
    (First.Bottom = Second.Bottom);
end;

function SpacingWidth(const Spacing: TSpacing): LongInt;
begin
  Result := Spacing.Left + Spacing.Right;
end;

function SpacingHeight(const Spacing: TSpacing): LongInt;
begin
  Result := Spacing.Top + Spacing.Bottom;
end;

function DeflateBySpacing(const Area: TRectangle; const Spacing: TSpacing): TRectangle;
begin
  Result.Left := Area.Left + Spacing.Left;
  Result.Top := Area.Top + Spacing.Top;
  Result.Right := Area.Right - Spacing.Right;
  Result.Bottom := Area.Bottom - Spacing.Bottom;
  if Result.Right < Result.Left then
    Result.Right := Result.Left;
  if Result.Bottom < Result.Top then
    Result.Bottom := Result.Top;
end;

function MakeConstraints(MinWidth, MinHeight, MaxWidth, MaxHeight: LongInt): TSizeConstraints;
begin
  Result.MinWidth := MinWidth;
  Result.MinHeight := MinHeight;
  Result.MaxWidth := MaxWidth;
  Result.MaxHeight := MaxHeight;
end;

function ConstrainExtent(Extent, Minimum, Maximum: LongInt): LongInt;
begin
  Result := Extent;
  if (Maximum > 0) and (Result > Maximum) then
    Result := Maximum;
  if Result < Minimum then
    Result := Minimum;
  if Result < 0 then
    Result := 0;
end;

function ConstrainWidth(Width: LongInt; const Constraints: TSizeConstraints): LongInt;
begin
  Result := ConstrainExtent(Width, Constraints.MinWidth, Constraints.MaxWidth);
end;

function ConstrainHeight(Height: LongInt; const Constraints: TSizeConstraints): LongInt;
begin
  Result := ConstrainExtent(Height, Constraints.MinHeight, Constraints.MaxHeight);
end;

function ConstrainSize(const Size: TSize; const Constraints: TSizeConstraints): TSize;
begin
  Result := MakeSize(ConstrainWidth(Size.cx, Constraints), ConstrainHeight(Size.cy, Constraints));
end;

procedure AnchorSpan(LowAnchored, HighAnchored: Boolean; Start, Extent, Reference, Current, Minimum,
  Maximum: LongInt; out NewStart, NewExtent: LongInt);
var
  Wanted: LongInt;
  DistanceToHigh: LongInt;
  Doubled: LongInt;
begin
  if LowAnchored and HighAnchored then
  begin
    NewStart := Start;
    NewExtent := ConstrainExtent(Extent + Current - Reference, Minimum, Maximum);
  end
  else if LowAnchored then
  begin
    NewStart := Start;
    NewExtent := ConstrainExtent(Extent, Minimum, Maximum);
  end
  else if HighAnchored then
  begin
    NewExtent := ConstrainExtent(Extent, Minimum, Maximum);
    DistanceToHigh := Reference - (Start + Extent);
    NewStart := Current - DistanceToHigh - NewExtent;
  end
  else
  begin
    { The middle at the same share: twice the middle is 2 * Start +
      Extent, scaled from Reference to Current. }
    NewExtent := ConstrainExtent(Extent, Minimum, Maximum);
    Doubled := 2 * Start + Extent;
    if Reference > 0 then
      Doubled := LongInt((Int64(Doubled) * Current) div Reference);
    Wanted := Doubled - NewExtent;
    if Wanted >= 0 then
      NewStart := Wanted div 2
    else
      NewStart := -((1 - Wanted) div 2);
  end;
end;

function AnchoredRectangle(Anchors: TAnchors; const Placed: TRectangle; ReferenceWidth, ReferenceHeight,
  ClientWidth, ClientHeight: LongInt; const Constraints: TSizeConstraints): TRectangle;
var
  Left, Width, Top, Height: LongInt;
begin
  AnchorSpan(akLeft in Anchors, akRight in Anchors, Placed.Left, RectangleWidth(Placed), ReferenceWidth,
    ClientWidth, Constraints.MinWidth, Constraints.MaxWidth, Left, Width);
  AnchorSpan(akTop in Anchors, akBottom in Anchors, Placed.Top, RectangleHeight(Placed), ReferenceHeight,
    ClientHeight, Constraints.MinHeight, Constraints.MaxHeight, Top, Height);
  Result := MakeRectangle(Left, Top, Width, Height);
end;

function DockRectangle(Align: TAlign; var Remaining: TRectangle; const Margin: TSpacing; const Size: TSize;
  const Constraints: TSizeConstraints): TRectangle;
var
  Strip: TRectangle;
  Width: LongInt;
  Height: LongInt;
begin
  Strip := DeflateBySpacing(Remaining, Margin);
  case Align of
    AlignTop, AlignBottom:
      begin
        Width := ConstrainWidth(RectangleWidth(Strip), Constraints);
        Height := ConstrainHeight(Size.cy, Constraints);
        if Align = AlignTop then
        begin
          Result := MakeRectangle(Strip.Left, Remaining.Top + Margin.Top, Width, Height);
          Remaining.Top := Remaining.Top + Margin.Top + Height + Margin.Bottom;
          if Remaining.Top > Remaining.Bottom then
            Remaining.Top := Remaining.Bottom;
        end
        else
        begin
          Result := MakeRectangle(Strip.Left, Remaining.Bottom - Margin.Bottom - Height, Width, Height);
          Remaining.Bottom := Remaining.Bottom - Margin.Bottom - Height - Margin.Top;
          if Remaining.Bottom < Remaining.Top then
            Remaining.Bottom := Remaining.Top;
        end;
      end;
    AlignLeft, AlignRight:
      begin
        Width := ConstrainWidth(Size.cx, Constraints);
        Height := ConstrainHeight(RectangleHeight(Strip), Constraints);
        if Align = AlignLeft then
        begin
          Result := MakeRectangle(Remaining.Left + Margin.Left, Strip.Top, Width, Height);
          Remaining.Left := Remaining.Left + Margin.Left + Width + Margin.Right;
          if Remaining.Left > Remaining.Right then
            Remaining.Left := Remaining.Right;
        end
        else
        begin
          Result := MakeRectangle(Remaining.Right - Margin.Right - Width, Strip.Top, Width, Height);
          Remaining.Right := Remaining.Right - Margin.Right - Width - Margin.Left;
          if Remaining.Right < Remaining.Left then
            Remaining.Right := Remaining.Left;
        end;
      end;
    AlignClient:
      Result := MakeRectangle(Strip.Left, Strip.Top, ConstrainWidth(RectangleWidth(Strip), Constraints),
        ConstrainHeight(RectangleHeight(Strip), Constraints));
  else
    Result := MakeRectangle(Remaining.Left, Remaining.Top, 0, 0);
  end;
end;

{ One axis of PlaceInCell. }
procedure PlaceAcross(CellStart, CellExtent, Extent, MarginLow, MarginHigh: LongInt; LowAnchored, HighAnchored: Boolean;
  Minimum, Maximum: LongInt; out Start, NewExtent: LongInt);
var
  Room: LongInt;
begin
  Room := CellExtent - MarginLow - MarginHigh;
  if Room < 0 then
    Room := 0;
  if LowAnchored and HighAnchored then
    NewExtent := ConstrainExtent(Room, Minimum, Maximum)
  else
    NewExtent := ConstrainExtent(Extent, Minimum, Maximum);
  if HighAnchored and not LowAnchored then
    Start := CellStart + CellExtent - MarginHigh - NewExtent
  else if LowAnchored then
    Start := CellStart + MarginLow
  else
    Start := CellStart + MarginLow + (Room - NewExtent) div 2;
end;

function PlaceInCell(const Cell: TRectangle; const Size: TSize; const Margin: TSpacing; Anchors: TAnchors;
  Fill: Boolean; const Constraints: TSizeConstraints): TRectangle;
var
  Left, Width, Top, Height: LongInt;
begin
  if Fill then
    Anchors := [akLeft, akTop, akRight, akBottom];
  PlaceAcross(Cell.Left, RectangleWidth(Cell), Size.cx, Margin.Left, Margin.Right, akLeft in Anchors,
    akRight in Anchors, Constraints.MinWidth, Constraints.MaxWidth, Left, Width);
  PlaceAcross(Cell.Top, RectangleHeight(Cell), Size.cy, Margin.Top, Margin.Bottom, akTop in Anchors,
    akBottom in Anchors, Constraints.MinHeight, Constraints.MaxHeight, Top, Height);
  Result := MakeRectangle(Left, Top, Width, Height);
end;

end.
