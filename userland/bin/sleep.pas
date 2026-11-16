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
  sleep - delay for a specified amount of time

  sleep NUMBER[SUFFIX]...

  Pauses for the sum of the given times. NUMBER may have a fraction
  (0.5); SUFFIX is s (seconds, the default), m (minutes), h (hours) or
  d (days).
}
program sleep;

{$mode objfpc}
{$H+}

uses
  Sys.Format,
  Sys.Processes,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: sleep NUMBER[SUFFIX]...'#10 +
    'Pause for NUMBER seconds. SUFFIX may be ''s'' for seconds (the default),'#10 +
    '''m'' for minutes, ''h'' for hours or ''d'' for days. NUMBER may be a'#10 +
    'decimal fraction. Given two or more arguments, pause for their sum.'#10;

  MillisecondsPerSecond = 1000;
  { Three decimals are as precise as the clock. }
  FractionDigitLimit = 3;

function UnitMultiplier(const Suffix: string; out Multiplier: QWord): Boolean;
begin
  Result := True;
  if (Suffix = '') or (Suffix = 's') then
    Multiplier := MillisecondsPerSecond
  else if Suffix = 'm' then
    Multiplier := 60 * MillisecondsPerSecond
  else if Suffix = 'h' then
    Multiplier := 60 * 60 * MillisecondsPerSecond
  else if Suffix = 'd' then
    Multiplier := 24 * 60 * 60 * MillisecondsPerSecond
  else
    Result := False;
end;

{ Parses "1.5m" into milliseconds. }
function ParseDuration(const Text: string; out Milliseconds: QWord): Boolean;
var
  Position: Integer;
  Whole: QWord;
  Fraction: QWord;
  FractionScale: QWord;
  FractionDigits: Integer;
  Multiplier: QWord;
begin
  Milliseconds := 0;
  Whole := 0;
  Fraction := 0;
  FractionScale := 1;
  FractionDigits := 0;
  if (Text = '') or not (Text[1] in ['0'..'9', '.']) then
    Exit(False);
  Position := 1;
  while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
  begin
    Whole := Whole * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  if (Position <= Length(Text)) and (Text[Position] = '.') then
  begin
    Inc(Position);
    while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
    begin
      if FractionDigits < FractionDigitLimit then
      begin
        Fraction := Fraction * 10 + QWord(Ord(Text[Position]) - Ord('0'));
        FractionScale := FractionScale * 10;
        Inc(FractionDigits);
      end;
      Inc(Position);
    end;
  end;
  if not UnitMultiplier(Copy(Text, Position, MaxInt), Multiplier) then
    Exit(False);
  Milliseconds := Whole * Multiplier + (Fraction * Multiplier) div FractionScale;
  Result := True;
end;

var
  Parser: TOptionParser;
  Index: Integer;
  Total: QWord;
  Duration: QWord;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  Total := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if not ParseDuration(Parser.Operands[Index], Duration) then
      FailWithUsageHint('invalid time interval ''%s''', [ArgumentText(Parser.Operands[Index])]);
    Total := Total + Duration;
  end;
  SleepMilliseconds(Total);
end.
