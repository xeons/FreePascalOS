{
  fmt - simple optimal text formatter

  fmt [-su] [-w WIDTH] [FILE]...

  Fills paragraphs (separated by blank lines or changes of indentation)
  to at most WIDTH columns (default 75), keeping each paragraph's
  indentation. -s only splits long lines; -u puts one space between
  words and two after sentences.
}
program fmt;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Environment,
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: fmt [-WIDTH] [OPTION]... [FILE]...'#10 +
    'Reformat each paragraph in the FILE(s), writing to standard output.'#10#10 +
    '  -s, --split-only        split long lines, but do not refill'#10 +
    '  -u, --uniform-spacing   one space between words, two after sentences'#10 +
    '  -w, --width=WIDTH       maximum line width (default of 75 columns)'#10;

  OptionSplitOnly = 1;
  OptionUniform = 2;
  OptionWidth = 3;

var
  Width: Int64;
  SplitOnly: Boolean;
  Uniform: Boolean;
  Output: TTextBuilder;   { the line being filled }
  OutputIndent: PChar;
  ParagraphIndent: TTextBuilder;
  HasParagraph: Boolean;
  LastWordEndedSentence: Boolean;

function IndentationOf(Line: PChar): PtrUInt;
begin
  Result := 0;
  while (Line[Result] = ' ') or (Line[Result] = #9) do
    Inc(Result);
end;

procedure FlushOutputLine;
begin
  if Output.Length > 0 then
  begin
    WriteText(StandardOutput, ParagraphIndent.Text);
    WriteLine(StandardOutput, Output.Text);
  end;
  Output.Length := 0;
  Output.Text[0] := #0;
end;

procedure AddWord(Word: PChar; WordLength: PtrUInt);
var
  Gap: Integer;
begin
  Gap := 1;
  if Uniform and LastWordEndedSentence then
    Gap := 2;
  if (Output.Length > 0) and (Int64(ParagraphIndent.Length + Output.Length + PtrUInt(Gap) + WordLength) > Width) then
    FlushOutputLine;
  if Output.Length > 0 then
  begin
    AppendCharacter(Output, ' ');
    if Gap = 2 then
      AppendCharacter(Output, ' ');
  end;
  AppendBytes(Output, Word, WordLength);
  LastWordEndedSentence := (WordLength > 0) and (Word[WordLength - 1] in ['.', '!', '?']);
end;

procedure EndParagraph;
begin
  FlushOutputLine;
  HasParagraph := False;
  LastWordEndedSentence := False;
end;

procedure AddLineWords(Line: PChar);
var
  Position: PtrUInt;
  Start: PtrUInt;
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
    AddWord(Line + Start, Position - Start);
  end;
end;

procedure ProcessLine(Line: PChar);
var
  Indent: PtrUInt;
begin
  Indent := IndentationOf(Line);
  if Line[Indent] = #0 then
  begin
    EndParagraph;
    WriteCharacter(StandardOutput, #10);
    Exit;
  end;
  if SplitOnly then
  begin
    { Each input line is its own paragraph. }
    EndParagraph;
    DiscardText(ParagraphIndent);
    BeginText(ParagraphIndent);
    AppendBytes(ParagraphIndent, Line, Indent);
    AddLineWords(Line + Indent);
    EndParagraph;
    Exit;
  end;
  if HasParagraph and (Indent <> ParagraphIndent.Length) then
    EndParagraph;
  if not HasParagraph then
  begin
    DiscardText(ParagraphIndent);
    BeginText(ParagraphIndent);
    AppendBytes(ParagraphIndent, Line, Indent);
    HasParagraph := True;
  end;
  AddLineWords(Line + Indent);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  Width := 75;
  { The old form "fmt -60". }
  if (ArgumentTotal > 1) and (ArgumentValues[1][0] = '-') and IsDigit(ArgumentValues[1][1]) then
  begin
    if not ParseInteger(ArgumentValues[1] + 1, Width) then
      Fail(1, 'invalid width', []);
    ArgumentValues[1] := '--';
  end;
  BeginOptions(Parser, [
    OptionDefinition('s', 'split-only', False, OptionSplitOnly),
    OptionDefinition('u', 'uniform-spacing', False, OptionUniform),
    OptionDefinition('w', 'width', True, OptionWidth)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionSplitOnly: SplitOnly := True;
      OptionUniform: Uniform := True;
      OptionWidth:
        if not ParseInteger(Value, Width) or (Width < 1) then
          Fail(1, 'invalid width: ''%s''', [ArgumentText(Value)]);
    end;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  BeginText(Output);
  BeginText(ParagraphIndent);
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
      ProcessLine(Line);
      FreeMemory(Line);
    end;
    CloseInput(Stream);
  end;
  EndParagraph;
  Halt(ExitStatus);
end.
