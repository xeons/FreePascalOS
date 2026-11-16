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
  TrueType glyph outlines: the "glyf" table, found through "loca".

  loca gives where each glyph's data starts in glyf (16-bit offsets
  halved, or 32-bit ones); a glyph whose data is empty has no outline
  (a space). Every offset is checked when the font is opened
  (CheckGlyphLocations): in order and inside glyf.

  A simple glyph: the contour count, a bounding box, each contour's last
  point, instructions (skipped: the hinting here is the system's own,
  Font.Hinting), a flag a point (on the curve or not, how its
  coordinates are stored, repeated), then the x and the y coordinates
  as deltas from the point before.

  A composite glyph (contour count negative) is other glyphs put
  together: each component a glyph, moved by an offset (or so that one
  of its points lands on a point of the glyph so far) and optionally
  scaled or transformed by a 2x2 matrix. Components may be composite
  themselves, up to a depth that no real font comes near; deeper is a
  loop or a broken file. Any read past a glyph's data, a point count
  out of reason or a component naming a glyph that is not there makes
  the glyph unreadable (it is drawn as nothing), never anything worse.
}
unit Font.GlyphData;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData,
  Font.Outlines;

type
  TGlyphLocations = record
    Glyf: TFontTable;
    Loca: TFontTable;
    LongOffsets: Boolean;
    GlyphCount: LongWord;
  end;

