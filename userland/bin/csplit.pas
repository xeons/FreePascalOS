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

(*
  csplit - split a file into sections determined by context lines

  csplit [-ksz] [-f PREFIX] [-n DIGITS] [-b FORMAT] FILE PATTERN...

  PATTERN is one of:
    N            up to (not including) line N
    /REGEX/[+-OFFSET]   up to the next line matching REGEX
    %REGEX%[+-OFFSET]   like /REGEX/, but the section is skipped
    {N}          repeat the previous pattern N more times
    {*}          repeat the previous pattern as often as possible

  Sections go to xx00, xx01, ...; their sizes in bytes are printed.
*)
program csplit;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.RegularExpressions;

const
  Usage = 'Usage: csplit [OPTION]... FILE PATTERN...'#10 +
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

type
  { The lines of the input and the sections written from them so far. }
  TContextSplitter = class
  private
    FLines: TStringList;
    FCreated: TStringList;
    { The first line not yet written. }
    FPosition: Integer;
    FSectionCount: Integer;
    function SectionName(Number: Integer): string;
    procedure RemoveCreatedFiles;
    procedure WriteSection(First, Last: Integer; Skip: Boolean);
    function ApplyExpression(const Pattern: string): Boolean;
    function ApplyLineNumber(const Pattern: string): Boolean;
  public
    Prefix: string;
    Digits: Integer;
    Quiet: Boolean;
    KeepFiles: Boolean;
    ElideEmpty: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure ReadLines(Stream: PInputStream);
    { Reports Message, removes the sections written and ends the program. }
    procedure Abort(const Message: string);
    { Applies one pattern; returns False if it was not found. }
    function ApplyPattern(const Pattern: string): Boolean;
    { The lines after the last pattern. }
    procedure WriteRest;
  end;

constructor TContextSplitter.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
  FCreated := TStringList.Create;
  Prefix := 'xx';
  Digits := 2;
end;

destructor TContextSplitter.Destroy;
begin
  FCreated.Free;
  FLines.Free;
  inherited Destroy;
end;

procedure TContextSplitter.ReadLines(Stream: PInputStream);
begin
  ReadLinesInto(Stream, FLines);
end;

function TContextSplitter.SectionName(Number: Integer): string;
var
  NumberText: string;
begin
  NumberText := IntToStr(Number);
  Result := Prefix + StringOfChar('0', Digits - Length(NumberText)) + NumberText;
end;

procedure TContextSplitter.RemoveCreatedFiles;
var
  Name: string;
begin
  if KeepFiles then
    Exit;
  for Name in FCreated do
    RemovePath(PChar(Name));
end;

procedure TContextSplitter.Abort(const Message: string);
begin
  Report(Message);
  RemoveCreatedFiles;
  Halt(1);
end;

{ Writes lines First .. Last - 1 as the next section (or skips them). }
procedure TContextSplitter.WriteSection(First, Last: Integer; Skip: Boolean);
var
  Name: string;
  Handle: Int64;
  Stream: POutputStream;
  Index: Integer;
  Bytes: QWord;
