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
  settings - read and change settings (libconfiguration)

  settings get [-s | -u] PATH
  settings set [-s [-f]] [-t KIND] PATH VALUE...
  settings delete [-s] PATH
  settings list [-s | -u] [PATH]
  settings check [-s | -u] GROUP
  settings watch [-s | -u] [-n COUNT] [-T SECONDS] GROUP...

  PATH names a setting: GROUP/KEY or GROUP/SECTION.../KEY, such as
  Notepad/WordWrap or Display/0/Scale; for delete and list it may name a
  section or a whole group too. Without -s or -u, get and list show what
  programs see: the user's settings ($HOME/.settings) over the system's
  (/etc/settings); set and delete change the user's.

    get      prints the value: a string as it is, a list an item a line;
             status 1 if it has none
    set      VALUE is read as in a settings file ("text", 150, true,
             [a, b]; anything else is a string), or as -t KIND says:
             string, integer, boolean, or list (each VALUE an item)
    delete   a key, or a section or group with everything in it
    list     the groups (no PATH), or a group's or section's sections
             (NAME/) and keys (KEY = VALUE, "fixed" before fixed ones)
    check    the lines of a group's file that cannot be read
    watch    prints "watching GROUP..." and then a line for every key of
             the groups that changes, as programs see it (a burst of
             writes is one change; a rewrite that changes nothing
             prints nothing): "PATH = VALUE (was OLD)", "PATH = VALUE
             (was not set)", "PATH removed (was OLD)", "fixed" before
             fixed values. Ends after COUNT keys changed (-n), or
             after SECONDS (-T; status 1 if COUNT keys had not changed
             by then), or when killed

  -s, --system   the system's settings (only root may change them)
  -u, --user     the user's alone
  -f, --fixed    with set -s: users cannot change it
  -n, --count    with watch: how many changed keys to wait for
  -T, --timeout  with watch: how long to watch
}
program settings;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Util.CommandLine,
  Util.Messages,
  Configuration.Names,
  Configuration.Values,
  Configuration.Scopes,
  Configuration.Settings,
  Configuration.Locations,
  Configuration.FileStorage,
  Configuration.Changes,
  Configuration.Watcher,
  Sys.Time;

const
  Usage = 'Usage: settings get [-s | -u] PATH'#10 +
    '       settings set [-s [-f]] [-t KIND] PATH VALUE...'#10 +
    '       settings delete [-s] PATH'#10 +
    '       settings list [-s | -u] [PATH]'#10 +
    '       settings check [-s | -u] GROUP'#10 +
    '       settings watch [-s | -u] [-n COUNT] [-T SECONDS] GROUP...'#10 +
    'Read and change settings: the user''s ($HOME/.settings) over the system''s (/etc/settings).'#10 +
    '  -s, --system      the system''s settings (only root may change them)'#10 +
    '  -u, --user        the user''s alone'#10 +
    '  -f, --fixed       with set -s: users cannot change it'#10 +
    '  -t, --type KIND   read VALUE as a string, integer, boolean or list'#10 +
    '  -n, --count N     watch: end after N keys changed'#10 +
    '  -T, --timeout S   watch: end after S seconds'#10;
  OptionSystem = 1;
  OptionUser = 2;
  OptionFixed = 3;
  OptionType = 4;
  OptionCount = 5;
  OptionTimeout = 6;

type
  TScopeChoice = (ChoiceBoth, ChoiceUser, ChoiceSystem);

var
  Choice: TScopeChoice;
  Fixed: Boolean;
  KindName: string;
  Operands: TStringArray;
  Store: TSettings;
  { watch: 0 for no limit. }
  ChangeCount: Integer;
  TimeoutSeconds: Integer;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
begin
  Choice := ChoiceBoth;
  Fixed := False;
  ChangeCount := 0;
  TimeoutSeconds := 0;
  KindName := '';
  CommandLine := TCommandLine.Create([CommandOption('s', 'system', False, OptionSystem),
    CommandOption('u', 'user', False, OptionUser),
    CommandOption('f', 'fixed', False, OptionFixed),
    CommandOption('t', 'type', True, OptionType),
    CommandOption('n', 'count', True, OptionCount),
    CommandOption('T', 'timeout', True, OptionTimeout)], Usage);
  try
    CommandLine.NegativeNumbersAreOperands := True;
    while CommandLine.NextOption(Code, OptionValue) do
      case Code of
        OptionSystem: Choice := ChoiceSystem;
        OptionUser: Choice := ChoiceUser;
        OptionFixed: Fixed := True;
        OptionType: KindName := LowerCase(OptionValue);
        OptionCount:
          if not TryStrToInt(OptionValue, ChangeCount) or (ChangeCount < 1) then
            FailWithUsageHint(OptionValue + ': not a count');
        OptionTimeout:
          if not TryStrToInt(OptionValue, TimeoutSeconds) or (TimeoutSeconds < 1) then
            FailWithUsageHint(OptionValue + ': not a number of seconds');
      end;
    Operands := CommandLine.Operands;
  finally
    CommandLine.Free;
  end;
  if Length(Operands) = 0 then
    FailWithUsageHint('a command is needed: get, set, delete, list, check or watch');
  if Fixed and (Choice <> ChoiceSystem) then
    FailWithUsageHint('--fixed is for the system''s settings (-s)');
