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
{$pointermath on}

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: pr [OPTION]... [FILE]...'#10 +
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
  Header: PChar;
  PageLength: Int64;
  NumberLines: Boolean;
  Indent: Int64;
  OmitHeader: Boolean;
  PageWidth: Int64;
  LineNumber: Int64;

procedure WriteSpaces(Count: Int64);
begin
  while Count > 0 do
  begin
    WriteCharacter(StandardOutput, ' ');
    Dec(Count);
  end;
end;

procedure WritePageHeader(Title: PChar; Page: Integer);
var
  DateTime: TDateTime;
  DateText: array[0..31] of Char;
  PageText: array[0..31] of Char;
  Middle: Int64;
  Formatted: PChar;
begin
  DecodeTime(CurrentTime, DateTime);
  Formatted := FormatText('%04d-%02d-%02d %02d:%02d', [ArgumentNumber(DateTime.Year), ArgumentNumber(DateTime.Month),
    ArgumentNumber(DateTime.Day), ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute)]);
  CopyText(@DateText[0], Formatted, SizeOf(DateText));
  FreeMemory(Formatted);
  Formatted := FormatText('Page %d', [ArgumentNumber(Page)]);
  CopyText(@PageText[0], Formatted, SizeOf(PageText));
  FreeMemory(Formatted);

  WriteCharacter(StandardOutput, #10);
  WriteCharacter(StandardOutput, #10);
  WriteSpaces(Indent);
  WriteText(StandardOutput, @DateText[0]);
  { The title centered between date and page number. }
  Middle := (PageWidth - Int64(TextLength(Title))) div 2 - Int64(TextLength(@DateText[0]));
  if Middle < 1 then
    Middle := 1;
  WriteSpaces(Middle);
  WriteText(StandardOutput, Title);
  Middle := PageWidth - Int64(TextLength(@DateText[0])) - Middle - Int64(TextLength(Title)) - Int64(TextLength(@PageText[0]));
  if Middle < 1 then
    Middle := 1;
  WriteSpaces(Middle);
  WriteLine(StandardOutput, @PageText[0]);
  WriteCharacter(StandardOutput, #10);
  WriteCharacter(StandardOutput, #10);
end;

{ Writes one text line (possibly empty), cut or padded to Width. }
procedure WriteCell(Line: PChar; Width: Int64; PadToWidth: Boolean);
var
  Length: Int64;
  Prefix: PChar;
begin
  Length := 0;
  if NumberLines and (Line <> nil) then
  begin
    Inc(LineNumber);
    Prefix := FormatText('%5d'#9, [ArgumentNumber(LineNumber)]);
    WriteText(StandardOutput, Prefix);
    FreeMemory(Prefix);
    Length := 8;
  end;
  if Line <> nil then
    while (Line^ <> #0) and (Length < Width) do
    begin
      WriteCharacter(StandardOutput, Line^);
      Inc(Line);
      Inc(Length);
    end;
  if PadToWidth then
    WriteSpaces(Width - Length);
end;

procedure PrintFile(const Lines: TLineList; Title: PChar);
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
          WriteCell(Lines.Items[Index], ColumnWidth - 1, Column < Columns - 1)
        else
          WriteCell(nil, ColumnWidth - 1, Column < Columns - 1);
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
      for Row := 1 to TrailerLines do
        WriteCharacter(StandardOutput, #10);
    end;
    First := First + Integer(LinesPerPage);
    Inc(Page);
  until First >= Lines.Count;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Lines: TLineList;
  Title: PChar;
  ExitStatus: LongInt;
begin
  Columns := 1;
  PageLength := 66;
  PageWidth := 72;
  Indent := 0;
  Header := nil;
  { "-2" means two columns. }
  for Index := 1 to ArgumentCount - 1 do
    if (ArgumentValues[Index][0] = '-') and IsDigit(ArgumentValues[Index][1]) then
    begin
      if not ParseInteger(ArgumentValues[Index] + 1, Columns) or (Columns < 1) then
        Fail(1, 'invalid number of columns', []);
      { Replaced by an option the parser ignores. }
      ArgumentValues[Index] := '--columns-given';
    end;
  BeginOptions(Parser, [
    OptionDefinition(#0, 'columns', True, OptionColumns),
    OptionDefinition(#0, 'columns-given', False, 0),
    OptionDefinition('d', 'double-space', False, OptionDouble),
    OptionDefinition('h', 'header', True, OptionHeader),
    OptionDefinition('l', 'length', True, OptionLength),
    OptionDefinition('n', 'number-lines', False, OptionNumber),
    OptionDefinition('o', 'indent', True, OptionIndent),
    OptionDefinition('t', 'omit-header', False, OptionOmitHeader),
    OptionDefinition('w', 'width', True, OptionWidth)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionColumns:
        if not ParseInteger(Value, Columns) or (Columns < 1) then
          Fail(1, 'invalid number of columns: ''%s''', [ArgumentText(Value)]);
      OptionDouble: DoubleSpace := True;
      OptionHeader: Header := Value;
      OptionLength:
        if not ParseInteger(Value, PageLength) or (PageLength < 1) then
          Fail(1, 'invalid page length: ''%s''', [ArgumentText(Value)]);
      OptionNumber: NumberLines := True;
      OptionIndent:
        if not ParseInteger(Value, Indent) or (Indent < 0) then
          Fail(1, 'invalid indent: ''%s''', [ArgumentText(Value)]);
      OptionOmitHeader: OmitHeader := True;
      OptionWidth:
        if not ParseInteger(Value, PageWidth) or (PageWidth < 1) then
          Fail(1, 'invalid page width: ''%s''', [ArgumentText(Value)]);
    end;
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
    BeginLineList(Lines);
    ReadAllLines(Stream, Lines);
    CloseInput(Stream);
    Title := Header;
    if Title = nil then
    begin
      Title := Parser.Operands[Index];
      if TextIsEqual(Title, '-') then
        Title := '';
    end;
    LineNumber := 0;
    PrintFile(Lines, Title);
    FreeLineList(Lines);
  end;
  Halt(ExitStatus);
end.
