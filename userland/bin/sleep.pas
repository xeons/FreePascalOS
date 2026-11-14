{
  sleep - delay for a specified amount of time

  sleep NUMBER[SUFFIX]...

  Pauses for the sum of the given times. NUMBER may have a fraction
  (0.5); SUFFIX is s (seconds, the default), m (minutes), h (hours) or
  d (days).
}
program sleep;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Processes,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: sleep NUMBER[SUFFIX]...'#10 +
    'Pause for NUMBER seconds. SUFFIX may be ''s'' for seconds (the default),'#10 +
    '''m'' for minutes, ''h'' for hours or ''d'' for days. NUMBER may be a'#10 +
    'decimal fraction. Given two or more arguments, pause for their sum.'#10;

{ Parses "1.5m" into milliseconds. }
function ParseDuration(Text: PChar; out Milliseconds: QWord): Boolean;
var
  Position: Integer;
  Whole: QWord;
  Fraction: QWord;
  FractionScale: QWord;
  Multiplier: QWord;
begin
  Milliseconds := 0;
  Position := 0;
  Whole := 0;
  Fraction := 0;
  FractionScale := 1;
  if not IsDigit(Text[0]) and (Text[0] <> '.') then
    Exit(False);
  while IsDigit(Text[Position]) do
  begin
    Whole := Whole * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  if Text[Position] = '.' then
  begin
    Inc(Position);
    while IsDigit(Text[Position]) do
    begin
      { Three decimals are as precise as the clock. }
      if FractionScale < 1000 then
      begin
        Fraction := Fraction * 10 + QWord(Ord(Text[Position]) - Ord('0'));
        FractionScale := FractionScale * 10;
      end;
      Inc(Position);
    end;
  end;
  case Text[Position] of
    #0, 's': Multiplier := 1000;
    'm': Multiplier := 60 * 1000;
    'h': Multiplier := 60 * 60 * 1000;
    'd': Multiplier := 24 * 60 * 60 * 1000;
  else
    Exit(False);
  end;
  if (Text[Position] <> #0) and (Text[Position + 1] <> #0) then
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
