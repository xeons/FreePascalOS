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
  A font as layout uses it: a face at a size, with its metrics in CSS
  pixels, and text placed glyph by glyph.

  Layout measures in CSS pixels from the faces' unhinted advances and
  kerning (font units scaled exactly), so the same text has the same
  width at every device scale; painting renders the glyphs at the
  device pixel size and puts them at the positions measured. A
  character the face lacks takes a fallback face (Web.Text.Fonts),
  remembered per font. A synthetic bold is drawn when bold is wanted
  and the family has no bold face.

  Variation selectors and joiners (U+200B to U+200F, U+FE00 to U+FE0F,
  U+E0100 to U+E01EF) take no room and draw nothing; a selector picks
  the glyph the face's variation sequences give its character (cmap
  format 14), and U+FE0F (emoji presentation) draws the character
  from the configuration's emoji family when it has it. Emoji joined
  by U+200D draw one after another (no ligatures).

  TextFontOf(Style) gives the font of a computed style: one per font
  struct (fonts are shared by every style with the same font values),
  kept until ClearTextFonts.
}
unit Web.Text.FontInstances;

{$mode objfpc}
{$H+}

interface

uses
  Web.Text.Fonts, Css.ComputedStyle;

type
  TPlacedGlyph = record
    Face: TFontFaceEntry;
    Glyph: LongWord;
    CodePoint: LongWord;
    { The pen's position from the start of the run, CSS px. }
    X: Single;
  end;
  TPlacedGlyphArray = array of TPlacedGlyph;

  TFallbackEntry = record
    CodePoint: LongWord;
    Face: TFontFaceEntry;
  end;

  TTextFont = class
  private
    FPrimary: TFontFaceEntry;
    FSize: Double;
    FWeight: Integer;
    FItalic: Boolean;
    FSyntheticBold: Boolean;
    FSyntheticItalic: Boolean;
    FAscent, FDescent, FLineGap: Double;
    FUnitScale: Double;
    FLatinAdvances: array[0..255] of Single;
    FLatinKnown: Boolean;
    FFallbacks: array of TFallbackEntry;
    FMonospace: Boolean;
    procedure FillLatinAdvances;
    procedure BindFace(Primary: TFontFaceEntry);
  public
    constructor Create(Primary: TFontFaceEntry; Size: Double; Weight: Integer; Italic: Boolean);
    { The face that draws CodePoint (the primary one or a fallback). }
    function FaceFor(CodePoint: LongWord): TFontFaceEntry;
    { The width of Count bytes of Text from byte Start (1 based). }
    function MeasureText(const Text: string; Start, Count: Integer): Double;
    { The glyphs of that text with their pen positions; returns the width. }
    function PlaceGlyphs(const Text: string; Start, Count: Integer; var Glyphs: TPlacedGlyphArray;
      out GlyphCount: Integer): Double;
    { The advance of one character. }
    function AdvanceOf(CodePoint: LongWord): Double;
    { Takes another primary face (the library gained a better match):
      metrics and cached advances start again. }
    procedure Rebind(Primary: TFontFaceEntry);
    property Primary: TFontFaceEntry read FPrimary;
    { CSS px. }
    property Size: Double read FSize;
    property Weight: Integer read FWeight;
    property Italic: Boolean read FItalic;
    property SyntheticBold: Boolean read FSyntheticBold;
    { Italic or oblique wanted but the face is upright: drawn slanted. }
    property SyntheticItalic: Boolean read FSyntheticItalic;
    property Ascent: Double read FAscent;
    property Descent: Double read FDescent;
    property LineGap: Double read FLineGap;
    property Monospace: Boolean read FMonospace;
  end;

{ The font of a computed style. }
function TextFontOf(Style: TCssComputedStyle): TTextFont;
{ The font for a family list's text (tests and tools). }
function MakeTextFont(const Families: array of string; Size: Double; Weight: Integer; Italic: Boolean): TTextFont;
procedure ClearTextFonts;
{ The font library gained faces (web fonts): every font made from a
  style picks its face again, in place (no font object goes, so display
  lists and layouts keep valid pointers), and the measurements are
  forgotten. Layouts must lay out again (Web.Layout.Resources'
  NotifyFontsChanged). True if any font took another face. }
function RefreshTextFonts: Boolean;
{ How many measurements the cache answered, and how many it computed. }
function MeasureCacheHits: Int64;
function MeasureCacheMisses: Int64;

implementation

uses
  SysUtils, Font.Outlines, Font.Utf8, Css.Values, Css.Keywords, Css.PropertyIds, Css.ComputedValues,
  Css.StyleStructs;

const
  MeasureCacheSize = 16384;

type
  TFontCacheEntry = record
    Struct: PCssStyleStruct;
    Font: TTextFont;
    { What the face was chosen from (Families referenced). }
    Families: TCssValue;
    Weight: Integer;
    Italic: Boolean;
  end;

  TMeasureEntry = record
    Font: TTextFont;
    Text: string;
    Width: Single;
  end;

var
  FontCache: array of TFontCacheEntry;
  MeasureEntries: array of TMeasureEntry;
  MeasureCount: Integer = 0;
  Hits: Int64 = 0;
  Misses: Int64 = 0;
  OwnedFonts: array of TTextFont;

constructor TTextFont.Create(Primary: TFontFaceEntry; Size: Double; Weight: Integer; Italic: Boolean);
begin
  inherited Create;
  FSize := Size;
  FWeight := Weight;
  FItalic := Italic;
  BindFace(Primary);
end;

procedure TTextFont.Rebind(Primary: TFontFaceEntry);
begin
  FLatinKnown := False;
  FFallbacks := nil;
  FLineGap := 0;
  FMonospace := False;
  BindFace(Primary);
end;

procedure TTextFont.BindFace(Primary: TFontFaceEntry);
var
  Outline: TOutlineFont;
begin
  FPrimary := Primary;
  FSyntheticBold := (Weight >= 600) and (Primary <> nil) and (Primary.Weight < 600);
  FSyntheticItalic := Italic and (Primary <> nil) and not Primary.Italic;
  if (Primary = nil) or (Primary.Font = nil) then
  begin
    FAscent := Size * 0.8;
    FDescent := Size * 0.2;
    FUnitScale := 0;
    Exit;
  end;
  Outline := Primary.Font;
  FUnitScale := Size / Outline.UnitsPerEm;
  FAscent := Outline.Ascender * FUnitScale;
  FDescent := Outline.Descender * FUnitScale;
  FLineGap := Outline.LineGap * FUnitScale;
  FMonospace := Pos('mono', Primary.Family) > 0;
end;

function TTextFont.FaceFor(CodePoint: LongWord): TFontFaceEntry;
var
  Index: Integer;
  Library_: TFontLibrary;
begin
  if (FPrimary = nil) or FPrimary.HasGlyph(CodePoint) or (CodePoint < 32) then
    Exit(FPrimary);
  for Index := 0 to High(FFallbacks) do
    if FFallbacks[Index].CodePoint = CodePoint then
      Exit(FFallbacks[Index].Face);
  Library_ := WebFontLibrary;
  Result := Library_.FallbackFace(CodePoint, FWeight, FItalic);
  if Result = nil then
    Result := FPrimary;
  if Length(FFallbacks) < 256 then
  begin
    SetLength(FFallbacks, Length(FFallbacks) + 1);
    FFallbacks[High(FFallbacks)].CodePoint := CodePoint;
    FFallbacks[High(FFallbacks)].Face := Result;
  end;
end;

function FaceAdvance(Face: TFontFaceEntry; Glyph: LongWord; Size: Double): Double;
var
  Outline: TOutlineFont;
begin
  Outline := Face.Font;
  if Outline = nil then
    Exit(Size * 0.5);
  Result := Outline.AdvanceUnits(Glyph) * Size / Outline.UnitsPerEm;
end;

procedure TTextFont.FillLatinAdvances;
var
  CodePoint: Integer;
  Face: TFontFaceEntry;
begin
  for CodePoint := 0 to 255 do
  begin
    if CodePoint < 32 then
    begin
      FLatinAdvances[CodePoint] := 0;
      Continue;
    end;
    Face := FaceFor(CodePoint);
    if Face = nil then
      FLatinAdvances[CodePoint] := FSize * 0.5
    else
      FLatinAdvances[CodePoint] := FaceAdvance(Face, Face.GlyphOf(CodePoint), FSize);
  end;
  FLatinKnown := True;
end;

function IsInvisible(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= $200B) and (CodePoint <= $200F)) or ((CodePoint >= $FE00) and (CodePoint <= $FE0F)) or
    ((CodePoint >= $E0100) and (CodePoint <= $E01EF)) or (CodePoint = $FEFF) or (CodePoint = $2060);
end;

function IsVariationSelector(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= $FE00) and (CodePoint <= $FE0F)) or ((CodePoint >= $E0100) and (CodePoint <= $E01EF));
end;

