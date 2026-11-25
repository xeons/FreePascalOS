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
  What makes an ACPI table usable before anything in it is read: a
  length that covers at least its 36-byte header (a table claiming less,
  or 0, would make the root table's entry count underflow into garbage
  addresses) and is not absurd, and a checksum over that length that
  adds up to 0. The root tables' entries are counted from such a
  length only.

  Plain Pascal (the host test tools/AcpiTableTest checks it).
}
unit Firmware.AcpiTableChecks;

{$mode objfpc}
{$pointermath on}

interface

const
  AcpiTableHeaderSize = 36;
  { No firmware table comes near this; a larger length is garbage. }
  MaximumAcpiTableLength = 32 * 1024 * 1024;

{ The Length bytes at Table: a sound length, and a checksum of 0. }
function AcpiTableIsSound(Table: PByte; Length: LongWord): Boolean;
{ The entries of EntrySize bytes in a root table (RSDT, XSDT) of
  Length bytes, at most Maximum; 0 if the length is not sound. }
function AcpiRootEntryCount(Length: LongWord; EntrySize: LongWord; Maximum: Integer): Integer;

implementation

function AcpiTableIsSound(Table: PByte; Length: LongWord): Boolean;
var
  Sum: Byte;
  Index: LongWord;
begin
  if (Table = nil) or (Length < AcpiTableHeaderSize) or (Length > MaximumAcpiTableLength) then
    Exit(False);
  Sum := 0;
  Index := 0;
  while Index < Length do
  begin
    Sum := Byte(Sum + Table[Index]);
    Inc(Index);
  end;
  Result := Sum = 0;
end;

function AcpiRootEntryCount(Length: LongWord; EntrySize: LongWord; Maximum: Integer): Integer;
var
  Count: QWord;
begin
  if (EntrySize = 0) or (Length < AcpiTableHeaderSize) or (Length > MaximumAcpiTableLength) then
    Exit(0);
  Count := (Length - AcpiTableHeaderSize) div EntrySize;
  if Count > QWord(Maximum) then
    Count := Maximum;
  Result := Integer(Count);
end;

end.
