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
  keyboardsettings - show or change the keyboards' layout and key repeat

  keyboardsettings [-r] [-d DELAY] [-s RATE] [LAYOUT]
  keyboardsettings -l

  LAYOUT                 us, uk, de or fr (-l lists them)
  -d, --delay MS         how long a key is held before it repeats: 250
                         to 1000 milliseconds
  -s, --rate N           how fast it then repeats: 2 to 30 a second
  -r, --remember         keep the settings in the user's settings
                         (Keyboard/Layout, Keyboard/RepeatDelay,
                         Keyboard/RepeatRate), which the session manager
                         gives the display server when the user logs in

  Changes what is given and prints the settings then:

    layout de, repeat delay 500, rate 11

  The kernel turns keys into characters for the console and the display
  server alike, and only root may change its layout: with a display
  server running, it asks the server (which does it for whoever sits at
  the screen, as for the mouse); otherwise only root may change them.
}
program ShowKeyboardSettings;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Sys.Keyboard,
  Util.Messages,
  Util.Options,
  Windowing.Connection,
  Windowing.KeyboardSettings,
  Configuration.Settings,
  Configuration.Locations;

const
  Usage: PChar = 'Usage: keyboardsettings [-r] [-d DELAY] [-s RATE] [LAYOUT]'#10 +
    '       keyboardsettings -l'#10 +
    'Show the keyboards'' layout and key repeat, or change them:'#10 +
    '  LAYOUT              us, uk, de or fr (-l lists them)'#10 +
    '  -d, --delay MS      250 to 1000 milliseconds before a key repeats'#10 +
    '  -s, --rate N        2 to 30 repeats a second'#10 +
    '  -r, --remember      keep them in the user''s settings'#10;
  OptionDelay = 1;
  OptionRate = 2;
  OptionList = 3;
  OptionRemember = 4;

procedure SaySettings(const Settings: TKeyboardSettings);
begin
  WriteFormatted(StandardOutput, 'layout %s, repeat delay %u, rate %u'#10,
    [ArgumentText(@Settings.Layout[0]), ArgumentUnsigned(Settings.RepeatDelay), ArgumentUnsigned(Settings.RepeatRate)]);
  FlushStream(StandardOutput);
end;

function IsKnownLayout(Name: PChar): Boolean;
var
  Index: Integer;
  Layout: TKeyboardLayoutDescription;
begin
  Index := 0;
  while DescribeKeyboardLayout(Index, Layout) do
  begin
    if TextIsEqual(@Layout.Name[0], Name) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

procedure ListLayouts;
var
  Index: Integer;
  Layout: TKeyboardLayoutDescription;
begin
  Index := 0;
  while DescribeKeyboardLayout(Index, Layout) do
  begin
    WriteFormatted(StandardOutput, '%s %s'#10, [ArgumentText(@Layout.Name[0]), ArgumentText(@Layout.Description[0])]);
    Inc(Index);
  end;
end;

function NumberIn(Text: PChar; Lowest, Highest: Int64; What: PChar): Int64;
begin
  if not ParseInteger(Text, Result) or (Result < Lowest) or (Result > Highest) then
    FailWithUsageHint('the %s must be a number from %d to %d', [ArgumentText(What), ArgumentNumber(Lowest),
      ArgumentNumber(Highest)]);
end;

procedure RememberForUser(const Settings: TKeyboardSettings);
var
  Store: TSettings;
  Error: LongInt;
begin
  Store := OpenSettings;
  if not Store.HasScope(ScopeUser) then
    Fail(1, 'there are no user settings to keep them in (HOME is not set)', []);
  RememberKeyboardSettings(Store, Settings);
  Error := Store.Flush;
  if Error <> ErrorNone then
    FailWithError(1, Error, '%s', [ArgumentText(PChar(Store.Scopes[ScopeUser].Storage.Location))]);
  Store.Free;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Delay: Int64;
  Rate: Int64;
  Remember: Boolean;
  Changing: Boolean;
  ThroughServer: Boolean;
  Settings: TKeyboardSettings;
  Applied: TKeyboardSettings;
  Error: LongInt;
begin
  Delay := -1;
  Rate := -1;
  Remember := False;
  BeginOptions(Parser, [OptionDefinition('d', 'delay', True, OptionDelay),
    OptionDefinition('s', 'rate', True, OptionRate),
    OptionDefinition('l', 'list', False, OptionList),
    OptionDefinition('r', 'remember', False, OptionRemember)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionDelay:
        Delay := NumberIn(OptionValue, MinimumKeyRepeatDelay, MaximumKeyRepeatDelay, 'delay');
      OptionRate:
        Rate := NumberIn(OptionValue, MinimumKeyRepeatRate, MaximumKeyRepeatRate, 'rate');
      OptionList:
        begin
          ListLayouts;
          Halt(0);
        end;
      OptionRemember:
        Remember := True;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if (Parser.OperandCount = 1) and not IsKnownLayout(Parser.Operands[0]) then
    Fail(1, 'there is no keyboard layout ''%s'' (keyboardsettings -l lists them)', [ArgumentText(Parser.Operands[0])]);

  ThroughServer := ConnectToDisplay = ErrorNone;
  if ThroughServer then
  begin
    if not AskKeyboardSettings(Settings) then
      Fail(1, 'the display server did not say its keyboard settings', []);
  end
  else
    GetKeyboardSettings(Settings);
  Applied := Settings;
  Changing := (Parser.OperandCount = 1) or (Delay >= 0) or (Rate >= 0);
  if Changing then
  begin
    if Parser.OperandCount = 1 then
      CopyText(@Settings.Layout[0], Parser.Operands[0], KeyboardLayoutNameCapacity);
    if Delay >= 0 then
      Settings.RepeatDelay := LongWord(Delay);
    if Rate >= 0 then
      Settings.RepeatRate := LongWord(Rate);
    if ThroughServer then
    begin
      if not ChangeKeyboardSettings(Settings, Applied) then
        Fail(1, 'the display server did not change its keyboard settings', []);
    end
    else
    begin
      Error := SetKeyboardSettings(Settings);
      if Error <> ErrorNone then
        FailWithError(1, Error, 'cannot change the keyboard settings', []);
      GetKeyboardSettings(Applied);
    end;
  end;
  if Remember then
    RememberForUser(Applied);
  SaySettings(Applied);
  if ThroughServer then
    DisconnectFromDisplay;
end.
