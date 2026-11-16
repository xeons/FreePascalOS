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
  pr - convert text files for printing

  pr [-COLUMNS] [-dnt] [-h HEADER] [-l LINES] [-o MARGIN] [-w WIDTH] [FILE]...

  Pages are LINES long (default 66): a 5 line header with the date, the
  file name and the page number, the text, and a 5 line trailer. -t
  leaves out headers and trailers. -COLUMNS prints the text in columns,
  filled downwards.
}
program pr;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  StrUtils,
  Sys.Streams,
  Sys.Time,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: pr [OPTION]... [FILE]...'#10 +
    'Paginate or columnate FILE(s) for printing.'#10#10 +
    '  -COLUMN, --columns=COLUMN  output COLUMN columns'#10 +
    '  -d, --double-space         double space the output'#10 +
    '  -h, --header=HEADER        use a centered HEADER instead of filename'#10 +
    '  -l, --length=PAGE_LENGTH   set the page length to PAGE_LENGTH (66) lines'#10 +
    '  -n, --number-lines         number lines'#10 +
    '  -o, --indent=MARGIN        offset each line with MARGIN (zero) spaces'#10 +
    '  -t, --omit-header          omit page headers and trailers'#10 +
    '  -w, --width=PAGE_WIDTH     set page width to PAGE_WIDTH (72) characters'#10;

  OptionColumns = 1;
  OptionDouble = 2;
  OptionHeader = 3;
  OptionLength = 4;
  OptionNumber = 5;
  OptionIndent = 6;
  OptionOmitHeader = 7;
  OptionWidth = 8;
  HeaderLines = 5;
  TrailerLines = 5;

var
  Columns: Int64;
  DoubleSpace: Boolean;
  PageLength: Int64;
  NumberLines: Boolean;
  Indent: Int64;
  OmitHeader: Boolean;
  PageWidth: Int64;
  LineNumber: Int64;

procedure WriteSpaces(Count: Int64);
begin
  if Count > 0 then
    PrintString(StringOfChar(' ', Count));
end;

procedure WritePageHeader(const Title: string; Page: Integer);
var
  DateTime: TDateTime;
  DateText: string;
  PageText: string;
  Middle: Int64;