{ Whether loca holds GlyphCount + 1 offsets, in order, inside glyf. }
function CheckGlyphLocations(const Locations: TGlyphLocations): Boolean;
{ The outline of Glyph in font units (see Font.Outlines' LoadOutline). }
function ReadGlyphOutline(const Locations: TGlyphLocations; Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
{ The left edge (xMin) the glyph's header gives; False for an empty or
  unreadable glyph. }
function ReadGlyphBoxLeft(const Locations: TGlyphLocations; Glyph: LongWord; out BoxLeft: LongInt): Boolean;

implementation

const
  MaximumComponentDepth = 8;
  MaximumPoints = 32768;
  MaximumContours = 8192;

  { Simple glyph flags. }
  FlagOnCurve = $01;
  FlagShortX = $02;
  FlagShortY = $04;
  FlagRepeat = $08;
  FlagSameOrPositiveX = $10;
  FlagSameOrPositiveY = $20;

  { Component flags. }
  ArgumentsAreWords = $0001;
  ArgumentsAreOffsets = $0002;
  HasScale = $0008;
  MoreComponents = $0020;
  HasXAndYScale = $0040;
  HasTwoByTwo = $0080;
  ScaledComponentOffset = $0800;
  UnscaledComponentOffset = $1000;

function GlyphOffset(const Locations: TGlyphLocations; Index: LongWord): QWord;
begin
  if Locations.LongOffsets then
    Result := ReadUnsigned32(Locations.Loca, 4 * QWord(Index))
  else
    Result := 2 * QWord(ReadUnsigned16(Locations.Loca, 2 * QWord(Index)));
end;

function CheckGlyphLocations(const Locations: TGlyphLocations): Boolean;
var
  EntrySize: QWord;
  Index: LongWord;
  Previous: QWord;
  Offset: QWord;
begin
  Result := False;
  if Locations.LongOffsets then
    EntrySize := 4
  else
    EntrySize := 2;
  if (Locations.GlyphCount = 0) or not Has(Locations.Loca, 0, EntrySize * (QWord(Locations.GlyphCount) + 1)) then
    Exit;
  Previous := 0;
  for Index := 0 to Locations.GlyphCount do
  begin
    Offset := GlyphOffset(Locations, Index);
    if (Offset < Previous) or (Offset > Locations.Glyf.Length) then
      Exit;
    Previous := Offset;
  end;
  Result := True;
end;

{ A simple glyph's points and contours, appended to Outline. }
function ReadSimpleGlyph(const Data: TFontTable; ContourCount: LongInt; var Outline: TGlyphOutline): Boolean;
var
  Position: QWord;
  Contour: LongInt;
  LastPoint: LongInt;
  PreviousEnd: LongInt;
  PointCount: LongInt;
  InstructionLength: LongWord;
  Flags: array of Byte;
  Flag: Byte;
  RepeatCount: LongWord;
  Point: LongInt;
  Coordinate: LongInt;
  Xs: array of LongInt;
  Value: LongInt;
  FirstPoint: LongInt;
  Ends: array of LongInt;
begin
  Result := False;
  if (ContourCount > MaximumContours) or not Has(Data, 10, 2 * QWord(ContourCount) + 2) then
    Exit;
  SetLength(Ends, ContourCount);
  PreviousEnd := -1;
  for Contour := 0 to ContourCount - 1 do
  begin
    LastPoint := ReadUnsigned16(Data, 10 + 2 * QWord(Contour));
    if LastPoint <= PreviousEnd then
      Exit;
    Ends[Contour] := LastPoint;
    PreviousEnd := LastPoint;
  end;
  PointCount := PreviousEnd + 1;
  if (ContourCount = 0) then
    Exit(True);
  if Outline.PointCount + PointCount > MaximumPoints then
    Exit;
  Position := 10 + 2 * QWord(ContourCount);
  InstructionLength := ReadUnsigned16(Data, Position);
  Position := Position + 2 + InstructionLength;
  { The flags, repeats unrolled. }
  SetLength(Flags, PointCount);
  Point := 0;
  while Point < PointCount do
  begin
    if not Has(Data, Position, 1) then
      Exit;
    Flag := ReadByte(Data, Position);
    Inc(Position);
    Flags[Point] := Flag;
    Inc(Point);
    if (Flag and FlagRepeat) <> 0 then
    begin
      if not Has(Data, Position, 1) then
        Exit;
      RepeatCount := ReadByte(Data, Position);
      Inc(Position);
      if Point + LongInt(RepeatCount) > PointCount then
        Exit;
      while RepeatCount > 0 do
      begin
        Flags[Point] := Flag;
        Inc(Point);
        Dec(RepeatCount);
      end;
    end;
  end;
  { The x coordinates, then the y ones. }
  SetLength(Xs, PointCount);
  Coordinate := 0;
  for Point := 0 to PointCount - 1 do
  begin
    Flag := Flags[Point];
    if (Flag and FlagShortX) <> 0 then
    begin
      if not Has(Data, Position, 1) then
        Exit;
      Value := ReadByte(Data, Position);
      Inc(Position);
      if (Flag and FlagSameOrPositiveX) = 0 then
        Value := -Value;
      Coordinate := Coordinate + Value;
    end
    else if (Flag and FlagSameOrPositiveX) = 0 then
    begin
      if not Has(Data, Position, 2) then
        Exit;
      Coordinate := Coordinate + ReadSigned16(Data, Position);
      Position := Position + 2;
    end;
    Xs[Point] := Coordinate;
  end;
  Coordinate := 0;
  FirstPoint := Outline.PointCount;
  Contour := 0;
  for Point := 0 to PointCount - 1 do
  begin
    Flag := Flags[Point];
    if (Flag and FlagShortY) <> 0 then
    begin
      if not Has(Data, Position, 1) then
        Exit;
      Value := ReadByte(Data, Position);
      Inc(Position);
      if (Flag and FlagSameOrPositiveY) = 0 then
        Value := -Value;
      Coordinate := Coordinate + Value;
    end
    else if (Flag and FlagSameOrPositiveY) = 0 then
    begin
      if not Has(Data, Position, 2) then
        Exit;
      Coordinate := Coordinate + ReadSigned16(Data, Position);
      Position := Position + 2;
    end;
    AddOutlinePoint(Outline, Xs[Point], Coordinate, (Flag and FlagOnCurve) <> 0);
    if Point = Ends[Contour] then
    begin
      EndOutlineContour(Outline);
      Inc(Contour);
    end;
  end;
  Result := Outline.PointCount = FirstPoint + PointCount;
end;

function ReadGlyphAtDepth(const Locations: TGlyphLocations; Glyph: LongWord; Depth: LongInt;
  var Outline: TGlyphOutline): Boolean; forward;

{ A composite glyph's components, each read on its own, placed and
  appended to Outline. }
function ReadCompositeGlyph(const Locations: TGlyphLocations; const Data: TFontTable; Depth: LongInt;
  var Outline: TGlyphOutline): Boolean;
var
  Position: QWord;
  Flags: LongWord;
  Component: LongWord;
  Argument1: LongInt;
  Argument2: LongInt;
  XX: Double;
  XY: Double;
  YX: Double;
  YY: Double;
  OffsetX: Double;
  OffsetY: Double;
  Part: TGlyphOutline;
  Point: LongInt;
  Contour: LongInt;
  Base: LongInt;
  X: Double;
  Y: Double;
  ParentPoint: LongInt;
  ChildPoint: LongInt;
begin
  Result := False;
  Position := 10;
  repeat
    if not Has(Data, Position, 4) then
      Exit;
    Flags := ReadUnsigned16(Data, Position);
    Component := ReadUnsigned16(Data, Position + 2);
    Position := Position + 4;
    if (Flags and ArgumentsAreWords) <> 0 then
    begin
      if not Has(Data, Position, 4) then
        Exit;
      if (Flags and ArgumentsAreOffsets) <> 0 then
      begin
        Argument1 := ReadSigned16(Data, Position);
        Argument2 := ReadSigned16(Data, Position + 2);
      end
      else
      begin
        Argument1 := ReadUnsigned16(Data, Position);
        Argument2 := ReadUnsigned16(Data, Position + 2);
      end;
      Position := Position + 4;
    end
    else
    begin
      if not Has(Data, Position, 2) then
        Exit;
      if (Flags and ArgumentsAreOffsets) <> 0 then
      begin
        Argument1 := ShortInt(Byte(ReadByte(Data, Position)));
        Argument2 := ShortInt(Byte(ReadByte(Data, Position + 1)));
      end
      else
      begin
        Argument1 := ReadByte(Data, Position);
        Argument2 := ReadByte(Data, Position + 1);
      end;
      Position := Position + 2;
    end;
    XX := 1;
    XY := 0;
    YX := 0;
    YY := 1;
    if (Flags and HasScale) <> 0 then
    begin
      if not Has(Data, Position, 2) then
        Exit;
      XX := ReadFixed2Dot14(Data, Position);
      YY := XX;
      Position := Position + 2;
    end
    else if (Flags and HasXAndYScale) <> 0 then
    begin
      if not Has(Data, Position, 4) then
        Exit;
      XX := ReadFixed2Dot14(Data, Position);
      YY := ReadFixed2Dot14(Data, Position + 2);
      Position := Position + 4;
    end
    else if (Flags and HasTwoByTwo) <> 0 then
    begin
      if not Has(Data, Position, 8) then
        Exit;
      XX := ReadFixed2Dot14(Data, Position);
      YX := ReadFixed2Dot14(Data, Position + 2);
      XY := ReadFixed2Dot14(Data, Position + 4);
      YY := ReadFixed2Dot14(Data, Position + 6);
      Position := Position + 8;
    end;
    ClearOutline(Part);
    if not ReadGlyphAtDepth(Locations, Component, Depth + 1, Part) then
      Exit;
    if Outline.PointCount + Part.PointCount > MaximumPoints then
      Exit;
    { Transformed, then moved. }
    for Point := 0 to Part.PointCount - 1 do
    begin
      X := Part.Points[Point].X;
      Y := Part.Points[Point].Y;
      Part.Points[Point].X := XX * X + XY * Y;
      Part.Points[Point].Y := YX * X + YY * Y;
    end;
    if (Flags and ArgumentsAreOffsets) <> 0 then
    begin
      OffsetX := Argument1;
      OffsetY := Argument2;
      if ((Flags and ScaledComponentOffset) <> 0) and ((Flags and UnscaledComponentOffset) = 0) then
      begin
        OffsetX := XX * Argument1 + XY * Argument2;
        OffsetY := YX * Argument1 + YY * Argument2;
      end;
    end
    else
    begin
      { The component's point Argument2 goes onto the glyph's point
        Argument1. }
      ParentPoint := Argument1;
      ChildPoint := Argument2;
      if (ParentPoint >= Outline.PointCount) or (ChildPoint >= Part.PointCount) then
        Exit;
      OffsetX := Outline.Points[ParentPoint].X - Part.Points[ChildPoint].X;
      OffsetY := Outline.Points[ParentPoint].Y - Part.Points[ChildPoint].Y;
    end;
    Base := Outline.PointCount;
    Contour := 0;
    for Point := 0 to Part.PointCount - 1 do
    begin
      AddOutlinePoint(Outline, Part.Points[Point].X + OffsetX, Part.Points[Point].Y + OffsetY,
        Part.Points[Point].OnCurve);
      if (Contour < Part.ContourCount) and (Point = Part.ContourEnds[Contour]) then
      begin
        EndOutlineContour(Outline);
        Inc(Contour);
      end;
    end;
    if Outline.PointCount <> Base + Part.PointCount then
      Exit;
  until (Flags and MoreComponents) = 0;
  Result := True;
end;

function ReadGlyphAtDepth(const Locations: TGlyphLocations; Glyph: LongWord; Depth: LongInt;
  var Outline: TGlyphOutline): Boolean;
var
  Start: QWord;
  Finish: QWord;
  Data: TFontTable;
  ContourCount: LongInt;
begin
  Result := False;
  if (Glyph >= Locations.GlyphCount) or (Depth > MaximumComponentDepth) then
    Exit;
  Start := GlyphOffset(Locations, Glyph);
  Finish := GlyphOffset(Locations, Glyph + 1);
  if Finish <= Start then
    Exit(True);
  Data := TablePart(Locations.Glyf, Start);
  Data.Length := Finish - Start;
  if not Has(Data, 0, 10) then
    Exit;
  ContourCount := ReadSigned16(Data, 0);
  if ContourCount >= 0 then
    Result := ReadSimpleGlyph(Data, ContourCount, Outline)
  else
    Result := ReadCompositeGlyph(Locations, Data, Depth, Outline);
end;

function ReadGlyphBoxLeft(const Locations: TGlyphLocations; Glyph: LongWord; out BoxLeft: LongInt): Boolean;
var
  Start: QWord;
  Finish: QWord;
  Data: TFontTable;
begin
  BoxLeft := 0;
  Result := False;
  if Glyph >= Locations.GlyphCount then
    Exit;
  Start := GlyphOffset(Locations, Glyph);
  Finish := GlyphOffset(Locations, Glyph + 1);
  if Finish <= Start then
    Exit;
  Data := TablePart(Locations.Glyf, Start);
  Data.Length := Finish - Start;
  if not Has(Data, 0, 10) then
    Exit;
  BoxLeft := ReadSigned16(Data, 2);
  Result := True;
end;

function ReadGlyphOutline(const Locations: TGlyphLocations; Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
begin
  ClearOutline(Outline);
  Result := ReadGlyphAtDepth(Locations, Glyph, 0, Outline);
  if not Result then
    ClearOutline(Outline);
end;

end.