function TTextFont.AdvanceOf(CodePoint: LongWord): Double;
var
  Face: TFontFaceEntry;
begin
  if CodePoint < 256 then
  begin
    if not FLatinKnown then
      FillLatinAdvances;
    Exit(FLatinAdvances[CodePoint]);
  end;
  if IsInvisible(CodePoint) and ((FPrimary = nil) or not FPrimary.HasGlyph(CodePoint)) then
    Exit(0);
  Face := FaceFor(CodePoint);
  if Face = nil then
    Exit(FSize * 0.5);
  Result := FaceAdvance(Face, Face.GlyphOf(CodePoint), FSize);
end;

function TTextFont.PlaceGlyphs(const Text: string; Start, Count: Integer; var Glyphs: TPlacedGlyphArray;
  out GlyphCount: Integer): Double;
var
  Cursor, Stop, Ahead: PChar;
  CodePoint, Selector: LongWord;
  Emoji: TFontFaceEntry;
  Face, PreviousFace: TFontFaceEntry;
  Glyph, PreviousGlyph: LongWord;
  Outline: TOutlineFont;
  Pen: Double;
begin
  GlyphCount := 0;
  Pen := 0;
  Result := 0;
  if (Count <= 0) or (Start < 1) or (Start > Length(Text)) then
    Exit;
  Cursor := @Text[Start];
  Stop := Cursor + Count;
  PreviousFace := nil;
  PreviousGlyph := 0;
  while (Cursor < Stop) and NextCharacter(Cursor, CodePoint) do
  begin
    if CodePoint < 32 then
    begin
      PreviousFace := nil;
      Continue;
    end;
    { A selector after the character changes its glyph or face. }
    Selector := 0;
    Ahead := Cursor;
    if (Ahead < Stop) and NextCharacter(Ahead, Selector) and not IsVariationSelector(Selector) then
      Selector := 0;
    if IsInvisible(CodePoint) and ((FPrimary = nil) or not FPrimary.HasGlyph(CodePoint)) then
      Continue;
    Face := nil;
    if Selector = $FE0F then
    begin
      Emoji := WebFontLibrary.EmojiFace(CodePoint);
      if Emoji <> nil then
        Face := Emoji;
    end;
    if Face = nil then
      Face := FaceFor(CodePoint);
    if Face = nil then
    begin
      Pen := Pen + FSize * 0.5;
      Continue;
    end;
    Glyph := Face.GlyphOf(CodePoint);
    if (Selector <> 0) and (Face.Font <> nil) then
      Glyph := Face.Font.GlyphOfVariation(CodePoint, Selector);
    Outline := Face.Font;
    if (PreviousFace = Face) and (Outline <> nil) and Outline.HasKerning then
      Pen := Pen + Outline.KerningUnits(PreviousGlyph, Glyph) * FSize / Outline.UnitsPerEm;
    if GlyphCount >= Length(Glyphs) then
      SetLength(Glyphs, GlyphCount * 2 + 16);
    Glyphs[GlyphCount].Face := Face;
    Glyphs[GlyphCount].Glyph := Glyph;
    Glyphs[GlyphCount].CodePoint := CodePoint;
    Glyphs[GlyphCount].X := Pen;
    Inc(GlyphCount);
    if (CodePoint < 256) and (Face = FaceFor(CodePoint)) then
    begin
      if not FLatinKnown then
        FillLatinAdvances;
      Pen := Pen + FLatinAdvances[CodePoint];
    end
    else
      Pen := Pen + FaceAdvance(Face, Glyph, FSize);
    PreviousFace := Face;
    PreviousGlyph := Glyph;
  end;
  Result := Pen;
