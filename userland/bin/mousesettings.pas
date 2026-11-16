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
  mousesettings - show or change the mouse's settings in the display
  server

  mousesettings [-r] [-s SPEED] [-a ACCELERATION] [-l on|off]

  -s, --speed N          how far the pointer goes for the mouse's
                         movement: 1 to 20, 10 as far as the mouse says
  -a, --acceleration N   how much further a fast movement goes: 0 (not
                         at all) to 10
  -l, --left-handed on|off
                         swap the left and right buttons
  -r, --remember         keep the settings in the user's settings
                         (Mouse/Speed, Mouse/Acceleration,
                         Mouse/LeftHanded), which the session manager
                         gives the display server when the user logs in

  Changes what is given and prints the settings then:

    speed S, acceleration A, left-handed on|off

  A tablet's positions are never changed. Without --remember the
  settings last until the display server ends, or the user logs off.
}
program ShowMouseSettings;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.MouseSettings,
  Configuration.Settings,
  Configuration.Locations;

const
  Usage: PChar = 'Usage: mousesettings [-r] [-s SPEED] [-a ACCELERATION] [-l on|off]'#10 +
    'Show the mouse''s settings in the display server, or change them:'#10 +
    '  -s, --speed N            1 to 20 (10: as far as the mouse moves)'#10 +
    '  -a, --acceleration N     0 (none) to 10'#10 +
    '  -l, --left-handed on|off swap the left and right buttons'#10 +
    '  -r, --remember           keep them in the user''s settings'#10;
  OptionSpeed = 1;
  OptionAcceleration = 2;
  OptionLeftHanded = 3;
  OptionRemember = 4;

procedure SaySettings(const Settings: TMouseSettings);
var
  LeftHanded: PChar;
begin
  if Settings.LeftHanded then
    LeftHanded := 'on'
  else
    LeftHanded := 'off';
  WriteFormatted(StandardOutput, 'speed %u, acceleration %u, left-handed %s'#10,
    [ArgumentUnsigned(Settings.Speed), ArgumentUnsigned(Settings.Acceleration), ArgumentText(LeftHanded)]);
  FlushStream(StandardOutput);
end;

function NumberIn(Text: PChar; Lowest, Highest: Int64; What: PChar): Int64;
begin
  if not ParseInteger(Text, Result) or (Result < Lowest) or (Result > Highest) then
    FailWithUsageHint('the %s must be a number from %d to %d', [ArgumentText(What), ArgumentNumber(Lowest),
      ArgumentNumber(Highest)]);
end;

procedure RememberForUser(const Settings: TMouseSettings);
var
  Store: TSettings;
  Error: LongInt;
begin
  Store := OpenSettings;
  if not Store.HasScope(ScopeUser) then
    Fail(1, 'there are no user settings to keep them in (HOME is not set)', []);
  RememberMouseSettings(Store, Settings);
  Error := Store.Flush;
  if Error <> ErrorNone then
    FailWithError(1, Error, '%s', [ArgumentText(PChar(Store.Scopes[ScopeUser].Storage.Location))]);
  Store.Free;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Speed: Int64;
  Acceleration: Int64;
  LeftHandedText: PChar;
  Remember: Boolean;
  Error: LongInt;
  Settings: TMouseSettings;
  Applied: TMouseSettings;
begin
  Speed := -1;
  Acceleration := -1;
  LeftHandedText := nil;
  Remember := False;
  BeginOptions(Parser, [OptionDefinition('s', 'speed', True, OptionSpeed),
    OptionDefinition('a', 'acceleration', True, OptionAcceleration),
    OptionDefinition('l', 'left-handed', True, OptionLeftHanded),
    OptionDefinition('r', 'remember', False, OptionRemember)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionSpeed:
        Speed := NumberIn(OptionValue, MinimumMouseSpeed, MaximumMouseSpeed, 'speed');
      OptionAcceleration:
        Acceleration := NumberIn(OptionValue, 0, MaximumMouseAcceleration, 'acceleration');
      OptionLeftHanded:
        begin
          if (CompareText(OptionValue, 'on') <> 0) and (CompareText(OptionValue, 'off') <> 0) then
            FailWithUsageHint('--left-handed takes on or off', []);
          LeftHandedText := OptionValue;
        end;
      OptionRemember:
        Remember := True;
    end;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('no operands are taken', []);
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  if not AskMouseSettings(Settings) then
    Fail(1, 'the display server did not say its mouse settings', []);
  Applied := Settings;
  if (Speed >= 0) or (Acceleration >= 0) or (LeftHandedText <> nil) then
  begin
    if Speed >= 0 then
      Settings.Speed := Speed;
    if Acceleration >= 0 then
      Settings.Acceleration := Acceleration;
    if LeftHandedText <> nil then
      Settings.LeftHanded := CompareText(LeftHandedText, 'on') = 0;
    if not ChangeMouseSettings(Settings, Applied) then
      Fail(1, 'the display server did not change its mouse settings', []);
  end;
  if Remember then
    RememberForUser(Applied);
  SaySettings(Applied);
  DisconnectFromDisplay;
end.