begin
  DecodeTime(CurrentTime, DateTime);
  DateText := Format('%.4d-%.2d-%.2d %.2d:%.2d', [DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute]);
  PageText := 'Page ' + IntToStr(Page);

  PrintString(#10#10);
  WriteSpaces(Indent);
  PrintString(DateText);
  { The title centered between date and page number. }
  Middle := (PageWidth - Length(Title)) div 2 - Length(DateText);
  if Middle < 1 then
    Middle := 1;
  WriteSpaces(Middle);
  PrintString(Title);
  Middle := PageWidth - Length(DateText) - Middle - Length(Title) - Length(PageText);
  if Middle < 1 then
    Middle := 1;
  WriteSpaces(Middle);
  PrintString(PageText + #10#10#10);
end;

{ Writes one text line, or an empty cell when HasLine is False, cut or
  padded to Width. }
procedure WriteCell(HasLine: Boolean; const Line: string; Width: Int64; PadToWidth: Boolean);
var
  Written: Int64;
  Shown: string;
begin
  Written := 0;
  if NumberLines and HasLine then
  begin
    Inc(LineNumber);
    PrintString(Format('%5d'#9, [LineNumber]));
    Written := 8;
  end;
  if HasLine and (Width > Written) then
  begin
    Shown := LeftStr(Line, Width - Written);
    PrintString(Shown);
    Inc(Written, Length(Shown));
  end;
  if PadToWidth then
    WriteSpaces(Width - Written);
end;

procedure PrintFile(Lines: TStrings; const Title: string);
var
  BodyLines: Int64;
  LinesPerPage: Int64;
  Page: Integer;
  First: Integer;
  Row: Int64;
  Column: Int64;
  ColumnWidth: Int64;
  Index: Int64;
  Written: Int64;
begin
  if OmitHeader then
    BodyLines := PageLength
  else
    BodyLines := PageLength - HeaderLines - TrailerLines;
  if BodyLines < 1 then
    BodyLines := 1;
  if DoubleSpace then
    BodyLines := (BodyLines + 1) div 2;
  LinesPerPage := BodyLines * Columns;
  ColumnWidth := PageWidth div Columns;

  Page := 1;
  First := 0;
  repeat
    if not OmitHeader then
      WritePageHeader(Title, Page);
    Written := 0;
    for Row := 0 to BodyLines - 1 do
    begin
      { Stop early on the last page unless a trailer pads it. }
      if (First + Row >= Lines.Count) and OmitHeader then
        Break;
      WriteSpaces(Indent);
      for Column := 0 to Columns - 1 do
      begin
        Index := First + Column * BodyLines + Row;
        if Index < Lines.Count then
          WriteCell(True, Lines[Index], ColumnWidth - 1, Column < Columns - 1)
        else
          WriteCell(False, '', ColumnWidth - 1, Column < Columns - 1);
        if Column < Columns - 1 then
          WriteCharacter(StandardOutput, ' ');
      end;
      WriteCharacter(StandardOutput, #10);
      if DoubleSpace then
        WriteCharacter(StandardOutput, #10);
      Inc(Written);
    end;
    if not OmitHeader then
    begin
      for Row := Written to BodyLines - 1 do
      begin
        WriteCharacter(StandardOutput, #10);
        if DoubleSpace then
          WriteCharacter(StandardOutput, #10);
      end;
      PrintString(StringOfChar(#10, TrailerLines));
    end;
    First := First + Integer(LinesPerPage);
    Inc(Page);
  until First >= Lines.Count;
end;

{ "-2" means two columns: such arguments are read here and replaced by
  an option the parser ignores. }
function ReadColumnArguments: TStringArray;
var
  Index: Integer;
begin
  Result := ProgramArguments;
  for Index := 0 to High(Result) do
    if (Length(Result[Index]) >= 2) and (Result[Index][1] = '-') and (Result[Index][2] in ['0'..'9']) then
    begin
      if not ParseDecimal(Copy(Result[Index], 2, MaxInt), Columns) or (Columns < 1) then
        Fail(1, 'invalid number of columns');
      Result[Index] := '--columns-given';
    end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  Stream: PInputStream;
  Lines: TStringList;
  Title: string;
  ExitStatus: LongInt;
begin
  Columns := 1;
  PageLength := 66;
  PageWidth := 72;
  Indent := 0;
  CommandLine := TCommandLine.Create([
    CommandOption(#0, 'columns', True, OptionColumns),
    CommandOption(#0, 'columns-given', False, 0),
    CommandOption('d', 'double-space', False, OptionDouble),
    CommandOption('h', 'header', True, OptionHeader),
    CommandOption('l', 'length', True, OptionLength),
    CommandOption('n', 'number-lines', False, OptionNumber),
    CommandOption('o', 'indent', True, OptionIndent),
    CommandOption('t', 'omit-header', False, OptionOmitHeader),
    CommandOption('w', 'width', True, OptionWidth)], Usage, ReadColumnArguments);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionColumns:
        if not ParseDecimal(Value, Columns) or (Columns < 1) then
          Fail(1, Format('invalid number of columns: ''%s''', [Value]));
      OptionDouble: DoubleSpace := True;
      OptionLength:
        if not ParseDecimal(Value, PageLength) or (PageLength < 1) then
          Fail(1, Format('invalid page length: ''%s''', [Value]));
      OptionNumber: NumberLines := True;
      OptionIndent:
        if not ParseDecimal(Value, Indent) or (Indent < 0) then
          Fail(1, Format('invalid indent: ''%s''', [Value]));
      OptionOmitHeader: OmitHeader := True;
      OptionWidth:
        if not ParseDecimal(Value, PageWidth) or (PageWidth < 1) then
          Fail(1, Format('invalid page width: ''%s''', [Value]));
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  ExitStatus := 0;
  Lines := TStringList.Create;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    Lines.Clear;
    ReadLinesInto(Stream, Lines);
    CloseInput(Stream);
    if CommandLine.OptionGiven(OptionHeader) then
      Title := CommandLine.OptionValue(OptionHeader)
    else
    begin
      Title := Operand;
      if Title = '-' then
        Title := '';
    end;
    LineNumber := 0;
    PrintFile(Lines, Title);
  end;
  Lines.Free;
  Halt(ExitStatus);
end.
