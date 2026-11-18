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
  SettingsTest: the settings library (libconfiguration) on the host.

    SettingsTest

  Names and paths (Configuration.Names); values written and read back,
  with escaping (Configuration.Values); settings files parsed, changed
  without losing comments or lines that cannot be read, and listed
  (Configuration.Documents); scopes over a storage in memory - changes
  seen before they are flushed, two writers keeping both changes, others'
  changes noticed, a damaged group not written over
  (Configuration.Scopes); and the user's settings over the system's over
  the defaults, with fixed values (Configuration.Settings); change
  notification - snapshots compared, bursts of file changes coalesced,
  safe writes' renames, rewrites that change nothing kept silent
  (SettingsTest.Changes); the network's
  settings and the network service's state files
  (SettingsTest.Network); the programs' folders and their program.info
  files (SettingsTest.Programs). Every check
  prints a line; the exit code is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
  The files themselves (Configuration.FileStorage) are tested on the
  system by settingstest.
}
program SettingsTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Configuration.Names,
  Configuration.Values,
  Configuration.Documents,
  Configuration.Storage,
  Configuration.Scopes,
  Configuration.Settings,
  SettingsTest.MemoryStorage,
  SettingsTest.Network,
  SettingsTest.Changes,
  SettingsTest.Programs;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[settings] pass: ', Name)
  else
  begin
    WriteLn('[settings] FAIL: ', Name);
    Inc(Failures);
  end;
end;

