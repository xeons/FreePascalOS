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
  Loading fonts from files.

  The system's fonts are families of files, one directory each in
  /lib/fonts, with their licences: "terminus" (PSF bitmap fonts in
  heights from 12 to 32 pixels, regular "...n.psf" and bold "...b.psf";
  the console's and the terminal's font, monospaced), "dejavu-sans"
  (DejaVu Sans, TrueType, regular and bold; proportional, the
  interface's) and "dejavu-sans-mono" (DejaVu Sans Mono, TrueType,
  regular and bold). A family may also hold coverage fonts (".cvf",
  Font.Coverage).

  LoadFontFamily reads only the start of every font file in a family's
  directory, enough for its size and weight (a TrueType font's table
  directory and its head and OS/2 tables), and gives the set a loader
  that reads a face's glyphs the first time it is picked. A TrueType
  font is one face of any size; its file is read whole, once, and kept
  for as long as the program runs.
}
unit Font.Files;

{$mode objfpc}
{$H+}

interface

uses
  Font.Faces,
  Font.Text;

const
  FontDirectory = '/lib/fonts';
  TerminusFamily = 'terminus';
  DejaVuSansFamily = 'dejavu-sans';
  DejaVuSansMonoFamily = 'dejavu-sans-mono';

{ Reads the font at Path (PSF, coverage or TrueType, by its name),
  glyphs and all (a TrueType font gives its face of any size). }
function LoadFontFace(const Path: string; out Face: TFontFace): Boolean;
{ Every font in /lib/fonts/<Family>; False if there are none. }
function LoadFontFamily(const Family: string; out FontSet: TFontSet): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Font.Psf,
  Font.Coverage,
  Font.FontData,
  Font.TrueType,
  Font.OutlineFaces;

