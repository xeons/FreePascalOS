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
  settingstest - checks file locks and the settings library's files

  settingstest

  Advisory file locks (ControlLockFile) on a folder: shared and
  exclusive, refused without waiting, a program waiting for one until it
  is given up, a waiting program ended, a lock given up when its program
  ends. Then the settings files (Configuration.FileStorage) in a folder
  of its own under /tmp: modes of the folder and the files, no file left
  half-written, what a crash in the middle of a rename leaves read back,
  and two programs writing to one group at the same time, many times,
  keeping every change.

  It starts itself for the second programs: --wait-lock FOLDER waits for
  an exclusive lock on FOLDER and ends; --hold-lock FOLDER takes one and
  ends without giving it up; --writer N FOLDER COUNT writes COUNT keys
  of its own into the group Shared, flushing after each.

  Each check prints a line; the exit status is 1 if any failed.
}
program SettingsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Processes,
  Sys.Streams,
  Configuration.Scopes,
  Configuration.Settings,
  Configuration.FileStorage,
  Configuration.Locations;

const
  WorkFolder = '/tmp/settingstest';
  LockFolder = WorkFolder + '/locked';
  ScopeFolder = WorkFolder + '/scope';
  SelfPath = '/bin/settingstest';
  WriterCount = 3;
  KeysPerWriter = 25;
  ChildTimeout = 30000;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteString(StandardOutput, Format('settingstest: pass: %s'#10, [PChar(Name)]))
  else
  begin
    WriteString(StandardOutput, Format('settingstest: FAIL: %s'#10, [PChar(Name)]));
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

function OpenFolder(const Path: string): Int64;
begin
  Result := OpenFile(PChar(Path), OpenRead);
end;

function StartSelf(const Arguments: array of string): Int64;
var
  Values: array of PChar;
  Index: Integer;
  Options: TProcessOptions;
begin
  SetLength(Values, Length(Arguments) + 2);
  Values[0] := SelfPath;
  for Index := 0 to High(Arguments) do
    Values[Index + 1] := PChar(Arguments[Index]);
  Values[High(Values)] := nil;
  DefaultProcessOptions(Options);
  Result := StartProgram(SelfPath, @Values[0], Options);
end;

{ The program's exit code, or -1 if it did not end in time. }
function EndOf(Process: Int64; Milliseconds: QWord): LongInt;
begin
  if WaitForProgramWithTimeout(Process, Milliseconds, Result) <> ErrorNone then
    Result := -1;
end;

function ModeOf(const Path: string): LongWord;
var
  Information: TFileInformation;
begin
  Result := $FFFF;
  if GetFileInformation(PChar(Path), Information) = ErrorNone then
    Result := Information.Mode and $FFF;
end;

{ --- Locks ------------------------------------------------------------------------------------ }

procedure TestLocks;
var
  First: Int64;
  Second: Int64;
  Child: Int64;
begin
  First := OpenFolder(LockFolder);
  Second := OpenFolder(LockFolder);
  Check('a folder opens twice', (First >= 0) and (Second >= 0));
  Check('an exclusive lock', LockFile(First, FileLockExclusive) = ErrorNone);
  Check('another exclusive one is refused without waiting',
    LockFile(Second, FileLockExclusive or FileLockNoWait) = ErrorWouldBlock);
  Check('so is a shared one', LockFile(Second, FileLockShared or FileLockNoWait) = ErrorWouldBlock);
  Check('given up', UnlockFile(First) = ErrorNone);
  Check('then a shared lock', LockFile(Second, FileLockShared or FileLockNoWait) = ErrorNone);
  Check('two shared locks at once', LockFile(First, FileLockShared or FileLockNoWait) = ErrorNone);
  Check('no exclusive lock beside a shared one', LockFile(First, FileLockExclusive or FileLockNoWait) = ErrorWouldBlock);
  CloseFile(Second);
  Check('closing the handle gives its lock up', LockFile(First, FileLockExclusive or FileLockNoWait) = ErrorNone);
  Check('a bad kind of lock is refused', LockFile(First, 7) = ErrorInvalidArgument);

  { A second program waits for the lock until it is given up. }
  Child := StartSelf(['--wait-lock', LockFolder]);
  Check('a program waits while the lock is held', (Child >= 0) and (EndOf(Child, 300) = -1));
  UnlockFile(First);
  Check('and gets it once it is given up', EndOf(Child, ChildTimeout) = 0);

  { A program ended while it waits. }
  LockFile(First, FileLockExclusive);
  Child := StartSelf(['--wait-lock', LockFolder]);
  SleepMilliseconds(200);
  TerminateProgram(QWord(ProcessIdOf(Child)), 143);
  Check('a waiting program can be ended', EndOf(Child, ChildTimeout) = 143);
  UnlockFile(First);
  Second := OpenFolder(LockFolder);
  Check('and leaves the lock free', LockFile(Second, FileLockExclusive or FileLockNoWait) = ErrorNone);
  CloseFile(Second);

  { A program that ends holding a lock gives it up. }
  Child := StartSelf(['--hold-lock', LockFolder]);
  Check('a program ends holding a lock', EndOf(Child, ChildTimeout) = 0);
  Check('its lock went with it', LockFile(First, FileLockExclusive or FileLockNoWait) = ErrorNone);
  CloseFile(First);
end;

{ --- Files ------------------------------------------------------------------------------------ }

function OpenScope: TSettings;
begin
  Result := TSettings.Create(TSettingsScope.Create(TFileSettingsStorage.Create(ScopeFolder, UserSettingsFileMode,
    UserSettingsFolderMode), True), nil);
end;

procedure WriteText(const Path, Text: string);
var
  Handle: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit;
  if Text <> '' then
    WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
end;

procedure TestFiles;
var
  Store: TSettings;
  Writers: array[1..WriterCount] of Int64;
  Index: Integer;
  Key: Integer;
  AllEnded: Boolean;
  AllThere: Boolean;
begin
  Store := OpenScope;
  Store.WriteString('Test/Name', 'a "quoted" value');
  Check('the first write makes the folder', (Store.Flush = ErrorNone) and IsDirectory(ScopeFolder));
  Check('a user''s folder is theirs alone (0700)', ModeOf(ScopeFolder) = $1C0);
  Check('and so are the files (0600)', ModeOf(ScopeFolder + '/Test.settings') = $180);
  Check('no new file is left behind', not PathExists(PChar(ScopeFolder + '/Test.settings.new')));
  Check('read back', Store.ReadString('Test/Name', '') = 'a "quoted" value');
  Store.Free;

  { What a crash between removing the old file and renaming the new one
    leaves: the new file only. }
  WriteText(ScopeFolder + '/Recover.settings.new', 'Value = 42'#10);
  Store := OpenScope;
  Check('a new file left by a crash is read', Store.ReadInteger('Recover/Value', 0) = 42);
  Store.WriteInteger('Recover/Other', 1);
  Store.Flush;
  Check('and put right by the next write', PathExists(PChar(ScopeFolder + '/Recover.settings')) and
    not PathExists(PChar(ScopeFolder + '/Recover.settings.new')) and (Store.ReadInteger('Recover/Value', 0) = 42));
  Store.Free;

  { Damaged files: what can be read is, the rest is kept. }
  WriteText(ScopeFolder + '/Damaged.settings', 'Good = 1'#10#1#2'garbage'#10);
  Store := OpenScope;
  Store.WriteInteger('Damaged/Added', 2);
  Check('a damaged file is read where it can be', (Store.ReadInteger('Damaged/Good', 0) = 1) and
    (Store.Flush = ErrorNone));
  Check('and written without losing its broken lines',
    Length(Store.Scopes[ScopeUser].Problems('Damaged')) = 1);
  Store.Free;

  { Several programs write to one group at once. }
  for Index := 1 to WriterCount do
    Writers[Index] := StartSelf(['--writer', IntToStr(Index), ScopeFolder, IntToStr(KeysPerWriter)]);
  AllEnded := True;
  for Index := 1 to WriterCount do
    if (Writers[Index] < 0) or (EndOf(Writers[Index], ChildTimeout) <> 0) then
      AllEnded := False;
  Check('writers at the same time end', AllEnded);
  Store := OpenScope;
  AllThere := True;
  for Index := 1 to WriterCount do
    for Key := 1 to KeysPerWriter do
      if Store.ReadInteger(Format('Shared/Writer%d/Key%d', [Index, Key]), 0) <> Index * 1000 + Key then
        AllThere := False;
  Check(Format('every change of %d writers kept (%d keys each)', [WriterCount, KeysPerWriter]), AllThere);
  Check('the file they wrote reads without problems', Length(Store.Scopes[ScopeUser].Problems('Shared')) = 0);
  Store.Free;
end;

{ --- The second programs ------------------------------------------------------------------- }

procedure WaitForLock(const Folder: string);
var
  Handle: Int64;
begin
  Handle := OpenFolder(Folder);
  if (Handle < 0) or (LockFile(Handle, FileLockExclusive) <> ErrorNone) then
    Halt(1);
  Halt(0);
end;

procedure HoldLock(const Folder: string);
var
  Handle: Int64;
begin
  Handle := OpenFolder(Folder);
  if (Handle < 0) or (LockFile(Handle, FileLockExclusive or FileLockNoWait) <> ErrorNone) then
    Halt(1);
  { Ends without giving it up. }
  Halt(0);
end;

procedure WriteKeys(Writer: Integer; const Folder: string; Count: Integer);
var
  Store: TSettings;
  Key: Integer;
begin
  Store := TSettings.Create(TSettingsScope.Create(TFileSettingsStorage.Create(Folder, UserSettingsFileMode,
    UserSettingsFolderMode), True), nil);
  for Key := 1 to Count do
  begin
    Store.WriteInteger(Format('Shared/Writer%d/Key%d', [Writer, Key]), Writer * 1000 + Key);
    if Store.Flush <> ErrorNone then
      Halt(1);
  end;
  Store.Free;
  Halt(0);
end;

procedure PrepareWorkFolder;
begin
  CreateDirectory(WorkFolder);
  CreateDirectory(LockFolder);
end;

begin
  if ParamStr(1) = '--wait-lock' then
    WaitForLock(ParamStr(2));
  if ParamStr(1) = '--hold-lock' then
    HoldLock(ParamStr(2));
  if ParamStr(1) = '--writer' then
    WriteKeys(StrToInt(ParamStr(2)), ParamStr(3), StrToInt(ParamStr(4)));
  PrepareWorkFolder;
  TestLocks;
  TestFiles;
  WriteString(StandardOutput, Format('settingstest: %d of %d checks passed'#10, [Checks - Failures,
    Checks]));
  FlushStream(StandardOutput);
  if Failures > 0 then
    Halt(1);
end.
