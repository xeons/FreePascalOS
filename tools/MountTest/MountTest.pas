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
  MountTest: the plain logic of mounting, on the host.

    * mount options (FileSystem.MountOptions): every option, umask
      setting both masks and fmask/dmask after it, sizes with k, m, g
      and %, wrong values refused at their position, the text mount
      lists;
    * owners and modes of formats without them (FileSystem.OwnerMapping):
      the masks, the read-only attribute on files but not folders;
    * the mount table (FileSystem.MountTable): finding a mount by its
      directory and by its volume, the top of a chain, cycles detected,
      the paths of nested mounts, a full table, removal;
    * the mount table file (Sys.MountTable): fields, comments, noauto
      and nofail taken out of the options, defaults, wrong lines.

  Prints FAIL lines and a summary; exit status 1 on any failure.
}
program MountTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  FileSystem.MountOptions,
  FileSystem.OwnerMapping,
  FileSystem.MountTable,
  Sys.MountTable;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Condition: Boolean; const Name: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    WriteLn('FAIL: ', Name);
    Inc(Failures);
  end;
end;

function Parsed(const Text: string; out Options: TMountOptions; out ErrorPosition: Integer): Boolean;
begin
  SetDefaultMountOptions(Options);
  Result := ParseMountOptions(PChar(Text), Options, ErrorPosition);
end;

function Formatted(const Options: TMountOptions; OwnerOptions, SizeOptions: Boolean): string;
var
  Buffer: array[0..MountOptionsTextCapacity - 1] of Char;
begin
  FormatMountOptions(Options, OwnerOptions, SizeOptions, @Buffer[0], SizeOf(Buffer));
  Result := PChar(@Buffer[0]);
end;

procedure TestOptions;
var
  Options: TMountOptions;
  Position: Integer;
begin
  Check(Parsed('', Options, Position) and not Options.ReadOnly and (Options.FileMask = $5B) and
    (Options.DirectoryMask = $12), 'defaults');
  Check(Parsed('ro,noexec,nosuid,discard', Options, Position) and Options.ReadOnly and Options.NoExecute and
    Options.NoSetId and Options.Discard, 'flags');
  Check(Parsed('ro,rw,noexec,exec,nosuid,suid,discard,nodiscard', Options, Position) and not Options.ReadOnly and
    not Options.NoExecute and not Options.NoSetId and not Options.Discard, 'flags undone');
  Check(Parsed('defaults,noatime,relatime,atime,,', Options, Position), 'ignored options and empty items');
  Check(Parsed('uid=1000,gid=100,umask=027', Options, Position) and (Options.OwnerId = 1000) and
    (Options.GroupId = 100) and (Options.FileMask = $17) and (Options.DirectoryMask = $17), 'owners and umask');
  Check(Parsed('umask=0,fmask=0133', Options, Position) and (Options.FileMask = $5B) and
    (Options.DirectoryMask = 0), 'fmask after umask');
  Check(Parsed('dmask=077', Options, Position) and (Options.DirectoryMask = $3F) and (Options.FileMask = $5B),
    'dmask alone');
  Check(Parsed('size=64m,mode=1777', Options, Position) and (Options.SizeLimitBytes = 64 * 1024 * 1024) and
    (Options.SizePercent = 0) and (Options.RootMode = $3FF), 'size and mode');
  Check(Parsed('size=4k', Options, Position) and (Options.SizeLimitBytes = 4096), 'size in KiB');
  Check(Parsed('size=2g', Options, Position) and (Options.SizeLimitBytes = QWord(2) shl 30), 'size in GiB');
  Check(Parsed('size=12345', Options, Position) and (Options.SizeLimitBytes = 12345), 'size in bytes');
  Check(Parsed('size=25%', Options, Position) and (Options.SizePercent = 25) and (Options.SizeLimitBytes = 0),
    'size as a share');
  Check(not Parsed('ro,bogus', Options, Position) and (Position = 3), 'unknown option at its place');
  Check(not Parsed('uid=x', Options, Position) and (Position = 0), 'uid not a number');
  Check(not Parsed('umask=9', Options, Position), 'umask not octal');
  Check(not Parsed('umask=1000', Options, Position), 'umask too large');
  Check(not Parsed('size=0', Options, Position), 'size zero');
  Check(not Parsed('size=101%', Options, Position), 'share above 100');
  Check(not Parsed('ro=1', Options, Position), 'flag with a value');
  Check(not Parsed('uid', Options, Position), 'value option without a value');
  Check(not Parsed('uid=4294967295', Options, Position), 'uid out of range');

  Parsed('ro,nosuid,uid=1000,gid=1000,umask=022', Options, Position);
  Check(Formatted(Options, True, False) = 'ro,nosuid,uid=1000,gid=1000,fmask=0022,dmask=0022', 'listed owners');
  Parsed('', Options, Position);
  Check(Formatted(Options, False, True) = 'rw,size=50%,mode=1777', 'listed tmpfs defaults');
  Parsed('size=64m,mode=755', Options, Position);
  Check(Formatted(Options, False, True) = 'rw,size=64m,mode=0755', 'listed tmpfs size');
  Parsed('size=1536k', Options, Position);
  Check(Formatted(Options, False, True) = 'rw,size=1536k,mode=1777', 'listed size in KiB');
  Check(Formatted(Options, False, False) = 'rw', 'listed plain');
