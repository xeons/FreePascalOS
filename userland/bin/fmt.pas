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
  fmt - simple optimal text formatter

  fmt [-su] [-w WIDTH] [FILE]...

  Fills paragraphs (separated by blank lines or changes of indentation)
  to at most WIDTH columns (default 75), keeping each paragraph's
  indentation. -s only splits long lines; -u puts one space between
  words and two after sentences.
}
program fmt;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Environment,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: fmt [-WIDTH] [OPTION]... [FILE]...'#10 +
    'Reformat each paragraph in the FILE(s), writing to standard output.'#10#10 +
    '  -s, --split-only        split long lines, but do not refill'#10 +
    '  -u, --uniform-spacing   one space between words, two after sentences'#10 +
    '  -w, --width=WIDTH       maximum line width (default of 75 columns)'#10;

  OptionSplitOnly = 1;
  OptionUniform = 2;
  OptionWidth = 3;

  SpaceCharacters = [' ', #9, #10, #11, #12, #13];

type
  { Fills the words of paragraphs into lines of at most Width columns. }
  TParagraphFiller = class
  private
    FWidth: Int64;
    FSplitOnly: Boolean;
    FUniform: Boolean;
    { The line being filled, without the indentation. }
    FLine: string;
    FParagraphIndent: string;
    FHasParagraph: Boolean;
    FLastWordEndedSentence: Boolean;
    procedure FlushLine;
    procedure AddWord(const Word: string);
    procedure AddLineWords(const Line: string; Start: Integer);
    procedure StartParagraph(const Indent: string);
  public
    constructor Create(Width: Int64; SplitOnly, Uniform: Boolean);
    procedure ProcessLine(const Line: string);
    procedure EndParagraph;
  end;

function IndentationOf(const Line: string): Integer;
begin
  Result := 0;
  while (Result < Length(Line)) and (Line[Result + 1] in [' ', #9]) do
    Inc(Result);
end;

constructor TParagraphFiller.Create(Width: Int64; SplitOnly, Uniform: Boolean);
begin
  inherited Create;
  FWidth := Width;
  FSplitOnly := SplitOnly;
  FUniform := Uniform;
end;

procedure TParagraphFiller.FlushLine;
begin
  if FLine <> '' then
    PrintStringLine(FParagraphIndent + FLine);
  FLine := '';
end;

procedure TParagraphFiller.AddWord(const Word: string);
var
  Gap: Integer;
begin
  Gap := 1;
  if FUniform and FLastWordEndedSentence then
    Gap := 2;
  if (FLine <> '') and (Length(FParagraphIndent) + Length(FLine) + Gap + Length(Word) > FWidth) then
    FlushLine;
  if FLine <> '' then
    FLine := FLine + StringOfChar(' ', Gap);
  FLine := FLine + Word;
  FLastWordEndedSentence := (Word <> '') and (Word[Length(Word)] in ['.', '!', '?']);
end;

procedure TParagraphFiller.EndParagraph;
begin
  FlushLine;
  FHasParagraph := False;
  FLastWordEndedSentence := False;
end;

{ Adds the words of Line from character Start on. }
procedure TParagraphFiller.AddLineWords(const Line: string; Start: Integer);
var
  Position: Integer;
  WordStart: Integer;
begin
  Position := Start;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and (Line[Position] in SpaceCharacters) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    WordStart := Position;
    while (Position <= Length(Line)) and not (Line[Position] in SpaceCharacters) do
      Inc(Position);
    AddWord(Copy(Line, WordStart, Position - WordStart));
  end;
end;

procedure TParagraphFiller.StartParagraph(const Indent: string);
begin
  FParagraphIndent := Indent;
  FHasParagraph := True;
end;

procedure TParagraphFiller.ProcessLine(const Line: string);
var
  Indent: Integer;
begin
  Indent := IndentationOf(Line);
  if Indent = Length(Line) then
  begin
    EndParagraph;
    PrintString(#10);
    Exit;
  end;
  if FSplitOnly then
  begin
    { Each input line is its own paragraph. }
    EndParagraph;
    FParagraphIndent := Copy(Line, 1, Indent);
    AddLineWords(Line, Indent + 1);
    EndParagraph;
    Exit;
  end;
  if FHasParagraph and (Indent <> Length(FParagraphIndent)) then
    EndParagraph;
  if not FHasParagraph then
    StartParagraph(Copy(Line, 1, Indent));
  AddLineWords(Line, Indent + 1);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Arguments: TStringArray;
  Operand: string;
  Width: Int64;
  SplitOnly: Boolean;
  Uniform: Boolean;
  Filler: TParagraphFiller;
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  Width := 75;
  SplitOnly := False;
  Uniform := False;
  { The old form "fmt -60": the argument becomes "--", so everything
    after it is an operand. }
  Arguments := ProgramArguments;
  if (Length(Arguments) > 0) and (Length(Arguments[0]) >= 2) and (Arguments[0][1] = '-') and
     (Arguments[0][2] in ['0'..'9']) then
  begin
    if not ParseDecimal(Copy(Arguments[0], 2, MaxInt), Width) then
      Fail(1, 'invalid width');
    Arguments[0] := '--';
  end;
  CommandLine := TCommandLine.Create([
    CommandOption('s', 'split-only', False, OptionSplitOnly),
    CommandOption('u', 'uniform-spacing', False, OptionUniform),
    CommandOption('w', 'width', True, OptionWidth)], Usage, Arguments);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionSplitOnly: SplitOnly := True;
      OptionUniform: Uniform := True;
      OptionWidth:
        if not ParseDecimal(Value, Width) or (Width < 1) then
          Fail(1, Format('invalid width: ''%s''', [Value]));
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  Filler := TParagraphFiller.Create(Width, SplitOnly, Uniform);
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
      Filler.ProcessLine(Line);
    CloseInput(Stream);
  end;
  Filler.EndParagraph;
  Filler.Free;
  CommandLine.Free;
  Halt(ExitStatus);
end.
