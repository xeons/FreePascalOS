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
  Reading TrueType fonts, checked: the fixtures' structure (simple,
  curved and composite glyphs, both loca formats, both character map
  formats), character map lookups, advances and kerning (the kern table
  against FreeType, GPOS against HarfBuzz) for the fixtures and DejaVu,
  and broken fonts: every truncation and every broken table refused,
  broken glyphs refused without harm.
}
unit FontTest.Parsing;

{$mode objfpc}
{$H+}

interface

uses
  FontTest.References,
  Font.TrueType;

type
  TNamedFont = record
    Name: string;
    Font: TTrueTypeFont;
  end;
  TNamedFonts = array of TNamedFont;

{ Every font the references name ("font" records), opened. }
function OpenReferenceFonts(const Directory: string; const References: TReferences): TNamedFonts;
function FontNamed(const Fonts: TNamedFonts; const Name: string): TTrueTypeFont;
procedure TestParsing(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);

implementation

uses
  SysUtils,
  Font.Outlines,
  FontTest.Checks;

function OpenReferenceFonts(const Directory: string; const References: TReferences): TNamedFonts;
var
  Index: Integer;
  Path: string;
begin
  Result := nil;
  for Index := 0 to High(References) do
    if References[Index].Kind = 'font' then
    begin
      Path := References[Index].Fields[0];
      if (Path <> '') and (Path[1] <> '/') then
        Path := IncludeTrailingPathDelimiter(Directory) + Path;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Name := References[Index].Name;
      Result[High(Result)].Font := LoadFontFile(Path);
      Check('opens ' + References[Index].Name, Result[High(Result)].Font <> nil);
    end;
end;

function FontNamed(const Fonts: TNamedFonts; const Name: string): TTrueTypeFont;
var
  Index: Integer;
begin
  for Index := 0 to High(Fonts) do
    if Fonts[Index].Name = Name then
      Exit(Fonts[Index].Font);
  Result := nil;
end;

