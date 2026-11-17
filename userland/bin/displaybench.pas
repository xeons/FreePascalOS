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
  displaybench - how fast a display shows what is drawn

  displaybench [-d NUMBER] [-s SECONDS]

  Takes the display (0, the console's, by default; it must be free: not
  while the display server runs) and measures, SECONDS each (default 2),
  the frames a second it shows as the display server would: drawn in
  memory, the changed rectangle copied to the framebuffer and flushed
  (on a display that needs it: virtio-gpu). First the whole screen each
  frame, then a 256 x 256 square moving across it; then, on a display
  with a hardware cursor, how many cursor moves a second it takes. The
  first line says how the display is driven.
}
program DisplayBench;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Display,
  Sys.Time,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Sys.Streams;

const
  Usage = 'Usage: displaybench [-d NUMBER] [-s SECONDS]'#10 +
    'Measure the frames a second a display shows, whole and in part.'#10 +
    '  -d NUMBER    the display (0, the first, by default)'#10 +
    '  -s SECONDS   how long each measurement runs (default 2)'#10;
  OptionNumber = 1;
  OptionSeconds = 2;
  DefaultSeconds = 2;
  PartSize = 256;
  { The square moves this far a frame. }
  PartStep = 37;

type
  TMeasurement = record
    Count: QWord;
    Milliseconds: QWord;
  end;

var
  Display: TDisplay;
  BackBuffer: array of LongWord;

function DescribeDriving: string;
begin
  if DisplayNeedsFlush(Display) then
    Result := 'framebuffer flushed to the device by rectangles'
  else
    Result := 'framebuffer drawn directly';
  if DisplayHasHardwareCursor(Display) then
    Result := Result + ', hardware cursor'
  else
    Result := Result + ', no hardware cursor';
end;

{ The rectangle filled in the back buffer with a colour for Frame. }
procedure DrawInMemory(Left, Top, Width, Height: LongInt; Frame: QWord);
var
  Row: LongInt;
  Column: LongInt;
  Color: LongWord;
  Line: LongInt;
begin
  Color := LongWord((Frame * $10305) and $FFFFFF);
  for Row := Top to Top + Height - 1 do
  begin
    Line := Row * LongInt(Display.Width);
    for Column := Left to Left + Width - 1 do
      BackBuffer[Line + Column] := Color;
  end;
end;

procedure Present(Left, Top, Width, Height: LongInt);
var
  Row: LongInt;
  Target: PByte;
begin
  for Row := Top to Top + Height - 1 do
  begin
    Target := PByte(Display.Pixels) + PtrUInt(Row) * Display.Pitch + PtrUInt(Left) * SizeOf(LongWord);
    Move(BackBuffer[Row * LongInt(Display.Width) + Left], Target^, Width * SizeOf(LongWord));
  end;
  FlushDisplay(Display, Left, Top, Width, Height);
end;

function MeasureFullScreen(Milliseconds: QWord): TMeasurement;
var
  Start: QWord;
begin
  Result.Count := 0;
  Start := UptimeMilliseconds;
  repeat
    DrawInMemory(0, 0, Display.Width, Display.Height, Result.Count);
    Present(0, 0, Display.Width, Display.Height);
    Inc(Result.Count);
    Result.Milliseconds := UptimeMilliseconds - Start;
  until Result.Milliseconds >= Milliseconds;
end;

function MeasurePart(Milliseconds: QWord; Size: LongInt): TMeasurement;
var
  Start: QWord;
  Left: LongInt;
  Top: LongInt;
  RangeX: LongInt;
  RangeY: LongInt;
begin
  Result.Count := 0;
  RangeX := LongInt(Display.Width) - Size + 1;
  RangeY := LongInt(Display.Height) - Size + 1;
  Start := UptimeMilliseconds;
  repeat
    Left := LongInt((Result.Count * PartStep) mod QWord(RangeX));
    Top := LongInt((Result.Count * PartStep div 3) mod QWord(RangeY));
    DrawInMemory(Left, Top, Size, Size, Result.Count);
    Present(Left, Top, Size, Size);
    Inc(Result.Count);
    Result.Milliseconds := UptimeMilliseconds - Start;
  until Result.Milliseconds >= Milliseconds;
end;

function MeasureCursor(Milliseconds: QWord): TMeasurement;
var
  Image: array[0..15] of LongWord;
  Start: QWord;
begin
  FillChar(Image, SizeOf(Image), $FF);
  SetDisplayCursorImage(Display, @Image[0], 4, 4, 0, 0);
  ShowDisplayCursor(Display, True);
  Result.Count := 0;
  Start := UptimeMilliseconds;
  repeat
    MoveDisplayCursor(Display, LongInt(Result.Count mod Display.Width), LongInt(Result.Count mod Display.Height));
    Inc(Result.Count);
    Result.Milliseconds := UptimeMilliseconds - Start;
  until Result.Milliseconds >= Milliseconds;
  ShowDisplayCursor(Display, False);
end;

function Rate(const Measurement: TMeasurement): string;
begin
  if Measurement.Milliseconds = 0 then
    Exit('-');
  Result := FormatFloat('0.0', Measurement.Count * 1000.0 / Measurement.Milliseconds);
end;

procedure Report(const What: string; const Measurement: TMeasurement; const Unit_: string);
begin
  PrintStringLine(Format('%s: %u %s in %u ms, %s %s/s',
    [What, Measurement.Count, Unit_, Measurement.Milliseconds, Rate(Measurement), Unit_]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Number: QWord;
  Seconds: QWord;
  Error: LongInt;
  PartEdge: LongInt;
begin
  Number := 0;
  Seconds := DefaultSeconds;
  CommandLine := TCommandLine.Create([CommandOption('d', 'display', True, OptionNumber),
    CommandOption('s', 'seconds', True, OptionSeconds)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    case Code of
      OptionNumber:
        if not ParseUnsignedDecimal(OptionValue, Number) or (Number > 63) then
          FailWithUsageHint('the display must be a number');
      OptionSeconds:
        if not ParseUnsignedDecimal(OptionValue, Seconds) or (Seconds = 0) or (Seconds > 600) then
          FailWithUsageHint('the time must be a whole number of seconds, 1 to 600');
    end;
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken');
  CommandLine.Free;
  Error := OpenDisplay(Display, LongInt(Number));
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('display %u', [Number]));
  SetLength(BackBuffer, QWord(Display.Width) * Display.Height);
  PrintStringLine(Format('displaybench: display %u, %ux%u, %s', [Number, Display.Width, Display.Height,
    DescribeDriving]));
  Report('full screen', MeasureFullScreen(Seconds * 1000), 'frames');
  PartEdge := PartSize;
  if PartEdge > LongInt(Display.Width) then
    PartEdge := Display.Width;
  if PartEdge > LongInt(Display.Height) then
    PartEdge := Display.Height;
  Report(Format('partial (%dx%d)', [PartEdge, PartEdge]), MeasurePart(Seconds * 1000, PartEdge), 'frames');
  if DisplayHasHardwareCursor(Display) then
    Report('cursor', MeasureCursor(Seconds * 1000), 'moves');
  CloseDisplay(Display);
end.
