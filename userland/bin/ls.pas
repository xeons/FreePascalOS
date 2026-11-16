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
  ls - list directory contents

  ls [-1aAdFhilrsRSt] [FILE]...

  Directories are listed by their contents, other files by name. On the
  console, names are arranged in columns; otherwise one per line.
  Owner and group names come from /etc/passwd and /etc/group.

  Called as dir it always uses columns, as vdir the long format.
}
program ls;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Contnrs,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Kernel,
  Sys.Environment,
  Sys.Time,
  Sys.TimeZones,
  Sys.LocalTime,
  Util.Accounts,
  Util.CommandLine,
  Util.Directories,
  Util.Modes,
  Util.Messages,
  Sys.Streams,
  Util.Paths,
  Util.Sizes;

const
  Usage = 'Usage: ls [OPTION]... [FILE]...'#10 +
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

  { A file to list. }
  TEntry = class
  public
    Name: string;        { as displayed }
    Path: string;        { for looking it up }
    Information: TFileInformation;
    HasLinkTarget: Boolean;
    LinkTarget: string;
  end;

  TEntryList = class;

  TEntryEnumerator = class
  private
    FList: TEntryList;
    FIndex: Integer;
    function GetCurrent: TEntry;
  public
    constructor Create(List: TEntryList);
    function MoveNext: Boolean;
    property Current: TEntry read GetCurrent;
  end;

  { Entries, owned by the list. }
  TEntryList = class(TObjectList)
  private
    function GetEntry(Index: Integer): TEntry;
  public
    function GetEnumerator: TEntryEnumerator;
    property Entries[Index: Integer]: TEntry read GetEntry; default;
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
  StartTime: Int64;
  ExitStatus: LongInt;

constructor TEntryEnumerator.Create(List: TEntryList);
begin
  inherited Create;
  FList := List;
  FIndex := -1;
end;

function TEntryEnumerator.GetCurrent: TEntry;
begin
  Result := FList[FIndex];
end;

function TEntryEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FList.Count;
end;

function TEntryList.GetEntry(Index: Integer): TEntry;
begin
  Result := TEntry(Items[Index]);
end;

function TEntryList.GetEnumerator: TEntryEnumerator;
begin
  Result := TEntryEnumerator.Create(Self);
end;

{ The entry for Path, or nil (reported) when it cannot be looked at. }
function NewEntry(const Name, Path: string): TEntry;
var
  Error: LongInt;
