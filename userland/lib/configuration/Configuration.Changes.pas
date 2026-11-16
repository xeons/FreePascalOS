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
  What a group of settings is at one moment, and what changed between
  two such moments.

  A snapshot holds every key of a group as a program sees it: the value
  that wins (the system's when it is fixed, else the user's, else the
  system's) and whether it is fixed. Comparing two snapshots gives the
  keys whose value or fixedness differs - a key that appeared, went
  away, or changed. Which scope a value comes from does not count: a
  user writing the value the system already gives changes nothing a
  program sees, and neither does a comment, a reordering, or a file
  written again with the same values.
}
unit Configuration.Changes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Values,
  Configuration.Settings;

type
  TSettingEntry = record
    { The whole path: GROUP/KEY or GROUP/SECTION.../KEY. }
    Path: string;
    Value: TSettingValue;
    Fixed: Boolean;
  end;

  { Sorted by path. }
  TSettingsSnapshot = array of TSettingEntry;

  TSettingChangeKind = (SettingAdded, SettingRemoved, SettingModified);

  TSettingChange = record
    Kind: TSettingChangeKind;
    Path: string;
    { Meaningful unless Kind is SettingAdded. }
    OldValue: TSettingValue;
    OldFixed: Boolean;
    { Meaningful unless Kind is SettingRemoved. }
    NewValue: TSettingValue;
    NewFixed: Boolean;
  end;

  TSettingChanges = array of TSettingChange;

{ Every key of Group as Settings shows it now. }
function TakeGroupSnapshot(Settings: TSettings; const Group: string): TSettingsSnapshot;
{ What differs from Before to After, by path. }
function CompareSnapshots(const Before, After: TSettingsSnapshot): TSettingChanges;

{ True if Changes has Path (GROUP/KEY), or a key below it when Path names
  a section or group. }
function ChangesInclude(const Changes: TSettingChanges; const Path: string): Boolean;
{ "Group/Key = 5 (was 3)", "Group/Key = fixed true (was not set)",
  "Group/Key removed (was 3)". }
function DescribeSettingChange(const Change: TSettingChange): string;

implementation

uses
  Configuration.Names;

procedure AddEntry(var Snapshot: TSettingsSnapshot; Settings: TSettings; const Path: string);
var
  Entry: TSettingEntry;
  Source: TSettingsScopeKind;
begin
  if not Settings.Lookup(Path, Entry.Value, Source) then
    Exit;
  Entry.Path := Path;
  Entry.Fixed := (Source = ScopeSystem) and Settings.IsFixed(Path);
  SetLength(Snapshot, Length(Snapshot) + 1);
  Snapshot[High(Snapshot)] := Entry;
end;

procedure AddSection(var Snapshot: TSettingsSnapshot; Settings: TSettings; const SectionPath: string);
var
  Keys: TStringArray;
  Sections: TStringArray;
  Index: Integer;
begin
  Keys := Settings.ListKeys(SectionPath);
  for Index := 0 to High(Keys) do
    AddEntry(Snapshot, Settings, SectionPath + SettingsPathSeparator + Keys[Index]);
  Sections := Settings.ListSections(SectionPath);
  for Index := 0 to High(Sections) do
    AddSection(Snapshot, Settings, SectionPath + SettingsPathSeparator + Sections[Index]);
end;

procedure SortByPath(var Snapshot: TSettingsSnapshot);
var
  Index: Integer;
  Place: Integer;
  Moving: TSettingEntry;
begin
  { Insertion sort: a group has a handful of keys. }
  Index := 1;
  while Index < Length(Snapshot) do
  begin
    Moving := Snapshot[Index];
    Place := Index;
    while (Place > 0) and (CompareStr(Snapshot[Place - 1].Path, Moving.Path) > 0) do
    begin
      Snapshot[Place] := Snapshot[Place - 1];
      Dec(Place);
    end;
    Snapshot[Place] := Moving;
    Inc(Index);
  end;
end;

