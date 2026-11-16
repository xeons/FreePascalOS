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
  Reading a font file's tables: big-endian numbers at offsets within a
  table, every read checked against the table's end first.

  A TFontTable is a part of the file (where it starts, how long it is).
  Has says whether Count bytes from Offset lie inside it, in 64-bit
  arithmetic so no offset from a broken file can wrap around; the
  readers assume that was checked and read only within the file.
}
unit Font.FontData;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TFontTable = record
    { The whole file's bytes. }
    Data: TBytes;
    Start: QWord;
    Length: QWord;
    Present: Boolean;
  end;

{ A table that is not there (Has is always False). }
function MissingTable: TFontTable;
{ Count bytes from Start of Data, if they lie inside it (else missing). }
function FontTableAt(const Data: TBytes; Start, Count: QWord): TFontTable;
{ The part of Table from Offset to its end (missing if Offset is past it). }
function TablePart(const Table: TFontTable; Offset: QWord): TFontTable;
{ Whether Count bytes from Offset lie inside the table. }
function Has(const Table: TFontTable; Offset, Count: QWord): Boolean;
function ReadByte(const Table: TFontTable; Offset: QWord): LongWord;
function ReadUnsigned16(const Table: TFontTable; Offset: QWord): LongWord;
function ReadSigned16(const Table: TFontTable; Offset: QWord): LongInt;
function ReadUnsigned32(const Table: TFontTable; Offset: QWord): LongWord;
{ A 2.14 fixed-point number (composite glyphs' scales). }
function ReadFixed2Dot14(const Table: TFontTable; Offset: QWord): Double;
{ A four-character tag as a string ("glyf"). }
function ReadTag(const Table: TFontTable; Offset: QWord): string;

implementation

function MissingTable: TFontTable;
begin
  Result.Data := nil;
  Result.Start := 0;
  Result.Length := 0;
  Result.Present := False;
end;

function FontTableAt(const Data: TBytes; Start, Count: QWord): TFontTable;
var
  Size: QWord;
begin
  Size := System.Length(Data);
  if (Start > Size) or (Count > Size - Start) then
    Exit(MissingTable);
  Result.Data := Data;
  Result.Start := Start;
  Result.Length := Count;
  Result.Present := True;
end;

function TablePart(const Table: TFontTable; Offset: QWord): TFontTable;
begin
  if not Table.Present or (Offset > Table.Length) then
    Exit(MissingTable);
  Result := Table;
  Result.Start := Table.Start + Offset;
  Result.Length := Table.Length - Offset;
end;

function Has(const Table: TFontTable; Offset, Count: QWord): Boolean;
begin
  Result := Table.Present and (Offset <= Table.Length) and (Count <= Table.Length - Offset);
end;

function ReadByte(const Table: TFontTable; Offset: QWord): LongWord;
begin
  Result := Table.Data[Table.Start + Offset];
end;

function ReadUnsigned16(const Table: TFontTable; Offset: QWord): LongWord;
var
  Position: QWord;
begin
  Position := Table.Start + Offset;
  Result := (LongWord(Table.Data[Position]) shl 8) or Table.Data[Position + 1];
end;

function ReadSigned16(const Table: TFontTable; Offset: QWord): LongInt;
begin
  Result := SmallInt(Word(ReadUnsigned16(Table, Offset)));
end;

function ReadUnsigned32(const Table: TFontTable; Offset: QWord): LongWord;
begin
  Result := (ReadUnsigned16(Table, Offset) shl 16) or ReadUnsigned16(Table, Offset + 2);
end;

function ReadFixed2Dot14(const Table: TFontTable; Offset: QWord): Double;
begin
  Result := ReadSigned16(Table, Offset) / 16384;
end;

function ReadTag(const Table: TFontTable; Offset: QWord): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to 3 do
    Result := Result + Chr(ReadByte(Table, Offset + QWord(Index)));
end;

end.
