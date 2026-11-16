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
  Deciding which groups of settings changed, and when to say so: the
  part of the settings watcher (Configuration.Watcher) that needs no
  kernel, so it is tested on the host.

  The tracker keeps a snapshot (Configuration.Changes) of every group it
  watches. It is told of files changing in either scope's folder by
  name; GROUP.settings and GROUP.settings.new are a group's (a safe
  write makes the .new file, writes it and renames it over the other,
  which shows as a burst of changes to both names), anything else is
  not. A change marks the group; a burst of changes is waited out, and
  once it is over (QuietMilliseconds without a change, or at most
  LongestDelayMilliseconds after its first change, so a stream of writes
  is not waited out for ever) every marked group is read again and its
  new snapshot compared with the old. OnChanged is called with the keys
  that differ; a group whose values are the same as before (written
  again unchanged, a comment edited) is not reported.

  Time is the caller's: the tracker is told the time with every call
  (milliseconds, any steady clock).
}
unit Configuration.ChangeTracker;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Changes,
  Configuration.Settings;

const
  QuietMilliseconds = 60;
  LongestDelayMilliseconds = 300;
  NoDeadline = High(QWord);

type
  { Changes is never empty. }
  TSettingsGroupChangedEvent = procedure(const Group: string; const Changes: TSettingChanges) of object;

  TWatchedGroup = record
    Name: string;
    Snapshot: TSettingsSnapshot;
    Marked: Boolean;
  end;

  TSettingsChangeTracker = class
  private
    FSettings: TSettings;
    FOwnsSettings: Boolean;
    FGroups: array of TWatchedGroup;
    FBurstStart: QWord;
    FLastChange: QWord;
    FBurstGoing: Boolean;
    FOnChanged: TSettingsGroupChangedEvent;
    function IndexOf(const Group: string): Integer;
    procedure MarkGroup(Index: Integer; Now: QWord);
  public
    { Reads through Settings (a TSettings of its own, not one the
      program writes through: changes not flushed would count). }
    constructor Create(Settings: TSettings; OwnsSettings: Boolean);
    destructor Destroy; override;

    { Starts watching Group (its present values are the snapshot). }
    procedure Watch(const Group: string);
    procedure Unwatch(const Group: string);
    function IsWatching(const Group: string): Boolean;
    function WatchedGroups: TStringArray;

    { A file of this name changed in a scope's folder. }
    procedure NoteFileChanged(const FileName: string; Now: QWord);
    { Anything may have changed (changes were lost, a folder appeared). }
    procedure NoteEverythingChanged(Now: QWord);

    { A burst of changes is being waited out. }
    function HasPendingChanges: Boolean;
    { When Collect should next be called (NoDeadline if nothing waits). }
    function Deadline: QWord;
    { If the burst is over, reads the marked groups again and calls
      OnChanged for each one whose values changed; how many were. }
    function Collect(Now: QWord): Integer;
    { The same at once, every watched group (for a program that looks
      now and then instead of watching). }
    function CollectEverything: Integer;

    property Settings: TSettings read FSettings;
    property OnChanged: TSettingsGroupChangedEvent read FOnChanged write FOnChanged;
  end;

{ The group a file in a settings folder holds ('' if none). }
function GroupOfSettingsFile(const FileName: string): string;

implementation

uses
  Configuration.Names;

const
  SettingsSuffix = '.settings';
  NewSettingsSuffix = '.settings.new';

function EndsWith(const Text, Suffix: string): Boolean;
begin
  Result := (Length(Text) > Length(Suffix)) and
    (Copy(Text, Length(Text) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

function GroupOfSettingsFile(const FileName: string): string;
begin
  Result := '';
  if EndsWith(FileName, NewSettingsSuffix) then
    Result := Copy(FileName, 1, Length(FileName) - Length(NewSettingsSuffix))
  else if EndsWith(FileName, SettingsSuffix) then
    Result := Copy(FileName, 1, Length(FileName) - Length(SettingsSuffix));
  if not IsSettingsName(Result) then
    Result := '';
end;

constructor TSettingsChangeTracker.Create(Settings: TSettings; OwnsSettings: Boolean);
begin
  inherited Create;
  FSettings := Settings;
  FOwnsSettings := OwnsSettings;
end;

destructor TSettingsChangeTracker.Destroy;
begin
  if FOwnsSettings then
    FSettings.Free;
  inherited Destroy;
end;

function TSettingsChangeTracker.IndexOf(const Group: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    if FGroups[Index].Name = Group then
      Exit(Index);
  Result := -1;
end;

procedure TSettingsChangeTracker.Watch(const Group: string);
var
  Index: Integer;
begin
  if not IsSettingsName(Group) or (IndexOf(Group) >= 0) then
    Exit;
  Index := Length(FGroups);
  SetLength(FGroups, Index + 1);
  FGroups[Index].Name := Group;
  FGroups[Index].Snapshot := TakeGroupSnapshot(FSettings, Group);
  FGroups[Index].Marked := False;
end;

procedure TSettingsChangeTracker.Unwatch(const Group: string);
var
  Index: Integer;
begin
  Index := IndexOf(Group);
  if Index < 0 then
    Exit;
  while Index < High(FGroups) do
  begin
    FGroups[Index] := FGroups[Index + 1];
    Inc(Index);
  end;
  SetLength(FGroups, Length(FGroups) - 1);
end;

function TSettingsChangeTracker.IsWatching(const Group: string): Boolean;
begin
  Result := IndexOf(Group) >= 0;
end;

function TSettingsChangeTracker.WatchedGroups: TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FGroups));
  for Index := 0 to High(FGroups) do
    Result[Index] := FGroups[Index].Name;
end;

procedure TSettingsChangeTracker.MarkGroup(Index: Integer; Now: QWord);
begin
  FGroups[Index].Marked := True;
  if not FBurstGoing then
  begin
    FBurstGoing := True;
    FBurstStart := Now;
  end;
  FLastChange := Now;
end;

procedure TSettingsChangeTracker.NoteFileChanged(const FileName: string; Now: QWord);
var
  Index: Integer;
begin
  Index := IndexOf(GroupOfSettingsFile(FileName));
  if Index >= 0 then
    MarkGroup(Index, Now);
end;

procedure TSettingsChangeTracker.NoteEverythingChanged(Now: QWord);
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    MarkGroup(Index, Now);
end;

function TSettingsChangeTracker.HasPendingChanges: Boolean;
begin
  Result := FBurstGoing;
end;

function TSettingsChangeTracker.Deadline: QWord;
var
  Quiet: QWord;
  Longest: QWord;
begin
  if not FBurstGoing then
    Exit(NoDeadline);
  Quiet := FLastChange + QuietMilliseconds;
  Longest := FBurstStart + LongestDelayMilliseconds;
  if Quiet < Longest then
    Result := Quiet
  else
    Result := Longest;
end;

function TSettingsChangeTracker.Collect(Now: QWord): Integer;
var
  Index: Integer;
  Fresh: TSettingsSnapshot;
  Changes: TSettingChanges;
  Group: string;
  Reported: TStringArray;
  ChangesOf: array of TSettingChanges;
begin
  Result := 0;
  if not FBurstGoing or (Now < Deadline) then
    Exit;
  FBurstGoing := False;
  { Every snapshot is taken before any handler runs: a handler may watch
    or unwatch groups. }
  Reported := nil;
  ChangesOf := nil;
  for Index := 0 to High(FGroups) do
  begin
    if not FGroups[Index].Marked then
      Continue;
    FGroups[Index].Marked := False;
    Fresh := TakeGroupSnapshot(FSettings, FGroups[Index].Name);
    Changes := CompareSnapshots(FGroups[Index].Snapshot, Fresh);
    FGroups[Index].Snapshot := Fresh;
    if Length(Changes) = 0 then
      Continue;
    SetLength(Reported, Length(Reported) + 1);
    Reported[High(Reported)] := FGroups[Index].Name;
    SetLength(ChangesOf, Length(ChangesOf) + 1);
    ChangesOf[High(ChangesOf)] := Changes;
  end;
  Result := Length(Reported);
  if not Assigned(FOnChanged) then
    Exit;
  for Index := 0 to High(Reported) do
  begin
    Group := Reported[Index];
    FOnChanged(Group, ChangesOf[Index]);
  end;
end;

function TSettingsChangeTracker.CollectEverything: Integer;
begin
  NoteEverythingChanged(0);
  FBurstStart := 0;
  FLastChange := 0;
  Result := Collect(NoDeadline - 1);
end;

end.