procedure CheckText(const Name, Got, Expected: string);
begin
  Check(Name, Got = Expected);
  if Got <> Expected then
  begin
    WriteLn('[settings]   expected: ', StringReplace(Expected, #10, '\n', [rfReplaceAll]));
    WriteLn('[settings]   got:      ', StringReplace(Got, #10, '\n', [rfReplaceAll]));
  end;
end;

function Joined(const Items: TStringArray): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Items) do
  begin
    if Index > 0 then
      Result := Result + ',';
    Result := Result + Items[Index];
  end;
end;

function Items(const Texts: array of string): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Texts));
  for Index := 0 to High(Texts) do
    Result[Index] := Texts[Index];
end;

{ --- Names ------------------------------------------------------------------------------------ }

procedure TestNames;
var
  Path: TSettingsPath;
begin
  Check('names: letters, digits, _ - .', IsSettingsName('Word_Wrap-2.x') and IsSettingsName('0'));
  Check('names: not empty, no spaces, no leading dot or dash',
    not IsSettingsName('') and not IsSettingsName('a b') and not IsSettingsName('.hidden') and
    not IsSettingsName('-x') and not IsSettingsName('a/b') and not IsSettingsName('a=b'));
  Check('names: at most 64 characters', IsSettingsName(StringOfChar('a', 64)) and
    not IsSettingsName(StringOfChar('a', 65)));
  Check('path: group and key', ParseKeyPath('Notepad/WordWrap', Path) and (Path.Group = 'Notepad') and
    (Path.Section = '') and (Path.Key = 'WordWrap'));
  Check('path: nested sections', ParseKeyPath('Display/0/Sub/Scale', Path) and (Path.Group = 'Display') and
    (Path.Section = '0/Sub') and (Path.Key = 'Scale'));
  Check('path: a key needs a group', not ParseKeyPath('Notepad', Path) and not ParseKeyPath('', Path));
  Check('path: empty names are refused', not ParseKeyPath('a//b', Path) and not ParseKeyPath('/a/b', Path) and
    not ParseKeyPath('a/b/', Path) and not ParseKeyPath('a/../b', Path));
  Check('path: a section path', ParseSectionPath('Display/0', Path) and (Path.Group = 'Display') and
    (Path.Section = '0') and (Path.Key = ''));
  Check('path: the empty section path names every group', ParseSectionPath('', Path) and (Path.Group = ''));
  CheckText('path: written back', SettingsPathText(Path), '');
  ParseKeyPath('A/B/C', Path);
  CheckText('path: written back (key)', SettingsPathText(Path), 'A/B/C');
end;

{ --- Values ----------------------------------------------------------------------------------- }

function RoundTrips(const Value: TSettingValue): Boolean;
var
  Back: TSettingValue;
begin
  Result := ParseSettingValue(FormatSettingValue(Value), Back) and SameSettingValue(Value, Back);
end;

procedure TestValues;
var
  Value: TSettingValue;
  Number: Int64;
  Flag: Boolean;
  Text: string;
  List: TStringArray;
  Awkward: string;
begin
  CheckText('values: a string is quoted', FormatSettingValue(StringSetting('DejaVu Sans')), '"DejaVu Sans"');
  CheckText('values: quotes, backslashes and control characters escaped',
    FormatSettingValue(StringSetting('a"b\c'#10'd'#9'e'#13#1#127)), '"a\"b\\c\nd\te\r\x01\x7F"');
  CheckText('values: UTF-8 kept as it is', FormatSettingValue(StringSetting('caf'#$C3#$A9)), '"caf'#$C3#$A9'"');
  Awkward := '"[x], = # ; \\ '#0#255' true';
  Check('values: an awkward string reads back the same', RoundTrips(StringSetting(Awkward)));
  Check('values: strings that look like other kinds stay strings',
    RoundTrips(StringSetting('true')) and RoundTrips(StringSetting('150')) and RoundTrips(StringSetting('[a]')) and
    RoundTrips(StringSetting('')));
  CheckText('values: integers', FormatSettingValue(IntegerSetting(-42)), '-42');
  Check('values: integers read back', RoundTrips(IntegerSetting(High(Int64))) and RoundTrips(IntegerSetting(Low(Int64) + 1)));
  Check('values: hexadecimal integers', ParseSettingValue('0x1F', Value) and SettingAsInteger(Value, Number) and
    (Number = 31));
  Check('values: booleans', ParseSettingValue('true', Value) and SettingAsBoolean(Value, Flag) and Flag and
    ParseSettingValue('Off', Value) and SettingAsBoolean(Value, Flag) and not Flag and
    ParseSettingValue('yes', Value) and SettingAsBoolean(Value, Flag) and Flag);
  CheckText('values: a list', FormatSettingValue(ListSetting(Items(['a', 'b, c', 'd"e']))), '["a", "b, c", "d\"e"]');
  Check('values: lists read back', RoundTrips(ListSetting(Items(['one', '', 'x]y']))) and RoundTrips(ListSetting(nil)));
  Check('values: a list of bare items', ParseSettingValue('[ red, green blue ,3 ]', Value) and
    SettingAsList(Value, List) and (Joined(List) = 'red,green blue,3'));
  Check('values: anything else is a bare string', ParseSettingValue('  /home/user/sky picture.bmp  ', Value) and
    (Value.Kind = SettingString) and (Value.Text = '/home/user/sky picture.bmp'));
  Check('values: a number too large is a string', ParseSettingValue('99999999999999999999', Value) and
    (Value.Kind = SettingString));
  Check('values: malformed ones are refused', not ParseSettingValue('"unfinished', Value) and
    not ParseSettingValue('"bad \q escape"', Value) and not ParseSettingValue('"x" trailing', Value) and
    not ParseSettingValue('"\x4"', Value) and not ParseSettingValue('[a, b', Value) and
    not ParseSettingValue('[a,,b]', Value) and not ParseSettingValue('["a" b]', Value) and
    not ParseSettingValue('[a] x', Value));
  Check('values: kinds are strict', not SettingAsInteger(StringSetting('5'), Number) and
    not SettingAsBoolean(IntegerSetting(1), Flag) and not SettingAsList(StringSetting('a'), List));
  Check('values: integers and booleans read as text', SettingAsString(IntegerSetting(7), Text) and (Text = '7') and
    SettingAsString(BooleanSetting(False), Text) and (Text = 'false') and
    not SettingAsString(ListSetting(nil), Text));
end;

{ --- Documents -------------------------------------------------------------------------------- }

const
  SampleFile: string =
    '# Notepad''s settings'#10 +
    'WordWrap = true'#10 +
    'Font = "DejaVu Sans Mono"'#10 +
    #10 +
    '[Window]'#10 +
    '; where it was'#10 +
    'Width = 640'#10 +
    'fixed Height = 480'#10 +
    #10 +
    '[Window/Recent]'#10 +
    'Files = ["/etc/passwd", "/tmp/a b.txt"]'#10;

function DocumentValueText(Document: TSettingsDocument; const Section, Key: string): string;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  if Document.GetValue(Section, Key, Value, Fixed) then
  begin
    Result := FormatSettingValue(Value);
    if Fixed then
      Result := 'fixed ' + Result;
  end
  else
    Result := '(none)';
end;

procedure TestDocuments;
var
  Document: TSettingsDocument;
begin
  Document := TSettingsDocument.Create;
  Document.Parse(SampleFile);
  CheckText('document: written back unchanged', Document.Serialize, SampleFile);
  CheckText('document: a key of the group', DocumentValueText(Document, '', 'WordWrap'), 'true');
  CheckText('document: a key of a section', DocumentValueText(Document, 'Window', 'Width'), '640');
  CheckText('document: a fixed key', DocumentValueText(Document, 'Window', 'Height'), 'fixed 480');
  CheckText('document: a list', DocumentValueText(Document, 'Window/Recent', 'Files'), '["/etc/passwd", "/tmp/a b.txt"]');
  CheckText('document: a missing key', DocumentValueText(Document, 'Window', 'WordWrap'), '(none)');
  CheckText('document: keys of the group', Joined(Document.ListKeys('')), 'WordWrap,Font');
  CheckText('document: sections of the group', Joined(Document.ListSections('')), 'Window');
  CheckText('document: sections of a section', Joined(Document.ListSections('Window')), 'Recent');

  Document.SetValue('Window', 'Width', IntegerSetting(800), False);
  Document.SetValue('', 'StatusBar', BooleanSetting(False), False);
  Document.SetValue('Window', 'Left', IntegerSetting(10), False);
  Document.SetValue('Find', 'Text', StringSetting('a "quoted" word'), False);
  CheckText('document: changes keep comments, order and blank lines', Document.Serialize,
    '# Notepad''s settings'#10 +
    'WordWrap = true'#10 +
    'Font = "DejaVu Sans Mono"'#10 +
    'StatusBar = false'#10 +
    #10 +
    '[Window]'#10 +
    '; where it was'#10 +
    'Width = 800'#10 +
    'fixed Height = 480'#10 +
    'Left = 10'#10 +
    #10 +
    '[Window/Recent]'#10 +
    'Files = ["/etc/passwd", "/tmp/a b.txt"]'#10 +
    #10 +
    '[Find]'#10 +
    'Text = "a \"quoted\" word"'#10);
  Check('document: deleting a key', Document.DeleteValue('', 'Font') and not Document.DeleteValue('', 'Font'));
  Check('document: deleting a section takes its subsections', Document.DeleteSection('Window') and
    (DocumentValueText(Document, 'Window/Recent', 'Files') = '(none)') and
    (DocumentValueText(Document, 'Find', 'Text') <> '(none)'));
  CheckText('document: what is left', Document.Serialize,
    '# Notepad''s settings'#10 +
    'WordWrap = true'#10 +
    'StatusBar = false'#10 +
    #10 +
    '[Find]'#10 +
    'Text = "a \"quoted\" word"'#10);
  Document.DeleteSection('');
  Check('document: deleting everything', Document.HasNoKeys and (Document.LineCount = 0));

  Document.SetValue('', 'First', IntegerSetting(1), False);
  CheckText('document: a key in an empty document', Document.Serialize, 'First = 1'#10);
  Document.Parse('[Only]'#10'A = 1'#10);
  Document.SetValue('', 'Top', IntegerSetting(2), False);
  CheckText('document: a key of the group goes before the first section', Document.Serialize,
    'Top = 2'#10'[Only]'#10'A = 1'#10);
  Document.Free;
end;

procedure TestDamagedDocuments;
var
  Document: TSettingsDocument;
  Problems: TStringArray;
  Damaged: string;
begin
  Damaged :=
    'Good = 1'#13#10 +
    'this line has no equals sign'#13#10 +
    'Bad Key = 2'#10 +
    'Broken = "unfinished'#10 +
    'Nul = x'#0'y'#10 +
    'Twice = "first"'#10 +
    'Twice = "second"'#10 +
    '[not a/valid section'#10 +
    'Lost = 3'#10 +
    '[Fine]'#10 +
    'Kept = yes'#10 +
    'fixedd Word = 1'#10 +
    'NoLineEnd = 5';
  Document := TSettingsDocument.Create;
  Document.Parse(Damaged);
  CheckText('damaged: good keys are read (CR LF too)', DocumentValueText(Document, '', 'Good'), '1');
  CheckText('damaged: a key appearing twice is read from its first line', DocumentValueText(Document, '', 'Twice'),
    '"first"');
  CheckText('damaged: keys under a broken header are not taken for the previous section''s',
    DocumentValueText(Document, '', 'Lost'), '(none)');
  CheckText('damaged: the section after it is read', DocumentValueText(Document, 'Fine', 'Kept'), 'true');
  CheckText('damaged: a last line without a line end', DocumentValueText(Document, 'Fine', 'NoLineEnd'), '5');
  CheckText('damaged: unfinished strings and NUL bytes are not read',
    DocumentValueText(Document, '', 'Broken') + DocumentValueText(Document, '', 'Nul'), '(none)(none)');
  Problems := Document.Problems;
  CheckText('damaged: problems name their lines', Joined(Problems),
    'line 2: this line has no equals sign,line 3: Bad Key = 2,line 4: Broken = "unfinished,' +
    'line 5: Nul = x'#0'y,line 8: [not a/valid section,line 9: Lost = 3,line 12: fixedd Word = 1');
  Document.SetValue('', 'Good', IntegerSetting(10), False);
  Document.SetValue('Fine', 'Added', BooleanSetting(True), False);
  Document.DeleteValue('', 'Twice');
  CheckText('damaged: lines that cannot be read survive changes', Document.Serialize,
    'Good = 10'#10 +
    'this line has no equals sign'#10 +
    'Bad Key = 2'#10 +
    'Broken = "unfinished'#10 +
    'Nul = x'#0'y'#10 +
    '[not a/valid section'#10 +
    'Lost = 3'#10 +
    '[Fine]'#10 +
    'Kept = yes'#10 +
    'fixedd Word = 1'#10 +
    'NoLineEnd = 5'#10 +
    'Added = true'#10);
  Document.Parse(#0#1#2#255'garbage'#10#10'[[['#10'==='#10);
  Check('damaged: binary garbage gives no keys and no crash', Document.HasNoKeys and
    (Length(Document.Problems) = 3));
  Document.Free;
end;

{ --- Scopes ----------------------------------------------------------------------------------- }

function KeyPath(const Path: string): TSettingsPath;
begin
  if not ParseKeyPath(Path, Result) then
    raise Exception.Create('bad test path ' + Path);
end;

function GroupPath(const Path: string): TSettingsPath;
begin
  if not ParseSectionPath(Path, Result) then
    raise Exception.Create('bad test path ' + Path);
end;

function ScopeValueText(Scope: TSettingsScope; const Path: string): string;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  if Scope.GetValue(KeyPath(Path), Value, Fixed) then
    Result := FormatSettingValue(Value)
  else
    Result := '(none)';
end;

procedure TestScopes;
var
  Storage: TMemoryStorage;
  First: TSettingsScope;
  Second: TSettingsScope;
  Changed: TStringArray;
begin
  Storage := TMemoryStorage.Create;
  First := TSettingsScope.Create(Storage, False);
  Second := TSettingsScope.Create(Storage, False);

  First.SetValue(KeyPath('Notepad/WordWrap'), BooleanSetting(True), False);
  CheckText('scope: a change is seen before it is flushed', ScopeValueText(First, 'Notepad/WordWrap'), 'true');
  Check('scope: nothing is written before the flush', not Storage.HasGroup('Notepad') and First.HasPendingChanges);
  Check('scope: flushing writes under the lock', (First.Flush = ErrorNone) and (Storage.LockCount = 1) and
    (Storage.TextOf('Notepad') = 'WordWrap = true'#10) and not First.HasPendingChanges);
  CheckText('scope: another program sees it', ScopeValueText(Second, 'Notepad/WordWrap'), 'true');

  { Two programs change the same group at once: both changes stay. }
  First.SetValue(KeyPath('Notepad/StatusBar'), BooleanSetting(False), False);
  Second.SetValue(KeyPath('Notepad/Font/Size'), IntegerSetting(120), False);
  Second.Flush;
  First.Flush;
  CheckText('scope: two writers keep both changes', Storage.TextOf('Notepad'),
    'WordWrap = true'#10'StatusBar = false'#10#10'[Font]'#10'Size = 120'#10);
  CheckText('scope: the first writer reads the second one''s change', ScopeValueText(First, 'Notepad/Font/Size'), '120');

  { A change made by someone else is noticed. }
  ScopeValueText(First, 'Notepad/WordWrap');
  Storage.Seed('Notepad', 'WordWrap = false'#10);
  Changed := First.CheckForChanges;
  CheckText('scope: changes by others are named', Joined(Changed), 'Notepad');
  CheckText('scope: and read again', ScopeValueText(First, 'Notepad/WordWrap'), 'false');
  Check('scope: nothing changed since', Length(First.CheckForChanges) = 0);
  First.SetValue(KeyPath('Notepad/WordWrap'), BooleanSetting(True), False);
  First.Flush;
  Check('scope: its own writes are not taken for changes by others', Length(First.CheckForChanges) = 0);

  { Writing the same value again writes nothing. }
  Storage.WriteCount := 0;
  First.SetValue(KeyPath('Notepad/WordWrap'), BooleanSetting(True), False);
  First.Flush;
  Check('scope: an unchanged group is not written', Storage.WriteCount = 0);

  { Listing. }
  First.SetValue(KeyPath('Terminal/Rows'), IntegerSetting(30), False);
  CheckText('scope: groups include the ones not flushed yet', Joined(First.ListSections(GroupPath(''))),
    'Notepad,Terminal');
  CheckText('scope: keys of a group', Joined(First.ListKeys(GroupPath('Notepad'))), 'WordWrap');
  CheckText('scope: sections of a group', Joined(First.ListSections(GroupPath('Notepad'))), '');
  First.Flush;

  { Deleting the last key removes the group. }
  First.Delete(KeyPath('Terminal/Rows'));
  First.Flush;
  Check('scope: a group without keys is removed', not Storage.HasGroup('Terminal'));
  First.Delete(GroupPath('Notepad'));
  First.Flush;
  Check('scope: deleting a group', not Storage.HasGroup('Notepad') and
    (ScopeValueText(Second, 'Notepad/WordWrap') = '(none)'));

  { A group that cannot be read is not written over. }
  Storage.Seed('Damaged', 'Precious = 1'#10);
  Storage.FailingGroup := 'Damaged';
  Storage.FailingError := ErrorCorrupted;
  CheckText('scope: an unreadable group reads as empty', ScopeValueText(First, 'Damaged/Precious'), '(none)');
  Check('scope: and says why', First.ReadError('Damaged') = ErrorCorrupted);
  First.SetValue(KeyPath('Damaged/New'), IntegerSetting(2), False);
  Check('scope: flushing it fails', First.Flush = ErrorCorrupted);
  Storage.FailingGroup := '';
  CheckText('scope: and leaves it alone', Storage.TextOf('Damaged'), 'Precious = 1'#10);
  CheckText('scope: the failed change is dropped', ScopeValueText(First, 'Damaged/New'), '(none)');

  First.Free;
  Second.Free;
  Storage.Free;
end;

{ --- Layers ----------------------------------------------------------------------------------- }

type
  TChangeListener = class
    Heard: string;
    procedure Changed(const Group: string);
  end;

procedure TChangeListener.Changed(const Group: string);
begin
  Heard := Heard + Group + ';';
end;

procedure TestLayers;
var
  UserStorage: TMemoryStorage;
  SystemStorage: TMemoryStorage;
  Settings: TSettings;
  Other: TSettings;
  Listener: TChangeListener;
  Value: TSettingValue;
  Source: TSettingsScopeKind;
begin
  UserStorage := TMemoryStorage.Create;
  SystemStorage := TMemoryStorage.Create;
  SystemStorage.Seed('Mouse', 'Speed = 12'#10'Acceleration = 3'#10'fixed LeftHanded = false'#10'Wrong = 2'#10);
  UserStorage.Seed('Mouse', 'Speed = 15'#10'LeftHanded = true'#10'Wrong = fast'#10);
  Settings := TSettings.Create(TSettingsScope.Create(UserStorage, False), TSettingsScope.Create(SystemStorage, False));

  Check('layers: the user''s value wins', Settings.ReadInteger('Mouse/Speed', 10) = 15);
  Check('layers: the system''s when the user has none', Settings.ReadInteger('Mouse/Acceleration', 0) = 3);
  Check('layers: the default when neither has one', Settings.ReadInteger('Mouse/Threshold', 4) = 4);
  Check('layers: a fixed system value wins over the user''s', not Settings.ReadBoolean('Mouse/LeftHanded', True) and
    Settings.IsFixed('Mouse/LeftHanded') and not Settings.IsFixed('Mouse/Speed'));
  Check('layers: a value of the wrong kind counts as none', Settings.ReadInteger('Mouse/Wrong', 0) = 2);
  Check('layers: and as text it is the user''s', Settings.ReadString('Mouse/Wrong', '') = 'fast');
  Check('layers: lookup names the scope', Settings.Lookup('Mouse/Acceleration', Value, Source) and
    (Source = ScopeSystem) and Settings.Lookup('Mouse/Speed', Value, Source) and (Source = ScopeUser));
  Check('layers: a bad path reads as the default', Settings.ReadInteger('Mouse', 7) = 7);

  Settings.Delete('Mouse/Speed');
  Check('layers: deleting the user''s value brings the system''s back', Settings.ReadInteger('Mouse/Speed', 10) = 12);
  Settings.WriteInteger('Mouse/Acceleration', 5);
  Settings.WriteString('Desktop/Wallpaper', '/home/user/sky.bmp');
  Settings.WriteList('Notepad/Recent', Items(['/etc/passwd']));
  Check('layers: writes go to the user''s scope', (Settings.Flush = ErrorNone) and
    (Pos('Acceleration = 5', UserStorage.TextOf('Mouse')) > 0) and
    (SystemStorage.TextOf('Mouse') = 'Speed = 12'#10'Acceleration = 3'#10'fixed LeftHanded = false'#10'Wrong = 2'#10));
  Settings.WriteValue('Mouse/Speed', IntegerSetting(8), ScopeSystem, True);
  Settings.Flush;
  Check('layers: or to the system''s, fixed if asked', Settings.IsFixed('Mouse/Speed') and
    (Settings.ReadInteger('Mouse/Speed', 0) = 8));
  Check('layers: lists and strings', (Settings.ReadString('Desktop/Wallpaper', '') = '/home/user/sky.bmp') and
    (Joined(Settings.ReadList('Notepad/Recent', nil)) = '/etc/passwd'));
  CheckText('layers: keys of both scopes', Joined(Settings.ListKeys('Mouse')), 'LeftHanded,Wrong,Acceleration,Speed');
  CheckText('layers: groups of both scopes', Joined(Settings.ListSections('')), 'Mouse,Desktop,Notepad');
  Settings.WriteInteger('Bad Path/x', 1);
  Check('layers: a bad path is never written', Settings.Flush = ErrorInvalidArgument);

  { Another program's change reaches OnChanged. }
  Listener := TChangeListener.Create;
  Settings.OnChanged := @Listener.Changed;
  Check('layers: nothing changed yet', not Settings.CheckForChanges and (Listener.Heard = ''));
  Other := TSettings.Create(TSettingsScope.Create(UserStorage, False), TSettingsScope.Create(SystemStorage, False));
  Other.WriteBoolean('Desktop/ShowIcons', False);
  Other.Free;
  Check('layers: another program''s change is heard', Settings.CheckForChanges and (Listener.Heard = 'Desktop;') and
    not Settings.ReadBoolean('Desktop/ShowIcons', True));
  Settings.Free;
  Listener.Free;

  { A program without a user (a service) has the system's alone. }
  Settings := TSettings.Create(nil, TSettingsScope.Create(SystemStorage, False));
  Check('layers: system settings alone', Settings.ReadInteger('Mouse/Acceleration', 0) = 3);
  Settings.WriteInteger('Mouse/Acceleration', 1);
  Check('layers: writing a user''s setting without a user fails', Settings.Flush = ErrorNotFound);
  Settings.Free;
  UserStorage.Free;
  SystemStorage.Free;
end;

begin
  TestNames;
  TestValues;
  TestDocuments;
  TestDamagedDocuments;
  TestScopes;
  TestLayers;
  TestChangeDetection(@Check);
  TestNetworkSettings(@Check);
  TestNetworkState(@Check);
  TestProgramInfo(@Check);
  TestProgramFolders(@Check);
  TestSourceProgramInfo(@Check);
  WriteLn('[settings] ', Checks - Failures, ' passed, ', Failures, ' failed');
  if Failures > 0 then
    Halt(1);
end.
