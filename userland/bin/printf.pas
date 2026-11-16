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
  printf - format and print data

  printf FORMAT [ARGUMENT]...

  Like the C function: FORMAT is printed with each % conversion replaced
  by the next ARGUMENT. Conversions: %s %b (text with escapes) %c
  %d %i %u %x %X %o %%, with flags (- 0 +), width and precision
  ("*" takes them from an argument). Escapes in FORMAT: \n \t \\ \"
  \a \b \f \r \v \NNN (octal). If there are more arguments than
  conversions, FORMAT is used again.
}
program printf;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Format,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers;

var
  Arguments: TStringArray;
  NextArgumentIndex: Integer;
  ExitStatus: LongInt;
  ConsumedAny: Boolean;

{ The character at Position (1-based), #0 past the end. }
function CharacterAt(const Text: string; Position: Integer): Char;
begin
  if (Position >= 1) and (Position <= Length(Text)) then
    Result := Text[Position]
  else
    Result := #0;
end;

{ The next argument, '' once they are used up. }
function NextArgument: string;
begin
  if NextArgumentIndex > High(Arguments) then
    Exit('');
  Result := Arguments[NextArgumentIndex];
  Inc(NextArgumentIndex);
  ConsumedAny := True;
end;

function ArgumentsLeft: Boolean;
begin
  Result := NextArgumentIndex <= High(Arguments);
end;

{ Numbers may be written 'c (the code of character c) or in decimal,
  0x hexadecimal or 0 octal. }
function ArgumentAsNumber(const Text: string): Int64;
var
  IsNegative: Boolean;
  Base: Integer;
  Digit: Integer;
  Position: Integer;
  Character: Char;
begin
  Result := 0;
  if Text = '' then
    Exit;
  if (Text[1] = '''') or (Text[1] = '"') then
    Exit(Ord(CharacterAt(Text, 2)));
  if ParseDecimal(Text, Result) then
    Exit;

  Position := 1;
  IsNegative := Text[1] = '-';
  if IsNegative or (Text[1] = '+') then
    Inc(Position);
  Base := 10;
  if (CharacterAt(Text, Position) = '0') and (LowerCase(CharacterAt(Text, Position + 1)) = 'x') then
  begin
    Base := 16;
    Inc(Position, 2);
  end
  else if CharacterAt(Text, Position) = '0' then
    Base := 8;
  while Position <= Length(Text) do
  begin
    Character := LowerCase(Text[Position]);
    if Character in ['0'..'9'] then
      Digit := Ord(Character) - Ord('0')
    else if Character in ['a'..'f'] then
      Digit := Ord(Character) - Ord('a') + 10
    else
      Digit := 99;
    if Digit >= Base then
    begin
      Report(Format('''%s'': expected a numeric value', [Text]));
      ExitStatus := 1;
      Break;
    end;
    Result := Result * Base + Digit;
    Inc(Position);
  end;
  if IsNegative then
    Result := -Result;
end;

{ Interprets one backslash escape at Text[Position] (just after the
  backslash); returns False for \c, which stops all output. }
function WriteEscape(const Text: string; var Position: Integer; OctalNeedsZero: Boolean): Boolean;
var
  Value: Integer;
  DigitCount: Integer;
begin
  Result := True;
  case Text[Position] of
    'n': WriteCharacter(StandardOutput, #10);
    't': WriteCharacter(StandardOutput, #9);
    'r': WriteCharacter(StandardOutput, #13);
    'a': WriteCharacter(StandardOutput, #7);
    'b': WriteCharacter(StandardOutput, #8);
    'f': WriteCharacter(StandardOutput, #12);
    'v': WriteCharacter(StandardOutput, #11);
    'e': WriteCharacter(StandardOutput, #27);
    '\': WriteCharacter(StandardOutput, '\');
    '"': WriteCharacter(StandardOutput, '"');
    '''': WriteCharacter(StandardOutput, '''');
    'c': Exit(False);
    '0'..'7':
      begin
        if OctalNeedsZero and (Text[Position] <> '0') then
        begin
          WriteCharacter(StandardOutput, '\');
          WriteCharacter(StandardOutput, Text[Position]);
        end
        else
        begin
          Value := 0;
          DigitCount := 0;
          if OctalNeedsZero then
            Inc(Position);
          while (DigitCount < 3) and (CharacterAt(Text, Position) in ['0'..'7']) do
          begin
            Value := Value * 8 + Ord(Text[Position]) - Ord('0');
            Inc(Position);
            Inc(DigitCount);
          end;
          Dec(Position);
          WriteCharacter(StandardOutput, Char(Value and $FF));
        end;
      end;
  else
    begin
      WriteCharacter(StandardOutput, '\');
      WriteCharacter(StandardOutput, Text[Position]);
    end;
  end;
  Inc(Position);
end;

{ %b: the argument with escapes interpreted. }
function WriteWithEscapes(const Text: string): Boolean;
var
  Position: Integer;
begin
  Result := True;
  Position := 1;
  while Position <= Length(Text) do
  begin
    if (Text[Position] = '\') and (Position < Length(Text)) then
    begin
      Inc(Position);
      if not WriteEscape(Text, Position, True) then
        Exit(False);
    end
    else
    begin
      WriteCharacter(StandardOutput, Text[Position]);
      Inc(Position);
    end;
  end;
end;

{ Prints FORMAT once. Returns False if output must stop (\c). }
function PrintFormatOnce(const FormatText: string): Boolean;
var
  Position: Integer;
  Specification: string;
  Conversion: Char;
  Number: Int64;
  Value: string;
begin
  Result := True;
  Position := 1;
  while Position <= Length(FormatText) do
  begin
    if FormatText[Position] = '\' then
    begin
      Inc(Position);
      if Position > Length(FormatText) then
      begin
        WriteCharacter(StandardOutput, '\');
        Break;
      end;
      if not WriteEscape(FormatText, Position, False) then
        Exit(False);
      Continue;
    end;
    if FormatText[Position] <> '%' then
    begin
      WriteCharacter(StandardOutput, FormatText[Position]);
      Inc(Position);
      Continue;
    end;
    if CharacterAt(FormatText, Position + 1) = '%' then
    begin
      WriteCharacter(StandardOutput, '%');
      Inc(Position, 2);
      Continue;
    end;

    { Collect the specification, replacing * with argument values, and
      hand it to the library formatter. }
    Specification := '%';
    Inc(Position);
    while CharacterAt(FormatText, Position) in ['-', '+', ' ', '#', '0'..'9', '.', '*'] do
    begin
      if FormatText[Position] = '*' then
        Specification := Specification + IntToStr(ArgumentAsNumber(NextArgument))
      else
        Specification := Specification + FormatText[Position];
      Inc(Position);
    end;
    { Length modifiers such as l or h make no difference here. }
    while CharacterAt(FormatText, Position) in ['l', 'h', 'j', 'z', 't', 'L'] do
      Inc(Position);
    Conversion := CharacterAt(FormatText, Position);
    if Conversion = #0 then
    begin
      Report(Specification + ': missing conversion specifier');
      ExitStatus := 1;
      Break;
    end;
    Inc(Position);

    case Conversion of
      's':
        begin
          Specification := Specification + 's';
          Value := NextArgument;
          { The C style formatter of the system library (flags, %o and
            lower case %x, which SysUtils' Format lacks). }
          WriteFormatted(StandardOutput, PChar(Specification), [ArgumentText(PChar(Value))]);
        end;
      'b':
        if not WriteWithEscapes(NextArgument) then
          Exit(False);
      'c':
        begin
          Value := NextArgument;
          if Value <> '' then
            WriteCharacter(StandardOutput, Value[1]);
        end;
      'd', 'i', 'u', 'x', 'X', 'o':
        begin
          Specification := Specification + Conversion;
          Number := ArgumentAsNumber(NextArgument);
          if Conversion in ['d', 'i'] then
            WriteFormatted(StandardOutput, PChar(Specification), [ArgumentNumber(Number)])
          else
            WriteFormatted(StandardOutput, PChar(Specification), [ArgumentUnsigned(QWord(Number))]);
        end;
    else
      begin
        Report('%' + Conversion + ': invalid conversion specification');
        ExitStatus := 1;
        Exit(False);
      end;
    end;
  end;
end;

var
  FormatText: string;
begin
  ExitStatus := 0;
  { FORMAT may itself start with '-': no option parsing. }
  Arguments := ProgramArguments;
  if Length(Arguments) = 0 then
    FailWithUsageHint('missing operand');
  if Arguments[0] = '--help' then
  begin
    PrintStringLine('Usage: printf FORMAT [ARGUMENT]...');
    PrintStringLine('Print ARGUMENT(s) according to FORMAT.');
    Halt(0);
  end;

  FormatText := Arguments[0];
  NextArgumentIndex := 1;
  if (FormatText = '--') and (Length(Arguments) >= 2) then
  begin
    FormatText := Arguments[1];
    NextArgumentIndex := 2;
  end;

  repeat
    ConsumedAny := False;
    if not PrintFormatOnce(FormatText) then
      Break;
  until not ArgumentsLeft or not ConsumedAny;
  Halt(ExitStatus);
end.
