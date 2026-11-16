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
  the console's font, monospaced) and "dejavu-sans" (DejaVu Sans
  rendered into coverage fonts, ".cvf", every pixel size from 9 to 40,
  regular and bold; proportional, the interface's).

  LoadFontFamily reads only the start of every font file in a family's
  directory, enough for its size and weight, and gives the set a loader
  that reads a face's glyphs the first time it is picked.
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

{ Reads the font at Path (PSF or coverage, by its name), glyphs and all. }
function LoadFontFace(const Path: string; out Face: TFontFace): Boolean;
{ Every font in /lib/fonts/<Family>; False if there are none. }
function LoadFontFamily(const Family: string; out FontSet: TFontSet): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Font.Psf,
  Font.Coverage;

const
  MaximumFontFileSize = 4 * 1024 * 1024;
  { Enough for the header of either kind of font. }
  SummaryBytes = 64;
  PsfExtension = '.psf';
  CoverageExtension = '.cvf';

type
  TFontKind = (NotAFont, PsfFont, CoverageFont);

function KindOfFont(const Name: string): TFontKind;
begin
  if ExtractFileExt(Name) = PsfExtension then
    Result := PsfFont
  else if ExtractFileExt(Name) = CoverageExtension then
    Result := CoverageFont
  else
    Result := NotAFont;
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
  end;
end;

{ The set's loader: the glyphs of a face known by its file. }
function LoadFaceFromSource(var Face: TFontFace): Boolean;
var
  Loaded: TFontFace;
  Source: string;
begin
  Source := Face.Source;
  Result := LoadFontFace(Source, Loaded) and (Loaded.Size = Face.Size) and (Loaded.Bold = Face.Bold);
  if not Result then
    Exit;
  Face := Loaded;
  Face.Source := Source;
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
