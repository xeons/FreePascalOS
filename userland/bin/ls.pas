{
  ls - list directory contents

  ls [-1aAdFhilrsRSt] [FILE]...

  Directories are listed by their contents, other files by name. On the
  console, names are arranged in columns; otherwise one per line.
  Owner and group names come from /etc/passwd and /etc/group.

  Called as dir it always uses columns, as vdir the long format.
}
program ls;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Environment,
  Sys.Time,
  Util.Accounts,
  Util.Directories,
  Util.Input,
  Util.Modes,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.Sizes,
  Util.Sorting;

const
  Usage: PChar = 'Usage: ls [OPTION]... [FILE]...'#10 +
    'List information about the FILEs (the current directory by default).'#10 +
    'Entries are sorted alphabetically unless -S or -t is given.'#10 +
    #10 +
    '  -a, --all                  do not ignore entries starting with .'#10 +
    '  -A, --almost-all           do not list implied . and ..'#10 +
    '  -d, --directory            list directories themselves, not their contents'#10 +
    '  -F, --classify             append indicator (one of */=>@|) to entries'#10 +
    '  -h, --human-readable       with -l, print sizes like 1K 234M 2G etc.'#10 +
    '  -i, --inode                print the index number of each file'#10 +
    '  -l                         use a long listing format'#10 +
    '  -n, --numeric-uid-gid      like -l, but list numeric user and group IDs'#10 +
    '  -r, --reverse              reverse order while sorting'#10 +
    '  -R, --recursive            list subdirectories recursively'#10 +
    '  -s, --size                 print the allocated size of each file, in blocks'#10 +
    '  -S                         sort by file size, largest first'#10 +
    '  -t                         sort by modification time, newest first'#10 +
    '  -1                         list one file per line'#10;

  OptionAll = 1;
  OptionAlmostAll = 2;
  OptionDirectory = 3;
  OptionClassify = 4;
  OptionHumanReadable = 5;
  OptionNodeNumber = 6;
  OptionLong = 7;
  OptionReverse = 8;
  OptionRecursive = 9;
  OptionSortSize = 10;
  OptionSortTime = 11;
  OptionOnePerLine = 12;
  OptionNumeric = 13;
  OptionSize = 14;

  ScreenWidth = 80;
  SecondsInHalfYear = 183 * 24 * 60 * 60;

type
  TSortOrder = (SortByName, SortBySize, SortByTime);

  PEntry = ^TEntry;
  TEntry = record
    Name: PChar;        { as displayed }
    Path: PChar;        { for looking it up }
    Information: TFileInformation;
    LinkTarget: PChar;
  end;

var
  ShowAll: Boolean;
  ShowAlmostAll: Boolean;
  ListDirectoriesThemselves: Boolean;
  Classify: Boolean;
  HumanReadable: Boolean;
  ShowNodeNumbers: Boolean;
  LongFormat: Boolean;
  Reverse: Boolean;
  Recursive: Boolean;
  SortOrder: TSortOrder;
  OnePerLine: Boolean;
  NumericIds: Boolean;
  ShowSizes: Boolean;
  BlockWidth: Integer;
  Now: Int64;
  ExitStatus: LongInt;

function NewEntry(Name, Path: PChar): PEntry;
var
  Error: LongInt;
  Target: array[0..PathCapacity - 1] of Char;
