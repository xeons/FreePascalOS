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
  SVG text (SVG 2 chapter 11, its basic parts): <text> with <tspan>,
  <a> and <textPath> (laid out as a tspan, not along its path) inside,
  as glyph outlines in user space, ready to fill and stroke.

  - White space as xml:space="default" and CSS's collapsing: newlines
    and tabs become spaces, runs of spaces one, none at the start or
    end of the text.
  - Positions: x, y, dx, dy and rotate lists on any of the elements;
    the n-th value of an element goes to its n-th character, the
    innermost element with a value for a character wins (rotate's last
    value goes on for the characters after it).
  - Text chunks start at every character with an absolute x or y;
    text-anchor (start, middle, end) shifts each chunk by its advance.
  - Glyphs come from the document's font source at the element's font
    size and weight, advanced with the font's kerning, letter-spacing
    and word-spacing; italic or oblique type without an italic face is
    slanted (synthetic oblique).

  The result is one run per stretch of characters of one element, each
  with that element's style (a reference the runs hold).
}
unit Svg.Text;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Paths,
  Css.ComputedStyle,
  Svg.Nodes,
  Svg.Numbers,
  Svg.Fonts;

type
  { A new reference: Node's style under ParentStyle. }
  TSvgStyleFunction = function(Node: TSvgNode; ParentStyle: TCssComputedStyle): TCssComputedStyle of object;

  TSvgTextRun = record
    Node: TSvgNode;
    Style: TCssComputedStyle;
    Path: TPath;
  end;

  TSvgTextRuns = array of TSvgTextRun;

function LayoutText(TextNode: TSvgNode; TextStyle: TCssComputedStyle; StyleFunction: TSvgStyleFunction;
  FontSource: TSvgFontSource; const Viewport: TSvgViewport): TSvgTextRuns;
procedure FreeTextRuns(var Runs: TSvgTextRuns);

implementation

uses
  SysUtils,
  Math,
  Drawing.Rasterizer,
  Drawing.Transforms,
  Font.Outlines,
  Css.Keywords,
  Css.PropertyIds,
  Css.ComputedValues,
  Svg.StyleValues;

type
  TPositionLists = record
    X, Y, DX, DY: TSvgNumbers;
    Rotate: TSvgNumbers;
  end;

  TPositioner = record
    Lists: TPositionLists;
    { The index of the element's first character. }
    Start: Integer;
  end;

  TCharacter = record
    CodePoint: LongWord;
    { Index into the run owners (element and style). }
    Owner: Integer;
    HasX, HasY: Boolean;
    X, Y, DX, DY, Rotate: Double;
    { Laid out: where the glyph goes. }
    PenX, PenY: Double;
    Advance: Double;
    Chunk: Integer;
    Font: TOutlineFont;
    Glyph: LongWord;
  end;

  TOwner = record
    Node: TSvgNode;
    Style: TCssComputedStyle;
  end;

  TTextLayout = record
    Characters: array of TCharacter;
    Count: Integer;
    Owners: array of TOwner;
    OwnerCount: Integer;
    Stack: array of TPositioner;
    StackCount: Integer;
    LastWasSpace: Boolean;
    Viewport: TSvgViewport;
  end;

function LengthList(Node: TSvgNode; const Name: string; Direction: TSvgLengthDirection;
  const Viewport: TSvgViewport): TSvgNumbers;
var
  Lengths: TSvgLengths;
  Index: Integer;
begin
  Result := nil;
  if not Node.HasAttribute(Name) then
    Exit;
  Lengths := ParseLengthList(Node.Attribute(Name));
  SetLength(Result, Length(Lengths));
  for Index := 0 to High(Lengths) do
    Result[Index] := ResolveLength(Lengths[Index], Direction, Viewport);
end;

function NextCodePoint(const Text: string; var Index: Integer): LongWord;
var
  Lead: Byte;
  Extra: Integer;
begin
  Lead := Ord(Text[Index]);
  Inc(Index);
  if Lead < $80 then
    Exit(Lead);
  if Lead >= $F0 then
  begin
    Result := Lead and $07;
    Extra := 3;
  end
  else if Lead >= $E0 then
  begin
    Result := Lead and $0F;
    Extra := 2;
  end
  else if Lead >= $C0 then
  begin
    Result := Lead and $1F;
    Extra := 1;
  end
  else
    Exit($FFFD);
  while (Extra > 0) and (Index <= Length(Text)) and ((Ord(Text[Index]) and $C0) = $80) do
  begin
    Result := (Result shl 6) or (Ord(Text[Index]) and $3F);
    Inc(Index);
    Dec(Extra);
  end;
  if Extra > 0 then
    Result := $FFFD;
end;

procedure AddCharacter(var Layout: TTextLayout; CodePoint: LongWord; Owner: Integer);
var
  Character: ^TCharacter;
  Level: Integer;
  Offset: Integer;
  Index: Integer;
  RotateFound: Boolean;
begin
  if Layout.Count = Length(Layout.Characters) then
    SetLength(Layout.Characters, 2 * Layout.Count + 32);
  Index := Layout.Count;
  Character := @Layout.Characters[Index];
  Character^ := Default(TCharacter);
  Character^.CodePoint := CodePoint;
  Character^.Owner := Owner;
  RotateFound := False;
  { The innermost element with a value for this character wins. }
  for Level := Layout.StackCount - 1 downto 0 do
  begin
    Offset := Index - Layout.Stack[Level].Start;
    with Layout.Stack[Level].Lists do
    begin
      if not Character^.HasX and (Offset < Length(X)) then
      begin
        Character^.HasX := True;
        Character^.X := X[Offset];
      end;
      if not Character^.HasY and (Offset < Length(Y)) then
      begin
        Character^.HasY := True;
        Character^.Y := Y[Offset];
      end;
      if (Character^.DX = 0) and (Offset < Length(DX)) then
        Character^.DX := DX[Offset];
      if (Character^.DY = 0) and (Offset < Length(DY)) then
        Character^.DY := DY[Offset];
      if not RotateFound and (Length(Rotate) > 0) then
      begin
        RotateFound := True;
        if Offset < Length(Rotate) then
          Character^.Rotate := Rotate[Offset]
        else
          Character^.Rotate := Rotate[High(Rotate)];
      end;
    end;
  end;
  Inc(Layout.Count);
end;

procedure AddText(var Layout: TTextLayout; const Text: string; Owner: Integer);
var
  Index: Integer;
  CodePoint: LongWord;
begin
  Index := 1;
  while Index <= Length(Text) do
  begin
    CodePoint := NextCodePoint(Text, Index);
    if CodePoint in [9, 10, 13] then
      CodePoint := 32;
    if CodePoint = 32 then
    begin
      if Layout.LastWasSpace then
        Continue;
      Layout.LastWasSpace := True;
    end
    else
      Layout.LastWasSpace := False;
    AddCharacter(Layout, CodePoint, Owner);
  end;
end;

function AddOwner(var Layout: TTextLayout; Node: TSvgNode; Style: TCssComputedStyle): Integer;
begin
  if Layout.OwnerCount = Length(Layout.Owners) then
    SetLength(Layout.Owners, 2 * Layout.OwnerCount + 4);
  Layout.Owners[Layout.OwnerCount].Node := Node;
  Layout.Owners[Layout.OwnerCount].Style := Style;
  Result := Layout.OwnerCount;
  Inc(Layout.OwnerCount);
end;

procedure CollectElement(var Layout: TTextLayout; Element: TSvgNode; Style: TCssComputedStyle;
  StyleFunction: TSvgStyleFunction; Depth: Integer);
var
  Owner: Integer;
  Child: TSvgNode;
  ChildStyle: TCssComputedStyle;
  Positioner: TPositioner;
begin
  if Depth > 32 then
    Exit;
  Owner := AddOwner(Layout, Element, Style);
  Positioner.Start := Layout.Count;
  Layout.Viewport.FontSize := Style.FontSize;
  Positioner.Lists.X := LengthList(Element, 'x', DirectionHorizontal, Layout.Viewport);
  Positioner.Lists.Y := LengthList(Element, 'y', DirectionVertical, Layout.Viewport);
  Positioner.Lists.DX := LengthList(Element, 'dx', DirectionHorizontal, Layout.Viewport);
  Positioner.Lists.DY := LengthList(Element, 'dy', DirectionVertical, Layout.Viewport);
  Positioner.Lists.Rotate := ParseNumberList(Element.Attribute('rotate'));
  if Layout.StackCount = Length(Layout.Stack) then
    SetLength(Layout.Stack, 2 * Layout.StackCount + 4);
  Layout.Stack[Layout.StackCount] := Positioner;
  Inc(Layout.StackCount);
  Child := Element.FirstChild;
  while Child <> nil do
  begin
    if Child.Kind = SvgTextNode then
      AddText(Layout, Child.Text, Owner)
    else if Child.ElementKind in [SvgTspan, SvgAnchor, SvgTextPath] then
    begin
      ChildStyle := StyleFunction(Child, Style);
      if ChildStyle <> nil then
      begin
        if ChildStyle.IsDisplayNone then
          ChildStyle.Release
        else
        begin
          CollectElement(Layout, Child, ChildStyle, StyleFunction, Depth + 1);
          { The element's characters were added under a new owner; text
            after it is this element's again. }
          Owner := AddOwner(Layout, Element, Style.AddRef);
        end;
      end;
    end;
    Child := Child.NextSibling;
  end;
  Dec(Layout.StackCount);
end;

function SpacingOf(Style: TCssComputedStyle; Id: TCssPropertyId): Double;
var
  Value: PCssComputedValue;
begin
  Value := Style.Value(Id);
  if Value^.Kind in [cvLength, cvLengthPercentage, cvCalc] then
    Result := ResolveComputed(Value^, Style.FontSize)
  else
    Result := 0;
end;

procedure PlaceCharacters(var Layout: TTextLayout; FontSource: TSvgFontSource);
var
  Index: Integer;
  PenX, PenY: Double;
  Chunk: Integer;
  Character: ^TCharacter;
  Style: TCssComputedStyle;
  Scale: Double;
  Previous: Integer;
begin
  PenX := 0;
  PenY := 0;
  Chunk := 0;
  Previous := -1;
  for Index := 0 to Layout.Count - 1 do
  begin
    Character := @Layout.Characters[Index];
    Style := Layout.Owners[Character^.Owner].Style;
    if (Index > 0) and (Character^.HasX or Character^.HasY) then
    begin
      Inc(Chunk);
      Previous := -1;
    end;
    if Character^.HasX then
      PenX := Character^.X;
    if Character^.HasY then
      PenY := Character^.Y;
    PenX := PenX + Character^.DX;
    PenY := PenY + Character^.DY;
    Character^.Chunk := Chunk;
    if not FontSource.GlyphFor(Style, Character^.CodePoint, Character^.Font, Character^.Glyph) then
    begin
      { No glyph: a space keeps its room as far as a font gives one. }
      Character^.Font := nil;
      if (Character^.CodePoint = 32) and FontSource.GlyphFor(Style, Ord('n'), Character^.Font, Character^.Glyph) then
        Character^.Advance := Style.FontSize * 0.3
      else
        Character^.Advance := 0;
      Character^.Font := nil;
    end
    else
    begin
      Scale := Style.FontSize / Character^.Font.UnitsPerEm;
      if (Previous >= 0) and (Layout.Characters[Previous].Font = Character^.Font) and Character^.Font.HasKerning then
        PenX := PenX + Character^.Font.KerningUnits(Layout.Characters[Previous].Glyph, Character^.Glyph) * Scale;
      Character^.Advance := Character^.Font.AdvanceUnits(Character^.Glyph) * Scale;
      Previous := Index;
    end;
    Character^.PenX := PenX;
    Character^.PenY := PenY;
    PenX := PenX + Character^.Advance + SpacingOf(Style, cpLetterSpacing);
    if Character^.CodePoint = 32 then
      PenX := PenX + SpacingOf(Style, cpWordSpacing);
  end;
end;

procedure AnchorChunks(var Layout: TTextLayout);
var
  First, Last, Index: Integer;
  Width, Shift: Double;
  Anchor: TCssKeyword;
begin
  First := 0;
  while First < Layout.Count do
  begin
    Last := First;
    while (Last + 1 < Layout.Count) and (Layout.Characters[Last + 1].Chunk = Layout.Characters[First].Chunk) do
      Inc(Last);
    Anchor := TextAnchorOf(Layout.Owners[Layout.Characters[First].Owner].Style);
    if Anchor in [kwMiddle, kwEnd] then
    begin
      Width := Layout.Characters[Last].PenX + Layout.Characters[Last].Advance - Layout.Characters[First].PenX;
      if Anchor = kwMiddle then
        Shift := -Width / 2
      else
        Shift := -Width;
      for Index := First to Last do
        Layout.Characters[Index].PenX := Layout.Characters[Index].PenX + Shift;
    end;
    First := Last + 1;
  end;
end;

{ A glyph's contours (TrueType's quadratic curves, CFF's cubic ones),
  transformed, added to Path. }
procedure AddGlyphOutline(var Path: TPath; constref Outline: TGlyphOutline; const Transform: TAffineTransform);
var
  Contour: Integer;
  First, Last, Count: Integer;
  Index, Step: Integer;
  Point, NextPoint: TOutlinePoint;
  StartX, StartY: Double;
  P: TPrecisePoint;
  Control: TPrecisePoint;
  SecondControl: TPrecisePoint;
  StartIndex: Integer;
  Skip: Integer;

  function Mapped(X, Y: Double): TPrecisePoint;
  begin
    Result := TransformPoint(Transform, X, Y);
  end;

begin
  First := 0;
  for Contour := 0 to Outline.ContourCount - 1 do
  begin
    Last := Outline.ContourEnds[Contour];
    Count := Last - First + 1;
    if Count < 2 then
    begin
      First := Last + 1;
      Continue;
    end;
    { Start on an on-curve point, or between two off-curve ones. }
    StartIndex := -1;
    for Index := First to Last do
      if Outline.Points[Index].OnCurve then
      begin
        StartIndex := Index;
        Break;
      end;
    if StartIndex >= 0 then
    begin
      StartX := Outline.Points[StartIndex].X;
      StartY := Outline.Points[StartIndex].Y;
    end
    else
    begin
      StartIndex := First;
      StartX := (Outline.Points[First].X + Outline.Points[Last].X) / 2;
      StartY := (Outline.Points[First].Y + Outline.Points[Last].Y) / 2;
      { Begin as if after the last point. }
      StartIndex := Last;
    end;
    P := Mapped(StartX, StartY);
    PathMoveTo(Path, P.X, P.Y);
    Skip := 0;
    for Step := 1 to Count do
    begin
      Index := First + (StartIndex - First + Step) mod Count;
      Point := Outline.Points[Index];
      if Skip > 0 then
      begin
        Dec(Skip);
        Continue;
      end;
      if Point.Cubic then
      begin
        { Two control points of a cubic curve (CFF), then its end. }
        NextPoint := Outline.Points[First + (Index - First + 1) mod Count];
        Control := Mapped(Point.X, Point.Y);
        SecondControl := Mapped(NextPoint.X, NextPoint.Y);
        NextPoint := Outline.Points[First + (Index - First + 2) mod Count];
        P := Mapped(NextPoint.X, NextPoint.Y);
        PathCubicTo(Path, Control.X, Control.Y, SecondControl.X, SecondControl.Y, P.X, P.Y);
        Skip := 2;
      end
      else if Point.OnCurve then
      begin
        P := Mapped(Point.X, Point.Y);
        PathLineTo(Path, P.X, P.Y);
      end
      else
      begin
        NextPoint := Outline.Points[First + (Index - First + 1) mod Count];
        Control := Mapped(Point.X, Point.Y);
        if NextPoint.OnCurve then
          P := Mapped(NextPoint.X, NextPoint.Y)
        else
          P := Mapped((Point.X + NextPoint.X) / 2, (Point.Y + NextPoint.Y) / 2);
        PathQuadraticTo(Path, Control.X, Control.Y, P.X, P.Y);
        { An on-curve point after a control point was reached already. }
      end;
    end;
    PathClose(Path);
    First := Last + 1;
  end;
end;

function WantsSlant(Style: TCssComputedStyle): Boolean;
begin
  Result := KeywordIn(Style.Keyword(cpFontStyle), [kwItalic, kwOblique]);
end;

function LayoutText(TextNode: TSvgNode; TextStyle: TCssComputedStyle; StyleFunction: TSvgStyleFunction;
  FontSource: TSvgFontSource; const Viewport: TSvgViewport): TSvgTextRuns;
var
  Layout: TTextLayout;
  Index, RunIndex: Integer;
  Character: ^TCharacter;
  Outline: TGlyphOutline;
  Scale: Double;
  Transform: TAffineTransform;
  Style: TCssComputedStyle;
  LastOwner: Integer;
  OwnerIndex: Integer;
begin
  Result := nil;
  Layout := Default(TTextLayout);
  Layout.LastWasSpace := True;
  Layout.Viewport := Viewport;
  CollectElement(Layout, TextNode, TextStyle.AddRef, StyleFunction, 0);
  { A trailing space goes. }
  if (Layout.Count > 0) and (Layout.Characters[Layout.Count - 1].CodePoint = 32) then
    Dec(Layout.Count);
  PlaceCharacters(Layout, FontSource);
  AnchorChunks(Layout);
  LastOwner := -1;
  RunIndex := -1;
  for Index := 0 to Layout.Count - 1 do
  begin
    Character := @Layout.Characters[Index];
    if Character^.Owner <> LastOwner then
    begin
      LastOwner := Character^.Owner;
      SetLength(Result, Length(Result) + 1);
      RunIndex := High(Result);
      Result[RunIndex].Node := Layout.Owners[LastOwner].Node;
      Result[RunIndex].Style := Layout.Owners[LastOwner].Style.AddRef;
      BeginPath(Result[RunIndex].Path);
    end;
    if (Character^.Font = nil) or (Character^.CodePoint = 32) then
      Continue;
    if not Character^.Font.LoadOutline(Character^.Glyph, Outline) then
      Continue;
    Style := Layout.Owners[Character^.Owner].Style;
    Scale := Style.FontSize / Character^.Font.UnitsPerEm;
    { Font units (y up) to user space at the pen, turned by rotate. }
    Transform := ScalingTransform(Scale, -Scale);
    if WantsSlant(Style) then
      Transform := CombineTransforms(SkewXTransform(-12), Transform);
    if Character^.Rotate <> 0 then
      Transform := CombineTransforms(RotationTransform(Character^.Rotate), Transform);
    Transform := CombineTransforms(TranslationTransform(Character^.PenX, Character^.PenY), Transform);
    AddGlyphOutline(Result[RunIndex].Path, Outline, Transform);
  end;
  for OwnerIndex := 0 to Layout.OwnerCount - 1 do
    Layout.Owners[OwnerIndex].Style.Release;
end;

procedure FreeTextRuns(var Runs: TSvgTextRuns);
var
  Index: Integer;
begin
  for Index := 0 to High(Runs) do
    Runs[Index].Style.Release;
  Runs := nil;
end;

end.
