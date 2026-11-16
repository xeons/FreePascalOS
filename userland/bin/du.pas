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

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.Directories,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.Paths,
  Util.Sizes;

const
  Usage = 'Usage: du [OPTION]... [FILE]...'#10 +
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

var
  ShowAll: Boolean;
  InBytes: Boolean;
  ApparentSizes: Boolean;
  Human: Boolean;
  MaximumDepth: Int64;   { -1 = unlimited }
  SeparateDirectories: Boolean;
  ExitStatus: LongInt;
  { The nodes with several links counted so far. }
  SeenNodes: array of QWord;

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
  Node: QWord;
begin
  if (Information.LinkCount <= 1) or (Information.Kind = KindDirectory) then
    Exit(True);
  for Node in SeenNodes do
    if Node = Information.NodeNumber then
      Exit(False);
  SetLength(SeenNodes, Length(SeenNodes) + 1);
  SeenNodes[High(SeenNodes)] := Information.NodeNumber;
  Result := True;
end;

procedure PrintSize(Bytes: QWord; const Path: string);
var
  SizeText: string;
begin
  if Human then
    SizeText := FormatHumanSize(Bytes)
  else if InBytes then
    SizeText := IntToStr(Bytes)
  else
    SizeText := IntToStr((Bytes + 1023) div 1024);
  PrintStringLine(SizeText + #9 + Path);
end;

function DepthIsShown(Depth: Integer): Boolean;
begin
  Result := (MaximumDepth < 0) or (Depth <= MaximumDepth);
end;

{ Returns the total size below Path (counted for its parent). }
function Measure(const Path: string; Depth: Integer): QWord;
var
  Information: TFileInformation;
  Names: TStringList;
  Name: string;
  ChildPath: string;
  ChildSize: QWord;
  OwnTotal: QWord;
  Error: LongInt;
begin
  Result := 0;
  Error := GetLinkInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot access ''%s''', [Path]));
    ExitStatus := 1;
    Exit;
  end;
  if not FirstSighting(Information) then
    Exit;
  if Information.Kind <> KindDirectory then
  begin
    Result := SizeOfFile(Information);
    if (Depth = 0) or (ShowAll and DepthIsShown(Depth)) then
      PrintSize(Result, Path);
    Exit;
  end;

  OwnTotal := SizeOfFile(Information);
  Result := OwnTotal;
  Names := TStringList.Create;
  try
    Error := ListDirectory(Path, Names);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot read directory ''%s''', [Path]));
      ExitStatus := 1;
    end;
    for Name in Names do
    begin
      ChildPath := JoinPath(Path, Name);
      ChildSize := Measure(ChildPath, Depth + 1);
      if GetLinkInformation(PChar(ChildPath), Information) = ErrorNone then
      begin
        if (Information.Kind <> KindDirectory) or not SeparateDirectories then
          OwnTotal := OwnTotal + ChildSize;
      end;
      Result := Result + ChildSize;
    end;
  finally
    Names.Free;
  end;
  if DepthIsShown(Depth) then
    PrintSize(OwnTotal, Path);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  ShowTotal: Boolean;
  Operand: string;
  GrandTotal: QWord;
begin
  MaximumDepth := -1;
  ShowTotal := False;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, OptionAll),
    CommandOption(#0, 'apparent-size', False, OptionApparent),
    CommandOption('b', 'bytes', False, OptionBytes),
    CommandOption('c', 'total', False, OptionTotal),
    CommandOption('d', 'max-depth', True, OptionDepth),
    CommandOption('h', 'human-readable', False, OptionHuman),
    CommandOption('k', '', False, OptionKilobytes),
    CommandOption('s', 'summarize', False, OptionSummarize),
    CommandOption('S', 'separate-dirs', False, OptionSeparate)], Usage);
  while CommandLine.NextOption(Code, Value) do
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
        if not ParseDecimal(Value, MaximumDepth) or (MaximumDepth < 0) then
          Fail(1, Format('invalid maximum depth ''%s''', [Value]));
      OptionHuman: Human := True;
      OptionKilobytes: InBytes := False;
      OptionSummarize: MaximumDepth := 0;
      OptionSeparate: SeparateDirectories := True;
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['.'];
  ExitStatus := 0;
  GrandTotal := 0;
  for Operand in CommandLine.Operands do
    GrandTotal := GrandTotal + Measure(Operand, 0);
  if ShowTotal then
    PrintSize(GrandTotal, 'total');
  Halt(ExitStatus);
end.
