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
  displayscale - show or change the display server's scale

  displayscale [PERCENT]

  Without an operand: the display's scale and DPI. With one: asks the
  display server for that scale (100 to 400 percent) while windows are
  open; the server draws its frames and pointer at it, and every program
  lays its windows out again at the same logical size. Prints the scale
  it is then:

    scale P%, D DPI
}
program SetDisplayScale;

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
  Usage: PChar = 'Usage: displayscale [PERCENT]'#10 +
    'Show the display server''s scale, or change it (100 to 400 percent).'#10;
  MinimumPercent = 100;
  MaximumPercent = 400;
  ReplyTimeout = 5000;

procedure SayScale;
begin
  WriteFormatted(StandardOutput, 'scale %u%%, %u DPI'#10, [ArgumentUnsigned(Windowing.Connection.DisplayScale),
    ArgumentUnsigned(DisplayDpi)]);
  FlushStream(StandardOutput);
end;

procedure ChangeScaleTo(Percent: LongWord);
var
  Message: TWindowMessage;
begin
  { The server says nothing when nothing changes. }
  if Percent = Windowing.Connection.DisplayScale then
    Exit;
  Message := NewMessage(RequestSetScale, 0);
  Message.Code := Percent;
  SendRequest(Message, -1);
  if not WaitForEvent(EventScaleChanged, ReplyTimeout, Message) then
    Fail(1, 'the display server did not change the scale', []);
  TakeScaleChange(Message);
end;

var
  Parser: TOptionParser;
  Percent: Int64;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('one scale at most', []);
  Percent := 0;
  if Parser.OperandCount = 1 then
    if not ParseInteger(Parser.Operands[0], Percent) or (Percent < MinimumPercent) or (Percent > MaximumPercent) then
      FailWithUsageHint('the scale must be a percentage from %d to %d', [ArgumentNumber(MinimumPercent),
        ArgumentNumber(MaximumPercent)]);
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  if Percent <> 0 then
    ChangeScaleTo(Percent);
  SayScale;
  DisconnectFromDisplay;
end.