begin
  Result := TEntry.Create;
  Result.Name := Name;
  Result.Path := Path;
  Error := GetLinkInformation(PChar(Path), Result.Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot access ''%s''', [Path]));
    ExitStatus := 1;
    Result.Free;
    Exit(nil);
  end;
  if Result.Information.Kind = KindSymbolicLink then
    Result.HasLinkTarget := ReadLinkTarget(Path, Result.LinkTarget) = ErrorNone;
end;

function CompareEntries(First, Second: Pointer): Integer;
var
  Left: TEntry;
  Right: TEntry;
begin
  Left := TEntry(First);
  Right := TEntry(Second);
  Result := 0;
  case SortOrder of
    SortBySize:
      if Left.Information.SizeInBytes > Right.Information.SizeInBytes then
        Result := -1
      else if Left.Information.SizeInBytes < Right.Information.SizeInBytes then
        Result := 1;
    SortByTime:
      if Left.Information.ModificationTime > Right.Information.ModificationTime then
        Result := -1
      else if Left.Information.ModificationTime < Right.Information.ModificationTime then
        Result := 1;
  end;
  if Result = 0 then
    Result := CompareStr(Left.Name, Right.Name);
  if Reverse then
    Result := -Result;
end;

{ The -F indicator; '' when there is none. }
function IndicatorOf(Entry: TEntry): string;
begin
  Result := '';
  if not Classify then
    Exit;
  case Entry.Information.Kind of
    KindDirectory: Result := '/';
    KindSymbolicLink: Result := '@';
    KindFifo: Result := '|';
    KindFile:
      if (Entry.Information.Mode and $49) <> 0 then
        Result := '*';
  end;
end;

function DisplayWidth(Entry: TEntry): Integer;
begin
  Result := Length(Entry.Name) + Length(IndicatorOf(Entry));
  if ShowSizes then
    Result := Result + BlockWidth + 1;
end;

function NameText(Entry: TEntry): string;
begin
  Result := Entry.Name + IndicatorOf(Entry);
end;

function KindLetter(Kind: LongWord): string;
begin
  case Kind of
    KindDirectory: Result := 'd';
    KindSymbolicLink: Result := 'l';
    KindFifo: Result := 'p';
    KindCharacterDevice: Result := 'c';
    KindBlockDevice: Result := 'b';
  else
    Result := '-';
  end;
end;

function ModeText(const Information: TFileInformation): string;
begin
  Result := KindLetter(Information.Kind) + FormatModeText(Information.Mode);
end;

{ Allocated size in 1 KiB blocks, as -s and "total" show it. }
function BlocksOf(const Information: TFileInformation): QWord;
begin
  Result := (Information.AllocatedBytes + 1023) div 1024;
end;

function BlocksText(Entry: TEntry): string;
begin
  Result := '';
  if ShowSizes then
    Result := Format('%*d ', [BlockWidth, BlocksOf(Entry.Information)]);
end;

var
  ShownZone: PTimeZone = nil;

function TimestampText(Time: Int64): string;
var
  Local: TLocalTime;
  DateTime: Sys.Time.TDateTime;
begin
  { Local time, in the zone found once for all the files. }
  if ShownZone = nil then
    ShownZone := CurrentTimeZone;
  DecodeTimeInZone(ShownZone, Time, Local);
  DateTime := Local.DateTime;
  Result := Format('%s %2d ', [string(MonthName(DateTime.Month)), DateTime.Day]);
  if (Time > StartTime - SecondsInHalfYear) and (Time <= StartTime + 3600) then
    Result := Result + Format('%.2d:%.2d', [DateTime.Hour, DateTime.Minute])
  else
    Result := Result + Format(' %4d', [DateTime.Year]);
end;

function OwnerText(Id: LongWord): string;
begin
  if NumericIds or not FindUserName(Id, Result) then
    Result := IntToStr(Id);
end;

function GroupText(Id: LongWord): string;
begin
  if NumericIds or not FindGroupName(Id, Result) then
    Result := IntToStr(Id);
end;

function SizeText(const Information: TFileInformation): string;
begin
  if HumanReadable then
    Result := FormatHumanSize(Information.SizeInBytes)
  else
    Result := IntToStr(Information.SizeInBytes);
end;

procedure RaiseToWidth(var Width: Integer; const Text: string);
begin
  if Length(Text) > Width then
    Width := Length(Text);
end;

procedure WriteLong(Entries: TEntryList);
var
  Entry: TEntry;
  SizeWidth: Integer;
  LinkWidth: Integer;
  NodeWidth: Integer;
  OwnerWidth: Integer;
  GroupWidth: Integer;
  Line: string;
begin
  { Column widths, so numbers line up. }
  SizeWidth := 1;
  LinkWidth := 1;
  NodeWidth := 1;
  OwnerWidth := 1;
  GroupWidth := 1;
  for Entry in Entries do
  begin
    RaiseToWidth(SizeWidth, SizeText(Entry.Information));
    RaiseToWidth(LinkWidth, IntToStr(Entry.Information.LinkCount));
    RaiseToWidth(NodeWidth, IntToStr(Entry.Information.NodeNumber));
    RaiseToWidth(OwnerWidth, OwnerText(Entry.Information.OwnerId));
    RaiseToWidth(GroupWidth, GroupText(Entry.Information.GroupId));
  end;

  for Entry in Entries do
  begin
    Line := '';
    if ShowNodeNumbers then
      Line := Format('%*d ', [NodeWidth, Entry.Information.NodeNumber]);
    Line := Line + BlocksText(Entry) + ModeText(Entry.Information);
    Line := Line + Format(' %*d %-*s %-*s ', [LinkWidth, Entry.Information.LinkCount,
      OwnerWidth, OwnerText(Entry.Information.OwnerId),
      GroupWidth, GroupText(Entry.Information.GroupId)]);
    Line := Line + Format('%*s ', [SizeWidth, SizeText(Entry.Information)]);
    Line := Line + TimestampText(Entry.Information.ModificationTime) + ' ' + NameText(Entry);
    if Entry.HasLinkTarget then
      Line := Line + ' -> ' + Entry.LinkTarget;
    PrintStringLine(Line);
  end;
end;

{ Arranges names in columns, filled top to bottom, as wide as fits. }
procedure WriteColumns(Entries: TEntryList);
var
  ColumnWidth: Integer;
  Columns: Integer;
  Rows: Integer;
  Row: Integer;
  Column: Integer;
  Index: Integer;
  Entry: TEntry;
  Line: string;
begin
  if Entries.Count = 0 then
    Exit;
  ColumnWidth := 0;
  for Entry in Entries do
    if DisplayWidth(Entry) > ColumnWidth then
      ColumnWidth := DisplayWidth(Entry);
  ColumnWidth := ColumnWidth + 2;
  Columns := ScreenWidth div ColumnWidth;
  if Columns < 1 then
    Columns := 1;
  Rows := (Entries.Count + Columns - 1) div Columns;

  for Row := 0 to Rows - 1 do
  begin
    Line := '';
    for Column := 0 to Columns - 1 do
    begin
      Index := Column * Rows + Row;
      if Index >= Entries.Count then
        Break;
      Entry := Entries[Index];
      Line := Line + BlocksText(Entry) + NameText(Entry);
      if Index + Rows < Entries.Count then
        Line := Line + StringOfChar(' ', ColumnWidth - DisplayWidth(Entry));
    end;
    PrintStringLine(Line);
  end;
end;

procedure WriteOnePerLine(Entries: TEntryList);
var
  Entry: TEntry;
  Line: string;
begin
  for Entry in Entries do
  begin
    Line := '';
    if ShowNodeNumbers then
      Line := IntToStr(Entry.Information.NodeNumber) + ' ';
    PrintStringLine(Line + BlocksText(Entry) + NameText(Entry));
  end;
end;

procedure WriteEntries(Entries: TEntryList);
var
  Entry: TEntry;
begin
  Entries.Sort(@CompareEntries);
  BlockWidth := 1;
  for Entry in Entries do
    RaiseToWidth(BlockWidth, IntToStr(BlocksOf(Entry.Information)));
  if LongFormat then
    WriteLong(Entries)
  else if OnePerLine then
    WriteOnePerLine(Entries)
  else
    WriteColumns(Entries);
end;

procedure ListDirectoryContents(const Path: string; ShowHeader: Boolean);
var
  Names: TStringList;
  Name: string;
  Entries: TEntryList;
  Entry: TEntry;
  Error: LongInt;
  Total: QWord;
begin
  Entries := TEntryList.Create;
  Names := TStringList.Create;
  try
    Error := ListDirectory(Path, Names);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot open directory ''%s''', [Path]));
      ExitStatus := 2;
      Exit;
    end;
    if ShowAll then
    begin
      Names.Add('.');
      Names.Add('..');
    end;

    Total := 0;
    for Name in Names do
    begin
      if (Name[1] = '.') and not (ShowAll or ShowAlmostAll) then
        Continue;
      Entry := NewEntry(Name, JoinPath(Path, Name));
      if Entry = nil then
        Continue;
      Entries.Add(Entry);
      Total := Total + BlocksOf(Entry.Information);
    end;

    if ShowHeader then
      PrintStringLine(Path + ':');
    if LongFormat or ShowSizes then
      PrintStringLine('total ' + IntToStr(Total));
    WriteEntries(Entries);

    if Recursive then
      for Entry in Entries do
        if (Entry.Information.Kind = KindDirectory) and not IsDotEntry(Entry.Name) then
        begin
          PrintString(#10);
          ListDirectoryContents(Entry.Path, True);
        end;
  finally
    Names.Free;
    Entries.Free;
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Index: Integer;
  Operand: string;
  Files: TEntryList;
  Directories: TStringList;
  Entry: TEntry;
  Information: TFileInformation;
  IsDirectoryOperand: Boolean;
  ProgramBase: string;
begin
  SortOrder := SortByName;
  OnePerLine := KernelGetHandleKind(StandardOutputHandle) <> HandleKindConsole;
  ProgramBase := BaseName(string(Argument(0)));
  if ProgramBase = 'dir' then
    OnePerLine := False
  else if ProgramBase = 'vdir' then
    LongFormat := True;
  ExitStatus := 0;
  StartTime := CurrentTime;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('A', 'almost-all', False, OptionAlmostAll),
    CommandOption('d', 'directory', False, OptionDirectory),
    CommandOption('F', 'classify', False, OptionClassify),
    CommandOption('h', 'human-readable', False, OptionHumanReadable),
    CommandOption('i', 'inode', False, OptionNodeNumber),
    CommandOption('l', '', False, OptionLong),
    CommandOption('r', 'reverse', False, OptionReverse),
    CommandOption('R', 'recursive', False, OptionRecursive),
    CommandOption('S', '', False, OptionSortSize),
    CommandOption('t', '', False, OptionSortTime),
    CommandOption('1', '', False, OptionOnePerLine),
    CommandOption('n', 'numeric-uid-gid', False, OptionNumeric),
    CommandOption('s', 'size', False, OptionSize)], Usage);
  while CommandLine.NextOption(Code, Value) do
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

  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['.'];

  { Files first (sorted together), then each directory. }
  Files := TEntryList.Create;
  Directories := TStringList.Create;
  for Operand in CommandLine.Operands do
  begin
    IsDirectoryOperand := (GetFileInformation(PChar(Operand), Information) = ErrorNone) and
      (Information.Kind = KindDirectory);
    if IsDirectoryOperand and not ListDirectoriesThemselves then
      Directories.Add(Operand)
    else
    begin
      Entry := NewEntry(Operand, Operand);
      if Entry <> nil then
        Files.Add(Entry)
      else
        ExitStatus := 2;
    end;
  end;

  WriteEntries(Files);
  for Index := 0 to Directories.Count - 1 do
  begin
    if (Files.Count > 0) or (Index > 0) then
      PrintString(#10);
    ListDirectoryContents(Directories[Index], (CommandLine.OperandCount > 1) or Recursive);
  end;
  Files.Free;
  Directories.Free;
  CommandLine.Free;
  Halt(ExitStatus);
end.