end;

{ The scope set and delete change. }
function WrittenScope: TSettingsScopeKind;
begin
  if Choice = ChoiceSystem then
    Result := ScopeSystem
  else
    Result := ScopeUser;
end;

function ChosenScope: TSettingsScope;
begin
  Result := Store.Scopes[WrittenScope];
  if Result = nil then
    Fail(1, 'there are no user settings here (HOME is not set)');
end;

procedure NeedOperands(Lowest, Highest: Integer);
begin
  if (Length(Operands) - 1 < Lowest) or (Length(Operands) - 1 > Highest) then
    FailWithUsageHint('wrong number of operands for ' + Operands[0]);
end;

procedure NeedKeyPath(const Path: string);
var
  Parsed: TSettingsPath;
begin
  if not ParseKeyPath(Path, Parsed) then
    Fail(2, Path + ': not the path of a setting (GROUP/KEY)');
end;

procedure NeedSectionPath(const Path: string);
var
  Parsed: TSettingsPath;
begin
  if not ParseSectionPath(Path, Parsed) then
    Fail(2, Path + ': not a settings path');
end;

procedure FlushOrFail;
var
  Error: LongInt;
begin
  Error := Store.Flush;
  if Error <> ErrorNone then
    FailWithError(1, Error, ChosenScope.Storage.Location);
end;

procedure PrintValue(const Value: TSettingValue);
var
  Index: Integer;
begin
  case Value.Kind of
    SettingString: WriteLn(Value.Text);
    SettingList:
      for Index := 0 to High(Value.Items) do
        WriteLn(Value.Items[Index]);
  else
    WriteLn(FormatSettingValue(Value));
  end;
end;

procedure GetCommand;
var
  Value: TSettingValue;
  Source: TSettingsScopeKind;
  Found: Boolean;
begin
  NeedOperands(1, 1);
  NeedKeyPath(Operands[1]);
  case Choice of
    ChoiceUser: Found := Store.LookupIn(ScopeUser, Operands[1], Value);
    ChoiceSystem: Found := Store.LookupIn(ScopeSystem, Operands[1], Value);
  else
    Found := Store.Lookup(Operands[1], Value, Source);
  end;
  if not Found then
  begin
    Report(Operands[1] + ' is not set');
    Halt(1);
  end;
  PrintValue(Value);
end;

function ValueToSet: TSettingValue;
var
  Items: TStringArray;
  Index: Integer;
  Text: string;
begin
  Text := Operands[2];
  if KindName = 'list' then
  begin
    Items := nil;
    SetLength(Items, Length(Operands) - 2);
    for Index := 2 to High(Operands) do
      Items[Index - 2] := Operands[Index];
    Exit(ListSetting(Items));
  end;
  if Length(Operands) > 3 then
    FailWithUsageHint('one VALUE (or -t list for several)');
  if KindName = 'string' then
    Exit(StringSetting(Text));
  if not ParseSettingValue(Text, Result) then
    Fail(2, Text + ': not a value (a string in quotes must end with one)');
  if (KindName = 'integer') and (Result.Kind <> SettingInteger) then
    Fail(2, Text + ': not an integer');
  if (KindName = 'boolean') and (Result.Kind <> SettingBoolean) then
    Fail(2, Text + ': not a boolean (true or false)');
  if (KindName <> '') and (KindName <> 'integer') and (KindName <> 'boolean') then
    FailWithUsageHint('the kind must be string, integer, boolean or list');
end;

procedure SetCommand;
begin
  NeedOperands(2, MaxInt);
  NeedKeyPath(Operands[1]);
  ChosenScope;
  Store.WriteValue(Operands[1], ValueToSet, WrittenScope, Fixed);
  FlushOrFail;
end;

procedure DeleteCommand;
begin
  NeedOperands(1, 1);
  NeedSectionPath(Operands[1]);
  if Operands[1] = '' then
    Fail(2, 'deleting every group is not done');
  ChosenScope;
  Store.Delete(Operands[1], WrittenScope);
  FlushOrFail;
end;

procedure ListValuesOf(const Path: string; const Keys: TStringArray);
var
  Index: Integer;
  KeyPath: string;
  Value: TSettingValue;
  Source: TSettingsScopeKind;
  Found: Boolean;
  FixedMark: string;
begin
  for Index := 0 to High(Keys) do
  begin
    KeyPath := Path + SettingsPathSeparator + Keys[Index];
    case Choice of
      ChoiceUser: Found := Store.LookupIn(ScopeUser, KeyPath, Value);
      ChoiceSystem: Found := Store.LookupIn(ScopeSystem, KeyPath, Value);
    else
      Found := Store.Lookup(KeyPath, Value, Source);
    end;
    FixedMark := '';
    if (Choice <> ChoiceUser) and Store.IsFixed(KeyPath) then
      FixedMark := 'fixed ';
    if Found then
      WriteLn(FixedMark, Keys[Index], ' = ', FormatSettingValue(Value));
  end;
