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
  Host test of the ACPI table soundness checks (make acpi-table-test:
  Firmware.AcpiTableChecks): a table whose length does not cover its
  header (0, 35) or is absurd is refused even when its bytes add up,
  a good one passes, a bad checksum fails, and a root table's entry
  count never underflows (an RSDT of length 0 used to count about 2^30
  entries, cut to 128 garbage addresses).

  Prints every failed check and exits with 1 if there was one.
}
program AcpiTableTest;

{$mode objfpc}
{$pointermath on}

uses
  SysUtils,
  Firmware.AcpiTableChecks;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('ACPI TABLE TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: Int64; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected));
end;

{ A table of Length bytes whose checksum byte (9) makes it add up. }
procedure MakeTable(var Table: array of Byte; Length: LongWord);
var
  Index: LongWord;
  Sum: Byte;
begin
  FillChar(Table[0], System.Length(Table), 0);
  Table[0] := Ord('T');
  Table[1] := Ord('E');
  Table[2] := Ord('S');
  Table[3] := Ord('T');
  PLongWord(@Table[4])^ := Length;
  Sum := 0;
  for Index := 0 to High(Table) do
    if Index <> 9 then
      Sum := Byte(Sum + Table[Index]);
  Table[9] := Byte(0 - Sum);
end;

procedure TestTables;
var
  Table: array[0..63] of Byte;
begin
  MakeTable(Table, 64);
  Check(AcpiTableIsSound(@Table[0], 64), 'a good table is sound');
  Table[40] := 1;
  Check(not AcpiTableIsSound(@Table[0], 64), 'a bad checksum is refused');
  FillChar(Table, SizeOf(Table), 0);
  Check(not AcpiTableIsSound(@Table[0], 0), 'a table of length 0 is refused (its zero bytes add up)');
  Check(not AcpiTableIsSound(@Table[0], 35), 'a table shorter than its header is refused');
  Check(AcpiTableIsSound(@Table[0], 36), 'a table of just its header (all zeros) adds up');
  Check(not AcpiTableIsSound(@Table[0], $FFFFFFFF), 'an absurd length is refused');
  Check(not AcpiTableIsSound(nil, 64), 'no table is refused');
end;

procedure TestRootEntries;
begin
  CheckNumber(AcpiRootEntryCount(0, 4, 128), 0, 'entries of an RSDT of length 0');
  CheckNumber(AcpiRootEntryCount(20, 8, 128), 0, 'entries of an XSDT shorter than its header');
  CheckNumber(AcpiRootEntryCount(36 + 5 * 8, 8, 128), 5, 'entries of an XSDT with five');
  CheckNumber(AcpiRootEntryCount(36 + 7, 8, 128), 0, 'a partial entry is not one');
  CheckNumber(AcpiRootEntryCount(36 + 1000 * 4, 4, 128), 128, 'entries past the most kept');
  CheckNumber(AcpiRootEntryCount($FFFFFFFF, 4, 128), 0, 'entries of a table of absurd length');
end;

begin
  TestTables;
  TestRootEntries;
  if Failures > 0 then
  begin
    WriteLn('ACPI TABLE TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('ACPI TABLE TEST PASSED');
end.