begin
  Result := PEntry(AllocateZeroedMemory(SizeOf(TEntry)));
  Result^.Name := DuplicateText(Name);
  Result^.Path := DuplicateText(Path);
  Error := GetLinkInformation(Path, Result^.Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot access ''%s''', [ArgumentText(Path)]);
    ExitStatus := 1;
    FreeMemory(Result^.Name);
    FreeMemory(Result^.Path);
    FreeMemory(Result);
    Exit(nil);
  end;
  if (Result^.Information.Kind = KindSymbolicLink) and
     (ReadSymbolicLink(Path, @Target[0], PathCapacity) = ErrorNone) then
    Result^.LinkTarget := DuplicateText(@Target[0]);
end;

procedure FreeEntry(Entry: PEntry);
begin
  FreeMemory(Entry^.Name);
  FreeMemory(Entry^.Path);
  FreeMemory(Entry^.LinkTarget);
  FreeMemory(Entry);
end;

function CompareEntries(First, Second: Pointer; Context: Pointer): Integer;
var
  Left: PEntry;
  Right: PEntry;
begin
  Left := PEntry(First);
  Right := PEntry(Second);
  Result := 0;
  case SortOrder of
    SortBySize:
      if Left^.Information.SizeInBytes > Right^.Information.SizeInBytes then
        Result := -1
      else if Left^.Information.SizeInBytes < Right^.Information.SizeInBytes then
        Result := 1;
    SortByTime:
      if Left^.Information.ModificationTime > Right^.Information.ModificationTime then
        Result := -1
      else if Left^.Information.ModificationTime < Right^.Information.ModificationTime then
        Result := 1;
  end;
  if Result = 0 then
    Result := CompareText(Left^.Name, Right^.Name);
  if Reverse then
    Result := -Result;
end;

function IndicatorOf(Entry: PEntry): Char;
begin
  Result := #0;
  if not Classify then
    Exit;
  case Entry^.Information.Kind of
    KindDirectory: Result := '/';
    KindSymbolicLink: Result := '@';
    KindFifo: Result := '|';
    KindFile:
      if (Entry^.Information.Mode and $49) <> 0 then
        Result := '*';
  end;
end;

function DisplayWidth(Entry: PEntry): Integer;
begin
  Result := Integer(TextLength(Entry^.Name));
  if IndicatorOf(Entry) <> #0 then
    Inc(Result);
  if ShowSizes then
    Result := Result + BlockWidth + 1;
end;

procedure WriteName(Entry: PEntry);
begin
  WriteText(StandardOutput, Entry^.Name);
  if IndicatorOf(Entry) <> #0 then
    WriteCharacter(StandardOutput, IndicatorOf(Entry));
end;

procedure WriteModeText(const Information: TFileInformation);
var
  Buffer: array[0..15] of Char;
begin
  case Information.Kind of
    KindDirectory: WriteCharacter(StandardOutput, 'd');
    KindSymbolicLink: WriteCharacter(StandardOutput, 'l');
    KindFifo: WriteCharacter(StandardOutput, 'p');
    KindCharacterDevice: WriteCharacter(StandardOutput, 'c');
    KindBlockDevice: WriteCharacter(StandardOutput, 'b');
  else
    WriteCharacter(StandardOutput, '-');
  end;
  WriteText(StandardOutput, FormatModeText(Information.Mode, @Buffer[0]));
end;

{ Allocated size in 1 KiB blocks, as -s and "total" show it. }
function BlocksOf(const Information: TFileInformation): QWord;
begin
  Result := (Information.AllocatedBytes + 1023) div 1024;
end;

procedure WriteBlocks(Entry: PEntry);
begin
  if ShowSizes then
    WriteFormatted(StandardOutput, '%*u ', [ArgumentNumber(BlockWidth),
      ArgumentUnsigned(BlocksOf(Entry^.Information))]);
end;

procedure WriteTimestamp(Time: Int64);
var
  DateTime: TDateTime;
begin
  DecodeTime(Time, DateTime);
  WriteFormatted(StandardOutput, '%s %2d ', [ArgumentText(MonthName(DateTime.Month)), ArgumentNumber(DateTime.Day)]);
  if (Time > Now - SecondsInHalfYear) and (Time <= Now + 3600) then
    WriteFormatted(StandardOutput, '%02d:%02d', [ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute)])
  else
    WriteFormatted(StandardOutput, ' %4d', [ArgumentNumber(DateTime.Year)]);
end;

function OwnerText(Id: LongWord; var Buffer: TNumberText): PChar;
begin
  Result := nil;
  if not NumericIds then
    Result := UserNameOf(Id);
  if Result = nil then
    Result := FormatDecimal(Id, Buffer);
end;

function GroupText(Id: LongWord; var Buffer: TNumberText): PChar;
begin
  Result := nil;
  if not NumericIds then
    Result := GroupNameOf(Id);
  if Result = nil then
    Result := FormatDecimal(Id, Buffer);
end;

procedure WriteLong(Entries: PPointer; Count: Integer);
var
  Index: Integer;
  Entry: PEntry;
  SizeWidth: Integer;
  LinkWidth: Integer;
  NodeWidth: Integer;
  SizeText: array[0..31] of Char;
  NumberText: TNumberText;
  Width: Integer;
  OwnerWidth: Integer;
  GroupWidth: Integer;
begin
  { Column widths, so numbers line up. }
  SizeWidth := 1;
  LinkWidth := 1;
  NodeWidth := 1;
  OwnerWidth := 1;
  GroupWidth := 1;
  for Index := 0 to Count - 1 do
  begin
    Entry := PEntry(Entries[Index]);
    if HumanReadable then
      Width := Integer(TextLength(FormatHumanSize(Entry^.Information.SizeInBytes, @SizeText[0])))
    else
      Width := Integer(TextLength(FormatDecimal(Entry^.Information.SizeInBytes, NumberText)));
    if Width > SizeWidth then
      SizeWidth := Width;
    Width := Integer(TextLength(FormatDecimal(Entry^.Information.LinkCount, NumberText)));
    if Width > LinkWidth then
      LinkWidth := Width;
    Width := Integer(TextLength(FormatDecimal(Entry^.Information.NodeNumber, NumberText)));
    if Width > NodeWidth then
      NodeWidth := Width;
    Width := Integer(TextLength(OwnerText(Entry^.Information.OwnerId, NumberText)));
    if Width > OwnerWidth then
      OwnerWidth := Width;
    Width := Integer(TextLength(GroupText(Entry^.Information.GroupId, NumberText)));
    if Width > GroupWidth then
      GroupWidth := Width;
  end;

  for Index := 0 to Count - 1 do
  begin
    Entry := PEntry(Entries[Index]);
    if ShowNodeNumbers then
      WriteFormatted(StandardOutput, '%*u ', [ArgumentNumber(NodeWidth), ArgumentUnsigned(Entry^.Information.NodeNumber)]);
    WriteBlocks(Entry);
    WriteModeText(Entry^.Information);
    WriteFormatted(StandardOutput, ' %*u %-*s %-*s ', [ArgumentNumber(LinkWidth),
      ArgumentUnsigned(Entry^.Information.LinkCount), ArgumentNumber(OwnerWidth),
      ArgumentText(OwnerText(Entry^.Information.OwnerId, NumberText)), ArgumentNumber(GroupWidth),
      ArgumentText(GroupText(Entry^.Information.GroupId, NumberText))]);
    if HumanReadable then
      WriteFormatted(StandardOutput, '%*s ', [ArgumentNumber(SizeWidth),
        ArgumentText(FormatHumanSize(Entry^.Information.SizeInBytes, @SizeText[0]))])
    else
      WriteFormatted(StandardOutput, '%*u ', [ArgumentNumber(SizeWidth), ArgumentUnsigned(Entry^.Information.SizeInBytes)]);
    WriteTimestamp(Entry^.Information.ModificationTime);
    WriteCharacter(StandardOutput, ' ');
    WriteName(Entry);
    if Entry^.LinkTarget <> nil then
    begin
      WriteText(StandardOutput, ' -> ');
      WriteText(StandardOutput, Entry^.LinkTarget);
    end;
    WriteCharacter(StandardOutput, #10);
  end;
end;

{ Arranges names in columns, filled top to bottom, as wide as fits. }
procedure WriteColumns(Entries: PPointer; Count: Integer);
var
  ColumnWidth: Integer;
  Columns: Integer;
  Rows: Integer;
  Row: Integer;
  Column: Integer;
  Index: Integer;
  Padding: Integer;
  Entry: PEntry;
begin
  if Count = 0 then
    Exit;
  ColumnWidth := 0;
  for Index := 0 to Count - 1 do
  begin
    if DisplayWidth(PEntry(Entries[Index])) > ColumnWidth then
      ColumnWidth := DisplayWidth(PEntry(Entries[Index]));
  end;
  ColumnWidth := ColumnWidth + 2;
  Columns := ScreenWidth div ColumnWidth;
  if Columns < 1 then
    Columns := 1;
  Rows := (Count + Columns - 1) div Columns;

  for Row := 0 to Rows - 1 do
  begin
    for Column := 0 to Columns - 1 do
    begin
      Index := Column * Rows + Row;
      if Index >= Count then
        Break;
      Entry := PEntry(Entries[Index]);
      WriteBlocks(Entry);
      WriteName(Entry);
      if (Index + Rows < Count) then
      begin
        Padding := ColumnWidth - DisplayWidth(Entry);
        while Padding > 0 do
        begin
          WriteCharacter(StandardOutput, ' ');
          Dec(Padding);
        end;
      end;
    end;
    WriteCharacter(StandardOutput, #10);
  end;
end;

procedure WriteEntries(Entries: PPointer; Count: Integer);
var
  Index: Integer;
  NumberText: TNumberText;
  Width: Integer;
begin
  SortPointers(Entries, Count, @CompareEntries, nil);
  BlockWidth := 1;
  for Index := 0 to Count - 1 do
  begin
    Width := Integer(TextLength(FormatDecimal(BlocksOf(PEntry(Entries[Index])^.Information), NumberText)));
    if Width > BlockWidth then
      BlockWidth := Width;
  end;
  if LongFormat then
    WriteLong(Entries, Count)
  else if OnePerLine then
    for Index := 0 to Count - 1 do
    begin
      if ShowNodeNumbers then
        WriteFormatted(StandardOutput, '%u ', [ArgumentUnsigned(PEntry(Entries[Index])^.Information.NodeNumber)]);
      WriteBlocks(PEntry(Entries[Index]));
      WriteName(PEntry(Entries[Index]));
      WriteCharacter(StandardOutput, #10);
    end
  else
    WriteColumns(Entries, Count);
end;

procedure ListDirectoryContents(Path: PChar; ShowHeader: Boolean);
var
  Names: TLineList;
  Entries: PPointer;
  Count: Integer;
  Index: Integer;
  ChildPath: PChar;
  Entry: PEntry;
  Error: LongInt;
  Total: QWord;
begin
  BeginLineList(Names);
  Error := ListDirectory(Path, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot open directory ''%s''', [ArgumentText(Path)]);
    ExitStatus := 2;
    FreeLineList(Names);
    Exit;
  end;
  if ShowAll then
  begin
    AddLine(Names, DuplicateText('.'));
    AddLine(Names, DuplicateText('..'));
  end;

  Entries := PPointer(AllocateMemory(QWord(Names.Count + 1) * SizeOf(Pointer)));
  Count := 0;
  Total := 0;
  for Index := 0 to Names.Count - 1 do
  begin
    if (Names.Items[Index][0] = '.') and not (ShowAll or ShowAlmostAll) then
      Continue;
    ChildPath := JoinPath(Path, Names.Items[Index]);
    Entry := NewEntry(Names.Items[Index], ChildPath);
    FreeMemory(ChildPath);
    if Entry = nil then
      Continue;
    Entries[Count] := Entry;
    Total := Total + BlocksOf(Entry^.Information);
    Inc(Count);
  end;
  FreeLineList(Names);

  if ShowHeader then
    WriteFormatted(StandardOutput, '%s:'#10, [ArgumentText(Path)]);
  if LongFormat or ShowSizes then
    WriteFormatted(StandardOutput, 'total %u'#10, [ArgumentUnsigned(Total)]);
  WriteEntries(Entries, Count);

  if Recursive then
    for Index := 0 to Count - 1 do
    begin
      Entry := PEntry(Entries[Index]);
      if (Entry^.Information.Kind = KindDirectory) and not IsDotEntry(Entry^.Name) then
      begin
        WriteCharacter(StandardOutput, #10);
        ListDirectoryContents(Entry^.Path, True);
      end;
    end;

  for Index := 0 to Count - 1 do
    FreeEntry(PEntry(Entries[Index]));
  FreeMemory(Entries);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Files: PPointer;
  FileCount: Integer;
  Directories: TLineList;
  Entry: PEntry;
  Information: TFileInformation;
  IsDirectoryOperand: Boolean;
  ProgramBase: PChar;
begin
  SortOrder := SortByName;
  OnePerLine := KernelGetHandleKind(StandardOutputHandle) <> HandleKindConsole;
  ProgramBase := BaseName(Argument(0));
  if TextIsEqual(ProgramBase, 'dir') then
    OnePerLine := False
  else if TextIsEqual(ProgramBase, 'vdir') then
    LongFormat := True;
  ExitStatus := 0;
  Now := CurrentTime;
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, OptionAll),
    OptionDefinition('A', 'almost-all', False, OptionAlmostAll),
    OptionDefinition('d', 'directory', False, OptionDirectory),
    OptionDefinition('F', 'classify', False, OptionClassify),
    OptionDefinition('h', 'human-readable', False, OptionHumanReadable),
    OptionDefinition('i', 'inode', False, OptionNodeNumber),
    OptionDefinition('l', nil, False, OptionLong),
    OptionDefinition('r', 'reverse', False, OptionReverse),
    OptionDefinition('R', 'recursive', False, OptionRecursive),
    OptionDefinition('S', nil, False, OptionSortSize),
    OptionDefinition('t', nil, False, OptionSortTime),
    OptionDefinition('1', nil, False, OptionOnePerLine),
    OptionDefinition('n', 'numeric-uid-gid', False, OptionNumeric),
    OptionDefinition('s', 'size', False, OptionSize)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAll: ShowAll := True;
      OptionAlmostAll: ShowAlmostAll := True;
      OptionDirectory: ListDirectoriesThemselves := True;
      OptionClassify: Classify := True;
      OptionHumanReadable: HumanReadable := True;
      OptionNodeNumber: ShowNodeNumbers := True;
      OptionLong: LongFormat := True;
      OptionReverse: Reverse := True;
      OptionRecursive: Recursive := True;
      OptionSortSize: SortOrder := SortBySize;
      OptionSortTime: SortOrder := SortByTime;
      OptionOnePerLine: OnePerLine := True;
      OptionSize: ShowSizes := True;
      OptionNumeric:
        begin
          NumericIds := True;
          LongFormat := True;
        end;
    end;

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '.';
    Parser.OperandCount := 1;
  end;

  { Files first (sorted together), then each directory. }
  Files := PPointer(AllocateMemory(QWord(Parser.OperandCount + 1) * SizeOf(Pointer)));
  FileCount := 0;
  BeginLineList(Directories);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    IsDirectoryOperand := (GetFileInformation(Parser.Operands[Index], Information) = ErrorNone) and
      (Information.Kind = KindDirectory);
    if IsDirectoryOperand and not ListDirectoriesThemselves then
      AddLine(Directories, Parser.Operands[Index])
    else
    begin
      Entry := NewEntry(Parser.Operands[Index], Parser.Operands[Index]);
      if Entry <> nil then
      begin
        Files[FileCount] := Entry;
        Inc(FileCount);
      end
      else
        ExitStatus := 2;
    end;
  end;

  WriteEntries(Files, FileCount);
  for Index := 0 to Directories.Count - 1 do
  begin
    if (FileCount > 0) or (Index > 0) then
      WriteCharacter(StandardOutput, #10);
    ListDirectoryContents(Directories.Items[Index], (Parser.OperandCount > 1) or Recursive);
  end;
  Halt(ExitStatus);
end.
