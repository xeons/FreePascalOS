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

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: events [-n COUNT]'#10 +
    'Show the input events of the keyboards and pointing devices.'#10 +
    '  -n COUNT   stop after COUNT events'#10;
  OptionCount = 1;
  EventsPath: PChar = '/dev/events';

function PressText(Value: LongInt): PChar;
begin
  if Value <> 0 then
    Result := 'press'
  else
    Result := 'release';
end;

procedure PrintEvent(const Event: TAbiInputEvent);
var
  Character: array[0..4] of Char;
begin
  case Event.Kind of
    InputEventKey:
      begin
        WriteFormatted(StandardOutput, 'key 0x%s %s', [ArgumentText(FormatText('%X', [ArgumentUnsigned(Event.Code)])),
          ArgumentText(PressText(Event.Value))]);
        if (Event.Character >= 32) and (Event.Character < 127) then
        begin
          Character[0] := ' ';
          Character[1] := Char(Event.Character);
          Character[2] := #0;
          WriteFormatted(StandardOutput, '%s', [ArgumentText(@Character[0])]);
        end;
        WriteFormatted(StandardOutput, #10, []);
      end;
    InputEventMotion:
      WriteFormatted(StandardOutput, 'motion %d %d'#10, [ArgumentNumber(Event.X), ArgumentNumber(Event.Y)]);
    InputEventPosition:
      WriteFormatted(StandardOutput, 'position %d %d'#10, [ArgumentNumber(Event.X), ArgumentNumber(Event.Y)]);
    InputEventButton:
      WriteFormatted(StandardOutput, 'button %u %s'#10, [ArgumentUnsigned(Event.Code),
        ArgumentText(PressText(Event.Value))]);
    InputEventWheel:
      WriteFormatted(StandardOutput, 'wheel %d'#10, [ArgumentNumber(Event.Value)]);
  else
    WriteFormatted(StandardOutput, 'event %u'#10, [ArgumentUnsigned(Event.Kind)]);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Limit: QWord;
  Shown: QWord;
  Handle: Int64;
  Buffer: array[0..15] of TAbiInputEvent;
  Got: Int64;
  Index: Integer;
begin
  Limit := 0;
  BeginOptions(Parser, [OptionDefinition('n', 'count', True, OptionCount)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    if Code = OptionCount then
      if not ParseUnsigned(OptionValue, Limit) or (Limit = 0) then
        FailWithUsageHint('the count must be a positive number', []);
  if Parser.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken', []);
  Handle := OpenFile(EventsPath, OpenRead);
  if Handle < 0 then
    FailWithError(1, LongInt(-Handle), '%s', [ArgumentText(EventsPath)]);
  Shown := 0;
  repeat
    Got := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Got <= 0 then
      FailWithError(1, LongInt(-Got), 'reading %s', [ArgumentText(EventsPath)]);
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
