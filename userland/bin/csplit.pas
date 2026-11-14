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
  csplit - split a file into sections determined by context lines

  csplit [-ksz] [-f PREFIX] [-n DIGITS] [-b FORMAT] FILE PATTERN...

  PATTERN is one of:
    N            up to (not including) line N
    /REGEX/[+-OFFSET]   up to the next line matching REGEX
    %REGEX%[+-OFFSET]   like /REGEX/, but the section is skipped
    {N}          repeat the previous pattern N more times
    {*}          repeat the previous pattern as often as possible

  Sections go to xx00, xx01, ...; their sizes in bytes are printed.
}
program csplit;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.RegularExpressions;

const
  Usage: PChar = 'Usage: csplit [OPTION]... FILE PATTERN...'#10 +
    'Output pieces of FILE separated by PATTERN(s) to files ''xx00'', ''xx01'', ...,'#10 +
    'and output byte counts of each piece to standard output.'#10#10 +
    '  -f, --prefix=PREFIX        use PREFIX instead of ''xx'''#10 +
    '  -k, --keep-files           do not remove output files on errors'#10 +
    '  -n, --digits=DIGITS        use specified number of digits instead of 2'#10 +
    '  -s, --quiet, --silent      do not print counts of output file sizes'#10 +
    '  -z, --elide-empty-files    remove empty output files'#10;

  OptionPrefix = 1;
  OptionKeep = 2;
  OptionDigits = 3;
  OptionQuiet = 4;
  OptionElide = 5;
  MaximumSections = 1000;

var
  Lines: TLineList;
  Prefix: PChar;
  Digits: Integer;
  Quiet: Boolean;
  KeepFiles: Boolean;
  ElideEmpty: Boolean;
  SectionCount: Integer;
  Created: array[0..MaximumSections - 1] of PChar;
  CreatedCount: Integer;

function SectionName(Number: Integer): PChar;
var
  Builder: TTextBuilder;
  Text: TNumberText;
  Formatted: PChar;
  Padding: Integer;
begin
  BeginText(Builder);
  AppendText(Builder, Prefix);
  Formatted := FormatDecimal(QWord(Number), Text);
  for Padding := Integer(TextLength(Formatted)) to Digits - 1 do
    AppendCharacter(Builder, '0');
  AppendText(Builder, Formatted);
  Result := FinishText(Builder);
end;

procedure RemoveCreatedFiles;
var
  Index: Integer;
begin
  if KeepFiles then
    Exit;
  for Index := 0 to CreatedCount - 1 do
    RemovePath(Created[Index]);
end;

procedure Abort(Format: PChar; const Arguments: array of TFormatArgument);
begin
  Report(Format, Arguments);
  RemoveCreatedFiles;
  Halt(1);
end;

{ Writes lines First .. Last - 1 as the next section (or skips them). }
procedure WriteSection(First, Last: Integer; Skip: Boolean);
var
  Name: PChar;
  Handle: Int64;
  Stream: POutputStream;
  Index: Integer;
  Bytes: QWord;
