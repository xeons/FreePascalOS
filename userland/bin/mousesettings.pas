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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Windowing.Protocol,
  Windowing.Connection,
  Windowing.MouseSettings,
  Configuration.Settings,
  Configuration.Locations;

const
  Usage = 'Usage: mousesettings [-r] [-s SPEED] [-a ACCELERATION] [-l on|off]'#10 +
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
  LeftHanded: string;
begin
  if Settings.LeftHanded then
    LeftHanded := 'on'
  else
    LeftHanded := 'off';
  PrintStringLine(Format('speed %u, acceleration %u, left-handed %s',
    [Settings.Speed, Settings.Acceleration, LeftHanded]));
  FlushStream(StandardOutput);
end;

function NumberIn(const Text: string; Lowest, Highest: Int64; const What: string): Int64;
begin
  if not ParseDecimal(Text, Result) or (Result < Lowest) or (Result > Highest) then
    FailWithUsageHint(Format('the %s must be a number from %d to %d', [What, Lowest, Highest]));
end;

procedure RememberForUser(const Settings: TMouseSettings);
var
  Store: TSettings;
  Error: LongInt;
begin
  Store := OpenSettings;
  if not Store.HasScope(ScopeUser) then
    Fail(1, 'there are no user settings to keep them in (HOME is not set)');
  RememberMouseSettings(Store, Settings);
  Error := Store.Flush;
  if Error <> ErrorNone then
    FailWithError(1, Error, Store.Scopes[ScopeUser].Storage.Location);
  Store.Free;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Speed: Int64;
  Acceleration: Int64;
  LeftHandedGiven: Boolean;
  LeftHanded: Boolean;
  Remember: Boolean;
  Error: LongInt;
  Settings: TMouseSettings;
  Applied: TMouseSettings;
begin
  Speed := -1;
  Acceleration := -1;
  LeftHandedGiven := False;
  LeftHanded := False;
  Remember := False;
  CommandLine := TCommandLine.Create([CommandOption('s', 'speed', True, OptionSpeed),
    CommandOption('a', 'acceleration', True, OptionAcceleration),
    CommandOption('l', 'left-handed', True, OptionLeftHanded),
    CommandOption('r', 'remember', False, OptionRemember)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    case Code of
      OptionSpeed:
        Speed := NumberIn(OptionValue, MinimumMouseSpeed, MaximumMouseSpeed, 'speed');
      OptionAcceleration:
        Acceleration := NumberIn(OptionValue, 0, MaximumMouseAcceleration, 'acceleration');
      OptionLeftHanded:
        begin
          if (OptionValue <> 'on') and (OptionValue <> 'off') then
            FailWithUsageHint('--left-handed takes on or off');
          LeftHandedGiven := True;
          LeftHanded := OptionValue = 'on';
        end;
      OptionRemember:
        Remember := True;
    end;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint('no operands are taken');
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server');
  if not AskMouseSettings(Settings) then
    Fail(1, 'the display server did not say its mouse settings');
  Applied := Settings;
  if (Speed >= 0) or (Acceleration >= 0) or LeftHandedGiven then
  begin
    if Speed >= 0 then
      Settings.Speed := Speed;
    if Acceleration >= 0 then
      Settings.Acceleration := Acceleration;
    if LeftHandedGiven then
      Settings.LeftHanded := LeftHanded;
    if not ChangeMouseSettings(Settings, Applied) then
      Fail(1, 'the display server did not change its mouse settings');
  end;
  if Remember then
    RememberForUser(Applied);
  SaySettings(Applied);
  DisconnectFromDisplay;
end.