end;

function HashMeasure(Font: TTextFont; Text: PChar; Count: Integer): LongWord;
var
  Index: Integer;
  Hash: QWord;
begin
  Hash := (2166136261 xor (PtrUInt(Font) shr 4)) and $FFFFFFFF;
  for Index := 0 to Count - 1 do
    Hash := ((Hash xor Ord(Text[Index])) * 16777619) and $FFFFFFFF;
  Result := LongWord(Hash);
end;

function TTextFont.MeasureText(const Text: string; Start, Count: Integer): Double;
var
  Slot, Mask: LongWord;
  Unused: TPlacedGlyphArray;
  GlyphCount: Integer;
  Key: string;
begin
  if Count <= 0 then
    Exit(0);
  if (Count = 1) and (Ord(Text[Start]) < 128) then
    Exit(AdvanceOf(Ord(Text[Start])));
  if Length(MeasureEntries) = 0 then
    SetLength(MeasureEntries, MeasureCacheSize * 2);
  Mask := LongWord(Length(MeasureEntries) - 1);
  Slot := HashMeasure(Self, @Text[Start], Count) and Mask;
  while MeasureEntries[Slot].Font <> nil do
  begin
    if (MeasureEntries[Slot].Font = Self) and (Length(MeasureEntries[Slot].Text) = Count) and
       (CompareByte(MeasureEntries[Slot].Text[1], Text[Start], Count) = 0) then
    begin
      Inc(Hits);
      Exit(MeasureEntries[Slot].Width);
    end;
    Slot := (Slot + 1) and Mask;
  end;
  Inc(Misses);
  Unused := nil;
  Result := PlaceGlyphs(Text, Start, Count, Unused, GlyphCount);
  if MeasureCount >= MeasureCacheSize then
  begin
    { Full: start again (cheaper than evicting one by one). }
    MeasureEntries := nil;
    SetLength(MeasureEntries, MeasureCacheSize * 2);
    MeasureCount := 0;
    Slot := HashMeasure(Self, @Text[Start], Count) and Mask;
  end;
  Key := Copy(Text, Start, Count);
  MeasureEntries[Slot].Font := Self;
  MeasureEntries[Slot].Text := Key;
  MeasureEntries[Slot].Width := Result;
  Inc(MeasureCount);
