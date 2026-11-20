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

  The library lists the TrueType faces under a font directory
  (/lib/fonts on the system; the host tools point it at userland/fonts):
  each subdirectory is a family, named by the directory with dashes as
  spaces ("dejavu-sans" is "DejaVu Sans"), each .ttf file a face whose
  weight and slant come from its name (Bold, Oblique, Italic) and its
  header. A face's file is read when it is first used.

  Matching follows CSS Fonts 4 in brief: the font-family list is tried
  in order, a generic family maps to an installed family (sans-serif,
  serif, system-ui, cursive and fantasy to DejaVu Sans, monospace to
  DejaVu Sans Mono), and the first family found gives the face nearest
  the wanted weight and slant; with none, the default family does. A
  character the face lacks is drawn with the first face of the library
  (of the same weight if there is one) that has it.
}
unit Web.Text.Fonts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Font.Outlines;

type
  TFontFaceEntry = class
  private
    FFamily: string;
    FPath: string;
    FWeight: Integer;
    FItalic: Boolean;
    FFont: TOutlineFont;
    FLoadFailed: Boolean;
    { Glyph ids for code points below 256, 0 when missing (filled on load). }
    FLatinGlyphs: array[0..255] of LongWord;
    function GetFont: TOutlineFont;
  public
    constructor Create(const Family, Path: string; Weight: Integer; Italic: Boolean);
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
  end;

  TFontFaceArray = array of TFontFaceEntry;

  TFontLibrary = class
  private
    FFaces: TFontFaceArray;
    FDefaultFamily: string;
    FMonospaceFamily: string;
    function FamilyExists(const Family: string): Boolean;
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
    { The first face (nearest Weight) that has CodePoint, nil if none. }
    function FallbackFace(CodePoint: LongWord; Weight: Integer; Italic: Boolean): TFontFaceEntry;
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
  Classes, Font.TrueType;

const
  MaximumFontFileBytes = 32 * 1024 * 1024;

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

constructor TFontFaceEntry.Create(const Family, Path: string; Weight: Integer; Italic: Boolean);
begin
  inherited Create;
  FFamily := Family;
  FPath := Path;
  FWeight := Weight;
  FItalic := Italic;
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
    FFont := LoadTrueTypeFont(Data);
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
          if (Extension = '.ttf') or (Extension = '.otf') then
            AddFace(TFontFaceEntry.Create(FamilyFromDirectory(Families.Name), FamilyPath + Files.Name,
              WeightFromFileName(Files.Name), ItalicFromFileName(Files.Name)));
        until FindNext(Files) <> 0;
      finally
        FindClose(Files);
      end;
    until FindNext(Families) <> 0;
  finally
    FindClose(Families);
  end;
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
  Result := '';
  Wanted := LowerCase(Trim(Name));
  if Generic then
  begin
    if (Wanted = 'monospace') or (Wanted = 'ui-monospace') then
      Wanted := FMonospaceFamily
    else
      Wanted := FDefaultFamily;
  end
  else if (Wanted = '-apple-system') or (Wanted = 'blinkmacsystemfont') or (Wanted = 'system-ui') then
    Wanted := FDefaultFamily
  else if (Wanted = 'courier') or (Wanted = 'courier new') or (Wanted = 'consolas') or (Wanted = 'menlo') then
    Wanted := FMonospaceFamily
  else if (Wanted = 'helvetica') or (Wanted = 'arial') or (Wanted = 'verdana') or (Wanted = 'bitstream vera sans') then
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

function TFontLibrary.FindFace(const Family: string; Weight: Integer; Italic: Boolean): TFontFaceEntry;
var
  Index, Distance, BestDistance: Integer;
begin
  Result := nil;
  BestDistance := MaxInt;
  for Index := 0 to High(FFaces) do
    if (FFaces[Index].Family = Family) and FFaces[Index].Load then
    begin
      Distance := WeightDistance(FFaces[Index], Weight, Italic);
      if Distance < BestDistance then
      begin
        BestDistance := Distance;
        Result := FFaces[Index];
      end;
    end;
end;

function TFontLibrary.FallbackFace(CodePoint: LongWord; Weight: Integer; Italic: Boolean): TFontFaceEntry;
var
  Index, Distance, BestDistance: Integer;
begin
  Result := nil;
  BestDistance := MaxInt;
  for Index := 0 to High(FFaces) do
    if FFaces[Index].HasGlyph(CodePoint) then
    begin
      Distance := WeightDistance(FFaces[Index], Weight, Italic);
      if Distance < BestDistance then
      begin
        BestDistance := Distance;
        Result := FFaces[Index];
      end;
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

finalization
  FreeAndNil(SharedLibrary);
end.
