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
  Settings change notification on the host (Configuration.Changes,
  Configuration.ChangeTracker): snapshots of a group compared - keys
  added, removed and changed, a value becoming fixed, a user's value the
  same as the system's, a file written again unchanged - and the
  tracker over storages in memory, told of file changes as the folder
  watches tell them: the files of a safe write (GROUP.settings.new made,
  written, renamed over GROUP.settings) heard as one change, a burst
  waited out (but not for ever), groups not watched and other files
  ignored, a rewrite that changes nothing silent, a group removed.
}
unit SettingsTest.Changes;

{$mode objfpc}
{$H+}

interface

uses
  SettingsTest.Network;

procedure TestChangeDetection(Check: TCheckProcedure);

implementation

uses
  SysUtils,
  Configuration.Values,
  Configuration.Scopes,
  Configuration.Settings,
  Configuration.Changes,
  Configuration.ChangeTracker,
  SettingsTest.MemoryStorage;

type
  TChangeLog = class
  public
    Calls: Integer;
    Text: string;
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

procedure TChangeLog.GroupChanged(const Group: string; const Changes: TSettingChanges);
var
  Index: Integer;
begin
  Inc(Calls);
  Text := Text + Group + ':';
  for Index := 0 to High(Changes) do
    Text := Text + ' ' + DescribeSettingChange(Changes[Index]) + ';';
  Text := Text + #10;
end;

function DescribeAll(const Changes: TSettingChanges): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Changes) do
    Result := Result + DescribeSettingChange(Changes[Index]) + ';';
end;

function NewSettings(UserStorage, SystemStorage: TMemoryStorage): TSettings;
begin
  Result := TSettings.Create(TSettingsScope.Create(UserStorage, False), TSettingsScope.Create(SystemStorage, False));
end;

{ Writes as another program does (through the scope, with its lock). }
procedure WriteAsOther(UserStorage, SystemStorage: TMemoryStorage; const Path: string; const Value: TSettingValue;
  Scope: TSettingsScopeKind; Fixed: Boolean);
var
  Other: TSettings;
begin
  Other := NewSettings(UserStorage, SystemStorage);
  Other.WriteValue(Path, Value, Scope, Fixed);
  Other.Free;
end;

procedure TestSnapshots(Check: TCheckProcedure);
var
  UserStorage: TMemoryStorage;
  SystemStorage: TMemoryStorage;
  Settings: TSettings;
  Before: TSettingsSnapshot;
  After: TSettingsSnapshot;
  Changes: TSettingChanges;
