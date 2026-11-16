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
  expand, unexpand - convert tabs to spaces, or spaces to tabs

  expand [-i] [-t N[,N]...] [FILE]...
  unexpand [-a] [--first-only] [-t N[,N]...] [FILE]...

  Tab stops are every 8 columns, every N with -t N, or at the listed
  columns. expand -i only converts leading tabs. unexpand converts only
  leading blanks unless -a (or -t) is given.
}
program expand;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Environment,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Paths;

const
  ExpandUsage = 'Usage: expand [OPTION]... [FILE]...'#10 +
    'Convert tabs in each FILE to spaces, writing to standard output.'#10#10 +
    '  -i, --initial    do not convert tabs after non blanks'#10 +
    '  -t, --tabs=N     have tabs N characters apart, not 8'#10 +
    '  -t, --tabs=LIST  use comma separated list of tab positions'#10;
  UnexpandUsage = 'Usage: unexpand [OPTION]... [FILE]...'#10 +
    'Convert blanks in each FILE to tabs, writing to standard output.'#10#10 +
    '  -a, --all        convert all blanks, instead of just initial blanks'#10 +
    '      --first-only  convert only leading sequences of blanks (overrides -a)'#10 +
    '  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)'#10 +
    '  -t, --tabs=LIST  use comma separated list of tab positions (enables -a)'#10;

  OptionInitial = 1;
  OptionTabs = 2;
  OptionAll = 3;
  OptionFirstOnly = 4;

var
  Stops: array of Integer;
  TabWidth: Integer;

{ The column of the next tab stop after Column. }
function NextStop(Column: Integer): Integer;
var
  Stop: Integer;
begin
  if Length(Stops) <= 1 then
    Exit((Column div TabWidth + 1) * TabWidth);
  for Stop in Stops do
    if Stop > Column then
      Exit(Stop);
  { Past the last stop: one column at a time. }
  Result := Column + 1;
end;

procedure ParseStops(const Text: string);
var
  Position: Integer;
  Value: Integer;
begin
  Stops := nil;
  Position := 1;
  while Position <= Length(Text) do
  begin
    if not (Text[Position] in ['0'..'9']) then
      Fail(1, Format('tab size contains invalid character(s): ''%s''', [Copy(Text, Position, MaxInt)]));
    Value := 0;
    while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
    begin
      Value := Value * 10 + Ord(Text[Position]) - Ord('0');
      Inc(Position);
    end;
    if (Value = 0) or ((Length(Stops) > 0) and (Value <= Stops[High(Stops)])) then
      Fail(1, 'tab sizes must be ascending');
    SetLength(Stops, Length(Stops) + 1);
    Stops[High(Stops)] := Value;
    if (Position <= Length(Text)) and (Text[Position] in [',', ' ']) then
      Inc(Position);
  end;
  if Length(Stops) = 1 then
    TabWidth := Stops[0];
end;

function ExpandLine(const Line: string; InitialOnly: Boolean): string;
var
  Character: Char;
  Column: Integer;
  Target: Integer;
  SeenNonBlank: Boolean;
begin
  Result := '';
  Column := 0;
  SeenNonBlank := False;
  for Character in Line do
  begin
    if (Character = #9) and not (InitialOnly and SeenNonBlank) then
    begin
      Target := NextStop(Column);
      Result := Result + StringOfChar(' ', Target - Column);
      Column := Target;
    end
    else
    begin
      if Character = #8 then
      begin
        if Column > 0 then
          Dec(Column);
      end
      else
        Inc(Column);
      if (Character <> ' ') and (Character <> #9) then
        SeenNonBlank := True;
      Result := Result + Character;
    end;
  end;
end;

function UnexpandLine(const Line: string; AllBlanks: Boolean): string;
var
  Character: Char;
  Column: Integer;
  PendingSpaces: Integer;
  PendingStart: Integer;
  SeenNonBlank: Boolean;
  Stop: Integer;

  procedure FlushPending;
  begin
    Result := Result + StringOfChar(' ', PendingSpaces);
    PendingSpaces := 0;
  end;

begin
  Result := '';
  Column := 0;
  PendingSpaces := 0;
  PendingStart := 0;
  SeenNonBlank := False;
  for Character in Line do
  begin
    if (Character = ' ') and (AllBlanks or not SeenNonBlank) then
    begin
      if PendingSpaces = 0 then
        PendingStart := Column;
      Inc(PendingSpaces);
      Inc(Column);
      { A run reaching a stop becomes one tab. }
      Stop := NextStop(PendingStart);
      if (Column = Stop) and (PendingSpaces > 1) then
      begin
        Result := Result + #9;
        PendingSpaces := 0;
      end
      else if Column = Stop then
        FlushPending;
    end
    else if (Character = #9) and (AllBlanks or not SeenNonBlank) then
    begin
      PendingSpaces := 0;
      Result := Result + #9;
      Column := NextStop(Column);
    end
    else
    begin
      FlushPending;
      SeenNonBlank := True;
      Result := Result + Character;
      Inc(Column);
    end;
  end;
  FlushPending;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  IsUnexpand: Boolean;
  InitialOnly: Boolean;
  AllBlanks: Boolean;
  FirstOnly: Boolean;
  Operand: string;
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  IsUnexpand := BaseName(string(Argument(0))) = 'unexpand';
  TabWidth := 8;
  InitialOnly := False;
  AllBlanks := False;
  FirstOnly := False;
  if IsUnexpand then
    CommandLine := TCommandLine.Create([
      CommandOption('a', 'all', False, OptionAll),
      CommandOption(#0, 'first-only', False, OptionFirstOnly),
      CommandOption('t', 'tabs', True, OptionTabs)], UnexpandUsage)
  else
    CommandLine := TCommandLine.Create([
      CommandOption('i', 'initial', False, OptionInitial),
      CommandOption('t', 'tabs', True, OptionTabs)], ExpandUsage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionInitial: InitialOnly := True;
      OptionAll: AllBlanks := True;
      OptionFirstOnly: FirstOnly := True;
      OptionTabs:
        begin
          ParseStops(Value);
          AllBlanks := True;
        end;
    end;
  if FirstOnly then
    AllBlanks := False;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadTextLine(Stream, Line, HadLineEnd) do
      if IsUnexpand then
        PrintStringLine(UnexpandLine(Line, AllBlanks))
      else
        PrintStringLine(ExpandLine(Line, InitialOnly));
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
