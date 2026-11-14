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

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  ExpandUsage: PChar = 'Usage: expand [OPTION]... [FILE]...'#10 +
    'Convert tabs in each FILE to spaces, writing to standard output.'#10#10 +
    '  -i, --initial    do not convert tabs after non blanks'#10 +
    '  -t, --tabs=N     have tabs N characters apart, not 8'#10 +
    '  -t, --tabs=LIST  use comma separated list of tab positions'#10;
  UnexpandUsage: PChar = 'Usage: unexpand [OPTION]... [FILE]...'#10 +
    'Convert blanks in each FILE to tabs, writing to standard output.'#10#10 +
    '  -a, --all        convert all blanks, instead of just initial blanks'#10 +
    '      --first-only  convert only leading sequences of blanks (overrides -a)'#10 +
    '  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)'#10 +
    '  -t, --tabs=LIST  use comma separated list of tab positions (enables -a)'#10;

  OptionInitial = 1;
  OptionTabs = 2;
  OptionAll = 3;
  OptionFirstOnly = 4;
  MaximumStops = 64;

var
  Stops: array[0..MaximumStops - 1] of Integer;
  StopCount: Integer;
  TabWidth: Integer;

{ The column of the next tab stop after Column. }
function NextStop(Column: Integer): Integer;
var
  Index: Integer;
begin
  if StopCount <= 1 then
    Exit((Column div TabWidth + 1) * TabWidth);
  for Index := 0 to StopCount - 1 do
    if Stops[Index] > Column then
      Exit(Stops[Index]);
  { Past the last stop: one column at a time. }
  Result := Column + 1;
end;

procedure ParseStops(Text: PChar);
var
  Position: Integer;
  Value: Integer;
begin
  StopCount := 0;
  Position := 0;
  while Text[Position] <> #0 do
  begin
    if not IsDigit(Text[Position]) then
      Fail(1, 'tab size contains invalid character(s): ''%s''', [ArgumentText(Text + Position)]);
    Value := 0;
    while IsDigit(Text[Position]) do
    begin
      Value := Value * 10 + Ord(Text[Position]) - Ord('0');
      Inc(Position);
    end;
    if (Value = 0) or ((StopCount > 0) and (Value <= Stops[StopCount - 1])) then
      Fail(1, 'tab sizes must be ascending', []);
    if StopCount < MaximumStops then
    begin
      Stops[StopCount] := Value;
      Inc(StopCount);
    end;
    if (Text[Position] = ',') or (Text[Position] = ' ') then
      Inc(Position);
  end;
  if StopCount = 1 then
    TabWidth := Stops[0];
end;

procedure ExpandLine(Line: PChar; InitialOnly: Boolean);
var
  Index: Integer;
  Column: Integer;
  Target: Integer;
  SeenNonBlank: Boolean;
begin
  Column := 0;
  SeenNonBlank := False;
  Index := 0;
  while Line[Index] <> #0 do
  begin
    if (Line[Index] = #9) and not (InitialOnly and SeenNonBlank) then
    begin
      Target := NextStop(Column);
      while Column < Target do
      begin
        WriteCharacter(StandardOutput, ' ');
        Inc(Column);
      end;
    end
    else
    begin
      if Line[Index] = #8 then
      begin
        if Column > 0 then
          Dec(Column);
      end
      else
        Inc(Column);
      if (Line[Index] <> ' ') and (Line[Index] <> #9) then
        SeenNonBlank := True;
      WriteCharacter(StandardOutput, Line[Index]);
    end;
    Inc(Index);
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure UnexpandLine(Line: PChar; AllBlanks: Boolean);
var
  Index: Integer;
  Column: Integer;
  PendingSpaces: Integer;
  PendingStart: Integer;
  SeenNonBlank: Boolean;
  Stop: Integer;

  procedure FlushPending;
  begin
    while PendingSpaces > 0 do
    begin
      WriteCharacter(StandardOutput, ' ');
      Dec(PendingSpaces);
    end;
  end;

begin
  Column := 0;
  PendingSpaces := 0;
  PendingStart := 0;
  SeenNonBlank := False;
  Index := 0;
  while Line[Index] <> #0 do
  begin
    if (Line[Index] = ' ') and (AllBlanks or not SeenNonBlank) then
    begin
      if PendingSpaces = 0 then
        PendingStart := Column;
      Inc(PendingSpaces);
      Inc(Column);
      { A run reaching a stop becomes one tab. }
      Stop := NextStop(PendingStart);
      if (Column = Stop) and (PendingSpaces > 1) then
      begin
        WriteCharacter(StandardOutput, #9);
        PendingSpaces := 0;
      end
      else if Column = Stop then
      begin
        FlushPending;
      end;
    end
    else if (Line[Index] = #9) and (AllBlanks or not SeenNonBlank) then
    begin
      PendingSpaces := 0;
      WriteCharacter(StandardOutput, #9);
      Column := NextStop(Column);
    end
    else
    begin
      FlushPending;
      SeenNonBlank := True;
      WriteCharacter(StandardOutput, Line[Index]);
      Inc(Column);
    end;
    Inc(Index);
  end;
  FlushPending;
  WriteCharacter(StandardOutput, #10);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  IsUnexpand: Boolean;
  InitialOnly: Boolean;
  AllBlanks: Boolean;
  FirstOnly: Boolean;
  Index: Integer;
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  IsUnexpand := TextIsEqual(BaseName(Argument(0)), 'unexpand');
  TabWidth := 8;
  StopCount := 0;
  InitialOnly := False;
  AllBlanks := False;
  FirstOnly := False;
  if IsUnexpand then
    BeginOptions(Parser, [
      OptionDefinition('a', 'all', False, OptionAll),
      OptionDefinition(#0, 'first-only', False, OptionFirstOnly),
      OptionDefinition('t', 'tabs', True, OptionTabs)], UnexpandUsage)
  else
    BeginOptions(Parser, [
      OptionDefinition('i', 'initial', False, OptionInitial),
      OptionDefinition('t', 'tabs', True, OptionTabs)], ExpandUsage);
  while NextOption(Parser, Code, Value) do
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
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadLine(Stream, Line, HadLineEnd) do
    begin
      if IsUnexpand then
        UnexpandLine(Line, AllBlanks)
      else
        ExpandLine(Line, InitialOnly);
      FreeMemory(Line);
    end;
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
