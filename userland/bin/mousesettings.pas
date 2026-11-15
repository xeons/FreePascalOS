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

  mousesettings [-s SPEED] [-a ACCELERATION] [-l on|off]

  -s, --speed N          how far the pointer goes for the mouse's
                         movement: 1 to 20, 10 as far as the mouse says
  -a, --acceleration N   how much further a fast movement goes: 0 (not
                         at all) to 10
  -l, --left-handed on|off
                         swap the left and right buttons

  Changes what is given and prints the settings then:

    speed S, acceleration A, left-handed on|off

  A tablet's positions are never changed. The settings last until the
  display server ends (keeping them is for the configuration library).
}
program ChangeMouseSettings;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Windowing.Protocol,
  Windowing.Connection;

const
  Usage: PChar = 'Usage: mousesettings [-s SPEED] [-a ACCELERATION] [-l on|off]'#10 +
    'Show the mouse''s settings in the display server, or change them:'#10 +
    '  -s, --speed N            1 to 20 (10: as far as the mouse moves)'#10 +
    '  -a, --acceleration N     0 (none) to 10'#10 +
    '  -l, --left-handed on|off swap the left and right buttons'#10;
  OptionSpeed = 1;
  OptionAcceleration = 2;
  OptionLeftHanded = 3;
  ReplyTimeout = 5000;

var
  Settings: TWindowMessage;

procedure AskForSettings;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestGetMouseSettings, 0);
  SendRequest(Message, -1);
  if not WaitForEvent(EventMouseSettings, ReplyTimeout, Settings) then
    Fail(1, 'the display server did not say its mouse settings', []);
end;

procedure SendSettings;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestSetMouseSettings, 0);
  Message.Code := Settings.Code;
  Message.Value := Settings.Value;
  Message.Flags := Settings.Flags;
  SendRequest(Message, -1);
  if not WaitForEvent(EventMouseSettings, ReplyTimeout, Settings) then
    Fail(1, 'the display server did not change its mouse settings', []);
end;

procedure SaySettings;
var
  LeftHanded: PChar;
begin
  if (Settings.Flags and MouseLeftHanded) <> 0 then
    LeftHanded := 'on'
  else
    LeftHanded := 'off';
  WriteFormatted(StandardOutput, 'speed %u, acceleration %d, left-handed %s'#10,
    [ArgumentUnsigned(Settings.Code), ArgumentNumber(Settings.Value), ArgumentText(LeftHanded)]);
  FlushStream(StandardOutput);
end;

function NumberIn(Text: PChar; Lowest, Highest: Int64; What: PChar): Int64;
begin
  if not ParseInteger(Text, Result) or (Result < Lowest) or (Result > Highest) then
    FailWithUsageHint('the %s must be a number from %d to %d', [ArgumentText(What), ArgumentNumber(Lowest),
      ArgumentNumber(Highest)]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Speed: Int64;
  Acceleration: Int64;
  LeftHandedText: PChar;
  Error: LongInt;
begin
  Speed := -1;
  Acceleration := -1;
  LeftHandedText := nil;
  BeginOptions(Parser, [OptionDefinition('s', 'speed', True, OptionSpeed),
    OptionDefinition('a', 'acceleration', True, OptionAcceleration),
    OptionDefinition('l', 'left-handed', True, OptionLeftHanded)], Usage);
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
    end;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('no operands are taken', []);
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  AskForSettings;
  if (Speed >= 0) or (Acceleration >= 0) or (LeftHandedText <> nil) then
  begin
    if Speed >= 0 then
      Settings.Code := Speed;
    if Acceleration >= 0 then
      Settings.Value := Acceleration;
    if LeftHandedText <> nil then
      if CompareText(LeftHandedText, 'on') = 0 then
        Settings.Flags := Settings.Flags or MouseLeftHanded
      else
        Settings.Flags := Settings.Flags and not MouseLeftHanded;
    SendSettings;
  end;
  SaySettings;
  DisconnectFromDisplay;
end.
