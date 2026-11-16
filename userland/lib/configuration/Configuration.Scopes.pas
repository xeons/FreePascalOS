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
  One scope of settings - a user's, or the system's - over its storage.

  Reading: a group is read when it is first wanted and kept as a
  document; every later read first asks the storage for the group's
  version (a look at the file, no reading) and reads the group again if
  it changed. So a program always sees what was last written, by itself
  or anyone else, without being told.

  Writing: changes are made to the kept document at once (the program
  reads its own changes back) and remembered as a list. Flush hands them
  to the storage, group by group: under the storage's lock it reads the
  group's latest text, makes the remembered changes to that, and writes
  the result. Two programs that change a group at the same time thus
  keep both changes (the second one's lock waits for the first one's
  write), and a crash between two flushes loses only what was not
  flushed. A group whose last key goes is removed.

  Changes made by others: CheckForChanges compares the version of every
  group read so far with the storage's, and names those that changed.
  The settings watcher (Configuration.Watcher) does better: it compares
  the values themselves, as soon as a folder watch reports a file.
}
unit Configuration.Scopes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Values,
  Configuration.Names,
  Configuration.Documents,
  Configuration.Storage;

type
  TPendingChangeKind = (ChangeSetValue, ChangeDeleteValue, ChangeDeleteSection);

  TPendingChange = record
    Kind: TPendingChangeKind;
    Section: string;
    Key: string;
    Value: TSettingValue;
    Fixed: Boolean;
  end;

  { A group as read, with the changes not flushed yet made to it. }
  TGroupState = class
  public
    Group: string;
    Loaded: Boolean;
    Version: TSettingsVersion;
    ReadError: LongInt;
    Document: TSettingsDocument;
    Pending: array of TPendingChange;
    constructor Create(const GroupName: string);
    destructor Destroy; override;
  end;

  TSettingsScope = class
  private
    FStorage: TSettingsStorage;
    FOwnsStorage: Boolean;
    FGroups: array of TGroupState;
    function FindGroup(const Group: string): TGroupState;
    function GroupState(const Group: string): TGroupState;
    procedure Load(State: TGroupState);
    procedure Refresh(State: TGroupState);
    procedure AddChange(const Group: string; const Change: TPendingChange);
    function FlushGroup(State: TGroupState): LongInt;
  public
    constructor Create(Storage: TSettingsStorage; OwnsStorage: Boolean);
    destructor Destroy; override;

    { Path's value (Path names a key); False if it has none. }
    function GetValue(const Path: TSettingsPath; out Value: TSettingValue; out Fixed: Boolean): Boolean;
    procedure SetValue(const Path: TSettingsPath; const Value: TSettingValue; Fixed: Boolean);
    { Path names a key, a section or a whole group. }
    procedure Delete(const Path: TSettingsPath);
    { The keys of the group or section Path names. }
    function ListKeys(const Path: TSettingsPath): TStringArray;
    { The sections below the group or section Path names; with no group,
      the groups there are. }
    function ListSections(const Path: TSettingsPath): TStringArray;
    { Lines of the group that could not be read ("line N: TEXT"). }
    function Problems(const Group: string): TStringArray;
    { The error reading Group met (ErrorNone if it was read or has no
      text yet). }
    function ReadError(const Group: string): LongInt;

    { Writes the changes; the first error, or ErrorNone. Changes that
      could not be written are dropped (the groups are read again). }
    function Flush: LongInt;
    function HasPendingChanges: Boolean;
    { The groups read so far whose text changed since. }
    function CheckForChanges: TStringArray;

    property Storage: TSettingsStorage read FStorage;
  end;

implementation

uses
  Abi.SystemCalls;

constructor TGroupState.Create(const GroupName: string);
begin
  inherited Create;
  Group := GroupName;
  Document := TSettingsDocument.Create;
end;

destructor TGroupState.Destroy;
begin
  Document.Free;
  inherited Destroy;
end;

function ContainsName(const Names: TStringArray; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] = Name then
      Exit(True);
  Result := False;
end;

procedure ApplyChange(Document: TSettingsDocument; const Change: TPendingChange);
begin
  case Change.Kind of
    ChangeSetValue: Document.SetValue(Change.Section, Change.Key, Change.Value, Change.Fixed);
    ChangeDeleteValue: Document.DeleteValue(Change.Section, Change.Key);
    ChangeDeleteSection: Document.DeleteSection(Change.Section);
  end;
end;

procedure ApplyChanges(Document: TSettingsDocument; State: TGroupState);
var
  Index: Integer;
begin
  for Index := 0 to High(State.Pending) do
    ApplyChange(Document, State.Pending[Index]);
end;

constructor TSettingsScope.Create(Storage: TSettingsStorage; OwnsStorage: Boolean);
begin
  inherited Create;
  FStorage := Storage;
  FOwnsStorage := OwnsStorage;
end;

destructor TSettingsScope.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    FGroups[Index].Free;
  if FOwnsStorage then
    FStorage.Free;
  inherited Destroy;
end;

function TSettingsScope.FindGroup(const Group: string): TGroupState;
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    if FGroups[Index].Group = Group then
      Exit(FGroups[Index]);
  Result := nil;
end;

function TSettingsScope.GroupState(const Group: string): TGroupState;
begin
  Result := FindGroup(Group);
  if Result <> nil then
    Exit;
  Result := TGroupState.Create(Group);
  SetLength(FGroups, Length(FGroups) + 1);
  FGroups[High(FGroups)] := Result;
end;

procedure TSettingsScope.Load(State: TGroupState);
var
  Text: string;
  Error: LongInt;
begin
  Error := FStorage.ReadGroup(State.Group, Text, State.Version);
  if Error = ErrorNotFound then
  begin
    Error := ErrorNone;
    Text := '';
    State.Version := Default(TSettingsVersion);
  end;
  if Error <> ErrorNone then
  begin
    { Unreadable (another user's settings, say) is the same as empty. }
    Text := '';
    State.Version := Default(TSettingsVersion);
  end;
  State.ReadError := Error;
  State.Document.Parse(Text);
  ApplyChanges(State.Document, State);
  State.Loaded := True;
end;

procedure TSettingsScope.Refresh(State: TGroupState);
var
  Version: TSettingsVersion;
begin
  if State.Loaded and (FStorage.ReadVersion(State.Group, Version) = ErrorNone) and
     SameSettingsVersion(Version, State.Version) then
    Exit;
  Load(State);
end;

function TSettingsScope.GetValue(const Path: TSettingsPath; out Value: TSettingValue; out Fixed: Boolean): Boolean;
var
  State: TGroupState;
begin
  State := GroupState(Path.Group);
  Refresh(State);
  Result := State.Document.GetValue(Path.Section, Path.Key, Value, Fixed);
end;

procedure TSettingsScope.AddChange(const Group: string; const Change: TPendingChange);
var
  State: TGroupState;
begin
  State := GroupState(Group);
  Refresh(State);
  SetLength(State.Pending, Length(State.Pending) + 1);
  State.Pending[High(State.Pending)] := Change;
  ApplyChange(State.Document, Change);
end;

procedure TSettingsScope.SetValue(const Path: TSettingsPath; const Value: TSettingValue; Fixed: Boolean);
var
  Change: TPendingChange;
begin
  Change := Default(TPendingChange);
  Change.Kind := ChangeSetValue;
  Change.Section := Path.Section;
  Change.Key := Path.Key;
  Change.Value := Value;
  Change.Fixed := Fixed;
  AddChange(Path.Group, Change);
end;

procedure TSettingsScope.Delete(const Path: TSettingsPath);
var
  Change: TPendingChange;
begin
  Change := Default(TPendingChange);
  if Path.Key <> '' then
    Change.Kind := ChangeDeleteValue
  else
    Change.Kind := ChangeDeleteSection;
  Change.Section := Path.Section;
  Change.Key := Path.Key;
  AddChange(Path.Group, Change);
end;

function TSettingsScope.ListKeys(const Path: TSettingsPath): TStringArray;
var
  State: TGroupState;
begin
  State := GroupState(Path.Group);
  Refresh(State);
  Result := State.Document.ListKeys(Path.Section);
end;

function TSettingsScope.ListSections(const Path: TSettingsPath): TStringArray;
var
  State: TGroupState;
  Index: Integer;
  Stored: TStringArray;
begin
  if Path.Group <> '' then
  begin
    State := GroupState(Path.Group);
    Refresh(State);
    Exit(State.Document.ListSections(Path.Section));
  end;
  { Every group the storage has, and those only changed here so far. }
  Result := nil;
  if FStorage.ListGroups(Stored) <> ErrorNone then
    Stored := nil;
  for Index := 0 to High(Stored) do
  begin
    State := GroupState(Stored[Index]);
    Refresh(State);
    if not State.Document.HasNoKeys then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Stored[Index];
    end;
  end;
  for Index := 0 to High(FGroups) do
  begin
    State := FGroups[Index];
    if (Length(State.Pending) = 0) or ContainsName(Result, State.Group) then
      Continue;
    Refresh(State);
    if not State.Document.HasNoKeys then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := State.Group;
    end;
  end;
end;

function TSettingsScope.Problems(const Group: string): TStringArray;
var
  State: TGroupState;
begin
  State := GroupState(Group);
  Refresh(State);
  Result := State.Document.Problems;
end;

function TSettingsScope.ReadError(const Group: string): LongInt;
var
  State: TGroupState;
begin
  State := GroupState(Group);
  Refresh(State);
  Result := State.ReadError;
end;

function TSettingsScope.FlushGroup(State: TGroupState): LongInt;
var
  Latest: TSettingsDocument;
  Text: string;
  Version: TSettingsVersion;
  Changed: string;
begin
  Result := FStorage.Lock;
  if Result <> ErrorNone then
    Exit;
  Latest := TSettingsDocument.Create;
  try
    Result := FStorage.ReadGroup(State.Group, Text, Version);
    if Result = ErrorNotFound then
    begin
      Text := '';
      Result := ErrorNone;
    end;
    { A group that cannot be read is not written over: whatever is in it
      would be lost. }
    if Result = ErrorNone then
    begin
      Latest.Parse(Text);
      ApplyChanges(Latest, State);
      Changed := Latest.Serialize;
      if Latest.LineCount = 0 then
        Result := FStorage.RemoveGroup(State.Group)
      else if Changed <> Text then
        Result := FStorage.WriteGroup(State.Group, Changed);
    end;
  finally
    Latest.Free;
    FStorage.Unlock;
  end;
end;

function TSettingsScope.Flush: LongInt;
var
  Index: Integer;
  Error: LongInt;
begin
  Result := ErrorNone;
  for Index := 0 to High(FGroups) do
  begin
    if Length(FGroups[Index].Pending) = 0 then
      Continue;
    Error := FlushGroup(FGroups[Index]);
    if (Error <> ErrorNone) and (Result = ErrorNone) then
      Result := Error;
    FGroups[Index].Pending := nil;
    FGroups[Index].Loaded := False;
  end;
end;

function TSettingsScope.HasPendingChanges: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    if Length(FGroups[Index].Pending) > 0 then
      Exit(True);
  Result := False;
end;

function TSettingsScope.CheckForChanges: TStringArray;
var
  Index: Integer;
  Version: TSettingsVersion;
begin
  Result := nil;
  for Index := 0 to High(FGroups) do
  begin
    if not FGroups[Index].Loaded then
      Continue;
    if (FStorage.ReadVersion(FGroups[Index].Group, Version) = ErrorNone) and
       SameSettingsVersion(Version, FGroups[Index].Version) then
      Continue;
    FGroups[Index].Loaded := False;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := FGroups[Index].Group;
  end;
end;

end.
