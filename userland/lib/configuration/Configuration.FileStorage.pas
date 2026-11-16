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
  A scope's settings as files in a folder: GROUP.settings for each group.

  Writing a group never leaves a half-written file. The new text goes
  into GROUP.settings.new, which is then renamed over GROUP.settings.
  Renaming is one step for every other program (the volume's lock is
  held throughout), and on ext3/ext4 the removal of the old file and the
  new name are one journal transaction, committed after the new file's
  data is on the disk: after a crash there is the old file or the new
  one. On FAT, exFAT and ext2 a crash between the removal and the
  rename can leave only GROUP.settings.new; it is complete (it was
  written before the rename began), so it is read in place of the
  missing file, and the next write puts it right.

  The writers' lock is an exclusive advisory lock on the folder itself
  (ControlLockFile on a handle of it), which needs write permission on
  it - that is, permission to write settings there at all - so readers
  can never hold writers up. The lock goes with the handle, so a writer
  that crashes leaves no stale lock behind. Readers take no lock: they
  see one version of a file or the next.

  New files get FileMode and the folder, made when the first group is
  written, FolderMode: a user's settings are theirs alone (0600, 0700);
  the system's are readable by all and written by root (0644, 0755).
  Files larger than MaximumSettingsFileSize are taken for damaged: they
  are not read, and not written over (ErrorCorrupted), but can be
  removed.
}
unit Configuration.FileStorage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Storage;

const
  SettingsFileSuffix = '.settings';
  SettingsNewFileSuffix = '.new';
  MaximumSettingsFileSize = 1024 * 1024;

type
  TFileSettingsStorage = class(TSettingsStorage)
  private
    FFolder: string;
    FFileMode: LongWord;
    FFolderMode: LongWord;
    FLockHandle: Int64;
    function GroupFile(const Group: string): string;
    function NewGroupFile(const Group: string): string;
    function MakeFolder: LongInt;
    function ReadFileText(const Path: string; out Text: string; out Version: TSettingsVersion): LongInt;
  public
    constructor Create(const Folder: string; FileMode, FolderMode: LongWord);
    destructor Destroy; override;
    function ReadGroup(const Group: string; out Text: string; out Version: TSettingsVersion): LongInt; override;
    function ReadVersion(const Group: string; out Version: TSettingsVersion): LongInt; override;
    function WriteGroup(const Group, Text: string): LongInt; override;
    function RemoveGroup(const Group: string): LongInt; override;
    function ListGroups(out Groups: TStringArray): LongInt; override;
    function Lock: LongInt; override;
    procedure Unlock; override;
    function Location: string; override;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Configuration.Names;

const
  NoHandle = -1;

procedure DescribeVersion(const Information: TFileInformation; out Version: TSettingsVersion);
begin
  Version := Default(TSettingsVersion);
  Version.Exists := True;
  Version.NodeNumber := Information.NodeNumber;
  Version.Size := Information.SizeInBytes;
  Version.ModificationTime := Information.ModificationTime;
end;

constructor TFileSettingsStorage.Create(const Folder: string; FileMode, FolderMode: LongWord);
begin
  inherited Create;
  FFolder := Folder;
  FFileMode := FileMode;
  FFolderMode := FolderMode;
  FLockHandle := NoHandle;
end;

destructor TFileSettingsStorage.Destroy;
begin
  Unlock;
  inherited Destroy;
end;

function TFileSettingsStorage.Location: string;
begin
  Result := FFolder;
end;

function TFileSettingsStorage.GroupFile(const Group: string): string;
begin
  Result := FFolder + '/' + Group + SettingsFileSuffix;
end;

function TFileSettingsStorage.NewGroupFile(const Group: string): string;
begin
  Result := GroupFile(Group) + SettingsNewFileSuffix;
end;

function TFileSettingsStorage.ReadFileText(const Path: string; out Text: string;
  out Version: TSettingsVersion): LongInt;
var
  Handle: Int64;
  Information: TFileInformation;
  Count: Int64;
  Done: QWord;
begin
  Text := '';
  Version := Default(TSettingsVersion);
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Result := GetHandleInformation(Handle, Information);
  if (Result = ErrorNone) and (Information.Kind <> KindFile) then
    Result := ErrorIsDirectory;
  if (Result = ErrorNone) and (Information.SizeInBytes > MaximumSettingsFileSize) then
    Result := ErrorCorrupted;
  if Result = ErrorNone then
  begin
    DescribeVersion(Information, Version);
    SetLength(Text, Information.SizeInBytes);
    Done := 0;
    while Done < Information.SizeInBytes do
    begin
      Count := ReadFile(Handle, @Text[Done + 1], Information.SizeInBytes - Done);
      if Count < 0 then
      begin
        Result := LongInt(-Count);
        Break;
      end;
      if Count = 0 then
        Break;
      Done := Done + QWord(Count);
    end;
    SetLength(Text, Done);
  end;
  CloseFile(Handle);