end;

procedure ListCommand;
var
  Path: string;
  Sections: TStringArray;
  Keys: TStringArray;
  Index: Integer;
begin
  NeedOperands(0, 1);
  Path := '';
  if Length(Operands) > 1 then
    Path := Operands[1];
  NeedSectionPath(Path);
  case Choice of
    ChoiceUser:
      begin
        Sections := Store.ListSectionsIn(ScopeUser, Path);
        Keys := Store.ListKeysIn(ScopeUser, Path);
      end;
    ChoiceSystem:
      begin
        Sections := Store.ListSectionsIn(ScopeSystem, Path);
        Keys := Store.ListKeysIn(ScopeSystem, Path);
      end;
  else
    Sections := Store.ListSections(Path);
    Keys := Store.ListKeys(Path);
  end;
  for Index := 0 to High(Sections) do
    WriteLn(Sections[Index], SettingsPathSeparator);
  ListValuesOf(Path, Keys);
end;

procedure CheckCommand;
var
  Problems: TStringArray;
  Scope: TSettingsScope;
  Index: Integer;
  Error: LongInt;
begin
  NeedOperands(1, 1);
  if not IsSettingsName(Operands[1]) then
    Fail(2, Operands[1] + ': not the name of a group');
  Scope := ChosenScope;
  Error := Scope.ReadError(Operands[1]);
  if Error <> ErrorNone then
    FailWithError(1, Error, Scope.Storage.Location + '/' + Operands[1]);
  Problems := Scope.Problems(Operands[1]);
  for Index := 0 to High(Problems) do
    WriteLn(Problems[Index]);
  if Length(Problems) > 0 then
    Halt(1);
end;

{ --- watch ------------------------------------------------------------------------------------ }

type
  TChangePrinter = class
  public
    Printed: Integer;
    procedure GroupChanged(const Group: string; const Changes: TSettingChanges);
  end;

procedure TChangePrinter.GroupChanged(const Group: string; const Changes: TSettingChanges);
var
  Index: Integer;
begin
  for Index := 0 to High(Changes) do
  begin
    WriteLn(DescribeSettingChange(Changes[Index]));
    Inc(Printed);
  end;
  Flush(Output);
end;

function OpenWatcher: TSettingsWatcher;
begin
  case Choice of
    ChoiceSystem: Result := OpenSystemSettingsWatcher;
    ChoiceUser:
      begin
        if CurrentHome = '' then
          Fail(1, 'there are no user settings here (HOME is not set)');
        Result := TSettingsWatcher.Create(TSettings.Create(TSettingsScope.Create(TFileSettingsStorage.Create(
          UserSettingsFolder(CurrentHome), UserSettingsFileMode, UserSettingsFolderMode), True), nil));
      end;
  else
    Result := OpenSettingsWatcher;
  end;
end;

procedure WatchCommand;
var
  Watcher: TSettingsWatcher;
  Printer: TChangePrinter;
  Index: Integer;
  Watched: string;
  Deadline: QWord;
  Now: QWord;
  Timeout: Int64;
begin
  NeedOperands(1, MaxInt);
  for Index := 1 to High(Operands) do
    if not IsSettingsName(Operands[Index]) then
      Fail(2, Operands[Index] + ': not the name of a group');
  Watcher := OpenWatcher;
  Printer := TChangePrinter.Create;
  Watcher.OnChanged := @Printer.GroupChanged;
  Watched := '';
  for Index := 1 to High(Operands) do
  begin
    Watcher.Watch(Operands[Index]);
    Watched := Watched + ' ' + Operands[Index];
  end;
  WriteLn('watching', Watched);
  Flush(Output);
  Deadline := 0;
  if TimeoutSeconds > 0 then
    Deadline := UptimeMilliseconds + QWord(TimeoutSeconds) * 1000;
  repeat
    Timeout := InfiniteWait;
    if Deadline > 0 then
    begin
      Now := UptimeMilliseconds;
      if Now >= Deadline then
        Break;
      Timeout := Int64(Deadline - Now);
    end;
    Watcher.WaitForChanges(Timeout);
  until (ChangeCount > 0) and (Printer.Printed >= ChangeCount);
  Index := Printer.Printed;
  Watcher.Free;
  Printer.Free;
  if (ChangeCount > 0) and (Index < ChangeCount) then
    Halt(1);
end;

begin
  ReadOptions;
  if Choice = ChoiceSystem then
    Store := OpenSystemSettings
  else
    Store := OpenSettings;
  if Operands[0] = 'get' then
    GetCommand
  else if Operands[0] = 'set' then
    SetCommand
  else if Operands[0] = 'delete' then
    DeleteCommand
  else if Operands[0] = 'list' then
    ListCommand
  else if Operands[0] = 'check' then
    CheckCommand
  else if Operands[0] = 'watch' then
    WatchCommand
  else
    FailWithUsageHint(Operands[0] + ': not a command (get, set, delete, list, check or watch)');
  Store.Free;
end.
