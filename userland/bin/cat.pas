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
  cat - concatenate files and print on the standard output

  cat [-AbeEnstTv] [FILE]...

  With no FILE, or when FILE is -, reads standard input.
}
program cat;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input;

const
  Usage = 'Usage: cat [OPTION]... [FILE]...'#10 +
    'Concatenate FILE(s) to standard output.'#10 +
    #10 +
    'With no FILE, or when FILE is -, read standard input.'#10 +
    #10 +
    '  -A, --show-all           equivalent to -vET'#10 +
    '  -b, --number-nonblank    number nonempty output lines, overrides -n'#10 +
    '  -e                       equivalent to -vE'#10 +
    '  -E, --show-ends          display $ at end of each line'#10 +
    '  -n, --number             number all output lines'#10 +
    '  -s, --squeeze-blank      suppress repeated empty output lines'#10 +
    '  -t                       equivalent to -vT'#10 +
    '  -T, --show-tabs          display TAB characters as ^I'#10 +
    '  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB'#10;

  OptionShowAll = 1;
  OptionNumberNonblank = 2;
  OptionE = 3;
  OptionShowEnds = 4;
  OptionNumber = 5;
  OptionSqueeze = 6;
  OptionT = 7;
  OptionShowTabs = 8;
  OptionShowNonprinting = 9;

var
  NumberLines: Boolean;
  NumberNonblank: Boolean;
  ShowEnds: Boolean;
  SqueezeBlank: Boolean;
  ShowTabs: Boolean;
  ShowNonprinting: Boolean;
  { State carried across files, as GNU cat does. }
  LineNumber: Int64;
  AtLineStart: Boolean;
  PreviousLineBlank: Boolean;

function NeedsLineProcessing: Boolean;
begin
  Result := NumberLines or NumberNonblank or ShowEnds or SqueezeBlank or ShowTabs or ShowNonprinting;
end;

procedure CopyRaw(Stream: PInputStream);
var
  Buffer: array[0..4095] of Byte;
  Count: QWord;
begin
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    WriteBytes(StandardOutput, @Buffer[0], Count);
  until Count = 0;
end;

procedure WriteVisible(Character: Char);
var
  Code: Integer;
begin
  Code := Ord(Character);
  if (Character = #9) and not ShowTabs then
  begin
    WriteCharacter(StandardOutput, #9);
    Exit;
  end;
  if not ShowNonprinting and (Character <> #9) then
  begin
    WriteCharacter(StandardOutput, Character);
    Exit;
  end;
  if Code >= 128 then
  begin
    WriteString(StandardOutput, 'M-');
    Code := Code - 128;
  end;
  if Code < 32 then
  begin
    WriteCharacter(StandardOutput, '^');
    WriteCharacter(StandardOutput, Char(Code + 64));
  end
  else if Code = 127 then
    WriteString(StandardOutput, '^?')
  else
    WriteCharacter(StandardOutput, Char(Code));
end;

procedure CopyProcessed(Stream: PInputStream);
var
  Character: Char;
  LineIsBlank: Boolean;
begin
  while ReadCharacter(Stream, Character) do
  begin
    if AtLineStart then
    begin
      LineIsBlank := Character = #10;
      if SqueezeBlank and LineIsBlank and PreviousLineBlank then
        Continue;
      PreviousLineBlank := LineIsBlank;
      if NumberLines and not (NumberNonblank and LineIsBlank) then
      begin
        Inc(LineNumber);
        PrintString(Format('%6d'#9, [LineNumber]));
      end;
      AtLineStart := False;
    end;
    if Character = #10 then
    begin
      if ShowEnds then
        WriteCharacter(StandardOutput, '$');
      WriteCharacter(StandardOutput, #10);
      AtLineStart := True;
    end
    else
      WriteVisible(Character);
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Path: string;
  Stream: PInputStream;
  ExitStatus: LongInt;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('A', 'show-all', False, OptionShowAll),
    CommandOption('b', 'number-nonblank', False, OptionNumberNonblank),
    CommandOption('e', '', False, OptionE),
    CommandOption('E', 'show-ends', False, OptionShowEnds),
    CommandOption('n', 'number', False, OptionNumber),
    CommandOption('s', 'squeeze-blank', False, OptionSqueeze),
    CommandOption('t', '', False, OptionT),
    CommandOption('T', 'show-tabs', False, OptionShowTabs),
    CommandOption('u', '', False, 0),
    CommandOption('v', 'show-nonprinting', False, OptionShowNonprinting)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionShowAll:
        begin
          ShowNonprinting := True;
          ShowEnds := True;
          ShowTabs := True;
        end;
      OptionNumberNonblank:
        begin
          NumberLines := True;
          NumberNonblank := True;
        end;
      OptionE:
        begin
          ShowNonprinting := True;
          ShowEnds := True;
        end;
      OptionShowEnds: ShowEnds := True;
      OptionNumber: NumberLines := True;
      OptionSqueeze: SqueezeBlank := True;
      OptionT:
        begin
          ShowNonprinting := True;
          ShowTabs := True;
        end;
      OptionShowTabs: ShowTabs := True;
      OptionShowNonprinting: ShowNonprinting := True;
    end;

  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  LineNumber := 0;
  AtLineStart := True;
  PreviousLineBlank := False;
  ExitStatus := 0;
  for Path in CommandLine.Operands do
  begin
    Stream := OpenInput(Path);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if NeedsLineProcessing then
      CopyProcessed(Stream)
    else
      CopyRaw(Stream);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
