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
  wc - print newline, word, and byte counts for each file

  wc [-clmwL] [FILE]...

  Without options prints lines, words and bytes. With several files a
  total line follows. Characters (-m) count UTF-8 sequences.
}
program wc;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Files,
  Sys.Streams,
  Sys.Text,
  Util.CommandLine,
  Util.Input;

const
  Usage = 'Usage: wc [OPTION]... [FILE]...'#10 +
    'Print newline, word, and byte counts for each FILE, and a total line if'#10 +
    'more than one FILE is specified. A word is a nonempty sequence of'#10 +
    'non white space characters.'#10 +
    #10 +
    '  -c, --bytes            print the byte counts'#10 +
    '  -m, --chars            print the character counts'#10 +
    '  -l, --lines            print the newline counts'#10 +
    '  -L, --max-line-length  print the maximum display width'#10 +
    '  -w, --words            print the word counts'#10;

  ShowLines = $01;
  ShowWords = $02;
  ShowCharacters = $04;
  ShowBytes = $08;
  ShowMaximumLine = $10;

type
  TCounts = record
    Lines: QWord;
    Words: QWord;
    Characters: QWord;
    Bytes: QWord;
    MaximumLine: QWord;
  end;

var
  Selection: Integer;
  Width: Integer;

procedure CountStream(Stream: PInputStream; out Counts: TCounts);
var
  Buffer: array[0..4095] of Char;
  Count: QWord;
  Index: QWord;
  InWord: Boolean;
  LineLength: QWord;
  Character: Char;
begin
  Counts := Default(TCounts);
  InWord := False;
  LineLength := 0;
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    Index := 0;
    while Index < Count do
    begin
      Character := Buffer[Index];
      Inc(Counts.Bytes);
      { UTF-8 continuation bytes do not start a character. }
      if (Byte(Character) and $C0) <> $80 then
      begin
        Inc(Counts.Characters);
        if Character <> #10 then
          Inc(LineLength);
      end;
      if Character = #10 then
      begin
        Inc(Counts.Lines);
        if LineLength > Counts.MaximumLine then
          Counts.MaximumLine := LineLength;
        LineLength := 0;
      end;
      if IsSpace(Character) then
        InWord := False
      else if not InWord then
      begin
        InWord := True;
        Inc(Counts.Words);
      end;
      Inc(Index);
    end;
  until Count = 0;
  if LineLength > Counts.MaximumLine then
    Counts.MaximumLine := LineLength;
end;

{ Name is empty for standard input, which is not named. }
procedure PrintCounts(const Counts: TCounts; const Name: string);
var
  Line: string;

  procedure AddNumber(Mask: Integer; Value: QWord);
  begin
    if (Selection and Mask) = 0 then
      Exit;
    if Line <> '' then
      Line := Line + ' ';
    Line := Line + IntToStr(Value).PadLeft(Width);
  end;

begin
  Line := '';
  AddNumber(ShowLines, Counts.Lines);
  AddNumber(ShowWords, Counts.Words);
  AddNumber(ShowCharacters, Counts.Characters);
  AddNumber(ShowBytes, Counts.Bytes);
  AddNumber(ShowMaximumLine, Counts.MaximumLine);
  if Name <> '' then
    Line := Line + ' ' + Name;
  PrintStringLine(Line);
end;

function TotalSizeWidth(const Paths: TStringArray): Integer;
var
  Path: string;
  Total: QWord;
  Information: TFileInformation;
begin
  Total := 0;
  for Path in Paths do
  begin
    if GetFileInformation(PChar(Path), Information) = 0 then
      Total := Total + Information.SizeInBytes;
  end;
  Result := Length(IntToStr(Total));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
  Counts: TCounts;
  Total: TCounts;
  ReadStandardInput: Boolean;
begin
  Selection := 0;
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'bytes', False, ShowBytes),
    CommandOption('m', 'chars', False, ShowCharacters),
    CommandOption('l', 'lines', False, ShowLines),
    CommandOption('L', 'max-line-length', False, ShowMaximumLine),
    CommandOption('w', 'words', False, ShowWords)], Usage);
  while CommandLine.NextOption(Code, Value) do
    Selection := Selection or Code;
  if Selection = 0 then
    Selection := ShowLines or ShowWords or ShowBytes;

  ReadStandardInput := CommandLine.OperandCount = 0;
  if ReadStandardInput then
    CommandLine.Operands := ['-'];
  { As GNU wc does: one number alone is not padded; for standard input
    columns are 7 wide; for files, as wide as their total size. }
  if (CommandLine.OperandCount = 1) and ((Selection and (Selection - 1)) = 0) then
    Width := 0
  else if ReadStandardInput then
    Width := 7
  else
    Width := TotalSizeWidth(CommandLine.Operands);

  Total := Default(TCounts);
  ExitStatus := 0;
  for Index := 0 to CommandLine.OperandCount - 1 do
  begin
    Stream := OpenInput(CommandLine.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    CountStream(Stream, Counts);
    CloseInput(Stream);
    if ReadStandardInput then
      PrintCounts(Counts, '')
    else
      PrintCounts(Counts, CommandLine.Operands[Index]);
    Total.Lines := Total.Lines + Counts.Lines;
    Total.Words := Total.Words + Counts.Words;
    Total.Characters := Total.Characters + Counts.Characters;
    Total.Bytes := Total.Bytes + Counts.Bytes;
    if Counts.MaximumLine > Total.MaximumLine then
      Total.MaximumLine := Counts.MaximumLine;
  end;
  if CommandLine.OperandCount > 1 then
    PrintCounts(Total, 'total');
  Halt(ExitStatus);
end.