function TakeGroupSnapshot(Settings: TSettings; const Group: string): TSettingsSnapshot;
begin
  Result := nil;
  if not IsSettingsName(Group) then
    Exit;
  AddSection(Result, Settings, Group);
  SortByPath(Result);
end;

procedure AddChange(var Changes: TSettingChanges; const Change: TSettingChange);
begin
  SetLength(Changes, Length(Changes) + 1);
  Changes[High(Changes)] := Change;
end;

procedure AddRemoved(var Changes: TSettingChanges; const Entry: TSettingEntry);
var
  Change: TSettingChange;
begin
  Change := Default(TSettingChange);
  Change.Kind := SettingRemoved;
  Change.Path := Entry.Path;
  Change.OldValue := Entry.Value;
  Change.OldFixed := Entry.Fixed;
  AddChange(Changes, Change);
end;

procedure AddAdded(var Changes: TSettingChanges; const Entry: TSettingEntry);
var
  Change: TSettingChange;
begin
  Change := Default(TSettingChange);
  Change.Kind := SettingAdded;
  Change.Path := Entry.Path;
  Change.NewValue := Entry.Value;
  Change.NewFixed := Entry.Fixed;
  AddChange(Changes, Change);
end;

procedure AddModifiedIfDifferent(var Changes: TSettingChanges; const Before, After: TSettingEntry);
var
  Change: TSettingChange;
begin
  if SameSettingValue(Before.Value, After.Value) and (Before.Fixed = After.Fixed) then
    Exit;
  Change := Default(TSettingChange);
  Change.Kind := SettingModified;
  Change.Path := After.Path;
  Change.OldValue := Before.Value;
  Change.OldFixed := Before.Fixed;
  Change.NewValue := After.Value;
  Change.NewFixed := After.Fixed;
  AddChange(Changes, Change);
end;

function CompareSnapshots(const Before, After: TSettingsSnapshot): TSettingChanges;
var
  BeforeIndex: Integer;
  AfterIndex: Integer;
  Order: Integer;
begin
  Result := nil;
  BeforeIndex := 0;
  AfterIndex := 0;
  { Both are sorted: walk them side by side. }
  while (BeforeIndex < Length(Before)) or (AfterIndex < Length(After)) do
  begin
    if BeforeIndex >= Length(Before) then
      Order := 1
    else if AfterIndex >= Length(After) then
      Order := -1
    else
      Order := CompareStr(Before[BeforeIndex].Path, After[AfterIndex].Path);
    if Order < 0 then
    begin
      AddRemoved(Result, Before[BeforeIndex]);
      Inc(BeforeIndex);
    end
    else if Order > 0 then
    begin
      AddAdded(Result, After[AfterIndex]);
      Inc(AfterIndex);
    end
    else
    begin
      AddModifiedIfDifferent(Result, Before[BeforeIndex], After[AfterIndex]);
      Inc(BeforeIndex);
      Inc(AfterIndex);
    end;
  end;
end;

function ChangesInclude(const Changes: TSettingChanges; const Path: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Changes) do
    if (Changes[Index].Path = Path) or
       (Copy(Changes[Index].Path, 1, Length(Path) + 1) = Path + SettingsPathSeparator) then
      Exit(True);
  Result := False;
end;

function ValueText(const Value: TSettingValue; Fixed: Boolean): string;
begin
  Result := FormatSettingValue(Value);
  if Fixed then
    Result := 'fixed ' + Result;
end;

function DescribeSettingChange(const Change: TSettingChange): string;
begin
  case Change.Kind of
    SettingAdded:
      Result := Change.Path + ' = ' + ValueText(Change.NewValue, Change.NewFixed) + ' (was not set)';
    SettingRemoved:
      Result := Change.Path + ' removed (was ' + ValueText(Change.OldValue, Change.OldFixed) + ')';
  else
    Result := Change.Path + ' = ' + ValueText(Change.NewValue, Change.NewFixed) + ' (was ' +
      ValueText(Change.OldValue, Change.OldFixed) + ')';
  end;
end;

end.
