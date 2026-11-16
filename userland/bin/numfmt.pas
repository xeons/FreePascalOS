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
  numfmt - convert numbers from or to human-readable strings

  numfmt [--from=UNIT] [--to=UNIT] [--suffix=TEXT] [--padding=N]
         [--field=N] [--header[=N]] [-d CHAR] [NUMBER]...

  UNIT is none, si (K = 1000), iec (K = 1024) or iec-i (Ki = 1024);
  --from also accepts auto (Ki is 1024, K is 1000). Numbers come from
  the arguments or, one per line, from standard input. Results are
  rounded up, as GNU numfmt does by default.
}
program numfmt;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: numfmt [OPTION]... [NUMBER]...'#10 +
    'Reformat NUMBER(s), or the numbers from standard input if none are specified.'#10#10 +
    '  -d, --delimiter=X    use X instead of whitespace for field delimiter'#10 +
    '      --field=N        replace the number in input field N (default is 1)'#10 +
    '      --from=UNIT      auto-scale input numbers to UNITs; default is ''none'''#10 +
    '      --header[=N]     print (without converting) the first N header lines'#10 +
    '      --padding=N      pad the output to N characters'#10 +
    '      --suffix=SUFFIX  add SUFFIX to output numbers, and accept optional'#10 +
    '                         SUFFIX in input numbers'#10 +
    '      --to=UNIT        auto-scale output numbers to UNITs'#10#10 +
    'UNIT options: none, auto (--from only), si, iec, iec-i'#10;

  OptionDelimiter = 1;
  OptionField = 2;
  OptionFrom = 3;
  OptionHeader = 4;
  OptionPadding = 5;
  OptionSuffix = 6;
  OptionTo = 7;

  UnitLetters = 'KMGTPEZY';

type
  TUnit = (UnitNone, UnitAuto, UnitSi, UnitIec, UnitIecI);

var
  FromUnit: TUnit;
  ToUnit: TUnit;
  Suffix: string;
  Padding: Int64;
  FieldNumber: Int64;
  Delimiter: Char;
  ExitStatus: LongInt;

