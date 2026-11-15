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

  The system's fonts are PSF files in /lib/fonts/terminus (Terminus, in
  heights from 12 to 32 pixels, regular "...n.psf" and bold "...b.psf").
  LoadSystemFonts reads every one there into a font set.
}
unit Font.Files;

{$mode objfpc}

interface

uses
  Font.Psf,
  Font.Text;

const
  SystemFontDirectory: PChar = '/lib/fonts/terminus';

{ Reads the PSF font at Path. }
function LoadFontFace(Path: PChar; out Face: TFontFace): Boolean;
{ Every .psf in the system font directory; False if none loaded. }
function LoadSystemFonts(out FontSet: TFontSet): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Text;

const
  MaximumFontFileSize = 1024 * 1024;

function LoadFontFace(Path: PChar; out Face: TFontFace): Boolean;
var
  Handle: Int64;
  Information: TFileInformation;
  Data: array of Byte;
  Got: Int64;
  Total: QWord;
begin
  Result := False;
  Face.GlyphCount := 0;
  if (GetFileInformation(Path, Information) <> ErrorNone) or (Information.SizeInBytes = 0) or
     (Information.SizeInBytes > MaximumFontFileSize) then
    Exit;
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit;
  SetLength(Data, Information.SizeInBytes);
  Total := 0;
  while Total < Information.SizeInBytes do
  begin
    Got := ReadFile(Handle, @Data[Total], Information.SizeInBytes - Total);
    if Got <= 0 then
      Break;
    Total := Total + QWord(Got);
  end;
  CloseFile(Handle);
  if Total <> Information.SizeInBytes then
    Exit;
  Result := ParsePsfFont(@Data[0], Total, Face);
end;

{ "...b.psf": a bold face. }
function NameIsBold(Name: PChar): Boolean;
var
  Length: PtrInt;
begin
  Length := TextLength(Name);
  Result := (Length >= 5) and (Name[Length - 5] = 'b');
end;

function NameIsFont(Name: PChar): Boolean;
var
  Length: PtrInt;
begin
  Length := TextLength(Name);
  Result := (Length > 4) and TextIsEqual(Name + Length - 4, '.psf');
end;

function LoadSystemFonts(out FontSet: TFontSet): Boolean;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Path: PChar;
  Face: TFontFace;
  Builder: TTextBuilder;
begin
  FontSet.Count := 0;
  Handle := OpenFile(SystemFontDirectory, OpenRead);
  if Handle < 0 then
    Exit(False);
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    if not NameIsFont(@Entry.Name[0]) then
      Continue;
    BeginText(Builder);
    AppendText(Builder, SystemFontDirectory);
    AppendText(Builder, '/');
    AppendText(Builder, @Entry.Name[0]);
    Path := FinishText(Builder);
    if LoadFontFace(Path, Face) then
    begin
      Face.Bold := NameIsBold(@Entry.Name[0]);
      AddFace(FontSet, Face);
    end;
    FreeMemory(Path);
  end;
  CloseFile(Handle);
  Result := FontSet.Count > 0;
end;

end.