const
  MaximumFontFileSize = 16 * 1024 * 1024;
  { Enough for the header of a bitmap or coverage font. }
  SummaryBytes = 64;
  PsfExtension = '.psf';
  CoverageExtension = '.cvf';
  TrueTypeExtension = '.ttf';
  OpenTypeExtension = '.otf';
  { A TrueType font's table directory, at most. }
  MaximumDirectoryTables = 256;
  MacStyleBold = $0001;
  BoldWeightClass = 600;

type
  TFontKind = (NotAFont, PsfFont, CoverageFont, TrueTypeFont);

function KindOfFont(const Name: string): TFontKind;
var
  Extension: string;
begin
  Extension := LowerCase(ExtractFileExt(Name));
  if Extension = PsfExtension then
    Result := PsfFont
  else if Extension = CoverageExtension then
    Result := CoverageFont
  else if (Extension = TrueTypeExtension) or (Extension = OpenTypeExtension) then
    Result := TrueTypeFont
  else
    Result := NotAFont;
end;

{ A TrueType font's whole file as its face of any size. }
function ParseTrueTypeFace(const Data: TBytes; out Face: TFontFace): Boolean;
var
  Font: TTrueTypeFont;
begin
  ClearFace(Face);
  Font := LoadTrueTypeFont(Data);
  Result := Font <> nil;
  if Result then
    DescribeOutlineFont(Font, Face);
end;

{ A PSF font's weight is in its name: "...b.psf" is bold. }
function PsfNameIsBold(const Name: string): Boolean;
var
  WeightPosition: LongInt;
begin
  WeightPosition := Length(Name) - Length(PsfExtension);
  Result := (WeightPosition >= 1) and (Name[WeightPosition] = 'b');
end;

{ The file at Path, whole; empty if it cannot be read or is too large. }
function ReadWholeFile(const Path: string): TBytes;
var
  Handle: Int64;
  Information: TFileInformation;
  Size: QWord;
  Got: Int64;
begin
  Result := nil;
  if (GetFileInformation(PChar(Path), Information) <> ErrorNone) or (Information.SizeInBytes = 0) or
     (Information.SizeInBytes > MaximumFontFileSize) then
    Exit;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit;
  SetLength(Result, Information.SizeInBytes);
  Size := 0;
  while Size < Information.SizeInBytes do
  begin
    Got := ReadFile(Handle, @Result[Size], Information.SizeInBytes - Size);
    if Got <= 0 then
      Break;
    Size := Size + QWord(Got);
  end;
  CloseFile(Handle);
  if Size <> Information.SizeInBytes then
    Result := nil;
end;

function LoadFontFace(const Path: string; out Face: TFontFace): Boolean;
var
  Data: TBytes;
begin
  Result := False;
  ClearFace(Face);
  Data := ReadWholeFile(Path);
  if Data = nil then
    Exit;
  case KindOfFont(Path) of
    PsfFont:
      begin
        Result := ParsePsfFont(@Data[0], Length(Data), Face);
        Face.Bold := PsfNameIsBold(Path);
      end;
    CoverageFont:
      Result := ParseCoverageFont(@Data[0], Length(Data), Face);
    TrueTypeFont:
      Result := ParseTrueTypeFace(Data, Face);
  end;
end;

{ The set's loader: the glyphs of a face known by its file. }
function LoadFaceFromSource(var Face: TFontFace): Boolean;
var
  Loaded: TFontFace;
  Source: string;
begin
  Source := Face.Source;
  Result := LoadFontFace(Source, Loaded) and (Loaded.Size = Face.Size) and (Loaded.Bold = Face.Bold) and
    (Loaded.AnySize = Face.AnySize);
  if not Result then
    Exit;
  Face := Loaded;
  Face.Source := Source;
end;

{ Count bytes of the open file at Offset; False if they are not all there. }
function ReadAt(Handle: Int64; Offset: QWord; Count: LongWord; out Bytes: TBytes): Boolean;
var
  Got: Int64;
begin
  Bytes := nil;
  SetLength(Bytes, Count);
  Result := (Count = 0) or ((SeekFile(Handle, Int64(Offset), SeekFromStart) = Int64(Offset)) and
    (ReadFile(Handle, @Bytes[0], Count) = Count));
end;

{ A TrueType font's weight, from its table directory, head and OS/2,
  read where they are without reading the rest of the file. }
function ReadTrueTypeWeight(const Path: string; out Bold: Boolean): Boolean;
var
  Handle: Int64;
  Header: TBytes;
  Directory: TBytes;
  Part: TBytes;
  Table: TFontTable;
  TableCount: LongWord;
  Index: LongWord;
  Tag: string;
  Offset: LongWord;
  Length_: LongWord;
begin
  Result := False;
  Bold := False;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit;
  try
    if not ReadAt(Handle, 0, 12, Header) or not LooksLikeTrueType(@Header[0], 12) then
      Exit;
    Table := FontTableAt(Header, 0, 12);
    TableCount := ReadUnsigned16(Table, 4);
    if (TableCount = 0) or (TableCount > MaximumDirectoryTables) or
       not ReadAt(Handle, 12, 16 * TableCount, Directory) then
      Exit;
    Table := FontTableAt(Directory, 0, Length(Directory));
    for Index := 0 to TableCount - 1 do
    begin
      Tag := ReadTag(Table, 16 * QWord(Index));
      Offset := ReadUnsigned32(Table, 16 * QWord(Index) + 8);
      Length_ := ReadUnsigned32(Table, 16 * QWord(Index) + 12);
      if (Tag = 'head') and (Length_ >= 46) and ReadAt(Handle, Offset, 46, Part) then
      begin
        if (ReadUnsigned16(FontTableAt(Part, 0, 46), 44) and MacStyleBold) <> 0 then
          Bold := True;
        Result := True;
      end
      else if (Tag = 'OS/2') and (Length_ >= 6) and ReadAt(Handle, Offset, 6, Part) then
      begin
        if ReadUnsigned16(FontTableAt(Part, 0, 6), 4) >= BoldWeightClass then
          Bold := True;
      end;
    end;
  finally
    CloseFile(Handle);
  end;
end;

{ A face known by its file: its size and weight from the file's start. }
function ReadFaceSummary(const Path, Name: string; out Face: TFontFace): Boolean;
var
  Handle: Int64;
  Header: array[0..SummaryBytes - 1] of Byte;
  Got: Int64;
  Size: LongInt;
  Bold: Boolean;
begin
  Result := False;
  ClearFace(Face);
  Size := 0;
  Bold := False;
  if KindOfFont(Name) = TrueTypeFont then
  begin
    Result := ReadTrueTypeWeight(Path, Bold);
    if Result then
    begin
      Face.Format := GlyphOutline;
      Face.AnySize := True;
      Face.Bold := Bold;
      Face.Source := Path;
    end;
    Exit;
  end;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit;
  Got := ReadFile(Handle, @Header[0], SizeOf(Header));
  CloseFile(Handle);
  if Got <= 0 then
    Exit;
  case KindOfFont(Name) of
    PsfFont:
      begin
        Result := ReadPsfSize(@Header[0], Got, Size);
        Bold := PsfNameIsBold(Name);
      end;
    CoverageFont:
      Result := ReadCoverageFontSummary(@Header[0], Got, Size, Bold);
  end;
  if not Result then
    Exit;
  Face.Size := Size;
  Face.Bold := Bold;
  Face.Source := Path;
end;

function LoadFontFamily(const Family: string; out FontSet: TFontSet): Boolean;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Directory: string;
  Name: string;
  Face: TFontFace;
begin
  ClearFontSet(FontSet);
  FontSet.Loader := @LoadFaceFromSource;
  Directory := FontDirectory + '/' + Family;
  Handle := OpenFile(PChar(Directory), OpenRead);
  if Handle >= 0 then
  begin
    while ReadDirectoryEntry(Handle, Entry) do
    begin
      Name := PChar(@Entry.Name[0]);
      if KindOfFont(Name) = NotAFont then
        Continue;
      if ReadFaceSummary(Directory + '/' + Name, Name, Face) then
        AddFace(FontSet, Face);
    end;
    CloseFile(Handle);
  end;
  Result := FontSet.Count > 0;
end;

end.
