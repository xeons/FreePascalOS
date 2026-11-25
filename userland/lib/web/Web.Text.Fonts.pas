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
  The installed fonts as the web engine sees them, and font matching.

  The library lists the faces under a font directory (/lib/fonts on
  the system; the host tools point it at userland/fonts): each
  subdirectory is a family, named by the directory with dashes as
  spaces ("liberation-sans" is "Liberation Sans"), each .ttf, .otf or
  .ttc file (a collection's first face) a face whose weight and slant
  come from its header (Font.Summaries: OS/2's weight class, the italic
  bits), read without reading the rest of the file. A face's file is
  read when it is first used.

  Matching follows CSS Fonts 4 in brief: the font-family list is tried
  in order; a name that is an installed family is that family, else the
  system's font configuration (/etc/fonts.conf, Font.Configuration)
  says which installed families stand for it: generic families
  (sans-serif and Arial and Helvetica to Liberation Sans, serif and
  Times New Roman to Liberation Serif, monospace and Courier New to
  Liberation Mono, system-ui to the interface's DejaVu Sans, emoji to
  Noto Color Emoji, ...) and common names. The first family found
  gives the face nearest the wanted weight and slant (chosen by the
  headers, then read); with none, the default family (sans-serif's)
  does. A character the face lacks is drawn from the families the
  configuration lists for its script and then the default fallback
  ones, each family read only when it is reached, so text mixing
  Latin, CJK and emoji draws every character.
}
unit Web.Text.Fonts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Font.Outlines, Font.Configuration;

type
  TFontFaceEntry = class
  private
    FFamily: string;
    FPath: string;
    FWeight: Integer;
    FItalic: Boolean;
    FFont: TOutlineFont;
    FLoadFailed: Boolean;
    FFaceIndex: Integer;
    { Glyph ids for code points below 256, 0 when missing (filled on load). }
    FLatinGlyphs: array[0..255] of LongWord;
    function GetFont: TOutlineFont;
  public
    constructor Create(const Family, Path: string; Weight: Integer; Italic: Boolean; FaceIndex: Integer = 0);
    constructor CreateFromFont(const Family: string; Font: TOutlineFont; Weight: Integer; Italic: Boolean);
    destructor Destroy; override;
    function Load: Boolean;
    { The glyph of a character, 0 when the face has none. }
    function GlyphOf(CodePoint: LongWord): LongWord;
    function HasGlyph(CodePoint: LongWord): Boolean;
    { Family name, lowercase. }
    property Family: string read FFamily;
    property Path: string read FPath;
    property Weight: Integer read FWeight;
    property Italic: Boolean read FItalic;
    { nil if the file cannot be read. }
    property Font: TOutlineFont read GetFont;
    { Whether the file has been read (and opened). }
    function IsLoaded: Boolean;
    { Whether its glyphs can be drawn (a colour bitmap font needs a
      decoder). Reads the file. }
    function CanDraw: Boolean;
    property FaceIndex: Integer read FFaceIndex;
  end;

  TFontFaceArray = array of TFontFaceEntry;

  TFontLibrary = class
  private
    FFaces: TFontFaceArray;
    FDefaultFamily: string;
    FMonospaceFamily: string;
    FFallbackCache: array of record
      CodePoint: LongWord;
      Weight: Integer;
      Italic: Boolean;
      Face: TFontFaceEntry;
    end;
    function FamilyExists(const Family: string): Boolean;
    function FirstInstalled(const Families: TFamilyList): string;
  public
    constructor Create;
    destructor Destroy; override;
    { Lists the families under Directory (one subdirectory each). }
    procedure AddDirectory(const Directory: string);
    procedure AddFace(Face: TFontFaceEntry);
    { The family a CSS family name or generic keyword stands for here
      ('' when none is installed). Name lowercase. }
    function ResolveFamily(const Name: string; Generic: Boolean): string;
    { The face of Family nearest Weight and Italic; nil if no such family. }
    function FindFace(const Family: string; Weight: Integer; Italic: Boolean): TFontFaceEntry;
    { The face that draws CodePoint when the chosen face lacks it: from
      the families the configuration lists for it (nearest Weight),
      nil if none has it. }
    function FallbackFace(CodePoint: LongWord; Weight: Integer; Italic: Boolean): TFontFaceEntry;
    { The face of the configuration's emoji family that has CodePoint
      (for emoji presentation), nil if none. }
    function EmojiFace(CodePoint: LongWord): TFontFaceEntry;
    function Count: Integer;
    function Face(Index: Integer): TFontFaceEntry;
    property DefaultFamily: string read FDefaultFamily write FDefaultFamily;
    property MonospaceFamily: string read FMonospaceFamily write FMonospaceFamily;
  end;

var
  { Where the system's fonts are. }
  WebFontDirectory: string = '/lib/fonts';

{ The process's font library (made from WebFontDirectory when first used). }
function WebFontLibrary: TFontLibrary;
{ Forgets the library (the next use lists WebFontDirectory again). }
procedure ResetWebFontLibrary;

implementation

uses
  Classes, Font.TrueType, Font.Summaries, Font.ColorBitmaps, Image.PictureColors;

const
  { A CJK collection is about 20 MB. }
  MaximumFontFileBytes = 48 * 1024 * 1024;
  FallbackCacheSize = 512;

var
  SharedLibrary: TFontLibrary = nil;

function WebFontLibrary: TFontLibrary;
begin
  if SharedLibrary = nil then
  begin
    SharedLibrary := TFontLibrary.Create;
    SharedLibrary.AddDirectory(WebFontDirectory);
  end;
  Result := SharedLibrary;
end;

procedure ResetWebFontLibrary;
begin
  FreeAndNil(SharedLibrary);
end;

function ReadWholeFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if (Stream.Size <= 0) or (Stream.Size > MaximumFontFileBytes) then
        Exit;
      SetLength(Result, Stream.Size);
      Stream.ReadBuffer(Result[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    Result := nil;
  end;
end;

constructor TFontFaceEntry.Create(const Family, Path: string; Weight: Integer; Italic: Boolean; FaceIndex: Integer);
begin
  inherited Create;
  FFamily := Family;
  FPath := Path;
  FWeight := Weight;
  FItalic := Italic;
  FFaceIndex := FaceIndex;
end;

function TFontFaceEntry.IsLoaded: Boolean;
begin
  Result := FFont <> nil;
end;

function TFontFaceEntry.CanDraw: Boolean;
begin
  Result := Load and FFont.CanDraw;
end;

constructor TFontFaceEntry.CreateFromFont(const Family: string; Font: TOutlineFont; Weight: Integer;
  Italic: Boolean);
var
  CodePoint: Integer;
begin
  Create(Family, '', Weight, Italic);
  FFont := Font;
  for CodePoint := 0 to 255 do
    FLatinGlyphs[CodePoint] := FFont.GlyphOf(CodePoint);
end;

destructor TFontFaceEntry.Destroy;
begin
  FFont.Free;
  inherited Destroy;
end;

function TFontFaceEntry.Load: Boolean;
var
  Data: TBytes;
  CodePoint: Integer;
begin
  if FFont <> nil then
    Exit(True);
  if FLoadFailed then
    Exit(False);
  Data := ReadWholeFile(FPath);
  if Data <> nil then
    FFont := LoadTrueTypeFont(Data, FFaceIndex);
  if FFont = nil then
  begin
    FLoadFailed := True;
    Exit(False);
  end;
  for CodePoint := 0 to 255 do
    FLatinGlyphs[CodePoint] := FFont.GlyphOf(CodePoint);
  Result := True;
end;

function TFontFaceEntry.GetFont: TOutlineFont;
begin
  Load;
  Result := FFont;
end;

function TFontFaceEntry.GlyphOf(CodePoint: LongWord): LongWord;
begin
  if not Load then
    Exit(0);
  if CodePoint < 256 then
    Result := FLatinGlyphs[CodePoint]
  else
    Result := FFont.GlyphOf(CodePoint);
end;

function TFontFaceEntry.HasGlyph(CodePoint: LongWord): Boolean;
begin
  Result := GlyphOf(CodePoint) <> 0;
end;

constructor TFontLibrary.Create;
begin
  inherited Create;
  FDefaultFamily := 'dejavu sans';
  FMonospaceFamily := 'dejavu sans mono';
end;

function TFontLibrary.FirstInstalled(const Families: TFamilyList): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Families) do
    if FamilyExists(LowerCase(Trim(Families[Index]))) then
      Exit(LowerCase(Trim(Families[Index])));
end;

destructor TFontLibrary.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FFaces) do
    FFaces[Index].Free;
  inherited Destroy;
end;

procedure TFontLibrary.AddFace(Face: TFontFaceEntry);
begin
  SetLength(FFaces, Length(FFaces) + 1);
  FFaces[High(FFaces)] := Face;
  { A new face (a web font) may answer what had no answer before. }
  FFallbackCache := nil;
end;

function FamilyFromDirectory(const Name: string): string;
begin
  Result := LowerCase(StringReplace(Name, '-', ' ', [rfReplaceAll]));
end;

function WeightFromFileName(const Name: string): Integer;
var
  Lowered: string;
begin
  Lowered := LowerCase(Name);
  if (Pos('extralight', Lowered) > 0) or (Pos('ultralight', Lowered) > 0) then
    Result := 200
  else if Pos('light', Lowered) > 0 then
    Result := 300
  else if Pos('semibold', Lowered) > 0 then
    Result := 600
  else if (Pos('extrabold', Lowered) > 0) or (Pos('black', Lowered) > 0) then
    Result := 800
  else if Pos('bold', Lowered) > 0 then
    Result := 700
  else
    Result := 400;
end;

function ItalicFromFileName(const Name: string): Boolean;
var
  Lowered: string;
begin
  Lowered := LowerCase(Name);
  Result := (Pos('italic', Lowered) > 0) or (Pos('oblique', Lowered) > 0);
end;

procedure TFontLibrary.AddDirectory(const Directory: string);
var
  Families, Files: TSearchRec;
  FamilyPath, Extension: string;
  Summary: TFontSummary;
  Weight: Integer;
  Italic: Boolean;
  Configured: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*', faDirectory, Families) <> 0 then
    Exit;
  try
    repeat
      if (Families.Name = '.') or (Families.Name = '..') or ((Families.Attr and faDirectory) = 0) then
        Continue;
      FamilyPath := IncludeTrailingPathDelimiter(Directory) + Families.Name + '/';
      if FindFirst(FamilyPath + '*', 0, Files) = 0 then
      try
        repeat
          Extension := LowerCase(ExtractFileExt(Files.Name));
          if (Extension <> '.ttf') and (Extension <> '.otf') and (Extension <> '.ttc') then
            Continue;
          if ReadFontSummary(FamilyPath + Files.Name, 0, Summary) then
          begin
            Weight := Summary.WeightClass;
            Italic := Summary.Italic or ItalicFromFileName(Files.Name);
          end
          else
          begin
            Weight := WeightFromFileName(Files.Name);
            Italic := ItalicFromFileName(Files.Name);
          end;
          AddFace(TFontFaceEntry.Create(FamilyFromDirectory(Families.Name), FamilyPath + Files.Name, Weight, Italic));
        until FindNext(Files) <> 0;
      finally
        FindClose(Files);
      end;
    until FindNext(Families) <> 0;
  finally
    FindClose(Families);
  end;
  { The defaults: what the configuration says sans-serif and monospace
    are, if installed. }
  Configured := FirstInstalled(SystemFontConfiguration.FamiliesFor('sans-serif'));
  if Configured <> '' then
    FDefaultFamily := Configured;
  Configured := FirstInstalled(SystemFontConfiguration.FamiliesFor('monospace'));
  if Configured <> '' then
    FMonospaceFamily := Configured;
end;

function TFontLibrary.FamilyExists(const Family: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FFaces) do
    if FFaces[Index].Family = Family then
      Exit(True);
  Result := False;
end;

function TFontLibrary.ResolveFamily(const Name: string; Generic: Boolean): string;
var
  Wanted: string;
begin
  Wanted := LowerCase(Trim(Name));
  { An installed family by its own name (not for generic keywords). }
  if not Generic and FamilyExists(Wanted) then
    Exit(Wanted);
  { What the configuration says stands for it. }
  Result := FirstInstalled(SystemFontConfiguration.FamiliesFor(Wanted));
  if (Result <> '') or not Generic then
    Exit;
  { A generic family the configuration does not name. }
  if (Wanted = 'monospace') or (Wanted = 'ui-monospace') then
    Wanted := FMonospaceFamily
  else
    Wanted := FDefaultFamily;
  if FamilyExists(Wanted) then
    Result := Wanted;
end;

function WeightDistance(Face: TFontFaceEntry; Weight: Integer; Italic: Boolean): Integer;
begin
  Result := Abs(Face.Weight - Weight);
  { Below 500 lighter faces are preferred, above it heavier ones. }
  if (Weight <= 500) and (Face.Weight > Weight) then
    Inc(Result, 50);
  if (Weight > 500) and (Face.Weight < Weight) then
    Inc(Result, 50);
  if Face.Italic <> Italic then
    Inc(Result, 1000);
end;

{ The faces are picked by their headers: the nearest is read, and if
  it cannot be, the next nearest. }
function TFontLibrary.FindFace(const Family: string; Weight: Integer; Italic: Boolean): TFontFaceEntry;
var
  Index, Distance, BestDistance: Integer;
  Tried: array of TFontFaceEntry;
  Candidate: TFontFaceEntry;
  Seen: Boolean;
  Other: Integer;
begin
  Result := nil;
  Tried := nil;
  repeat
    Candidate := nil;
    BestDistance := MaxInt;
    for Index := 0 to High(FFaces) do
      if (FFaces[Index].Family = Family) and not FFaces[Index].FLoadFailed then
      begin
        Seen := False;
        for Other := 0 to High(Tried) do
          if Tried[Other] = FFaces[Index] then
            Seen := True;
        if Seen then
          Continue;
        Distance := WeightDistance(FFaces[Index], Weight, Italic);
        if Distance < BestDistance then
        begin
          BestDistance := Distance;
          Candidate := FFaces[Index];
        end;
      end;
    if Candidate = nil then
      Exit;
    if Candidate.Load then
      Exit(Candidate);
    SetLength(Tried, Length(Tried) + 1);
    Tried[High(Tried)] := Candidate;
  until False;
end;

function TFontLibrary.FallbackFace(CodePoint: LongWord; Weight: Integer; Italic: Boolean): TFontFaceEntry;
var
  Families: TFamilyList;
  Index, Slot: Integer;
  Family: string;
  Candidate: TFontFaceEntry;
begin
  Result := nil;
  if Length(FFallbackCache) = 0 then
    SetLength(FFallbackCache, FallbackCacheSize);
  Slot := Integer((CodePoint * 7 + LongWord(Weight) + LongWord(Ord(Italic))) mod FallbackCacheSize);
  if (FFallbackCache[Slot].Face <> nil) and (FFallbackCache[Slot].CodePoint = CodePoint) and
     (FFallbackCache[Slot].Weight = Weight) and (FFallbackCache[Slot].Italic = Italic) then
    Exit(FFallbackCache[Slot].Face);
  Families := SystemFontConfiguration.FallbackFamilies(CodePoint);
  for Index := 0 to High(Families) do
  begin
    Family := LowerCase(Trim(Families[Index]));
    if not FamilyExists(Family) then
      Continue;
    Candidate := FindFace(Family, Weight, Italic);
    if (Candidate <> nil) and Candidate.HasGlyph(CodePoint) and Candidate.CanDraw then
    begin
      Result := Candidate;
      Break;
    end;
  end;
  { Web fonts and families the configuration does not name: only those
    already read are looked at (reading every file would read them
    all). }
  if Result = nil then
    for Index := 0 to High(FFaces) do
      if FFaces[Index].IsLoaded and FFaces[Index].HasGlyph(CodePoint) and FFaces[Index].CanDraw then
      begin
        Result := FFaces[Index];
        Break;
      end;
  if Result <> nil then
  begin
    FFallbackCache[Slot].CodePoint := CodePoint;
    FFallbackCache[Slot].Weight := Weight;
    FFallbackCache[Slot].Italic := Italic;
    FFallbackCache[Slot].Face := Result;
  end;
end;

function TFontLibrary.EmojiFace(CodePoint: LongWord): TFontFaceEntry;
var
  Families: TFamilyList;
  Index: Integer;
  Family: string;
begin
  Result := nil;
  Families := SystemFontConfiguration.FamiliesFor('emoji');
  for Index := 0 to High(Families) do
  begin
    Family := LowerCase(Trim(Families[Index]));
    if not FamilyExists(Family) then
      Continue;
    Result := FindFace(Family, 400, False);
    if (Result <> nil) and Result.HasGlyph(CodePoint) and Result.CanDraw then
      Exit;
    Result := nil;
  end;
end;

function TFontLibrary.Count: Integer;
begin
  Result := Length(FFaces);
end;

function TFontLibrary.Face(Index: Integer): TFontFaceEntry;
begin
  Result := FFaces[Index];
end;

initialization
  { Colour glyphs (emoji) are decoded with libimage. }
  if ColorBitmapDecoder = nil then
    ColorBitmapDecoder := @DecodePictureColors;
finalization
  FreeAndNil(SharedLibrary);
end.
