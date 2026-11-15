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

interface

uses
  Font.Faces,
  Font.Text;

const
  FontDirectory: PChar = '/lib/fonts';
  TerminusFamily: PChar = 'terminus';
  DejaVuSansFamily: PChar = 'dejavu-sans';

{ Reads the font at Path (PSF or coverage, by its name), glyphs and all. }
function LoadFontFace(Path: PChar; out Face: TFontFace): Boolean;
{ Every font in /lib/fonts/<Family>; False if there are none. }
function LoadFontFamily(Family: PChar; out FontSet: TFontSet): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Text,
  Font.Psf,
  Font.Coverage;

const
  MaximumFontFileSize = 4 * 1024 * 1024;
  { Enough for the header of either kind of font. }
  SummaryBytes = 64;

type
  TFontKind = (NotAFont, PsfFont, CoverageFont);

function KindOfFont(Name: PChar): TFontKind;
begin
  if TextEndsWith(Name, '.psf') then
    Result := PsfFont
  else if TextEndsWith(Name, '.cvf') then
    Result := CoverageFont
  else
    Result := NotAFont;
end;

{ A PSF font's weight is in its name: "...b.psf" is bold. }
function PsfNameIsBold(Name: PChar): Boolean;
var
  Length: PtrInt;
begin
  Length := TextLength(Name);
  Result := (Length >= 5) and (Name[Length - 5] = 'b');
end;

{ The file at Path, whole; nil if it cannot be read or is too large. }
function ReadWholeFile(Path: PChar; out Size: QWord): PByte;
var
  Handle: Int64;
  Information: TFileInformation;
  Got: Int64;
begin
  Result := nil;
  Size := 0;
  if (GetFileInformation(Path, Information) <> ErrorNone) or (Information.SizeInBytes = 0) or
     (Information.SizeInBytes > MaximumFontFileSize) then
    Exit;
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit;
  Result := AllocateMemory(Information.SizeInBytes);
  if Result <> nil then
    while Size < Information.SizeInBytes do
    begin
      Got := ReadFile(Handle, Result + Size, Information.SizeInBytes - Size);
      if Got <= 0 then
        Break;
      Size := Size + QWord(Got);
    end;
  CloseFile(Handle);
  if (Result <> nil) and (Size <> Information.SizeInBytes) then
  begin
    FreeMemory(Result);
    Result := nil;
  end;
end;

function LoadFontFace(Path: PChar; out Face: TFontFace): Boolean;
var
  Data: PByte;
  Size: QWord;
begin
  Result := False;
  ClearFace(Face);
  Data := ReadWholeFile(Path, Size);
  if Data = nil then
    Exit;
  case KindOfFont(Path) of
    PsfFont:
      begin
        Result := ParsePsfFont(Data, Size, Face);
        Face.Bold := PsfNameIsBold(Path);
      end;
    CoverageFont:
      Result := ParseCoverageFont(Data, Size, Face);
  end;
  FreeMemory(Data);
end;

{ The set's loader: the glyphs of a face known by its file. }
function LoadFaceFromSource(var Face: TFontFace): Boolean;
var
  Loaded: TFontFace;
  Source: array[0..MaximumSourceLength] of Char;
begin
  Source := Face.Source;
  Result := LoadFontFace(@Source[0], Loaded) and (Loaded.Size = Face.Size) and (Loaded.Bold = Face.Bold);
  if not Result then
    Exit;
  Face := Loaded;
  Face.Source := Source;
end;

{ A face known by its file: its size and weight from the file's start. }
function ReadFaceSummary(Path, Name: PChar; out Face: TFontFace): Boolean;
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
  if TextLength(Path) > MaximumSourceLength then
    Exit;
  Handle := OpenFile(Path, OpenRead);
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
  Move(Path^, Face.Source[0], TextLength(Path));
end;

function LoadFontFamily(Family: PChar; out FontSet: TFontSet): Boolean;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Directory: PChar;
  Path: PChar;
  Face: TFontFace;
  Builder: TTextBuilder;
begin
  ClearFontSet(FontSet);
  FontSet.Loader := @LoadFaceFromSource;
  BeginText(Builder);
  AppendText(Builder, FontDirectory);
  AppendText(Builder, '/');
  AppendText(Builder, Family);
  Directory := FinishText(Builder);
  Handle := OpenFile(Directory, OpenRead);
  if Handle >= 0 then
  begin
    while ReadDirectoryEntry(Handle, Entry) do
    begin
      if KindOfFont(@Entry.Name[0]) = NotAFont then
        Continue;
      BeginText(Builder);
      AppendText(Builder, Directory);
      AppendText(Builder, '/');
      AppendText(Builder, @Entry.Name[0]);
      Path := FinishText(Builder);
      if ReadFaceSummary(Path, @Entry.Name[0], Face) then
        AddFace(FontSet, Face);
      FreeMemory(Path);
    end;
    CloseFile(Handle);
  end;
  FreeMemory(Directory);
  Result := FontSet.Count > 0;
end;

end.