end;

function MeasureCacheHits: Int64;
begin
  Result := Hits;
end;

function MeasureCacheMisses: Int64;
begin
  Result := Misses;
end;

function FamilyName(Item: TCssValue; out Generic: Boolean): string;
var
  Index: Integer;
begin
  Generic := False;
  Result := '';
  case Item.Kind of
    vkString, vkCustomIdent:
      Result := Item.Text;
    vkKeyword:
      begin
        Generic := True;
        Result := KeywordName(Item.Keyword);
      end;
    vkList:
      for Index := 0 to Item.Count - 1 do
      begin
        if Result <> '' then
          Result := Result + ' ';
        if Item.Items[Index].Kind = vkKeyword then
          Result := Result + KeywordName(Item.Items[Index].Keyword)
        else
          Result := Result + Item.Items[Index].Text;
      end;
  end;
end;

function ChooseFace(Families: TCssValue; Weight: Integer; Italic: Boolean): TFontFaceEntry;
var
  Library_: TFontLibrary;
  Index: Integer;
  Name, Family: string;
  Generic: Boolean;
begin
  Library_ := WebFontLibrary;
  if Families <> nil then
  begin
    if Families.Kind = vkList then
    begin
      for Index := 0 to Families.Count - 1 do
      begin
        Name := FamilyName(Families.Items[Index], Generic);
        Family := Library_.ResolveFamily(Name, Generic);
        if Family <> '' then
        begin
          Result := Library_.FindFace(Family, Weight, Italic);
          if Result <> nil then
            Exit;
        end;
      end;
    end
    else
    begin
      Name := FamilyName(Families, Generic);
      Family := Library_.ResolveFamily(Name, Generic);
      if Family <> '' then
      begin
        Result := Library_.FindFace(Family, Weight, Italic);
        if Result <> nil then
          Exit;
      end;
    end;
  end;
  Result := Library_.FindFace(Library_.DefaultFamily, Weight, Italic);
  if (Result = nil) and (Library_.Count > 0) then
    Result := Library_.FindFace(Library_.Face(0).Family, Weight, Italic);
