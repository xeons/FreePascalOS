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

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: factor [NUMBER]...'#10 +
    'Print the prime factors of each specified integer NUMBER.  If none'#10 +
    'are specified on the command line, read them from standard input.'#10;

procedure PrintFactor(Value: QWord);
begin
  WriteCharacter(StandardOutput, ' ');
  WriteUnsigned(StandardOutput, Value);
end;

{ True if Divisor * Divisor <= Value, without overflowing. }
function SquareFits(Divisor, Value: QWord): Boolean;
begin
  Result := Divisor <= Value div Divisor;
end;

procedure Factor(Text: PChar; var ExitStatus: LongInt);
var
  Value: QWord;
  Divisor: QWord;
  Step: QWord;
begin
  if not ParseUnsigned(Text, Value) then
  begin
    Report('''%s'' is not a valid positive integer', [ArgumentText(Text)]);
    ExitStatus := 1;
    Exit;
  end;
  WriteUnsigned(StandardOutput, Value);
  WriteCharacter(StandardOutput, ':');
  while (Value > 1) and (Value mod 2 = 0) do
  begin
    PrintFactor(2);
    Value := Value div 2;
  end;
  while (Value > 1) and (Value mod 3 = 0) do
  begin
    PrintFactor(3);
    Value := Value div 3;
  end;
  { Candidates 5, 7, 11, 13, ...: steps of 2 and 4 skip multiples of 2 and 3. }
  Divisor := 5;
  Step := 2;
  while (Value > 1) and SquareFits(Divisor, Value) do
  begin
    while Value mod Divisor = 0 do
    begin
      PrintFactor(Divisor);
      Value := Value div Divisor;
    end;
    Divisor := Divisor + Step;
    Step := 6 - Step;
  end;
  if Value > 1 then
    PrintFactor(Value);
  WriteCharacter(StandardOutput, #10);
end;

var
  Parser: TOptionParser;
  Index: Integer;
  ExitStatus: LongInt;
  Line: PChar;
  HadLineEnd: Boolean;
  Position: PtrUInt;
  Start: PtrUInt;
begin
  ParseOperandsOnly(Parser, Usage);
  ExitStatus := 0;
  if Parser.OperandCount > 0 then
    for Index := 0 to Parser.OperandCount - 1 do
      Factor(Parser.Operands[Index], ExitStatus)
  else
    while ReadLine(StandardInput, Line, HadLineEnd) do
    begin
      Position := 0;
      while Line[Position] <> #0 do
      begin
        while IsSpace(Line[Position]) do
          Inc(Position);
        if Line[Position] = #0 then
          Break;
        Start := Position;
        while (Line[Position] <> #0) and not IsSpace(Line[Position]) do
          Inc(Position);
        if Line[Position] <> #0 then
        begin
          Line[Position] := #0;
          Inc(Position);
        end;
        Factor(Line + Start, ExitStatus);
      end;
      FreeMemory(Line);
    end;
  Halt(ExitStatus);
end.