{ --- The fixtures' structure -------------------------------------------- }

function OutlineOf(Font: TTrueTypeFont; Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
begin
  Result := (Font <> nil) and Font.LoadOutline(Glyph, Outline);
end;

function PointIs(const Outline: TGlyphOutline; Index: Integer; X, Y: Double; OnCurve: Boolean): Boolean;
begin
  Result := (Index < Outline.PointCount) and (Abs(Outline.Points[Index].X - X) < 0.01) and
    (Abs(Outline.Points[Index].Y - Y) < 0.01) and (Outline.Points[Index].OnCurve = OnCurve);
end;

procedure TestFixtureStructure(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Outline: TGlyphOutline;
  Composite: TGlyphOutline;
  Nested: TGlyphOutline;
  Same: Boolean;
  Index: Integer;
begin
  Font := FontNamed(Fonts, 'fixture');
  if Font = nil then
    Exit;
  Check('fixture: metrics', (Font.UnitsPerEm = 1000) and (Font.Ascender = 800) and (Font.Descender = 200) and
    (Font.LineGap = 0) and (Font.GlyphCount = 8) and not Font.Bold and (Font.UnderlineThickness = 60) and
    (Font.UnderlinePosition = 120 - 30) and (Font.MaximumAdvance = 900));
  Check('fixture: a simple glyph of straight lines', OutlineOf(Font, 1, Outline) and (Outline.PointCount = 6) and
    (Outline.ContourCount = 1) and PointIs(Outline, 1, 250, 700, True) and PointIs(Outline, 4, 250, 400, True));
  Check('fixture: two contours (a hole)', OutlineOf(Font, 0, Outline) and (Outline.ContourCount = 2) and
    (Outline.ContourEnds[0] = 3) and (Outline.ContourEnds[1] = 7));
  Check('fixture: curves keep their off-curve points', OutlineOf(Font, 2, Outline) and (Outline.PointCount = 8) and
    PointIs(Outline, 0, 250, 0, False) and PointIs(Outline, 1, 500, 0, False) and PointIs(Outline, 2, 500, 350, True));
  Check('fixture: an empty glyph has no points', OutlineOf(Font, 5, Outline) and (Outline.PointCount = 0));
  { C: A as it is, then B halved and moved by (520, 100). }
  Check('fixture: a composite glyph', OutlineOf(Font, 3, Composite) and (Composite.PointCount = 14) and
    (Composite.ContourCount = 2) and (Composite.ContourEnds[0] = 5) and (Composite.ContourEnds[1] = 13) and
    PointIs(Composite, 1, 250, 700, True) and PointIs(Composite, 6, 520 + 125, 100, False) and
    PointIs(Composite, 8, 520 + 250, 100 + 175, True));
  { D: A through the matrix (0.75 0.25 / -0.25 0.75), moved by (30, -40):
    x' = 0.75 x - 0.25 y + 30, y' = 0.25 x + 0.75 y - 40. }
  Check('fixture: a composite glyph with a 2x2 transform', OutlineOf(Font, 4, Outline) and
    (Outline.PointCount = 6) and PointIs(Outline, 1, 0.75 * 250 - 0.25 * 700 + 30, 0.25 * 250 + 0.75 * 700 - 40, True));
  { E: the composite C moved by (300, 200). }
  Same := OutlineOf(Font, 6, Nested) and (Nested.PointCount = Composite.PointCount) and
    (Nested.ContourCount = Composite.ContourCount);
  if Same then
    for Index := 0 to Nested.PointCount - 1 do
      Same := Same and PointIs(Nested, Index, Composite.Points[Index].X + 300, Composite.Points[Index].Y + 200,
        Composite.Points[Index].OnCurve);
  Check('fixture: a composite of a composite', Same);
  Check('fixture: a glyph past the font is refused', not Font.LoadOutline(8, Outline) and (Outline.PointCount = 0));
  Check('fixture: advances past the last one share it', (Font.AdvanceUnits(5) = 250) and
    (Font.AdvanceUnits(7) = 250) and (Font.AdvanceUnits(8) = 0));
  Font := FontNamed(Fonts, 'fixture-format4');
  Check('fixture with long loca offsets: the same outlines', (Font <> nil) and OutlineOf(Font, 6, Outline) and
    (Outline.PointCount = 14) and PointIs(Outline, 1, 550, 900, True));
end;

{ --- Against FreeType and HarfBuzz --------------------------------------- }

const
  ReferenceKindNames: array[0..3] of string = ('character map lookups', 'advances', 'kern table pairs',
    'GPOS kerning');

function JoinFields(const Reference: TReference): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Reference.Fields) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + Reference.Fields[Index];
  end;
end;

procedure TestAgainstReferences(const References: TReferences; const Fonts: TNamedFonts);
var
  Index: Integer;
  Reference: TReference;
  Font: TTrueTypeFont;
  Counts: array[0..3] of Integer;
  Wrong: array[0..3] of Integer;
  FirstWrong: array[0..3] of string;
  Kind: Integer;
  Got: Int64;
  Expected: Int64;
  Passed: Boolean;
begin
  for Kind := 0 to 3 do
  begin
    Counts[Kind] := 0;
    Wrong[Kind] := 0;
    FirstWrong[Kind] := '';
  end;
  for Index := 0 to High(References) do
  begin
    Reference := References[Index];
    Font := FontNamed(Fonts, Reference.Name);
    if Font = nil then
      Continue;
    Kind := -1;
    Got := 0;
    Expected := 0;
    Passed := False;
    if Reference.Kind = 'cmap' then
    begin
      Kind := 0;
      Got := Font.GlyphOf(NumberField(Reference, 0));
      Expected := NumberField(Reference, 1);
      Passed := Got = Expected;
    end
    else if Reference.Kind = 'advance' then
    begin
      Kind := 1;
      Got := Font.AdvanceUnits(NumberField(Reference, 0));
      Expected := NumberField(Reference, 1);
      Passed := Got = Expected;
    end
    else if Reference.Kind = 'kern' then
    begin
      Kind := 2;
      Got := Font.KernTableUnits(NumberField(Reference, 0), NumberField(Reference, 1));
      Expected := NumberField(Reference, 2);
      Passed := Got = Expected;
    end
    else if Reference.Kind = 'gpos' then
    begin
      { HarfBuzz measured it at a size of one pixel a unit, so to a unit. }
      Kind := 3;
      Got := Font.KerningUnits(Font.GlyphOf(NumberField(Reference, 0)), Font.GlyphOf(NumberField(Reference, 1)));
      Expected := NumberField(Reference, 2);
      Passed := Abs(Got - Expected) <= 1;
    end;
    if Kind < 0 then
      Continue;
    Inc(Counts[Kind]);
    if not Passed then
    begin
      Inc(Wrong[Kind]);
      if FirstWrong[Kind] = '' then
        FirstWrong[Kind] := Format(' (first: %s %s: got %d, expected %d)',
          [Reference.Name, JoinFields(Reference), Got, Expected]);
    end;
  end;
  for Kind := 0 to 3 do
    Check(Format('%s as the references have them: %d, %d wrong%s', [ReferenceKindNames[Kind], Counts[Kind], Wrong[Kind],
      FirstWrong[Kind]]), (Counts[Kind] > 0) and (Wrong[Kind] = 0));
end;

procedure TestKerningChoice(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
begin
  Font := FontNamed(Fonts, 'fixture');
  Check('a font with only a kern table kerns from it', (Font <> nil) and Font.HasKerning and
    (Font.KerningUnits(1, 2) = -50) and (Font.KerningUnits(3, 4) = -120) and (Font.PositioningUnits(1, 2) = 0));
  Font := FontNamed(Fonts, 'fixture-gpos');
  Check('GPOS: format 1 pairs and format 2 classes through an extension lookup', (Font <> nil) and
    Font.HasKerning and (Font.KerningUnits(1, 2) = -70) and (Font.KerningUnits(2, 1) = 25) and
    (Font.KerningUnits(3, 1) = -40) and (Font.KerningUnits(4, 1) = -40) and (Font.KerningUnits(6, 1) = 0) and
    (Font.KerningUnits(1, 3) = 0));
  Font := FontNamed(Fonts, 'fixture-format4');
  Check('a font without kerning tables', (Font <> nil) and not Font.HasKerning and (Font.KerningUnits(1, 2) = 0));
  Font := FontNamed(Fonts, 'sans');
  Check('DejaVu Sans kerns from GPOS (which agrees with its kern table for AV)', (Font <> nil) and
    Font.HasKerning and (Font.KerningUnits(Font.GlyphOf(Ord('A')), Font.GlyphOf(Ord('V'))) =
    Font.KernTableUnits(Font.GlyphOf(Ord('A')), Font.GlyphOf(Ord('V')))));
end;

procedure TestCharacterMapFormats(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Format4: TTrueTypeFont;
begin
  Font := FontNamed(Fonts, 'fixture');
  Format4 := FontNamed(Fonts, 'fixture-format4');
  Check('format 12 reaches past the Basic Multilingual Plane', (Font <> nil) and (Font.GlyphOf($1F600) = 7) and
    (Length(Font.Mappings) = 8));
  Check('format 4: by delta and through the glyph array', (Format4 <> nil) and (Format4.GlyphOf($41) = 1) and
    (Format4.GlyphOf($42) = 2) and (Format4.GlyphOf($E9) = 3) and (Format4.GlyphOf($1F600) = 0) and
    (Length(Format4.Mappings) = 7));
end;

{ --- Broken fonts ------------------------------------------------------- }

procedure TestBrokenFonts(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);
var
  Index: Integer;
  Data: TBytes;
  Cut: TBytes;
  Length_: Integer;
  AllRefused: Boolean;
  Font: TTrueTypeFont;
  Outline: TGlyphOutline;
begin
  for Index := 0 to High(References) do
    if References[Index].Kind = 'refuse' then
    begin
      Font := LoadFontFile(IncludeTrailingPathDelimiter(Directory) + References[Index].Name);
      Check('refused: ' + References[Index].Name, Font = nil);
      Font.Free;
    end
    else if References[Index].Kind = 'badglyph' then
    begin
      Font := FontNamed(Fonts, References[Index].Name);
      Check('a broken glyph is refused, the font kept: ' + References[Index].Name, (Font <> nil) and
        not Font.LoadOutline(NumberField(References[Index], 0), Outline) and (Outline.PointCount = 0) and
        Font.LoadOutline(2, Outline) and (Outline.PointCount = 8));
    end;
  { The fixture ends where its last table does: every shorter file cuts
    a table, so every one is refused. }
  AllRefused := ReadFileBytes(IncludeTrailingPathDelimiter(Directory) + 'fixture.ttf', Data);
  for Length_ := 0 to System.Length(Data) - 1 do
  begin
    Cut := Copy(Data, 0, Length_);
    Font := LoadTrueTypeFont(Cut);
    if Font <> nil then
    begin
      AllRefused := False;
      Font.Free;
    end;
  end;
  Check(Format('every truncation of the fixture refused (%d)', [System.Length(Data)]), AllRefused);
  Font := LoadTrueTypeFont(Data);
  Check('the whole fixture opens', Font <> nil);
  Font.Free;
end;

procedure TestParsing(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);
begin
  TestFixtureStructure(Fonts);
  TestCharacterMapFormats(Fonts);
  TestAgainstReferences(References, Fonts);
  TestKerningChoice(Fonts);
  TestBrokenFonts(Directory, References, Fonts);
end;

end.