procedure WriteString(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

{ The character at Position (1-based), #0 past the end. }
function CharacterAt(const Text: string; Position: Integer): Char;
begin
  if (Position >= 1) and (Position <= Length(Text)) then
    Result := Text[Position]
  else
    Result := #0;
end;

function ParseUnit(const Text: string; AllowAuto: Boolean): TUnit;
begin
  if Text = 'none' then Result := UnitNone
  else if Text = 'si' then Result := UnitSi
  else if Text = 'iec' then Result := UnitIec
  else if Text = 'iec-i' then Result := UnitIecI
  else if AllowAuto and (Text = 'auto') then Result := UnitAuto
  else
  begin
    Fail(1, 'invalid unit: ''%s''', [ArgumentText(PChar(Text))]);
    Result := UnitNone;
  end;
end;

{ Parses "1.5K" style numbers into a value scaled by 1000 (milli-units),
  so a fraction survives. }
function ParseHuman(const Text: string; out Thousandths: Int64): Boolean;
var
  Position: Integer;
  Whole: Int64;
  Fraction: Int64;
  FractionScale: Int64;
  Negative: Boolean;
  Letter: Integer;
  Base: Int64;
  Power: Integer;
  Multiplier: Int64;
begin
  Result := False;
  Thousandths := 0;
  Position := 1;
  Negative := CharacterAt(Text, 1) = '-';
  if Negative then
    Inc(Position);
  if not IsDigit(CharacterAt(Text, Position)) then
    Exit;
  Whole := 0;
  while IsDigit(CharacterAt(Text, Position)) do
  begin
    Whole := Whole * 10 + Ord(Text[Position]) - Ord('0');
    Inc(Position);
  end;
  Fraction := 0;
  FractionScale := 1;
  if CharacterAt(Text, Position) = '.' then
  begin
    Inc(Position);
    while IsDigit(CharacterAt(Text, Position)) do
    begin
      if FractionScale < 1000 then
      begin
        Fraction := Fraction * 10 + Ord(Text[Position]) - Ord('0');
        FractionScale := FractionScale * 10;
      end;
      Inc(Position);
    end;
  end;
  Multiplier := 1;
  if (Position <= Length(Text)) and (FromUnit <> UnitNone) then
  begin
    Letter := Pos(UpCase(Text[Position]), UnitLetters) - 1;
    if Letter >= 0 then
    begin
      Inc(Position);
      Base := 1000;
      if (FromUnit = UnitIec) or ((FromUnit in [UnitIecI, UnitAuto]) and (CharacterAt(Text, Position) = 'i')) then
        Base := 1024;
      if (FromUnit = UnitIecI) and (CharacterAt(Text, Position) <> 'i') then
        Exit;
      if CharacterAt(Text, Position) = 'i' then
        Inc(Position);
      for Power := 0 to Letter do
        Multiplier := Multiplier * Base;
    end;
  end;
  { An optional suffix may follow. }
  if PosEx(Suffix, Text, Position) = Position then
    Position := Position + Length(Suffix);
  if Position <= Length(Text) then
    Exit;
  Thousandths := Whole * Multiplier * 1000 + (Fraction * 1000 div FractionScale) * Multiplier;
  if Negative then
    Thousandths := -Thousandths;
  Result := True;
end;

{ A number (in thousandths) scaled to ToUnit. }
function FormatHuman(Thousandths: Int64): string;
var
  Negative: Boolean;
  Value: QWord;
  Base: QWord;
  Power: Integer;
  Divisor: QWord;
  Tenths: QWord;
begin
  Result := '';
  Negative := Thousandths < 0;
  if Negative then
  begin
    Thousandths := -Thousandths;
    Result := '-';
  end;
  if ToUnit = UnitNone then
  begin
    { Round up to a whole number. }
    Result := Result + IntToStr((QWord(Thousandths) + 999) div 1000);
  end
  else
  begin
    if ToUnit = UnitSi then
      Base := 1000
    else
      Base := 1024;
    Value := (QWord(Thousandths) + 999) div 1000;
    Power := -1;
    Divisor := 1;
    while (Value div Divisor >= Base) and (Power < 7) do
    begin
      Divisor := Divisor * Base;
      Inc(Power);
    end;
    if Power < 0 then
      Result := Result + IntToStr(Value)
    else
    begin
      Tenths := (Value * 10 + Divisor - 1) div Divisor;
      if Tenths >= 100 then
        Result := Result + IntToStr((Tenths + 9) div 10)
      else
        Result := Result + IntToStr(Tenths div 10) + '.' + Char(Ord('0') + Tenths mod 10);
      Result := Result + UnitLetters[Power + 1];
      if ToUnit = UnitIecI then
        Result := Result + 'i';
    end;
  end;
  Result := Result + Suffix;
end;

procedure WritePadded(const Text: string);
begin
  if Length(Text) < Padding then
    WriteString(StringOfChar(' ', Padding - Length(Text)));
  WriteString(Text);
  if Length(Text) < -Padding then
    WriteString(StringOfChar(' ', -Padding - Length(Text)));
end;

procedure ConvertNumber(const Text: string);
var
  Value: Int64;
begin
  if not ParseHuman(Text, Value) then
  begin
    Report('invalid number: ''%s''', [ArgumentText(PChar(Text))]);
    ExitStatus := 2;
    WriteString(Text);
    Exit;
  end;
  WritePadded(FormatHuman(Value));
end;

function IsFieldEnd(Character: Char): Boolean;
begin
  if Delimiter = #0 then
    Result := IsSpace(Character)
  else
    Result := Character = Delimiter;
end;

{ Converts field FieldNumber of Line, copying the rest unchanged. }
procedure ConvertLine(const Line: string);
var
  Position: Integer;
  Field: Int64;
  Start: Integer;
begin
  Position := 1;
  Field := 1;
  while True do
  begin
    { Leading blanks belong to the field when splitting on whitespace. }
    Start := Position;
    if Delimiter = #0 then
      while CharacterAt(Line, Position) in [' ', #9] do
        Inc(Position);
    while (Position <= Length(Line)) and not IsFieldEnd(Line[Position]) do
      Inc(Position);
    if Field = FieldNumber then
    begin
      while CharacterAt(Line, Start) in [' ', #9] do
      begin
        WriteCharacter(StandardOutput, Line[Start]);
        Inc(Start);
      end;
      ConvertNumber(Copy(Line, Start, Position - Start));
    end
    else
      WriteString(Copy(Line, Start, Position - Start));
    if Position > Length(Line) then
      Break;
    WriteCharacter(StandardOutput, Line[Position]);
    Inc(Position);
    Inc(Field);
  end;
  WriteCharacter(StandardOutput, #10);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  HeaderLines: Int64;
  Index: Integer;
  Line: PChar;
  HadLineEnd: Boolean;
begin
  FromUnit := UnitNone;
  ToUnit := UnitNone;
  Suffix := '';
  Padding := 0;
  FieldNumber := 1;
  Delimiter := #0;
  HeaderLines := 0;
  BeginOptions(Parser, [
    OptionDefinition('d', 'delimiter', True, OptionDelimiter),
    OptionDefinition(#0, 'field', True, OptionField),
    OptionDefinition(#0, 'from', True, OptionFrom),
    OptionDefinition(#0, 'header', False, OptionHeader),
    OptionDefinition(#0, 'padding', True, OptionPadding),
    OptionDefinition(#0, 'suffix', True, OptionSuffix),
    OptionDefinition(#0, 'to', True, OptionTo)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDelimiter:
        begin
          if Length(string(Value)) <> 1 then
            Fail(1, 'the delimiter must be a single character', []);
          Delimiter := Value[0];
        end;
      OptionField:
        if not ParseInteger(Value, FieldNumber) or (FieldNumber < 1) then
          Fail(1, 'invalid field value ''%s''', [ArgumentText(Value)]);
      OptionFrom: FromUnit := ParseUnit(Value, True);
      OptionHeader: HeaderLines := 1;
      OptionPadding:
        if not ParseInteger(Value, Padding) or (Padding = 0) then
          Fail(1, 'invalid padding value ''%s''', [ArgumentText(Value)]);
      OptionSuffix: Suffix := Value;
      OptionTo: ToUnit := ParseUnit(Value, False);
    end;

  ExitStatus := 0;
  if Parser.OperandCount > 0 then
  begin
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      ConvertNumber(Parser.Operands[Index]);
      WriteCharacter(StandardOutput, #10);
    end;
    Halt(ExitStatus);
  end;
  while ReadLine(StandardInput, Line, HadLineEnd) do
  begin
    if HeaderLines > 0 then
    begin
      WriteLine(StandardOutput, Line);
      Dec(HeaderLines);
    end
    else
      ConvertLine(Line);
    FreeMemory(Line);
  end;
  Halt(ExitStatus);
end.