end;

function TFileSettingsStorage.ReadGroup(const Group: string; out Text: string;
  out Version: TSettingsVersion): LongInt;
begin
  Result := ReadFileText(GroupFile(Group), Text, Version);
  { What a crash in the middle of a rename leaves (see above). }
  if Result = ErrorNotFound then
    Result := ReadFileText(NewGroupFile(Group), Text, Version);
end;

function TFileSettingsStorage.ReadVersion(const Group: string; out Version: TSettingsVersion): LongInt;
var
  Information: TFileInformation;
begin
  Version := Default(TSettingsVersion);
  Result := GetFileInformation(PChar(GroupFile(Group)), Information);
  if Result = ErrorNotFound then
    Result := GetFileInformation(PChar(NewGroupFile(Group)), Information);
  if Result = ErrorNone then
    DescribeVersion(Information, Version)
  else if Result = ErrorNotFound then
    Result := ErrorNone;
end;

function TFileSettingsStorage.MakeFolder: LongInt;
begin
  if IsDirectory(PChar(FFolder)) then
    Exit(ErrorNone);
  Result := CreateDirectory(PChar(FFolder));
  if Result = ErrorExists then
    Exit(ErrorNone);
  if Result = ErrorNone then
    Result := ChangeMode(PChar(FFolder), FFolderMode);
end;

function TFileSettingsStorage.WriteGroup(const Group, Text: string): LongInt;
var
  NewFile: string;
  Handle: Int64;
begin
  Result := MakeFolder;
  if Result <> ErrorNone then
    Exit;
  NewFile := NewGroupFile(Group);
  Handle := OpenFile(PChar(NewFile), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  { The mode before the text, so it is never readable by others. }
  Result := ChangeMode(PChar(NewFile), FFileMode);
  if (Result = ErrorNone) and (Text <> '') then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
  if Result = ErrorNone then
    Result := RenamePath(PChar(NewFile), PChar(GroupFile(Group)));
  if Result <> ErrorNone then
    RemovePath(PChar(NewFile));
end;

function TFileSettingsStorage.RemoveGroup(const Group: string): LongInt;
begin
  Result := RemovePath(PChar(GroupFile(Group)));
  if Result = ErrorNotFound then
    Result := ErrorNone;
  RemovePath(PChar(NewGroupFile(Group)));
end;

function TFileSettingsStorage.ListGroups(out Groups: TStringArray): LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
begin
  Groups := nil;
  Handle := OpenFile(PChar(FFolder), OpenRead);
  if Handle < 0 then
  begin
    Result := LongInt(-Handle);
    if Result = ErrorNotFound then
      Result := ErrorNone;
    Exit;
  end;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := PChar(@Entry.Name[0]);
    if (Entry.Kind <> KindFile) or (Length(Name) <= Length(SettingsFileSuffix)) or
       (Copy(Name, Length(Name) - Length(SettingsFileSuffix) + 1, Length(SettingsFileSuffix)) <> SettingsFileSuffix) then
      Continue;
    Name := Copy(Name, 1, Length(Name) - Length(SettingsFileSuffix));
    if not IsSettingsName(Name) then
      Continue;
    SetLength(Groups, Length(Groups) + 1);
    Groups[High(Groups)] := Name;
  end;
  CloseFile(Handle);
  Result := ErrorNone;
end;

function TFileSettingsStorage.Lock: LongInt;
var
  Handle: Int64;
begin
  if FLockHandle <> NoHandle then
    Exit(ErrorNone);
  Result := MakeFolder;
  if Result <> ErrorNone then
    Exit;
  Handle := OpenFile(PChar(FFolder), OpenRead);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Result := LockFile(Handle, FileLockExclusive);
  if Result <> ErrorNone then
  begin
    CloseFile(Handle);
    Exit;
  end;
  FLockHandle := Handle;
end;

procedure TFileSettingsStorage.Unlock;
begin
  if FLockHandle = NoHandle then
    Exit;
  { Closing the only handle gives the lock up. }
  CloseFile(FLockHandle);
  FLockHandle := NoHandle;
end;

end.