end;

procedure TestOwnerMapping;
var
  Options: TMountOptions;
  Position: Integer;
begin
  Parsed('', Options, Position);
  Check(OwnerlessMode(False, False, Options) = $1A4, 'file rw-r--r--');
  Check(OwnerlessMode(True, False, Options) = $1ED, 'folder rwxr-xr-x');
  Check(OwnerlessMode(False, True, Options) = $124, 'read-only file r--r--r--');
  Check(OwnerlessMode(True, True, Options) = $1ED, 'read-only attribute ignored on folders');
  Parsed('umask=027', Options, Position);
  Check(OwnerlessMode(False, False, Options) = $1E8, 'umask=027 file');
  Check(OwnerlessMode(False, True, Options) = $168, 'umask=027 read-only file');
  Check(ModeMeansReadOnly($124) and not ModeMeansReadOnly($1A4), 'driver modes');
end;

procedure TestTable;
var
  Table: TMountTable;
  System: Integer;
  Memory: Integer;
  Usb: Integer;
  Other: Integer;
  MountPoint: Integer;
  First: PMountRecord;
  Second: PMountRecord;
  Path: array[0..MaximumMountPathBytes - 1] of Char;
  Joined: array[0..MaximumMountPathBytes - 1] of Char;
  Index: Integer;
  Full: Boolean;