end;

procedure KeepFont(Font: TTextFont);
begin
  SetLength(OwnedFonts, Length(OwnedFonts) + 1);
  OwnedFonts[High(OwnedFonts)] := Font;
end;

function TextFontOf(Style: TCssComputedStyle): TTextFont;
var
  Struct: PCssStyleStruct;
  Index: Integer;
  Families: TCssValue;
  FamilyValue: PCssComputedValue;
  Weight: Integer;
  Italic: Boolean;
begin
  Struct := Style.Structs[pgFont];
  for Index := 0 to High(FontCache) do
    if FontCache[Index].Struct = Struct then
      Exit(FontCache[Index].Font);
  FamilyValue := Style.Value(cpFontFamily);
  Families := nil;
  if FamilyValue^.Kind = cvValue then
    Families := FamilyValue^.Data;
  Weight := Round(Style.Value(cpFontWeight)^.Number);
  if Weight <= 0 then
    Weight := 400;
  Italic := KeywordIn(Style.Keyword(cpFontStyle), [kwItalic, kwOblique]);
  Result := TTextFont.Create(ChooseFace(Families, Weight, Italic), Style.FontSize, Weight, Italic);
  AddRefStruct(Struct);
  SetLength(FontCache, Length(FontCache) + 1);
  FontCache[High(FontCache)].Struct := Struct;
  FontCache[High(FontCache)].Font := Result;
  if Families <> nil then
    Families.AddRef;
  FontCache[High(FontCache)].Families := Families;
  FontCache[High(FontCache)].Weight := Weight;
  FontCache[High(FontCache)].Italic := Italic;
end;

function RefreshTextFonts: Boolean;
var
  Index: Integer;
  Face: TFontFaceEntry;
begin
  Result := False;
  for Index := 0 to High(FontCache) do
  begin
    Face := ChooseFace(FontCache[Index].Families, FontCache[Index].Weight, FontCache[Index].Italic);
    if Face <> FontCache[Index].Font.Primary then
    begin
      FontCache[Index].Font.Rebind(Face);
      Result := True;
    end;
  end;
  if Result then
  begin
    MeasureEntries := nil;
    MeasureCount := 0;
  end;
end;

function MakeTextFont(const Families: array of string; Size: Double; Weight: Integer; Italic: Boolean): TTextFont;
var
  List: TCssValue;
  Index: Integer;
  Item: TCssValue;
begin
  List := NewList(lsComma);
  for Index := 0 to High(Families) do
  begin
    if (Families[Index] = 'sans-serif') or (Families[Index] = 'serif') or (Families[Index] = 'monospace') then
    begin
      Item := NewKeyword(kwSansSerif);
      if Families[Index] = 'monospace' then
        Item.Keyword := kwMonospace
      else if Families[Index] = 'serif' then
        Item.Keyword := kwSerif;
    end
    else
      Item := NewString(Families[Index]);
    List.Add(Item);
  end;
  Result := TTextFont.Create(ChooseFace(List, Weight, Italic), Size, Weight, Italic);
  List.Release;
  KeepFont(Result);
end;

procedure ClearTextFonts;
var
  Index: Integer;
begin
  for Index := 0 to High(FontCache) do
  begin
    ReleaseStruct(FontCache[Index].Struct);
    FontCache[Index].Font.Free;
    ReleaseValue(FontCache[Index].Families);
  end;
  FontCache := nil;
  for Index := 0 to High(OwnedFonts) do
    OwnedFonts[Index].Free;
  OwnedFonts := nil;
  MeasureEntries := nil;
  MeasureCount := 0;
end;

finalization
  ClearTextFonts;
end.