begin
  UserStorage := TMemoryStorage.Create;
  SystemStorage := TMemoryStorage.Create;
  SystemStorage.Seed('Mouse', 'Speed = 12'#10'Acceleration = 3'#10);
  UserStorage.Seed('Mouse', 'Speed = 15'#10'[Buttons]'#10'Left = "primary"'#10);
  Settings := NewSettings(UserStorage, SystemStorage);

  Before := TakeGroupSnapshot(Settings, 'Mouse');
  Check('changes: a snapshot holds every key of both scopes, sections too', (Length(Before) = 3) and
    (Before[0].Path = 'Mouse/Acceleration') and (Before[1].Path = 'Mouse/Buttons/Left') and
    (Before[2].Path = 'Mouse/Speed') and (Before[2].Value.Number = 15));
  Check('changes: the same snapshot twice differs in nothing',
    Length(CompareSnapshots(Before, TakeGroupSnapshot(Settings, 'Mouse'))) = 0);

  UserStorage.Seed('Mouse', '# a comment'#10'Speed  =  15'#10#10'[Buttons]'#10'; another'#10'Left = "primary"'#10);
  Check('changes: comments and spacing do not count',
    Length(CompareSnapshots(Before, TakeGroupSnapshot(Settings, 'Mouse'))) = 0);

  WriteAsOther(UserStorage, SystemStorage, 'Mouse/Speed', IntegerSetting(15), ScopeSystem, False);
  UserStorage.Seed('Mouse', '[Buttons]'#10'Left = "primary"'#10);
  { The user's 15 went, the system's is 15 now: a program sees 15 still. }
  Check('changes: the same value from the other scope does not count',
    Length(CompareSnapshots(Before, TakeGroupSnapshot(Settings, 'Mouse'))) = 0);

  WriteAsOther(UserStorage, SystemStorage, 'Mouse/LeftHanded', BooleanSetting(True), ScopeUser, False);
  WriteAsOther(UserStorage, SystemStorage, 'Mouse/Buttons/Left', StringSetting(''), ScopeUser, False);
  Settings.Free;
  Settings := NewSettings(UserStorage, SystemStorage);
  Settings.Delete('Mouse/Buttons');
  Settings.Free;
  WriteAsOther(UserStorage, SystemStorage, 'Mouse/Acceleration', IntegerSetting(4), ScopeSystem, False);
  Settings := NewSettings(UserStorage, SystemStorage);
  After := TakeGroupSnapshot(Settings, 'Mouse');
  Changes := CompareSnapshots(Before, After);
  Check('changes: added, removed and changed keys, in path order', DescribeAll(Changes) =
    'Mouse/Acceleration = 4 (was 3);Mouse/Buttons/Left removed (was "primary");' +
    'Mouse/LeftHanded = true (was not set);');
  Check('changes: their kinds', (Length(Changes) = 3) and (Changes[0].Kind = SettingModified) and
    (Changes[1].Kind = SettingRemoved) and (Changes[2].Kind = SettingAdded));

  Before := After;
  WriteAsOther(UserStorage, SystemStorage, 'Mouse/LeftHanded', BooleanSetting(True), ScopeSystem, True);
  Changes := CompareSnapshots(Before, TakeGroupSnapshot(Settings, 'Mouse'));
  Check('changes: a value becoming fixed counts, even with the same value',
    DescribeAll(Changes) = 'Mouse/LeftHanded = fixed true (was true);');
  Check('changes: found by path, section or group', ChangesInclude(Changes, 'Mouse/LeftHanded') and
    ChangesInclude(Changes, 'Mouse') and not ChangesInclude(Changes, 'Mouse/Left') and
    not ChangesInclude(Changes, 'Mouse/Speed'));

  Before := TakeGroupSnapshot(Settings, 'Mouse');
  WriteAsOther(UserStorage, SystemStorage, 'Mouse/LeftHanded', BooleanSetting(False), ScopeUser, False);
  Check('changes: a user''s value under a fixed one does not count',
    Length(CompareSnapshots(Before, TakeGroupSnapshot(Settings, 'Mouse'))) = 0);
  Check('changes: a group with no keys has an empty snapshot', Length(TakeGroupSnapshot(Settings, 'Nothing')) = 0);

  Settings.Free;
  UserStorage.Free;
  SystemStorage.Free;
end;

procedure TestTracker(Check: TCheckProcedure);
var
  UserStorage: TMemoryStorage;
  SystemStorage: TMemoryStorage;
  Tracker: TSettingsChangeTracker;
  Log: TChangeLog;
  Time: QWord;
begin
  Check('tracker: the files of a group', (GroupOfSettingsFile('Notepad.settings') = 'Notepad') and
    (GroupOfSettingsFile('Notepad.settings.new') = 'Notepad') and (GroupOfSettingsFile('Notepad') = '') and
    (GroupOfSettingsFile('.settings') = '') and (GroupOfSettingsFile('Notepad.settings~') = '') and
    (GroupOfSettingsFile('a b.settings') = ''));

  UserStorage := TMemoryStorage.Create;
  SystemStorage := TMemoryStorage.Create;
  UserStorage.Seed('Terminal', 'FontSize = 110'#10);
  Log := TChangeLog.Create;
  Tracker := TSettingsChangeTracker.Create(NewSettings(UserStorage, SystemStorage), True);
  Tracker.OnChanged := @Log.GroupChanged;
  Tracker.Watch('Terminal');
  Tracker.Watch('Notepad');
  Check('tracker: watching groups', Tracker.IsWatching('Terminal') and Tracker.IsWatching('Notepad') and
    not Tracker.IsWatching('Desktop') and not Tracker.HasPendingChanges and (Tracker.Deadline = NoDeadline));

  { A safe write: the .new file made and written, then renamed over the
    group's file. }
  Time := 1000;
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/FontSize', IntegerSetting(140), ScopeUser, False);
  Tracker.NoteFileChanged('Terminal.settings.new', Time);
  Tracker.NoteFileChanged('Terminal.settings.new', Time + 2);
  Tracker.NoteFileChanged('Terminal.settings', Time + 3);
  Check('tracker: a change waits for the burst to end', Tracker.HasPendingChanges and
    (Tracker.Deadline = Time + 3 + QuietMilliseconds) and (Tracker.Collect(Time + 10) = 0) and (Log.Calls = 0));
  Check('tracker: then the group is reported once, with what changed',
    (Tracker.Collect(Time + 3 + QuietMilliseconds) = 1) and (Log.Calls = 1) and
    (Log.Text = 'Terminal: Terminal/FontSize = 140 (was 110);'#10) and not Tracker.HasPendingChanges);

  { Several programs writing one after another: one report with all. }
  Log.Text := '';
  Time := 2000;
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/FontSize', IntegerSetting(120), ScopeUser, False);
  Tracker.NoteFileChanged('Terminal.settings', Time);
  WriteAsOther(UserStorage, SystemStorage, 'Notepad/WordWrap', BooleanSetting(True), ScopeUser, False);
  Tracker.NoteFileChanged('Notepad.settings', Time + 40);
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/TextColor', StringSetting('#00ff00'), ScopeUser, False);
  Tracker.NoteFileChanged('Terminal.settings', Time + 80);
  Check('tracker: a burst is coalesced', (Tracker.Collect(Time + 100) = 0) and
    (Tracker.Collect(Time + 80 + QuietMilliseconds) = 2) and (Log.Calls = 3) and
    (Log.Text = 'Terminal: Terminal/FontSize = 120 (was 140); Terminal/TextColor = "#00ff00" (was not set);'#10 +
    'Notepad: Notepad/WordWrap = true (was not set);'#10));

  { A stream of changes is reported at most LongestDelayMilliseconds
    after it began. }
  Time := 3000;
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/FontSize', IntegerSetting(130), ScopeUser, False);
  Tracker.NoteFileChanged('Terminal.settings', Time);
  Tracker.NoteFileChanged('Terminal.settings', Time + 50);
  Tracker.NoteFileChanged('Terminal.settings', Time + 100);
  Tracker.NoteFileChanged('Terminal.settings', Time + 150);
  Tracker.NoteFileChanged('Terminal.settings', Time + 200);
  Tracker.NoteFileChanged('Terminal.settings', Time + 250);
  Check('tracker: a stream of changes is not waited out for ever',
    (Tracker.Deadline = Time + LongestDelayMilliseconds) and (Tracker.Collect(Time + LongestDelayMilliseconds) = 1) and
    (Log.Calls = 4));

  { Written again, the same values: silent. }
  Time := 4000;
  UserStorage.Seed('Terminal', '# kept by hand'#10 + UserStorage.TextOf('Terminal'));
  Tracker.NoteFileChanged('Terminal.settings.new', Time);
  Tracker.NoteFileChanged('Terminal.settings', Time);
  Check('tracker: a rewrite that changes nothing is silent',
    (Tracker.Collect(Time + LongestDelayMilliseconds) = 0) and (Log.Calls = 4) and not Tracker.HasPendingChanges);

  { The file going away for a moment (removed, then the new one renamed
    in) is one change: the values before and after. }
  Time := 5000;
  Log.Text := '';
  UserStorage.Seed('Terminal', 'FontSize = 150'#10);
  Tracker.NoteFileChanged('Terminal.settings', Time);
  Tracker.NoteFileChanged('Terminal.settings.new', Time + 1);
  Check('tracker: a replaced file is heard as its new values',
    (Tracker.Collect(Time + 100) = 1) and
    (Log.Text = 'Terminal: Terminal/FontSize = 150 (was 130); Terminal/TextColor removed (was "#00ff00");'#10));

  { Other files, and groups not watched, wake nothing. }
  Time := 6000;
  WriteAsOther(UserStorage, SystemStorage, 'Desktop/Wallpaper', StringSetting('/sky.png'), ScopeUser, False);
  Tracker.NoteFileChanged('Desktop.settings', Time);
  Tracker.NoteFileChanged('notes.txt', Time);
  Tracker.NoteFileChanged('', Time);
  Check('tracker: other files and groups are ignored', not Tracker.HasPendingChanges and (Tracker.Collect(Time + 500) = 0));

  { The system's scope: a value fixed for everyone. }
  Time := 7000;
  Log.Text := '';
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/FontSize', IntegerSetting(100), ScopeSystem, True);
  Tracker.NoteFileChanged('Terminal.settings', Time);
  Check('tracker: a value the system fixes is heard', (Tracker.Collect(Time + 100) = 1) and
    (Log.Text = 'Terminal: Terminal/FontSize = fixed 100 (was 150);'#10));

  { Lost changes (an overflow): every group is read again, only real
    changes reported. }
  Time := 8000;
  Log.Text := '';
  UserStorage.RemoveGroup('Terminal');
  Tracker.NoteEverythingChanged(Time);
  Check('tracker: after lost changes only real ones are reported', (Tracker.Collect(Time + 100) = 0) and
    (Log.Text = ''));
  SystemStorage.RemoveGroup('Terminal');
  Tracker.NoteEverythingChanged(Time + 200);
  Check('tracker: a group removed reports its keys gone', (Tracker.Collect(Time + 400) = 1) and
    (Log.Text = 'Terminal: Terminal/FontSize removed (was fixed 100);'#10));

  Tracker.Unwatch('Notepad');
  WriteAsOther(UserStorage, SystemStorage, 'Notepad/WordWrap', BooleanSetting(False), ScopeUser, False);
  Tracker.NoteFileChanged('Notepad.settings', Time + 1000);
  Check('tracker: a group no longer watched is not reported', not Tracker.IsWatching('Notepad') and
    (Tracker.Collect(Time + 2000) = 0));
  WriteAsOther(UserStorage, SystemStorage, 'Terminal/FontSize', IntegerSetting(90), ScopeUser, False);
  Check('tracker: looking at everything at once (no watches)', (Tracker.CollectEverything = 1) and (Log.Calls = 8));

  Tracker.Free;
  Log.Free;
  UserStorage.Free;
  SystemStorage.Free;
end;

procedure TestChangeDetection(Check: TCheckProcedure);
begin
  TestSnapshots(Check);
  TestTracker(Check);
end;

end.
