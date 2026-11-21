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
  The mount table file, /etc/fstab: what is mounted where at start.

  One mount per line, fields separated by spaces or tabs, as on Unix:

    SOURCE  TARGET  TYPE  OPTIONS  [DUMP  PASS]

    tmpfs              /tmp       tmpfs  mode=1777,size=50%   0 0
    LABEL=FAT16TEST    /mnt/fat   vfat   uid=1000,umask=022,nofail

  SOURCE is a device (/dev/disk1p2), a volume (/volumes/NAME), a label
  (LABEL=NAME: the volume of that label) or, for a memory volume, any
  word (tmpfs); TYPE is the file system ("auto" for any); OPTIONS are
  the kernel's mount options ("defaults" for none) plus two of the
  table's own, which are not passed on: noauto (not mounted at start or
  by "mount -a") and nofail (a missing source is no error). DUMP and
  PASS are read and ignored. "#" starts a comment; a line with too few
  fields is a problem reported with its number.

  Plain Pascal strings (no units), so the host tests build it too.
}
unit Sys.MountTable;

{$mode objfpc}
{$H+}

interface

const
  MountTablePath = '/etc/fstab';

type
  TMountTableEntry = record
    Source: string;
    Target: string;
    FileSystemType: string;
    { What goes to the kernel: "defaults", noauto and nofail left out. }
    Options: string;
    NoAuto: Boolean;
    NoFail: Boolean;
    LineNumber: Integer;
  end;
  TMountTableEntries = array of TMountTableEntry;
  TMountTableProblems = array of string;

{ Reads one line. False for a blank line, a comment or a wrong line
  (then Problem says why). }
function ParseMountTableLine(const Line: string; out Entry: TMountTableEntry; out Problem: string): Boolean;
{ Reads a whole table; each problem is "line N: why". }
procedure ParseMountTable(const Text: string; out Entries: TMountTableEntries; out Problems: TMountTableProblems);

implementation

function IsSpace(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #13);
end;

function IntegerText(Value: Integer): string;
begin
  Str(Value, Result);
end;

procedure SplitFields(const Line: string; out Fields: TMountTableProblems);
var
  Position: Integer;
  Start: Integer;
  Count: Integer;
begin
  Fields := nil;
  Count := 0;
  Position := 1;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and IsSpace(Line[Position]) do
      Inc(Position);
    if (Position > Length(Line)) or (Line[Position] = '#') then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and not IsSpace(Line[Position]) and (Line[Position] <> '#') do
      Inc(Position);
    SetLength(Fields, Count + 1);
    Fields[Count] := Copy(Line, Start, Position - Start);
    Inc(Count);
  end;
end;

{ Takes the table's own options out of Options. }
procedure SeparateOptions(const Options: string; var Entry: TMountTableEntry);
var
  Position: Integer;
  Start: Integer;
  Option: string;
begin
  Entry.Options := '';
  Position := 1;
  while Position <= Length(Options) do
  begin
    Start := Position;
    while (Position <= Length(Options)) and (Options[Position] <> ',') do
      Inc(Position);
    Option := Copy(Options, Start, Position - Start);
    Inc(Position);
    if Option = 'noauto' then
      Entry.NoAuto := True
    else if Option = 'nofail' then
      Entry.NoFail := True
    else if (Option = 'auto') or (Option = 'defaults') or (Option = '') then
      { nothing to pass on }
    else
    begin
      if Entry.Options <> '' then
        Entry.Options := Entry.Options + ',';
      Entry.Options := Entry.Options + Option;
    end;
  end;
end;

function ParseMountTableLine(const Line: string; out Entry: TMountTableEntry; out Problem: string): Boolean;
var
  Fields: TMountTableProblems;
begin
  Entry := Default(TMountTableEntry);
  Problem := '';
  SplitFields(Line, Fields);
  if Length(Fields) = 0 then
    Exit(False);
  if Length(Fields) < 3 then
  begin
    Problem := 'needs a source, a target and a type';
    Exit(False);
  end;
  if Length(Fields) > 6 then
  begin
    Problem := 'too many fields';
    Exit(False);
  end;
  if (Fields[1] = '') or ((Fields[1][1] <> '/') and (Fields[1] <> 'none')) then
  begin
    Problem := 'the target must be an absolute path';
    Exit(False);
  end;
  Entry.Source := Fields[0];
  Entry.Target := Fields[1];
  Entry.FileSystemType := Fields[2];
  if Length(Fields) >= 4 then
    SeparateOptions(Fields[3], Entry);
  Result := True;
end;

procedure ParseMountTable(const Text: string; out Entries: TMountTableEntries; out Problems: TMountTableProblems);
var
  Position: Integer;
  Start: Integer;
  LineNumber: Integer;
  Entry: TMountTableEntry;
  Problem: string;
begin
  Entries := nil;
  Problems := nil;
  LineNumber := 0;
  Position := 1;
  while Position <= Length(Text) do
  begin
    Start := Position;
    while (Position <= Length(Text)) and (Text[Position] <> #10) do
      Inc(Position);
    Inc(LineNumber);
    if ParseMountTableLine(Copy(Text, Start, Position - Start), Entry, Problem) then
    begin
      Entry.LineNumber := LineNumber;
      SetLength(Entries, Length(Entries) + 1);
      Entries[High(Entries)] := Entry;
    end
    else if Problem <> '' then
    begin
      SetLength(Problems, Length(Problems) + 1);
      Problems[High(Problems)] := 'line ' + IntegerText(LineNumber) + ': ' + Problem;
    end;
    Inc(Position);
  end;
end;

end.
