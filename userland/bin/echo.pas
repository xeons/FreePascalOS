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
  echo - display a line of text

  echo [-neE] [STRING]...

  Writes the arguments separated by single spaces, followed by a line
  end. -n leaves out the line end, -e interprets backslash escapes
  (\n \t \\ \a \b \r \v \f \0NNN \c), -E disables them (the default).
  As in GNU echo, options are only recognized before the first string,
  and "--help" is not special.
}
program echo;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Sys.Streams;

var
  PrintLineEnd: Boolean;
  InterpretEscapes: Boolean;

function IsEchoOption(const Text: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if (Length(Text) < 2) or (Text[1] <> '-') then
    Exit;
  for Index := 2 to Length(Text) do
    if not (Text[Index] in ['n', 'e', 'E']) then
      Exit;
  Result := True;
end;

procedure ApplyOption(const Text: string);
var
  Index: Integer;
begin
  for Index := 2 to Length(Text) do
    case Text[Index] of
      'n': PrintLineEnd := False;
      'e': InterpretEscapes := True;
      'E': InterpretEscapes := False;
    end;
end;

{ Text with escapes interpreted. Stopped becomes True at \c, which ends
  all output (Result holds what came before it). }
function InterpretText(const Text: string; out Stopped: Boolean): string;
var
  Index: Integer;
  Value: Integer;
  DigitCount: Integer;
begin
  Result := '';
  Stopped := False;
  Index := 1;
  while Index <= Length(Text) do
  begin
    if (Text[Index] <> '\') or (Index = Length(Text)) then
    begin
      Result := Result + Text[Index];
      Inc(Index);
      Continue;
    end;
    Inc(Index);
    case Text[Index] of
      'n': Result := Result + #10;
      't': Result := Result + #9;
      'r': Result := Result + #13;
      'a': Result := Result + #7;
      'b': Result := Result + #8;
      'v': Result := Result + #11;
      'f': Result := Result + #12;
      'e': Result := Result + #27;
      '\': Result := Result + '\';
      'c':
        begin
          Stopped := True;
          Exit;
        end;
      '0':
        begin
          Value := 0;
          DigitCount := 0;
          while (DigitCount < 3) and (Index < Length(Text)) and (Text[Index + 1] in ['0'..'7']) do
          begin
            Inc(Index);
            Value := Value * 8 + Ord(Text[Index]) - Ord('0');
            Inc(DigitCount);
          end;
          Result := Result + Char(Value and $FF);
        end;
    else
      Result := Result + '\' + Text[Index];
    end;
    Inc(Index);
  end;
end;

var
  Arguments: TStringArray;
  ArgumentIndex: Integer;
  FirstString: Integer;
  Stopped: Boolean;
begin
  PrintLineEnd := True;
  InterpretEscapes := False;
  Arguments := ProgramArguments;

  ArgumentIndex := 0;
  while (ArgumentIndex < Length(Arguments)) and IsEchoOption(Arguments[ArgumentIndex]) do
  begin
    ApplyOption(Arguments[ArgumentIndex]);
    Inc(ArgumentIndex);
  end;

  FirstString := ArgumentIndex;
  while ArgumentIndex < Length(Arguments) do
  begin
    if ArgumentIndex > FirstString then
      PrintString(' ');
    if InterpretEscapes then
    begin
      PrintString(InterpretText(Arguments[ArgumentIndex], Stopped));
      if Stopped then
        Halt(0);
    end
    else
      PrintString(Arguments[ArgumentIndex]);
    Inc(ArgumentIndex);
  end;
  if PrintLineEnd then
    PrintString(#10);
end.
