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
  watchtest - checks watching files and folders for changes

  watchtest

  Run by coretest. The changes are made by another process (a shell
  started for each step), and must arrive on the watches with the right
  kinds and names: files created, written, renamed, their attributes
  changed, removed, folders made and removed; a watch on a whole
  subtree beside one on its top folder; a watch on a file, followed
  through a rename until it is removed; a watch on a folder that is
  removed; the overflow record once more changes came than were read;
  a watch waited on together with other handles. Also the refusals: a
  path that does not exist, /dev, flags that make no sense.

  The file checks run in /tmp (ext4, the system volume) and on every
  writable test volume there is of another format (FAT16TEST, EXFATTEST,
  EXT2TEST), each in a folder of its own that is removed afterwards.

  Each check prints a line; the exit status is 1 if any failed.
}
program WatchTest;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.FileWatches,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Objects,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Sys.Volumes,
  Util.FileTree;

const
  TestVolumeLabels: array[0..2] of PChar = ('FAT16TEST', 'EXFATTEST', 'EXT2TEST');
  OverflowFileCount = 80;
  PathCapacity = 512;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  { Where the checks of one volume run, and its name in the output. }
  Folder: array[0..PathCapacity - 1] of Char;
  Place: PChar;

procedure Check(Name: PChar; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteFormatted(StandardOutput, 'watchtest: pass: %s: %s'#10, [ArgumentText(Place), ArgumentText(Name)])
  else
  begin
    WriteFormatted(StandardOutput, 'watchtest: FAIL: %s: %s'#10, [ArgumentText(Place), ArgumentText(Name)]);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

{ Writes Text on one line after Title, its lines separated by '|'. }
procedure ShowLines(Title, Text: PChar);
var
  Index: PtrUInt;
begin
  WriteFormatted(StandardOutput, '  %s: ', [ArgumentText(Title)]);
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if Text[Index] = #10 then
      WriteText(StandardOutput, '|')
    else
      WriteFormatted(StandardOutput, '%c', [ArgumentCharacter(Text[Index])]);
    Inc(Index);
  end;
  WriteText(StandardOutput, #10);
end;

{ Compares the changes that came with what should have; says both when
  they differ. }
procedure CheckChanges(Name: PChar; Got, Expected: PChar);
begin
  Check(Name, TextIsEqual(Got, Expected));
  if not TextIsEqual(Got, Expected) then
  begin
    ShowLines('expected', Expected);
    ShowLines('got', Got);
  end;
end;

{ Folder/Name. }
procedure MakePath(Name: PChar; Path: PChar);
var
  Builder: TTextBuilder;
  Text: PChar;
begin
  BeginText(Builder);
  AppendText(Builder, @Folder[0]);
  if Name^ <> #0 then
  begin
    AppendText(Builder, '/');
    AppendText(Builder, Name);
  end;
  Text := FinishText(Builder);
  CopyText(Path, Text, PathCapacity);
  FreeMemory(Text);
end;

{ Runs Command with sh in Folder: another process makes the changes. }
function RunShell(Command: PChar): LongInt;
var
  Arguments: array[0..3] of PChar;
begin
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Command;
  Arguments[3] := nil;
  Result := RunProgram('/bin/sh', @Arguments[0]);
end;

function StartShell(Command: PChar): Int64;
var
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
begin
  Arguments[0] := 'sh';
  Arguments[1] := '-c';
  Arguments[2] := Command;
  Arguments[3] := nil;
  DefaultProcessOptions(Options);
  Options.WorkingDirectory := @Folder[0];
  Result := StartProgram('/bin/sh', @Arguments[0], Options);
end;

function Watch(Name: PChar; Flags: LongWord): Int64;
var
  Path: array[0..PathCapacity - 1] of Char;
begin
  MakePath(Name, @Path[0]);
  Result := WatchPath(@Path[0], Flags);
end;

{ Every change waiting in the watch, one line each: "kind name", a
  folder's name ending in '/', a rename's as "new<-old". The caller
  frees the text. }
function TakeChanges(Handle: Int64): PChar;
var
  Builder: TTextBuilder;
  Reader: TFileChangeReader;
  Change: TFileChange;
begin
  BeginText(Builder);
  while ReadFileChanges(Reader, Handle) = ErrorNone do
    while NextFileChange(Reader, Change) do
    begin
      AppendText(Builder, FileChangeKindText(Change.Kind));
      if Change.Kind <> FileChangeOverflow then
      begin
        AppendText(Builder, ' ');
        AppendText(Builder, Change.Name);
        if Change.IsDirectory then
          AppendText(Builder, '/');
        if Change.OldName <> nil then
        begin
          AppendText(Builder, '<-');
          AppendText(Builder, Change.OldName);
        end;
      end;
      AppendText(Builder, #10);
    end;
  Result := FinishText(Builder);
end;

procedure CheckWatchChanges(Name: PChar; Handle: Int64; Expected: PChar);
var
  Got: PChar;
begin
  Got := TakeChanges(Handle);
  CheckChanges(Name, Got, Expected);
  FreeMemory(Got);
end;

{ Runs Command in Folder (cd first). }
procedure ChangeThings(Command: PChar);
var
  Builder: TTextBuilder;
  Text: PChar;
begin
  BeginText(Builder);
  AppendText(Builder, 'cd ');
  AppendText(Builder, @Folder[0]);
  AppendText(Builder, ' && ');
  AppendText(Builder, Command);
  Text := FinishText(Builder);
  if RunShell(Text) <> 0 then
    WriteFormatted(StandardOutput, '  (the shell failed: %s)'#10, [ArgumentText(Command)]);
  FreeMemory(Text);
end;

procedure TestFolder;
var
  Handle: Int64;
begin
  Handle := Watch('', WatchNames or WatchContents or WatchAttributes);
  Check('a watch on the folder', Handle >= 0);
  ChangeThings('echo x > a; mv a b; echo y >> b; chmod 600 b; mkdir sub; rmdir sub; rm b');
  CheckWatchChanges('created, written, renamed, attributes, removed, folders', Handle,
    'created a'#10'written a'#10'renamed b<-a'#10'written b'#10'attributes b'#10 +
    'created sub/'#10'removed sub/'#10'removed b'#10);
  Check('nothing more', WaitForHandle(Handle, 0) = ErrorTimedOut);
  CloseHandle(Handle);

  { Only what was asked for. }
  Handle := Watch('', WatchContents);
  ChangeThings('echo x > c; mv c d; echo y >> d; rm d');
  CheckWatchChanges('only writes', Handle, 'written c'#10'written d'#10);
  CloseHandle(Handle);
end;

procedure TestSubtree;
var
  Whole: Int64;
  Top: Int64;
begin
  Whole := Watch('', WatchNames or WatchContents or WatchSubtree);
  Top := Watch('', WatchNames);
  Check('a watch on the subtree', (Whole >= 0) and (Top >= 0));
  ChangeThings('mkdir s1; mkdir s1/s2; echo z > s1/s2/f; mv s1/s2/f s1/g; rm s1/g; rmdir s1/s2; rmdir s1');
  CheckWatchChanges('changes below, with paths', Whole,
    'created s1/'#10'created s1/s2/'#10'created s1/s2/f'#10'written s1/s2/f'#10 +
    'renamed s1/g<-s1/s2/f'#10'removed s1/g'#10'removed s1/s2/'#10'removed s1/'#10);
  CheckWatchChanges('the top folder only sees its own names', Top, 'created s1/'#10'removed s1/'#10);
  CloseHandle(Whole);
  CloseHandle(Top);
end;

procedure TestMovingInAndOut;
var
  Handle: Int64;
begin
  ChangeThings('mkdir inner; echo x > outside');
  Handle := Watch('inner', WatchNames);
  ChangeThings('mv outside inner/inside; mv inner/inside back');
  CheckWatchChanges('moved in is created, moved out removed', Handle, 'created inside'#10'removed inside'#10);
  CloseHandle(Handle);
  ChangeThings('rm back; rmdir inner');
end;

procedure TestFile;
var
  Handle: Int64;
begin
  ChangeThings('echo x > watched');
  Handle := Watch('watched', WatchContents or WatchAttributes);
  Check('a watch on a file', Handle >= 0);
  ChangeThings('echo y >> watched; chmod 600 watched; mv watched moved; echo z >> moved; rm moved');
  CheckWatchChanges('written, attributes, followed through a rename, removed', Handle,
    'written '#10'attributes '#10'watched item moved moved'#10'written '#10'watched item removed '#10);
  CloseHandle(Handle);
end;

procedure TestRemovedFolder;
var
  Handle: Int64;
begin
  ChangeThings('mkdir doomed');
  Handle := Watch('doomed', WatchNames);
  ChangeThings('rmdir doomed; mkdir doomed; rmdir doomed');
  CheckWatchChanges('the watched folder removed, then nothing', Handle, 'watched item removed /'#10);
  CloseHandle(Handle);
  Check('a path that does not exist', Watch('doomed', WatchNames) = -ErrorNotFound);
end;

{ "Verb fFirst ... fLast". The caller frees the text. }
function FileListCommand(Verb: PChar; First, Last: Integer): PChar;
var
  Builder: TTextBuilder;
  Index: Integer;
begin
  BeginText(Builder);
  AppendText(Builder, Verb);
  for Index := First to Last do
  begin
    AppendText(Builder, ' f');
    AppendDecimal(Builder, Index);
  end;
  Result := FinishText(Builder);
end;

function CountLines(Text: PChar): Integer;
var
  Index: PtrUInt;
begin
  Result := 0;
  Index := 0;
  while Text[Index] <> #0 do
  begin
    if Text[Index] = #10 then
      Inc(Result);
    Inc(Index);
  end;
end;

procedure TestOverflow;
var
  Handle: Int64;
  Command: PChar;
  Got: PChar;
begin
  Handle := Watch('', WatchNames);
  Command := FileListCommand('touch', 1, OverflowFileCount);
  ChangeThings(Command);
  FreeMemory(Command);
  Got := TakeChanges(Handle);
  Check('a full watch ends with the overflow record',
    (CountLines(Got) = MaximumQueuedWatchRecords) and (TextLength(Got) > 9) and
    TextIsEqual(Got + TextLength(Got) - 9, 'overflow'#10));
  FreeMemory(Got);
  ChangeThings('rm f1');
  CheckWatchChanges('read, it reports again', Handle, 'removed f1'#10);
  { Removing the rest overflows it again; it is closed full. }
  Command := FileListCommand('rm', 2, OverflowFileCount);
  ChangeThings(Command);
  FreeMemory(Command);
  CloseHandle(Handle);
end;

procedure TestWaitingWithOtherHandles;
var
  Handle: Int64;
  Event: Int64;
  Timer: Int64;
  Child: Int64;
begin
  Handle := Watch('', WatchNames);
  Event := CreateEvent(True, False);
  Timer := CreateTimer(True);
  SetTimer(Timer, 60000, 0);
  Check('not ready before a change', WaitForHandles([Event, Timer, Handle], 0) = -ErrorTimedOut);
  Child := StartShell('sleep 1; touch late');
  Check('ready among other handles when a change came', WaitForHandles([Event, Timer, Handle], 10000) = 2);
  if Child >= 0 then
  begin
    WaitForProgram(Child);
    CloseHandle(Child);
  end;
  CheckWatchChanges('the change that made it ready', Handle, 'created late'#10);
  Check('not ready once read', WaitForHandles([Event, Timer, Handle], 0) = -ErrorTimedOut);
  ChangeThings('rm late');
  CloseHandle(Timer);
  CloseHandle(Event);
  CloseHandle(Handle);
end;

procedure RunFileChecks;
begin
  if PathExists(@Folder[0]) then
    RemoveTree(PChar(@Folder[0]));
  Check('the folder made', CreateDirectory(@Folder[0]) = ErrorNone);
  TestFolder;
  TestSubtree;
  TestMovingInAndOut;
  TestFile;
  TestRemovedFolder;
  TestOverflow;
  TestWaitingWithOtherHandles;
  RemoveTree(PChar(@Folder[0]));
end;

procedure RunOnSystemVolume;
begin
  if not IsDirectory('/tmp') then
    CreateDirectory('/tmp');
  CopyText(@Folder[0], '/tmp/watchtest', PathCapacity);
  Place := 'system volume';
  RunFileChecks;
end;

{ The first writable volume labelled Wanted. }
function FindTestVolume(Wanted: PChar; out Volume: TVolumeDescription): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while GetVolumeDescription(Index, Volume) do
  begin
    if TextIsEqual(@Volume.VolumeLabel[0], Wanted) and not Volume.IsReadOnly then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

procedure RunOnTestVolumes;
var
  Index: Integer;
  Volume: TVolumeDescription;
  Length: PtrUInt;
begin
  for Index := 0 to High(TestVolumeLabels) do
  begin
    if not FindTestVolume(TestVolumeLabels[Index], Volume) then
      Continue;
    CopyText(@Folder[0], @Volume.MountPoint[0], PathCapacity);
    Length := TextLength(@Folder[0]);
    CopyText(@Folder[Length], '/watchtest', PathCapacity - Length);
    Place := @Volume.FileSystemType[0];
    RunFileChecks;
  end;
end;

procedure TestRefusals;
var
  Handle: Int64;
  Volume: TVolumeDescription;
begin
  Place := 'refusals';
  Check('/dev is not watched', WatchPath('/dev', WatchNames) = -ErrorUnsupported);
  Check('no kind of change asked for', WatchPath('/tmp', 0) = -ErrorInvalidArgument);
  Check('an unknown flag', WatchPath('/tmp', WatchNames or $1000) = -ErrorInvalidArgument);
  Handle := WatchVolumes;
  Check('a watch on the list of volumes', Handle >= 0);
  Check('the list of volumes has not changed', WaitForHandle(Handle, 0) = ErrorTimedOut);
  CloseHandle(Handle);
  Check('the system volume is listed', GetVolumeDescription(0, Volume) and
    FindVolumeDescription(@Volume.Name[0], Volume));
end;

begin
  RunOnSystemVolume;
  RunOnTestVolumes;
  TestRefusals;
  WriteFormatted(StandardOutput, 'watchtest: %d of %d checks passed'#10, [ArgumentNumber(Checks - Failures),
    ArgumentNumber(Checks)]);
  if Failures > 0 then
    Halt(1);
end.
