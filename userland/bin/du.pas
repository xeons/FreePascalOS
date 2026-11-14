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
  du - estimate file space usage

  du [-abchksSx] [-d N] [--apparent-size] [FILE]...

  Sizes are the space files take on their volume (whole blocks or
  clusters), in 1 KiB units by default; --apparent-size and -b count
  file sizes instead. A file with several hard links is counted once.
}
program du;

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
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.Sizes;

const
  Usage: PChar = 'Usage: du [OPTION]... [FILE]...'#10 +
    'Summarize device usage of the set of FILEs, recursively for directories.'#10#10 +
    '  -a, --all             write counts for all files, not just directories'#10 +
    '      --apparent-size   print apparent sizes rather than device usage'#10 +
    '  -b, --bytes           equivalent to --apparent-size --block-size=1'#10 +
    '  -c, --total           produce a grand total'#10 +
    '  -d, --max-depth=N     print the total for a directory (or file, with --all)'#10 +
    '                          only if it is N or fewer levels below the command'#10 +
    '                          line argument'#10 +
    '  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)'#10 +
    '  -k                    like --block-size=1K'#10 +
    '  -s, --summarize       display only a total for each argument'#10 +
    '  -S, --separate-dirs   for directories do not include size of subdirectories'#10;

  OptionAll = 1;
  OptionBytes = 2;
  OptionTotal = 3;
  OptionDepth = 4;
  OptionHuman = 5;
  OptionKilobytes = 6;
  OptionSummarize = 7;
  OptionSeparate = 8;
  OptionApparent = 9;
  MaximumSeenNodes = 4096;

var
  ShowAll: Boolean;
  InBytes: Boolean;
  ApparentSizes: Boolean;
  Human: Boolean;
  MaximumDepth: Int64;   { -1 = unlimited }
  SeparateDirectories: Boolean;
  ExitStatus: LongInt;
  SeenNodes: array[0..MaximumSeenNodes - 1] of QWord;
  SeenCount: Integer;

function SizeOfFile(const Information: TFileInformation): QWord;
begin
  if ApparentSizes then
    Result := Information.SizeInBytes
  else
    Result := Information.AllocatedBytes;
end;

{ True the first time a node with several links is seen. }
function FirstSighting(const Information: TFileInformation): Boolean;
var
  Index: Integer;
begin
  if (Information.LinkCount <= 1) or (Information.Kind = KindDirectory) then
    Exit(True);
  for Index := 0 to SeenCount - 1 do
    if SeenNodes[Index] = Information.NodeNumber then
      Exit(False);
  if SeenCount < MaximumSeenNodes then
  begin
    SeenNodes[SeenCount] := Information.NodeNumber;
    Inc(SeenCount);
  end;
  Result := True;
end;

procedure PrintSize(Bytes: QWord; Path: PChar);
var
  Buffer: array[0..31] of Char;
begin
  if Human then
    WriteText(StandardOutput, FormatHumanSize(Bytes, @Buffer[0]))
  else if InBytes then
    WriteUnsigned(StandardOutput, Bytes)
  else
    WriteUnsigned(StandardOutput, (Bytes + 1023) div 1024);
  WriteCharacter(StandardOutput, #9);
  WriteLine(StandardOutput, Path);
end;

{ Returns the total size below Path (counted for its parent). }
function Measure(Path: PChar; Depth: Integer): QWord;
var
  Information: TFileInformation;
  Names: TLineList;
  Index: Integer;
  ChildPath: PChar;
  ChildSize: QWord;
  OwnTotal: QWord;
  Error: LongInt;
begin
  Result := 0;
  Error := GetLinkInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot access ''%s''', [ArgumentText(Path)]);
    ExitStatus := 1;
    Exit;
  end;
  if not FirstSighting(Information) then
    Exit;
  if Information.Kind <> KindDirectory then
  begin
    Result := SizeOfFile(Information);
    if (Depth = 0) or (ShowAll and ((MaximumDepth < 0) or (Depth <= MaximumDepth))) then
      PrintSize(Result, Path);
    Exit;
  end;

  OwnTotal := SizeOfFile(Information);
  Result := OwnTotal;
  BeginLineList(Names);
  Error := ListDirectory(Path, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot read directory ''%s''', [ArgumentText(Path)]);
    ExitStatus := 1;
  end;
  for Index := 0 to Names.Count - 1 do
  begin
    ChildPath := JoinPath(Path, Names.Items[Index]);
    ChildSize := Measure(ChildPath, Depth + 1);
    if GetLinkInformation(ChildPath, Information) = ErrorNone then
    begin
      if (Information.Kind <> KindDirectory) or not SeparateDirectories then
        OwnTotal := OwnTotal + ChildSize;
    end;
    Result := Result + ChildSize;
    FreeMemory(ChildPath);
  end;
  FreeLineList(Names);
  if (MaximumDepth < 0) or (Depth <= MaximumDepth) then
    PrintSize(OwnTotal, Path);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ShowTotal: Boolean;
  Index: Integer;
  GrandTotal: QWord;
begin
  MaximumDepth := -1;
  ShowTotal := False;
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, OptionAll),
    OptionDefinition(#0, 'apparent-size', False, OptionApparent),
    OptionDefinition('b', 'bytes', False, OptionBytes),
    OptionDefinition('c', 'total', False, OptionTotal),
    OptionDefinition('d', 'max-depth', True, OptionDepth),
    OptionDefinition('h', 'human-readable', False, OptionHuman),
    OptionDefinition('k', nil, False, OptionKilobytes),
    OptionDefinition('s', 'summarize', False, OptionSummarize),
    OptionDefinition('S', 'separate-dirs', False, OptionSeparate)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAll: ShowAll := True;
      OptionBytes:
        begin
          InBytes := True;
          ApparentSizes := True;
        end;
      OptionApparent: ApparentSizes := True;
      OptionTotal: ShowTotal := True;
      OptionDepth:
        if not ParseInteger(Value, MaximumDepth) or (MaximumDepth < 0) then
          Fail(1, 'invalid maximum depth ''%s''', [ArgumentText(Value)]);
      OptionHuman: Human := True;
      OptionKilobytes: InBytes := False;
      OptionSummarize: MaximumDepth := 0;
      OptionSeparate: SeparateDirectories := True;
    end;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '.';
    Parser.OperandCount := 1;
  end;
  ExitStatus := 0;
  GrandTotal := 0;
  for Index := 0 to Parser.OperandCount - 1 do
    GrandTotal := GrandTotal + Measure(Parser.Operands[Index], 0);
  if ShowTotal then
    PrintSize(GrandTotal, 'total');
  Halt(ExitStatus);
end.