begin
  InitializeMountTable(Table);
  First := AddMount(Table, @System, @MountPoint, 12, @Memory, @System, '/tmp');
  Check(First <> nil, 'adding a mount');
  Check(FindMountAt(Table, @System, 12) = First, 'found by its directory');
  Check(FindMountAt(Table, @System, 13) = nil, 'another directory');
  Check(FindMountAt(Table, @Memory, 12) = nil, 'another volume');
  Check(FindMountOf(Table, @Memory) = First, 'found by its volume');
  Check(TopVolumeOf(Table, @Memory) = @System, 'top of the chain');
  Check(TopVolumeOf(Table, @System) = @System, 'a volume mounted nowhere is its own top');

  CopyVolumeRootPath(Table, @Memory, @Path[0], SizeOf(Path));
  JoinMountPath(@Path[0], '/usb', @Joined[0], SizeOf(Joined));
  Check(StrPas(PChar(@Joined[0])) = '/tmp/usb', 'nested mount path');
  Second := AddMount(Table, @Memory, @MountPoint, 5, @Usb, TopVolumeOf(Table, @Memory), @Joined[0]);
  Check(TopVolumeOf(Table, @Usb) = @System, 'top of a nested chain');
  Check(IsMountedBelow(Table, @Usb, @System) and IsMountedBelow(Table, @Usb, @Memory) and
    IsMountedBelow(Table, @Usb, @Usb), 'mounted below its ancestors');
  Check(not IsMountedBelow(Table, @System, @Usb) and not IsMountedBelow(Table, @Other, @System),
    'not below others');
  Check(CountMountsOn(Table, @System) = 1, 'one mount on the system volume');
  Check(MountAt(Table, 1) = Second, 'listed in order');
  Check(MountAt(Table, 2) = nil, 'listing ends');
  CopyVolumeRootPath(Table, @Usb, @Path[0], SizeOf(Path));
  Check(StrPas(PChar(@Path[0])) = '/tmp/usb', 'root path of a nested volume');
  CopyVolumeRootPath(Table, @System, @Path[0], SizeOf(Path));
  Check(Path[0] = #0, 'root path of a volume mounted nowhere');

  RemoveMount(Second);
  Check(FindMountOf(Table, @Usb) = nil, 'removed');
  Check(CountMountsOn(Table, @Memory) = 0, 'nothing on it any more');

  Full := True;
  for Index := 2 to MaximumMounts do
    if AddMount(Table, @System, @MountPoint, 100 + Index, @Other, @System, '/x') = nil then
      Full := False;
  Check(Full, 'the table holds MaximumMounts');
  Check(AddMount(Table, @System, @MountPoint, 1, @Other, @System, '/y') = nil, 'a full table refuses');

  JoinMountPath('', '', @Joined[0], SizeOf(Joined));
  Check(StrPas(PChar(@Joined[0])) = '/', 'joining nothing');
  JoinMountPath('/a/', '/b', @Joined[0], SizeOf(Joined));
  Check(StrPas(PChar(@Joined[0])) = '/a/b', 'joining without doubled separators');
  Check(not JoinMountPath('/abc', 'def', @Joined[0], 6), 'a join that does not fit');
end;

procedure TestTableFile;
var
  Entries: TMountTableEntries;
  Problems: TMountTableProblems;
  Entry: TMountTableEntry;
  Problem: string;
begin
  ParseMountTable('# comment'#10 +
    'tmpfs /tmp tmpfs mode=1777,size=50% 0 0'#10 +
    #10 +
    '   LABEL=DATA'#9'/mnt/data  vfat  defaults,nofail,uid=1000,noauto  # trailing'#10 +
    '/dev/disk1p2 /mnt ext4'#10 +
    'only-two /x'#10 +
    'bad relative ext4 defaults'#10, Entries, Problems);
  Check(Length(Entries) = 3, 'three entries');
  Check(Length(Problems) = 2, 'two problems');
  if Length(Entries) = 3 then
  begin
    Check((Entries[0].Source = 'tmpfs') and (Entries[0].Target = '/tmp') and (Entries[0].FileSystemType = 'tmpfs') and
      (Entries[0].Options = 'mode=1777,size=50%') and (Entries[0].LineNumber = 2), 'tmpfs entry');
    Check((Entries[1].Source = 'LABEL=DATA') and (Entries[1].Target = '/mnt/data') and
      (Entries[1].Options = 'uid=1000') and Entries[1].NoFail and Entries[1].NoAuto and
      (Entries[1].LineNumber = 4), 'entry with table options');
    Check((Entries[2].Options = '') and not Entries[2].NoAuto, 'entry without options');
  end;
  if Length(Problems) = 2 then
  begin
    Check(Problems[0] = 'line 6: needs a source, a target and a type', 'too few fields');
    Check(Problems[1] = 'line 7: the target must be an absolute path', 'relative target');
  end;
  Check(not ParseMountTableLine('  # nothing', Entry, Problem) and (Problem = ''), 'comment line');
  Check(not ParseMountTableLine('a /b c d 0 0 extra', Entry, Problem) and (Problem = 'too many fields'),
    'too many fields');
  Check(ParseMountTableLine('/volumes/disk1p1 none auto ro', Entry, Problem) and (Entry.Target = 'none'),
    'a volume mounted at /volumes only');
end;

begin
  TestOptions;
  TestOwnerMapping;
  TestTable;
  TestTableFile;
  if Failures > 0 then
  begin
    WriteLn('MOUNT TEST FAILED: ', Failures, ' of ', Checks, ' checks');
    Halt(1);
  end;
  WriteLn('MOUNT TEST PASSED: ', Checks, ' checks');
end.
