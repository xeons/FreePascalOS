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
  factor - print the prime factors of numbers

  factor [NUMBER]...

  Reads numbers from standard input when none are given. Numbers up to
  2^64 - 1 are factored by trial division up to the square root,
  stepping over multiples of 2 and 3.
}
program factor;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: factor [NUMBER]...'#10 +
    'Print the prime factors of each specified integer NUMBER.  If none'#10 +
    'are specified on the command line, read them from standard input.'#10;

  Spaces = [' ', #9, #10, #11, #12, #13];

{ True if Divisor * Divisor <= Value, without overflowing. }
function SquareFits(Divisor, Value: QWord): Boolean;
begin
  Result := Divisor <= Value div Divisor;
end;

{ " 2 2 3" for 12. }
function PrimeFactors(Value: QWord): string;
var
  Divisor: QWord;
  Step: QWord;
begin
  Result := '';
  while (Value > 1) and (Value mod 2 = 0) do
  begin
    Result := Result + ' 2';
    Value := Value div 2;
  end;
  while (Value > 1) and (Value mod 3 = 0) do
  begin
    Result := Result + ' 3';
    Value := Value div 3;
  end;
  { Candidates 5, 7, 11, 13, ...: steps of 2 and 4 skip multiples of 2 and 3. }
  Divisor := 5;
  Step := 2;
  while (Value > 1) and SquareFits(Divisor, Value) do
  begin
    while Value mod Divisor = 0 do
    begin
      Result := Result + ' ' + IntToStr(Divisor);
      Value := Value div Divisor;
    end;
    Divisor := Divisor + Step;
    Step := 6 - Step;
  end;
  if Value > 1 then
    Result := Result + ' ' + IntToStr(Value);
end;

procedure Factor(const Text: string; var ExitStatus: LongInt);
var
  Value: QWord;
begin
  if not ParseUnsignedDecimal(Text, Value) then
  begin
    Report(Format('''%s'' is not a valid positive integer', [Text]));
    ExitStatus := 1;
    Exit;
  end;
  PrintString(IntToStr(Value) + ':' + PrimeFactors(Value) + #10);
end;

{ Factors every number on Line (separated by white space). }
procedure FactorLine(const Line: string; var ExitStatus: LongInt);
var
  Position: Integer;
  Start: Integer;
begin
  Position := 1;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and (Line[Position] in Spaces) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and not (Line[Position] in Spaces) do
      Inc(Position);
    Factor(Copy(Line, Start, Position - Start), ExitStatus);
  end;
end;

var
  CommandLine: TCommandLine;
  Operand: string;
  ExitStatus: LongInt;
  Line: string;
  HadLineEnd: Boolean;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  ExitStatus := 0;
  if CommandLine.OperandCount > 0 then
    for Operand in CommandLine.Operands do
      Factor(Operand, ExitStatus)
  else
    while ReadTextLine(StandardInput, Line, HadLineEnd) do
      FactorLine(Line, ExitStatus);
  Halt(ExitStatus);
end.