begin
  if Skip then
    Exit;
  Bytes := 0;
  for Index := First to Last - 1 do
    Bytes := Bytes + TextLength(Lines.Items[Index]) + 1;
  if ElideEmpty and (Bytes = 0) then
    Exit;
  Name := SectionName(SectionCount);
  Inc(SectionCount);
  Handle := OpenFile(Name, OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Abort('%s: %s', [ArgumentText(Name), ArgumentText(ErrorMessage(ErrorCodeOf(Handle)))]);
  if CreatedCount < MaximumSections then
  begin
    Created[CreatedCount] := Name;
    Inc(CreatedCount);
  end;
  Stream := CreateOutputStream(Handle);
  for Index := First to Last - 1 do
    WriteLine(Stream, Lines.Items[Index]);
  DestroyOutputStream(Stream);
  CloseFile(Handle);
  if not Quiet then
  begin
    WriteUnsigned(StandardOutput, Bytes);
    WriteCharacter(StandardOutput, #10);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Stream: PInputStream;
  Position: Integer;     { first line not yet written }
  PatternIndex: Integer;
  Pattern: PChar;
  LineNumber: Int64;
  Delimiter: Char;
  Closing: PtrInt;
  RegexText: PChar;
  Offset: Int64;
  Expression: TExpression;
  Match: TMatch;
  ErrorText: PChar;
  Found: Integer;
  Target: Integer;
  RepeatCount: Int64;
  RepeatForever: Boolean;
  Repetition: Int64;
  PreviousPattern: PChar;
  Number: Int64;

{ Applies one pattern; returns False if a regex was not found. }
function ApplyPattern(Text: PChar): Boolean;
begin
  Result := True;
  if (Text[0] = '/') or (Text[0] = '%') then
  begin
    Delimiter := Text[0];
    Closing := FindLastCharacter(Text, Delimiter);
    if Closing <= 0 then
      Abort('%s: closing delimiter ''%c'' missing', [ArgumentText(Text), ArgumentCharacter(Delimiter)]);
    RegexText := PChar(AllocateMemory(Closing));
    CopyText(RegexText, Text + 1, PtrUInt(Closing));
    Offset := 0;
    if (Text[Closing + 1] <> #0) and not ParseInteger(Text + Closing + 1, Offset) then
      Abort('%s: invalid pattern', [ArgumentText(Text)]);
    if not CompileExpression(RegexText, SyntaxBasic, Expression, ErrorText) then
      Abort('%s: %s', [ArgumentText(Text), ArgumentText(ErrorText)]);
    { The search starts after the current line (the previous match). }
    Found := -1;
    Target := Position;
    if (Position > 0) or (SectionCount > 0) then
      Target := Position + 1;
    if Delimiter = '%' then
      Target := Position;
    while Target < Lines.Count do
    begin
      if SearchExpression(Expression, Lines.Items[Target], Match) then
      begin
        Found := Target;
        Break;
      end;
      Inc(Target);
    end;
    FreeExpression(Expression);
    FreeMemory(RegexText);
    if Found < 0 then
      Exit(False);
    Target := Found + Integer(Offset);
    if (Target < Position) or (Target > Lines.Count) then
      Abort('%s: line number out of range', [ArgumentText(Text)]);
    WriteSection(Position, Target, Delimiter = '%');
    Position := Target;
    Exit;
  end;
  if not ParseInteger(Text, LineNumber) or (LineNumber < 1) then
    Abort('%s: invalid pattern', [ArgumentText(Text)]);
  if (LineNumber - 1 < Position) then
    Abort('%s: line number out of range', [ArgumentText(Text)]);
  if LineNumber - 1 > Lines.Count then
    Exit(False);
  WriteSection(Position, Integer(LineNumber) - 1, False);
  Position := Integer(LineNumber) - 1;
end;

begin
  Prefix := 'xx';
  Digits := 2;
  BeginOptions(Parser, [
    OptionDefinition('f', 'prefix', True, OptionPrefix),
    OptionDefinition('k', 'keep-files', False, OptionKeep),
    OptionDefinition('n', 'digits', True, OptionDigits),
    OptionDefinition('s', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'silent', False, OptionQuiet),
    OptionDefinition('z', 'elide-empty-files', False, OptionElide)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionPrefix: Prefix := Value;
      OptionKeep: KeepFiles := True;
      OptionDigits:
        begin
          if not ParseInteger(Value, Number) or (Number < 1) or (Number > 9) then
            Fail(1, 'invalid number: ''%s''', [ArgumentText(Value)]);
          Digits := Integer(Number);
        end;
      OptionQuiet: Quiet := True;
      OptionElide: ElideEmpty := True;
    end;
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing operand', []);

  Stream := OpenInput(Parser.Operands[0]);
  if Stream = nil then
    Halt(1);
  BeginLineList(Lines);
  ReadAllLines(Stream, Lines);
  CloseInput(Stream);

  Position := 0;
  SectionCount := 0;
  PreviousPattern := nil;
  PatternIndex := 1;
  while PatternIndex < Parser.OperandCount do
  begin
    Pattern := Parser.Operands[PatternIndex];
    if Pattern[0] = '{' then
    begin
      if PreviousPattern = nil then
        Abort('%s: no previous pattern to repeat', [ArgumentText(Pattern)]);
      RepeatForever := TextIsEqual(Pattern, '{*}');
      RepeatCount := 0;
      if not RepeatForever then
      begin
        Closing := FindCharacter(Pattern, '}');
        if Closing < 0 then
          Abort('%s: invalid repeat count', [ArgumentText(Pattern)]);
        Pattern[Closing] := #0;
        if not ParseInteger(Pattern + 1, RepeatCount) or (RepeatCount < 0) then
          Abort('%s: invalid repeat count', [ArgumentText(Pattern + 1)]);
      end;
      Repetition := 0;
      while RepeatForever or (Repetition < RepeatCount) do
      begin
        if not ApplyPattern(PreviousPattern) then
        begin
          if RepeatForever then
            Break;
          Abort('%s: match not found on repetition %d', [ArgumentText(PreviousPattern),
            ArgumentNumber(Repetition + 1)]);
        end;
        Inc(Repetition);
      end;
    end
    else
    begin
      if not ApplyPattern(Pattern) then
        Abort('%s: match not found', [ArgumentText(Pattern)]);
      PreviousPattern := Pattern;
    end;
    Inc(PatternIndex);
  end;
  WriteSection(Position, Lines.Count, False);
end.
