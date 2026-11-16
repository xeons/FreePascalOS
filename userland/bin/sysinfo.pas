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
  sysinfo - show what the system is, beside its logo

  sysinfo [-l] [-c|-C]

  Prints the user and machine, then the system's facts (SystemInfo.Facts:
  the system and kernel, uptime, programs, shell, displays, terminal,
  processor, memory, processes, disks, time zone) to the right of the
  logo, and two rows of the terminal's sixteen colours.

  Colours are used when standard output is a terminal and NO_COLOR is
  not set; -c forces them, -C turns them off. -l leaves out the logo.
}
program sysinfo;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.Format,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  SystemInfo.Facts,
  SystemInfo.Logo;

const
  Usage: PChar = 'Usage: sysinfo [OPTION]...'#10 +
    'Show information about the system beside its logo.'#10#10 +
    '  -l, --no-logo    leave out the logo'#10 +
    '  -c, --color      use colours even when not writing to a terminal'#10 +
    '  -C, --no-color   use no colours'#10;

  OptionNoLogo = 1;
  OptionColor = 2;
  OptionNoColor = 3;

  { Columns between the logo and the facts. }
  LogoGap = 3;

  Escape = #27;
  ResetColour = Escape + '[0m';
  LabelColour = Escape + '[96m';
  TitleColour = Escape + '[93m';
  LogoColours: array[TLogoPart] of string = (Escape + '[96m', Escape + '[94m', Escape + '[93m');

var
  UseColours: Boolean;
  ShowLogo: Boolean;

procedure Write(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

function Coloured(const Colour, Text: string): string;
begin
  if UseColours then
    Result := Colour + Text + ResetColour
  else
    Result := Text;
end;

function OutputIsTerminal: Boolean;
begin
  Result := IsConsole(StandardOutputHandle) or (TerminalNumber(StandardOutputHandle) >= 0);
end;

{ Logo line Line (blank past its end), coloured, with the gap after it;
  nothing without a logo. }
function LogoColumn(Line: LongInt): string;
var
  Column: LongInt;
  Part: TLogoPart;
  Run: string;
begin
  if not ShowLogo then
    Exit('');
  if Line >= LogoLineCount then
    Exit(StringOfChar(' ', LogoWidth + LogoGap));
  Result := '';
  Run := '';
  Part := LogoPartAt(Line, 0);
  for Column := 0 to LogoWidth - 1 do
  begin
    if LogoPartAt(Line, Column) <> Part then
    begin
      Result := Result + Coloured(LogoColours[Part], Run);
      Run := '';
      Part := LogoPartAt(Line, Column);
    end;
    Run := Run + LogoLines[Line][Column + 1];
  end;
  Result := Result + Coloured(LogoColours[Part], Run) + StringOfChar(' ', LogoGap);
end;

{ The sixteen colours as blocks: the normal eight (First = 40) or the
  bright eight (First = 100). }
function ColourBlocks(First: LongInt): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to 7 do
    Result := Result + Escape + '[' + IntToStr(First + Index) + 'm   ';
  Result := Result + ResetColour;
end;

procedure ShowEverything;
var
  Facts: TFactList;
  Lines: array of string;
  Title: string;
  Index: LongInt;
  LineCount: LongInt;
begin
  Facts := GatherFacts;
  Title := UserAndHost;
  SetLength(Lines, Length(Facts) + 2);
  Lines[0] := Coloured(TitleColour, Title);
  Lines[1] := StringOfChar('-', Length(Title));
  for Index := 0 to High(Facts) do
    Lines[Index + 2] := Coloured(LabelColour, Facts[Index].Name + ':') + ' ' + Facts[Index].Value;
  if UseColours then
  begin
    SetLength(Lines, Length(Lines) + 3);
    Lines[High(Lines) - 2] := '';
    Lines[High(Lines) - 1] := ColourBlocks(40);
    Lines[High(Lines)] := ColourBlocks(100);
  end;

  LineCount := Length(Lines);
  if ShowLogo and (LogoLineCount > LineCount) then
    LineCount := LogoLineCount;
  for Index := 0 to LineCount - 1 do
  begin
    Write(LogoColumn(Index));
    if Index < Length(Lines) then
      Write(Lines[Index]);
    Write(#10);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
begin
  ShowLogo := True;
  UseColours := OutputIsTerminal and (GetVariable('NO_COLOR') = nil);
  BeginOptions(Parser, [
    OptionDefinition('l', 'no-logo', False, OptionNoLogo),
    OptionDefinition('c', 'color', False, OptionColor),
    OptionDefinition('C', 'no-color', False, OptionNoColor)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionNoLogo: ShowLogo := False;
      OptionColor: UseColours := True;
      OptionNoColor: UseColours := False;
    end;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[0])]);
  ShowEverything;
end.