begin
  if Skip then
    Exit;
  Bytes := 0;
  for Index := First to Last - 1 do
    Bytes := Bytes + QWord(Length(FLines[Index])) + 1;
  if ElideEmpty and (Bytes = 0) then
    Exit;
  Name := SectionName(FSectionCount);
  Inc(FSectionCount);
  Handle := OpenFile(PChar(Name), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Abort(Format('%s: %s', [Name, ErrorText(ErrorCodeOf(Handle))]));
  FCreated.Add(Name);
  Stream := CreateOutputStream(Handle);
  for Index := First to Last - 1 do
    WriteStringLine(Stream, FLines[Index]);
  DestroyOutputStream(Stream);
  CloseFile(Handle);
  if not Quiet then
    PrintStringLine(IntToStr(Bytes));
end;

{ /REGEX/[OFFSET] or %REGEX%[OFFSET]. }
function TContextSplitter.ApplyExpression(const Pattern: string): Boolean;
var
  Delimiter: Char;
  Closing: Integer;
  OffsetText: string;
  Offset: Int64;
  Expression: TExpression;
  Match: TMatch;
  CompileError: string;
  Found: Integer;
  Target: Integer;
begin
  Delimiter := Pattern[1];
  Closing := LastDelimiter(Delimiter, Pattern);
  if Closing <= 1 then
    Abort(Format('%s: closing delimiter ''', [Pattern]) + Delimiter + ''' missing');
  Offset := 0;
  OffsetText := Copy(Pattern, Closing + 1, MaxInt);
  if (OffsetText <> '') and not ParseDecimal(OffsetText, Offset) then
    Abort(Format('%s: invalid pattern', [Pattern]));
  if not CompileExpression(Copy(Pattern, 2, Closing - 2), SyntaxBasic, Expression, CompileError) then
    Abort(Format('%s: %s', [Pattern, CompileError]));
  { The search starts after the current line (the previous match). }
  Found := -1;
  Target := FPosition;
  if (FPosition > 0) or (FSectionCount > 0) then
    Target := FPosition + 1;
  if Delimiter = '%' then
    Target := FPosition;
  while Target < FLines.Count do
  begin
    if SearchExpression(Expression, FLines[Target], Match) then
    begin
      Found := Target;
      Break;
    end;
    Inc(Target);
  end;
  FreeExpression(Expression);
  if Found < 0 then
    Exit(False);
  Target := Found + Integer(Offset);
  if (Target < FPosition) or (Target > FLines.Count) then
    Abort(Format('%s: line number out of range', [Pattern]));
  WriteSection(FPosition, Target, Delimiter = '%');
  FPosition := Target;
  Result := True;
end;

{ N: up to line N. }
function TContextSplitter.ApplyLineNumber(const Pattern: string): Boolean;
var
  LineNumber: Int64;
begin
  if not ParseDecimal(Pattern, LineNumber) or (LineNumber < 1) then
    Abort(Format('%s: invalid pattern', [Pattern]));
  if LineNumber - 1 < FPosition then
    Abort(Format('%s: line number out of range', [Pattern]));
  if LineNumber - 1 > FLines.Count then
    Exit(False);
  WriteSection(FPosition, Integer(LineNumber) - 1, False);
  FPosition := Integer(LineNumber) - 1;
  Result := True;
end;

function TContextSplitter.ApplyPattern(const Pattern: string): Boolean;
begin
  if (Pattern <> '') and (Pattern[1] in ['/', '%']) then
    Result := ApplyExpression(Pattern)
  else
    Result := ApplyLineNumber(Pattern);
end;

procedure TContextSplitter.WriteRest;
begin
  WriteSection(FPosition, FLines.Count, False);
end;

var
  Splitter: TContextSplitter;

(* {N} or {*}: Previous again N more times, or as often as it is found. *)
procedure RepeatPattern(const Pattern, Previous: string);
var
  RepeatForever: Boolean;
  RepeatCount: Int64;
  Repetition: Int64;
  Closing: Integer;
  CountText: string;
begin
  if Previous = '' then
    Splitter.Abort(Format('%s: no previous pattern to repeat', [Pattern]));
  RepeatForever := Pattern = '{*}';
  RepeatCount := 0;
  if not RepeatForever then
  begin
    Closing := Pos('}', Pattern);
    if Closing = 0 then
      Splitter.Abort(Format('%s: invalid repeat count', [Pattern]));
    CountText := Copy(Pattern, 2, Closing - 2);
    if not ParseDecimal(CountText, RepeatCount) or (RepeatCount < 0) then
      Splitter.Abort(Format('%s: invalid repeat count', [CountText]));
  end;
  Repetition := 0;
  while RepeatForever or (Repetition < RepeatCount) do
  begin
    if not Splitter.ApplyPattern(Previous) then
    begin
      if RepeatForever then
        Break;
      Splitter.Abort(Format('%s: match not found on repetition %d', [Previous, Repetition + 1]));
    end;
    Inc(Repetition);
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Stream: PInputStream;
  PatternIndex: Integer;
  Pattern: string;
  PreviousPattern: string;
  Number: Int64;
begin
  Splitter := TContextSplitter.Create;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'prefix', True, OptionPrefix),
    CommandOption('k', 'keep-files', False, OptionKeep),
    CommandOption('n', 'digits', True, OptionDigits),
    CommandOption('s', 'quiet', False, OptionQuiet),
    CommandOption(#0, 'silent', False, OptionQuiet),
    CommandOption('z', 'elide-empty-files', False, OptionElide)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionPrefix: Splitter.Prefix := Value;
      OptionKeep: Splitter.KeepFiles := True;
      OptionDigits:
        begin
          if not ParseDecimal(Value, Number) or (Number < 1) or (Number > 9) then
            Fail(1, Format('invalid number: ''%s''', [Value]));
          Splitter.Digits := Integer(Number);
        end;
      OptionQuiet: Splitter.Quiet := True;
      OptionElide: Splitter.ElideEmpty := True;
    end;
  if CommandLine.OperandCount < 2 then
    FailWithUsageHint('missing operand');

  Stream := OpenInput(CommandLine.Operands[0]);
  if Stream = nil then
    Halt(1);
  Splitter.ReadLines(Stream);
  CloseInput(Stream);

  { No pattern is empty once it has been applied: an empty one fails. }
  PreviousPattern := '';
  for PatternIndex := 1 to CommandLine.OperandCount - 1 do
  begin
    Pattern := CommandLine.Operands[PatternIndex];
    if (Pattern <> '') and (Pattern[1] = '{') then
      RepeatPattern(Pattern, PreviousPattern)
    else
    begin
      if not Splitter.ApplyPattern(Pattern) then
        Splitter.Abort(Format('%s: match not found', [Pattern]));
      PreviousPattern := Pattern;
    end;
  end;
  Splitter.WriteRest;
  Splitter.Free;
  CommandLine.Free;
end.
