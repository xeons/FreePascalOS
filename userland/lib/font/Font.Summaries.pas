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
  What a font file is, read from a few hundred bytes of it: how many
  faces it holds (a collection, .ttc, holds several), and a face's
  weight class and slant (from head's style bits and OS/2's weight
  class and selection bits), so a family can be listed and a face
  picked without reading whole files (a CJK collection is 20 MB).
}
unit Font.Summaries;

{$mode objfpc}
{$H+}

interface

type
  TFontSummary = record
    FaceCount: LongInt;
    { 100 to 900: 400 regular, 700 bold. }
    WeightClass: LongInt;
    Bold: Boolean;
    Italic: Boolean;
  end;

{ The summary of face FaceIndex of the font at Path; False if it is not
  a TrueType or OpenType font (or collection) with that face. }
function ReadFontSummary(const Path: string; FaceIndex: LongInt; out Summary: TFontSummary): Boolean;

implementation

uses
  SysUtils,
  Font.FontData,
  Font.TrueType;

const
  MaximumTables = 256;
  HeadBytes = 46;
  Os2Bytes = 64;
  MacStyleBold = $0001;
  MacStyleItalic = $0002;
  FsSelectionItalic = $0001;
  BoldWeightClass = 600;

{ Count bytes at Offset of the open file. }
function ReadPart(Handle: THandle; Offset: Int64; Count: LongInt; out Bytes: TBytes): Boolean;
begin
  Bytes := nil;
  SetLength(Bytes, Count);
  Result := (Count = 0) or ((FileSeek(Handle, Offset, fsFromBeginning) = Offset) and
    (FileRead(Handle, Bytes[0], Count) = Count));
end;

function ReadFontSummary(const Path: string; FaceIndex: LongInt; out Summary: TFontSummary): Boolean;
var
  Handle: THandle;
  Header: TBytes;
  Directory: TBytes;
  Part: TBytes;
  Table: TFontTable;
  Base: Int64;
  TableCount: LongWord;
  Index: LongWord;
  Tag: string;
  Offset: Int64;
  Length_: LongWord;
  Version: LongWord;
  FoundHead: Boolean;
  FoundOs2: Boolean;
  HeadBold: Boolean;
begin
  Result := False;
  Summary.FaceCount := 0;
  Summary.WeightClass := 400;
  Summary.Bold := False;
  Summary.Italic := False;
  Handle := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  try
    if not ReadPart(Handle, 0, 12, Header) or not LooksLikeTrueType(@Header[0], 12) then
      Exit;
    Table := FontTableAt(Header, 0, 12);
    Version := ReadUnsigned32(Table, 0);
    Base := 0;
    if IsCollectionVersion(Version) then
    begin
      Summary.FaceCount := ReadUnsigned32(Table, 8);
      if (FaceIndex < 0) or (FaceIndex >= Summary.FaceCount) or
         not ReadPart(Handle, 12 + 4 * Int64(FaceIndex), 4, Part) then
        Exit;
      Base := ReadUnsigned32(FontTableAt(Part, 0, 4), 0);
      if not ReadPart(Handle, Base, 12, Header) or not IsTrueTypeVersion(ReadUnsigned32(FontTableAt(Header, 0, 12), 0)) then
        Exit;
    end
    else
    begin
      Summary.FaceCount := 1;
      if FaceIndex <> 0 then
        Exit;
    end;
    TableCount := ReadUnsigned16(FontTableAt(Header, 0, 12), 4);
    if (TableCount = 0) or (TableCount > MaximumTables) or not ReadPart(Handle, Base + 12, 16 * TableCount, Directory) then
      Exit;
    Table := FontTableAt(Directory, 0, Length(Directory));
    FoundHead := False;
    FoundOs2 := False;
    HeadBold := False;
    for Index := 0 to TableCount - 1 do
    begin
      Tag := ReadTag(Table, 16 * QWord(Index));
      Offset := ReadUnsigned32(Table, 16 * QWord(Index) + 8);
      Length_ := ReadUnsigned32(Table, 16 * QWord(Index) + 12);
      if (Tag = 'head') and (Length_ >= HeadBytes) and ReadPart(Handle, Offset, HeadBytes, Part) then
      begin
        FoundHead := True;
        HeadBold := (ReadUnsigned16(FontTableAt(Part, 0, HeadBytes), 44) and MacStyleBold) <> 0;
        if (ReadUnsigned16(FontTableAt(Part, 0, HeadBytes), 44) and MacStyleItalic) <> 0 then
          Summary.Italic := True;
      end
      else if (Tag = 'OS/2') and (Length_ >= Os2Bytes) and ReadPart(Handle, Offset, Os2Bytes, Part) then
      begin
        FoundOs2 := True;
        Summary.WeightClass := ReadUnsigned16(FontTableAt(Part, 0, Os2Bytes), 4);
        if (Summary.WeightClass < 1) or (Summary.WeightClass > 1000) then
          Summary.WeightClass := 400;
        if (ReadUnsigned16(FontTableAt(Part, 0, Os2Bytes), 62) and FsSelectionItalic) <> 0 then
          Summary.Italic := True;
      end;
    end;
    if HeadBold and not FoundOs2 then
      Summary.WeightClass := 700;
    Summary.Bold := HeadBold or (Summary.WeightClass >= BoldWeightClass);
    Result := FoundHead;
  finally
    FileClose(Handle);
  end;
end;

end.
