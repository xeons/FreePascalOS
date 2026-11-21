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
  mount - mount a volume at a directory, or list the mounted volumes

  mount                                   list every mounted volume
  mount [-t TYPE] [-o OPTIONS] SOURCE [DIRECTORY]
  mount -a                                mount what /etc/fstab says
  mount DIRECTORY                         mount what /etc/fstab says
                                          for DIRECTORY

  SOURCE is a device (/dev/disk1p2), a volume (/volumes/disk1p2), a
  label (LABEL=NAME) or, with -t tmpfs, any word. OPTIONS: ro, rw,
  noexec, nosuid, discard, uid=N, gid=N, umask=OCTAL, fmask=OCTAL,
  dmask=OCTAL (FAT and exFAT), size=N[k|m|g|%] and mode=OCTAL (tmpfs).
  Without a directory the volume is only mounted at /volumes/NAME.
}
program mount;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Mounts,
  Sys.MountTable,
  Sys.MountAll,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages;

const
  Usage = 'Usage: mount [-t TYPE] [-o OPTIONS] SOURCE [DIRECTORY]'#10 +
    '       mount -a | mount DIRECTORY | mount'#10 +
    'Mount a volume at a directory, or list the mounted volumes.'#10 +
    #10 +
    '  -a, --all             mount everything /etc/fstab lists (not noauto)'#10 +
    '  -t, --types=TYPE      the file system: tmpfs makes a memory volume'#10 +
    '  -o, --options=LIST    ro, rw, noexec, nosuid, discard, uid=N, gid=N,'#10 +
    '                        umask=, fmask=, dmask= (FAT, exFAT),'#10 +
    '                        size=N[k|m|g|%], mode= (tmpfs)'#10 +
    '  -v, --verbose         say what was mounted'#10;

  OptionAll = 1;
  OptionType = 2;
  OptionOptions = 3;
  OptionVerbose = 4;

procedure ListMounts;
var
  Index: Integer;
  Description: TMountDescription;
begin
  Index := 0;
  while GetMountDescription(Index, Description) do
  begin
    PrintStringLine(Format('%s on %s type %s (%s)', [Description.Source, Description.MountPoint,
      Description.FileSystemType, Description.Options]));
    Inc(Index);
  end;
end;

function MountAll(Verbose: Boolean): Integer;
var
  Messages: TMountMessages;
  Message: string;
begin
  Result := MountAllFromTable(MountTablePath, Messages);
  for Message in Messages do
    if Verbose or (Pos('cannot', Message) > 0) or (Pos(MountTablePath + ': line', Message) = 1) then
      PrintErrorStringLine('mount: ' + Message);
end;

{ "mount DIRECTORY": the table's entry for it. }
function MountFromTable(const Target: string): Integer;
var
  Text: string;
  Entries: TMountTableEntries;
  Problems: TMountTableProblems;
  Entry: TMountTableEntry;
  Error: LongInt;
begin
  if not ReadMountTableText(MountTablePath, Text) then
    Fail(1, 'cannot read ' + MountTablePath);
  ParseMountTable(Text, Entries, Problems);
  for Entry in Entries do
    if Entry.Target = Target then
    begin
      Error := MountTableEntry(Entry);
      if Error <> ErrorNone then
      begin
        ReportError(Error, Format('cannot mount %s at %s', [Entry.Source, Target]));
        Exit(1);
      end;
      Exit(0);
    end;
  Fail(1, Format('%s is not in %s', [Target, MountTablePath]));
  Result := 1;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  All: Boolean;
  Verbose: Boolean;
  FileSystemType: string;
  Options: string;
  Source: string;
  Target: string;
  Error: LongInt;
begin
  All := False;
  Verbose := False;
  FileSystemType := '';
  Options := '';
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('t', 'types', True, OptionType),
    CommandOption('o', 'options', True, OptionOptions),
    CommandOption('v', 'verbose', False, OptionVerbose)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionAll: All := True;
      OptionType: FileSystemType := Value;
      OptionOptions:
        if Options = '' then
          Options := Value
        else
          Options := Options + ',' + Value;
      OptionVerbose: Verbose := True;
    end;

  if All then
    Halt(Ord(MountAll(Verbose) > 0));
  if CommandLine.OperandCount = 0 then
  begin
    ListMounts;
    Halt(0);
  end;
  if CommandLine.OperandCount > 2 then
    FailWithUsageHint('too many operands');

  Source := CommandLine.Operands[0];
  Target := '';
  if CommandLine.OperandCount = 2 then
    Target := CommandLine.Operands[1]
  else if (FileSystemType = '') and (Options = '') and (Copy(Source, 1, 5) <> '/dev/') and
          (Copy(Source, 1, 9) <> '/volumes/') and (Copy(Source, 1, 6) <> 'LABEL=') then
    Halt(MountFromTable(Source));

  if (Copy(Source, 1, 6) = 'LABEL=') and not FindLabelledVolume(Copy(Source, 7, Length(Source)), Source) then
    Fail(1, Format('no volume is labelled %s', [Copy(Source, 7, Length(Source))]));
  Error := MountVolume(Source, Target, FileSystemType, Options);
  if Error = ErrorInvalidArgument then
    Fail(1, Format('cannot mount %s: wrong option, type or source', [Source]));
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('cannot mount %s', [Source]));
  if Verbose then
    PrintStringLine(Format('mounted %s at %s', [Source, Target]));
  CommandLine.Free;
end.
