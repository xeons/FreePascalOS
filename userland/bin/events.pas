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
  events - show the input events of the keyboards and pointing devices

  events [-n COUNT]

  Takes the input (/dev/events: the console's keyboards stop typing into
  it meanwhile) and prints each event on a line of its own, COUNT of
  them (by default until interrupted):

    key 0x1E press a       a key (its code), and the character it typed
    key 0x1E release
    motion 5 -3            relative motion, right and down positive
    position 32767 16383   absolute position, 0 to 65535 across the screen
    button 1 press         1 left, 2 right, 3 middle
    wheel 1                steps, positive away from the user

  Only root may take the input.
}
program events;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: events [-n COUNT]'#10 +
    'Show the input events of the keyboards and pointing devices.'#10 +
    '  -n COUNT   stop after COUNT events'#10;
  OptionCount = 1;
  EventsPath = '/dev/events';

function PressText(Value: LongInt): string;
begin
  if Value <> 0 then
    Result := 'press'
  else
    Result := 'release';
end;

procedure PrintEvent(const Event: TAbiInputEvent);
var
  Line: string;
begin
  case Event.Kind of
    InputEventKey:
      begin
        Line := Format('key 0x%X %s', [Event.Code, PressText(Event.Value)]);
        if (Event.Character >= 32) and (Event.Character < 127) then
          Line := Line + ' ' + Char(Event.Character);
      end;
    InputEventMotion:
      Line := Format('motion %d %d', [Event.X, Event.Y]);
    InputEventPosition:
      Line := Format('position %d %d', [Event.X, Event.Y]);
    InputEventButton:
      Line := Format('button %u %s', [Event.Code, PressText(Event.Value)]);
    InputEventWheel:
      Line := Format('wheel %d', [Event.Value]);
  else
    Line := Format('event %u', [Event.Kind]);
  end;
  PrintStringLine(Line);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Limit: QWord;
  Shown: QWord;
  Handle: Int64;
  Buffer: array[0..15] of TAbiInputEvent;
  Got: Int64;
  Index: Integer;
begin
  Limit := 0;
  CommandLine := TCommandLine.Create([CommandOption('n', 'count', True, OptionCount)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    if Code = OptionCount then
      if not ParseUnsignedDecimal(OptionValue, Limit) or (Limit = 0) then
        FailWithUsageHint('the count must be a positive number');
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken');
  Handle := OpenFile(EventsPath, OpenRead);
  if Handle < 0 then
    FailWithError(1, LongInt(-Handle), EventsPath);
  Shown := 0;
  repeat
    Got := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Got <= 0 then
      FailWithError(1, LongInt(-Got), 'reading ' + EventsPath);
    for Index := 0 to Got div SizeOf(TAbiInputEvent) - 1 do
    begin
      PrintEvent(Buffer[Index]);
      Inc(Shown);
      if (Limit <> 0) and (Shown >= Limit) then
        Break;
    end;
    FlushStream(StandardOutput);
  until (Limit <> 0) and (Shown >= Limit);
  CloseFile(Handle);
end.
