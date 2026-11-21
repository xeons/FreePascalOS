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
  The archive test's checks of the small pieces: SafeEntryPath, DOS
  times, CP437 names, tar numbers and pax records.
}
unit ArchiveTest.Basics;

{$mode objfpc}
{$H+}

interface

procedure TestSafeEntryPath;
procedure TestTimes;
procedure TestCp437;
procedure TestTarFields;

implementation

uses
  SysUtils,
  TestChecks,
  Archive.Entries,
  Archive.Times,
  Archive.Cp437,
  Archive.TarFormat;

procedure CheckSafe(const Name, Expected: string);
begin
  Check(SafeEntryPath(Name) = Expected, Format('SafeEntryPath("%s") = "%s" (got "%s")',
    [Name, Expected, SafeEntryPath(Name)]));
end;

procedure TestSafeEntryPath;
begin
  CheckSafe('a.txt', 'a.txt');
  CheckSafe('folder/', 'folder');
  CheckSafe('a/b/c.txt', 'a/b/c.txt');
  CheckSafe('./a//b/./c', 'a/b/c');
  CheckSafe('a\b\c.txt', 'a/b/c.txt');
  CheckSafe('', '');
  CheckSafe('/etc/passwd', '');
  CheckSafe('\windows\file', '');
  CheckSafe('C:/file', '');
  CheckSafe('c:file', '');
  CheckSafe('../up', '');
  CheckSafe('a/../../up', '');
  CheckSafe('a/..', '');
  CheckSafe('a\..\..\up', '');
  CheckSafe('.', '');
  CheckSafe('./', '');
  CheckSafe('bad'#10'name', '');
  CheckSafe('nul'#0'byte', '');
  CheckSafe('..a/b..', '..a/b..');
  CheckSafe('caf'#$C3#$A9'/x', 'caf'#$C3#$A9'/x');
end;

procedure TestTimes;
var
  DosDate, DosTime: Word;
begin
  Check(DaysFromCivil(1970, 1, 1) = 0, 'days of 1970-01-01');
  Check(DaysFromCivil(2000, 3, 1) = 11017, 'days of 2000-03-01');
  Check(DosDateTimeToUnix((44 shl 9) or (5 shl 5) or 17, (13 shl 11) or (45 shl 5) or 15) = 1715953530,
    'DOS 2024-05-17 13:45:30');
  UnixToDosDateTime(1715953530, DosDate, DosTime);
  Check((DosDate = ((44 shl 9) or (5 shl 5) or 17)) and (DosTime = ((13 shl 11) or (45 shl 5) or 15)),
    'Unix to DOS 2024-05-17 13:45:30');
  UnixToDosDateTime(1715953531, DosDate, DosTime);
  Check(DosDateTimeToUnix(DosDate, DosTime) = 1715953530, 'odd seconds go down to even');
  UnixToDosDateTime(0, DosDate, DosTime);
  Check(DosDateTimeToUnix(DosDate, DosTime) = 315532800, 'before 1980 is held to 1980');
  UnixToDosDateTime(951825600, DosDate, DosTime);
  Check(DosDateTimeToUnix(DosDate, DosTime) = 951825600, 'leap day 2000-02-29 12:00');
end;

procedure TestCp437;
begin
  Check(Cp437ToUtf8('plain') = 'plain', 'CP437 ASCII stays');
  Check(Cp437ToUtf8(#$82#$81) = #$C3#$A9#$C3#$BC, 'CP437 82 81 is U+00E9 U+00FC');
  Check(Cp437ToUtf8(#$C4) = #$E2#$94#$80, 'CP437 C4 is U+2500');
  Check(Cp437ToUtf8(#$FF) = #$C2#$A0, 'CP437 FF is U+00A0');
  Check(CodePointToUtf8($1F600) = #$F0#$9F#$98#$80, 'UTF-8 of U+1F600');
end;

procedure TestTarFields;
var
  Block: TTarBlock;
  Value: Int64;
  Records: TPaxRecords;
  Text: string;
begin
  FillChar(Block, SizeOf(Block), 0);
  Text := '0000644 ';
  Move(Text[1], Block[100], Length(Text));
  Check(TarNumber(Block, 100, 8, Value) and (Value = &644), 'tar octal number');
  FillChar(Block, SizeOf(Block), 0);
  Block[124] := $80;
  Block[134] := 1;
  Block[135] := 2;
  Check(TarNumber(Block, 124, 12, Value) and (Value = 258), 'tar base-256 number');
  Block[124] := Ord('9');
  Check(not TarNumber(Block, 124, 12, Value), 'tar number with a 9 refused');
  Check(TarPadding(0) = 0, 'no padding after 0 bytes');
  Check(TarPadding(1) = 511, 'padding after 1 byte');
  Check(TarPadding(512) = 0, 'no padding after a block');

  Records := Default(TPaxRecords);
  ParsePaxRecords('20 path=some/file.x' + #10 + '20 mtime=1234.75000' + #10 + '13 size=4096' + #10 +
    '22 linkpath=a b=c d.e' + #10, Records);
  Check(Records.HasPath and (Records.Path = 'some/file.x'), 'pax path');
  Check(Records.HasModificationTime and (Records.ModificationTime = 1234), 'pax fractional mtime');
  Check(Records.HasSize and (Records.Size = 4096), 'pax size');
  Check(Records.HasLinkPath and (Records.LinkPath = 'a b=c d.e'), 'pax linkpath with = and spaces');
  Records := Default(TPaxRecords);
  ParsePaxRecords('14 mtime=-1.5' + #10, Records);
  Check(Records.HasModificationTime and (Records.ModificationTime = -2), 'pax negative fractional mtime');
  Records := Default(TPaxRecords);
  ParsePaxRecords('99 path=short' + #10, Records);
  Check(not Records.HasPath, 'pax record longer than the data refused');
end;

end.
