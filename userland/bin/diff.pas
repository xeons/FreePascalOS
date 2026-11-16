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
  diff - compare files line by line

  diff [OPTION]... FILE1 FILE2

  Finds the smallest set of line changes (Myers' algorithm) that turns
  FILE1 into FILE2 and prints it in the normal format, or as unified (-u)
  or context (-c) hunks. Either FILE may be "-" for standard input; when
  one is a directory, the file of the same name inside it is used; when
  both are, their entries are compared (recursively with -r).

  Exit status: 0 if the inputs are the same, 1 if they differ, 2 on trouble.
}
program diff;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Files,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.CommandLine,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.Paths;

const
  Usage = 'Usage: diff [OPTION]... FILES'#10 +
    'Compare FILES line by line.'#10#10 +
    '  -q, --brief                   report only when files differ'#10 +
    '  -c, -C NUM, --context[=NUM]   output NUM (default 3) lines of copied context'#10 +
    '  -u, -U NUM, --unified[=NUM]   output NUM (default 3) lines of unified context'#10 +
    '  -r, --recursive               recursively compare any subdirectories found'#10 +
    '  -N, --new-file                treat absent files as empty'#10 +
    '  -i, --ignore-case             ignore case differences in file contents'#10 +
    '  -b, --ignore-space-change     ignore changes in the amount of white space'#10 +
    '  -w, --ignore-all-space        ignore all white space'#10 +
    '  -B, --ignore-blank-lines      ignore changes where lines are all blank'#10#10 +
    'FILES are ''FILE1 FILE2'' or ''DIR1 DIR2'' or ''DIR FILE'' or ''FILE DIR''.'#10 +
    'If a FILE is ''-'', read standard input.'#10 +
    'Exit status is 0 if inputs are the same, 1 if different, 2 if trouble.'#10;

  OptionBrief = 1;
  OptionContext = 2;
  OptionContextLines = 3;
  OptionUnified = 4;
  OptionUnifiedLines = 5;
  OptionRecursive = 6;
  OptionNewFile = 7;
  OptionIgnoreCase = 8;
  OptionIgnoreSpaceChange = 9;
  OptionIgnoreAllSpace = 10;
  OptionIgnoreBlankLines = 11;

  StatusSame = 0;
  StatusDifferent = 1;
  StatusTrouble = 2;

  DefaultContext = 3;

type
  TOutputFormat = (FormatNormal, FormatUnified, FormatContext);

  { One input file, read into memory. }
  TSide = class
  private
    FPath: string;
    FLines: TStringList;
    { The lines as compared (after -i, -b, -w), and their hashes. }
    FKeys: array of string;
    FHashes: array of LongWord;
    FLastLineTerminated: Boolean;
    FModificationTime: Int64;
    function GetCount: Integer;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    { Reads the file; False (reported) if it cannot be read. An absent
      file is empty when MayBeAbsent. }
    function Read(MayBeAbsent: Boolean): Boolean;
    function LineTerminated(Index: Integer): Boolean;
    function LineIsBlank(Index: Integer): Boolean;
    { True if line Index here is line OtherIndex of Other, as compared. }
    function SameLine(Index: Integer; Other: TSide; OtherIndex: Integer): Boolean;
    { The line with Prefix before it (and a note if it has no line end). }
    procedure WriteLine(const Prefix: string; Index: Integer);
    { The "--- path<TAB>time" line of unified and context output. }
    procedure WriteHeader(const Marker: string);
    property Path: string read FPath;
    property Count: Integer read GetCount;
  end;

  { A run of changed lines: [AStart, AEnd) in FILE1 becomes
    [BStart, BEnd) in FILE2. }
  TChange = record
    AStart, AEnd: Integer;
    BStart, BEnd: Integer;
  end;

  { The changes that turn one side into the other, and their printing. }
  TDifference = class
  private
    FSideA: TSide;
    FSideB: TSide;
    FChangedA: array of Boolean;
    FChangedB: array of Boolean;
    FChanges: array of TChange;
    procedure MarkChanges(LowA, HighA, LowB, HighB: Integer);
    function ChangeIsBlank(const Change: TChange): Boolean;
    procedure CollectChanges;
    procedure HunkBounds(First, Last: Integer; out AStart, AEnd, BStart, BEnd: Integer);
    function HunkEnd(First: Integer): Integer;
    procedure PrintContextLines(Side: TSide; First, Last, Start, Finish: Integer; IsSideA: Boolean);
  public
    constructor Create(SideA, SideB: TSide);
    function ChangeCount: Integer;
    procedure PrintNormal;
    procedure PrintUnified;
    procedure PrintContext;
  end;

var
  OutputFormat: TOutputFormat;
  ContextLines: Integer;
  Brief: Boolean;
  Recursive: Boolean;
  NewFile: Boolean;
  IgnoreCase: Boolean;
  IgnoreSpaceChange: Boolean;
  IgnoreAllSpace: Boolean;
  IgnoreBlankLines: Boolean;
  { The options as given, repeated before each file pair compared
    inside directories ("diff -ru a/x b/x"). }
  HeaderOptions: string;
  Status: LongInt;

{ --- Reading --------------------------------------------------------- }

function IsBlank(Character: Char): Boolean;
begin
  Result := Character in [' ', #9, #13, #11, #12];
end;

function MakeKey(const Line: string): string;
var
  Character: Char;
  PendingSpace: Boolean;
begin
  if not IgnoreCase and not IgnoreSpaceChange and not IgnoreAllSpace then
    Exit(Line);
  Result := '';
  PendingSpace := False;
  for Character in Line do
  begin
    if IsBlank(Character) and (IgnoreAllSpace or IgnoreSpaceChange) then
    begin
      PendingSpace := IgnoreSpaceChange and not IgnoreAllSpace;
      Continue;
    end;
    if PendingSpace then
    begin
      Result := Result + ' ';
      PendingSpace := False;
    end;
    if IgnoreCase then
      Result := Result + ToLowerCase(Character)
    else
      Result := Result + Character;
  end;
  { Trailing white space is dropped (PendingSpace is not written). }
end;

function HashOf(const Text: string; Terminated: Boolean): LongWord;
var
  Character: Char;
begin
  Result := 2166136261;
  for Character in Text do
    Result := (Result xor Byte(Character)) * 16777619;
  if not Terminated then
    Result := Result xor $5A5A5A5A;
end;

constructor TSide.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  FLines := TStringList.Create;
  FLastLineTerminated := True;
end;

destructor TSide.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

function TSide.GetCount: Integer;
begin
  Result := FLines.Count;
end;

function TSide.LineTerminated(Index: Integer): Boolean;
begin
  Result := (Index < FLines.Count - 1) or FLastLineTerminated;
end;

function TSide.LineIsBlank(Index: Integer): Boolean;
begin
  Result := FKeys[Index] = '';
end;

function TSide.SameLine(Index: Integer; Other: TSide; OtherIndex: Integer): Boolean;
begin
  Result := (FHashes[Index] = Other.FHashes[OtherIndex]) and
    (FKeys[Index] = Other.FKeys[OtherIndex]) and
    (LineTerminated(Index) = Other.LineTerminated(OtherIndex));
end;

function TSide.Read(MayBeAbsent: Boolean): Boolean;
var
  Stream: PInputStream;
  Information: TFileInformation;
  Index: Integer;
begin
  FModificationTime := 0;
  if MayBeAbsent and (FPath <> '-') and not PathExists(PChar(FPath)) then
    FModificationTime := 0
  else
  begin
    if FPath = '-' then
      FModificationTime := CurrentTime
    else if GetFileInformation(PChar(FPath), Information) = ErrorNone then
      FModificationTime := Information.ModificationTime;
    Stream := OpenInput(FPath);
    if Stream = nil then
      Exit(False);
    FLastLineTerminated := ReadLinesInto(Stream, FLines);
    CloseInput(Stream);
  end;
  SetLength(FKeys, FLines.Count);
  SetLength(FHashes, FLines.Count);
  for Index := 0 to FLines.Count - 1 do
  begin
    FKeys[Index] := MakeKey(FLines[Index]);
    FHashes[Index] := HashOf(FKeys[Index], LineTerminated(Index));
  end;
  Result := True;
end;

procedure TSide.WriteLine(const Prefix: string; Index: Integer);
begin
  PrintStringLine(Prefix + FLines[Index]);
  if not LineTerminated(Index) then
    PrintStringLine('\ No newline at end of file');
end;

procedure TSide.WriteHeader(const Marker: string);
var
  DateTime: Sys.Time.TDateTime;
begin
  Sys.Time.DecodeTime(FModificationTime, DateTime);
  PrintString(Format('%s %s'#9'%.4d-%.2d-%.2d %.2d:%.2d:%.2d.000000000 +0000'#10, [Marker, FPath,
    DateTime.Year, DateTime.Month, DateTime.Day, DateTime.Hour, DateTime.Minute, DateTime.Second]));
end;

{ --- Comparing (Myers) ----------------------------------------------- }

constructor TDifference.Create(SideA, SideB: TSide);
begin
  inherited Create;
  FSideA := SideA;
  FSideB := SideB;
  SetLength(FChangedA, SideA.Count);
  SetLength(FChangedB, SideB.Count);
  MarkChanges(0, SideA.Count, 0, SideB.Count);
  CollectChanges;
end;

function TDifference.ChangeCount: Integer;
begin
  Result := Length(FChanges);
end;

{ Marks the lines of [LowA, HighA) and [LowB, HighB) that are not part
  of a longest common subsequence. }
procedure TDifference.MarkChanges(LowA, HighA, LowB, HighB: Integer);
var
  N, M: Integer;
  MaximumD: Integer;
  Offset: Integer;
  V: array of LongInt;
  Trace: array of array of LongInt;
  D, K: Integer;
  X, Y: Integer;
  PreviousK: Integer;
  PreviousX, PreviousY: Integer;
  SnakeStartX: Integer;
  Found: Boolean;
  Index: Integer;
begin
  { Common lines at both ends need no search. }
  while (LowA < HighA) and (LowB < HighB) and FSideA.SameLine(LowA, FSideB, LowB) do
  begin
    Inc(LowA);
    Inc(LowB);
  end;
  while (LowA < HighA) and (LowB < HighB) and FSideA.SameLine(HighA - 1, FSideB, HighB - 1) do
  begin
    Dec(HighA);
    Dec(HighB);
  end;
  N := HighA - LowA;
  M := HighB - LowB;
  if (N = 0) or (M = 0) then
  begin
    for Index := LowA to HighA - 1 do
      FChangedA[Index] := True;
    for Index := LowB to HighB - 1 do
      FChangedB[Index] := True;
    Exit;
  end;

  MaximumD := N + M;
  Offset := MaximumD + 1;
  V := nil;
  SetLength(V, 2 * MaximumD + 3);
  Trace := nil;
  SetLength(Trace, MaximumD + 1);
  Found := False;
  D := 0;
  while (D <= MaximumD) and not Found do
  begin
    K := -D;
    while K <= D do
    begin
      if (K = -D) or ((K <> D) and (V[Offset + K - 1] < V[Offset + K + 1])) then
        X := V[Offset + K + 1]
      else
        X := V[Offset + K - 1] + 1;
      Y := X - K;
      while (X < N) and (Y < M) and FSideA.SameLine(LowA + X, FSideB, LowB + Y) do
      begin
        Inc(X);
        Inc(Y);
      end;
      V[Offset + K] := X;
      if (X >= N) and (Y >= M) then
        Found := True;
      Inc(K, 2);
    end;
    { Keep the diagonals -D..D of this round for the walk back. }
    Trace[D] := Copy(V, Offset - D, 2 * D + 1);
    if not Found then
      Inc(D);
  end;

  { Walk back from (N, M), marking each insertion and deletion. }
  X := N;
  Y := M;
  while D > 0 do
  begin
    K := X - Y;
    if (K = -D) or ((K <> D) and (Trace[D - 1][K - 1 + D - 1] < Trace[D - 1][K + 1 + D - 1])) then
      PreviousK := K + 1
    else
      PreviousK := K - 1;
    PreviousX := Trace[D - 1][PreviousK + D - 1];
    PreviousY := PreviousX - PreviousK;
    { The snake of this round starts just after the edit. }
    if PreviousK = K + 1 then
      SnakeStartX := PreviousX
    else
      SnakeStartX := PreviousX + 1;
    while X > SnakeStartX do
    begin
      Dec(X);
      Dec(Y);
    end;
    if PreviousK = K + 1 then
      FChangedB[LowB + PreviousY] := True
    else
      FChangedA[LowA + PreviousX] := True;
    X := PreviousX;
    Y := PreviousY;
    Dec(D);
  end;
end;

function TDifference.ChangeIsBlank(const Change: TChange): Boolean;
var
  Index: Integer;
begin
  for Index := Change.AStart to Change.AEnd - 1 do
    if not FSideA.LineIsBlank(Index) then
      Exit(False);
  for Index := Change.BStart to Change.BEnd - 1 do
    if not FSideB.LineIsBlank(Index) then
      Exit(False);
  Result := True;
end;

{ Turns the marks into runs of changes. }
procedure TDifference.CollectChanges;
var
  IndexA, IndexB: Integer;
  Change: TChange;
begin
  FChanges := nil;
  IndexA := 0;
  IndexB := 0;
  while (IndexA < FSideA.Count) or (IndexB < FSideB.Count) do
  begin
    if (IndexA < FSideA.Count) and (IndexB < FSideB.Count) and
       not FChangedA[IndexA] and not FChangedB[IndexB] then
    begin
      Inc(IndexA);
      Inc(IndexB);
      Continue;
    end;
    Change.AStart := IndexA;
    Change.BStart := IndexB;
    while (IndexA < FSideA.Count) and FChangedA[IndexA] do
      Inc(IndexA);
    while (IndexB < FSideB.Count) and FChangedB[IndexB] do
      Inc(IndexB);
    Change.AEnd := IndexA;
    Change.BEnd := IndexB;
    if (Change.AEnd = Change.AStart) and (Change.BEnd = Change.BStart) then
    begin
      { Should not happen; step on to stay safe. }
      if IndexA < FSideA.Count then
        Inc(IndexA);
      if IndexB < FSideB.Count then
        Inc(IndexB);
      Continue;
    end;
    if IgnoreBlankLines and ChangeIsBlank(Change) then
      Continue;
    SetLength(FChanges, Length(FChanges) + 1);
    FChanges[High(FChanges)] := Change;
  end;
end;

{ --- Printing -------------------------------------------------------- }

{ Normal and context ranges, 1-based; a single line prints as one
  number, an empty range as the line before it. }
function RangeText(Start, Finish: Integer): string;
begin
  if Finish - Start = 0 then
    Result := IntToStr(Start)
  else if Finish - Start = 1 then
    Result := IntToStr(Start + 1)
  else
    Result := IntToStr(Start + 1) + ',' + IntToStr(Finish);
end;

{ Unified ranges: "start,count", with ",1" left out; an empty range
  names the line before it. }
function UnifiedRangeText(Start, Count: Integer): string;
begin
  if Count = 0 then
    Result := IntToStr(Start)
  else
    Result := IntToStr(Start + 1);
  if Count <> 1 then
    Result := Result + ',' + IntToStr(Count);
end;

procedure TDifference.PrintNormal;
var
  Change: TChange;
  Line: Integer;
begin
  for Change in FChanges do
  begin
    if Change.AEnd = Change.AStart then
      PrintStringLine(IntToStr(Change.AStart) + 'a' + RangeText(Change.BStart, Change.BEnd))
    else if Change.BEnd = Change.BStart then
      PrintStringLine(RangeText(Change.AStart, Change.AEnd) + 'd' + IntToStr(Change.BStart))
    else
      PrintStringLine(RangeText(Change.AStart, Change.AEnd) + 'c' + RangeText(Change.BStart, Change.BEnd));
    for Line := Change.AStart to Change.AEnd - 1 do
      FSideA.WriteLine('< ', Line);
    if (Change.AEnd > Change.AStart) and (Change.BEnd > Change.BStart) then
      PrintStringLine('---');
    for Line := Change.BStart to Change.BEnd - 1 do
      FSideB.WriteLine('> ', Line);
  end;
end;

{ The changes First..Last form one hunk with its surrounding context. }
procedure TDifference.HunkBounds(First, Last: Integer; out AStart, AEnd, BStart, BEnd: Integer);
begin
  AStart := FChanges[First].AStart - ContextLines;
  if AStart < 0 then
    AStart := 0;
  BStart := FChanges[First].BStart - (FChanges[First].AStart - AStart);
  AEnd := FChanges[Last].AEnd + ContextLines;
  if AEnd > FSideA.Count then
    AEnd := FSideA.Count;
  BEnd := FChanges[Last].BEnd + (AEnd - FChanges[Last].AEnd);
end;

function TDifference.HunkEnd(First: Integer): Integer;
begin
  Result := First;
  while (Result + 1 < ChangeCount) and
        (FChanges[Result + 1].AStart - FChanges[Result].AEnd <= 2 * ContextLines) do
    Inc(Result);
end;

procedure TDifference.PrintUnified;
var
  First, Last: Integer;
  AStart, AEnd, BStart, BEnd: Integer;
  Index: Integer;
  LineA: Integer;
  Line: Integer;
begin
  FSideA.WriteHeader('---');
  FSideB.WriteHeader('+++');
  First := 0;
  while First < ChangeCount do
  begin
    Last := HunkEnd(First);
    HunkBounds(First, Last, AStart, AEnd, BStart, BEnd);
    PrintStringLine('@@ -' + UnifiedRangeText(AStart, AEnd - AStart) + ' +' +
      UnifiedRangeText(BStart, BEnd - BStart) + ' @@');
    LineA := AStart;
    for Index := First to Last do
    begin
      while LineA < FChanges[Index].AStart do
      begin
        FSideA.WriteLine(' ', LineA);
        Inc(LineA);
      end;
      for Line := FChanges[Index].AStart to FChanges[Index].AEnd - 1 do
        FSideA.WriteLine('-', Line);
      for Line := FChanges[Index].BStart to FChanges[Index].BEnd - 1 do
        FSideB.WriteLine('+', Line);
      LineA := FChanges[Index].AEnd;
    end;
    while LineA < AEnd do
    begin
      FSideA.WriteLine(' ', LineA);
      Inc(LineA);
    end;
    First := Last + 1;
  end;
end;

{ One half of a context hunk: the lines Start..Finish - 1 of Side with
  the changes First..Last marked; a change found on both sides is "!",
  one on this side only "-" (side A) or "+" (side B). }
procedure TDifference.PrintContextLines(Side: TSide; First, Last, Start, Finish: Integer;
  IsSideA: Boolean);
var
  Index: Integer;
  Line: Integer;
  Cursor: Integer;
  ChangeStart, ChangeEnd: Integer;
  OtherIsEmpty: Boolean;
  Marker: string;
begin
  Cursor := Start;
  for Index := First to Last do
  begin
    if IsSideA then
    begin
      ChangeStart := FChanges[Index].AStart;
      ChangeEnd := FChanges[Index].AEnd;
      OtherIsEmpty := FChanges[Index].BEnd = FChanges[Index].BStart;
    end
    else
    begin
      ChangeStart := FChanges[Index].BStart;
      ChangeEnd := FChanges[Index].BEnd;
      OtherIsEmpty := FChanges[Index].AEnd = FChanges[Index].AStart;
    end;
    while Cursor < ChangeStart do
    begin
      Side.WriteLine('  ', Cursor);
      Inc(Cursor);
    end;
    if not OtherIsEmpty then
      Marker := '! '
    else if IsSideA then
      Marker := '- '
    else
      Marker := '+ ';
    for Line := ChangeStart to ChangeEnd - 1 do
      Side.WriteLine(Marker, Line);
    Cursor := ChangeEnd;
  end;
  while Cursor < Finish do
  begin
    Side.WriteLine('  ', Cursor);
    Inc(Cursor);
  end;
end;

procedure TDifference.PrintContext;
var
  First, Last: Integer;
  AStart, AEnd, BStart, BEnd: Integer;
  Index: Integer;
  HasDeletions, HasInsertions: Boolean;
begin
  FSideA.WriteHeader('***');
  FSideB.WriteHeader('---');
  First := 0;
  while First < ChangeCount do
  begin
    Last := HunkEnd(First);
    HunkBounds(First, Last, AStart, AEnd, BStart, BEnd);
    HasDeletions := False;
    HasInsertions := False;
    for Index := First to Last do
    begin
      if FChanges[Index].AEnd > FChanges[Index].AStart then
        HasDeletions := True;
      if FChanges[Index].BEnd > FChanges[Index].BStart then
        HasInsertions := True;
    end;
    PrintStringLine('***************');
    PrintStringLine('*** ' + RangeText(AStart, AEnd) + ' ****');
    if HasDeletions then
      PrintContextLines(FSideA, First, Last, AStart, AEnd, True);
    PrintStringLine('--- ' + RangeText(BStart, BEnd) + ' ----');
    if HasInsertions then
      PrintContextLines(FSideB, First, Last, BStart, BEnd, False);
    First := Last + 1;
  end;
end;

{ --- Files and directories ------------------------------------------- }

procedure NoteStatus(Value: LongInt);
begin
  if Value > Status then
    Status := Value;
end;

procedure PrintDifference(Difference: TDifference; const PathA, PathB: string; InsideDirectories: Boolean);
begin
  if Brief then
  begin
    PrintString(Format('Files %s and %s differ'#10, [PathA, PathB]));
    Exit;
  end;
  if InsideDirectories then
    PrintString(Format('diff%s %s %s'#10, [HeaderOptions, PathA, PathB]));
  case OutputFormat of
    FormatUnified: Difference.PrintUnified;
    FormatContext: Difference.PrintContext;
  else
    Difference.PrintNormal;
  end;
end;

{ Compares two files; InsideDirectories prints the "diff ..." line
  before a difference. }
procedure CompareFiles(const PathA, PathB: string; InsideDirectories: Boolean);
var
  SideA, SideB: TSide;
  Difference: TDifference;
begin
  SideA := TSide.Create(PathA);
  SideB := TSide.Create(PathB);
  try
    if not SideA.Read(NewFile and InsideDirectories) or not SideB.Read(NewFile and InsideDirectories) then
    begin
      NoteStatus(StatusTrouble);
      Exit;
    end;
    Difference := TDifference.Create(SideA, SideB);
    try
      if Difference.ChangeCount > 0 then
      begin
        NoteStatus(StatusDifferent);
        PrintDifference(Difference, PathA, PathB, InsideDirectories);
      end;
    finally
      Difference.Free;
    end;
  finally
    SideA.Free;
    SideB.Free;
  end;
end;

function KindOf(const Path: string; out Kind: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  Result := GetFileInformation(PChar(Path), Information) = ErrorNone;
  if Result then
    Kind := Information.Kind
  else
    Kind := 0;
end;

function KindName(Kind: LongWord): string;
begin
  if Kind = KindDirectory then
    Result := 'directory'
  else
    Result := 'regular file';
end;

{ The names in Path, in byte order. }
function SortedNames(const Path: string): TStringList;
begin
  Result := TStringList.Create;
  ListDirectory(Path, Result);
  Result.UseLocale := False;
  Result.CaseSensitive := True;
  Result.Sort;
end;

procedure CompareDirectories(const PathA, PathB: string); forward;

{ One name of two directories being compared; Order tells which of them
  has it (below 0: only PathA, above 0: only PathB, 0: both). }
procedure CompareEntry(const PathA, PathB, Name: string; Order: Integer);
var
  ChildA, ChildB: string;
  KindA, KindB: LongWord;
  HaveA, HaveB: Boolean;
begin
  ChildA := JoinPath(PathA, Name);
  ChildB := JoinPath(PathB, Name);
  HaveA := KindOf(ChildA, KindA);
  HaveB := KindOf(ChildB, KindB);
  if (Order <> 0) and not (NewFile and ((HaveA and (KindA <> KindDirectory)) or
     (HaveB and (KindB <> KindDirectory)))) then
  begin
    if Order < 0 then
      PrintString(Format('Only in %s: %s'#10, [PathA, Name]))
    else
      PrintString(Format('Only in %s: %s'#10, [PathB, Name]));
    NoteStatus(StatusDifferent);
  end
  else if (Order = 0) and (KindA = KindDirectory) and (KindB = KindDirectory) then
  begin
    if Recursive then
      CompareDirectories(ChildA, ChildB)
    else
      PrintString(Format('Common subdirectories: %s and %s'#10, [ChildA, ChildB]));
  end
  else if (Order = 0) and ((KindA = KindDirectory) <> (KindB = KindDirectory)) then
  begin
    PrintString(Format('File %s is a %s while file %s is a %s'#10, [ChildA, KindName(KindA), ChildB,
      KindName(KindB)]));
    NoteStatus(StatusDifferent);
  end
  else
    CompareFiles(ChildA, ChildB, True);
end;

procedure CompareDirectories(const PathA, PathB: string);
var
  NamesA, NamesB: TStringList;
  IndexA, IndexB: Integer;
  Order: Integer;
begin
  NamesA := SortedNames(PathA);
  NamesB := SortedNames(PathB);
  try
    IndexA := 0;
    IndexB := 0;
    while (IndexA < NamesA.Count) or (IndexB < NamesB.Count) do
    begin
      if IndexA >= NamesA.Count then
        Order := 1
      else if IndexB >= NamesB.Count then
        Order := -1
      else
        Order := CompareStr(NamesA[IndexA], NamesB[IndexB]);
      if Order < 0 then
        CompareEntry(PathA, PathB, NamesA[IndexA], Order)
      else
        CompareEntry(PathA, PathB, NamesB[IndexB], Order);
      if Order <= 0 then
        Inc(IndexA);
      if Order >= 0 then
        Inc(IndexB);
    end;
  finally
    NamesA.Free;
    NamesB.Free;
  end;
end;

procedure SetContext(const Value: string);
var
  Number: Int64;
begin
  if not ParseDecimal(Value, Number) or (Number < 0) then
    FailWithUsageHint(Format('invalid context length ''%s''', [Value]));
  ContextLines := Integer(Number);
end;

{ Every argument but the two operands, each after a space. }
function CollectHeaderOptions(const Operands: TStringArray): string;
var
  Index: Integer;
  OperandIndex: Integer;
  Text: string;
begin
  Result := '';
  OperandIndex := 0;
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Text := Argument(Index);
    if (OperandIndex < Length(Operands)) and (Text = Operands[OperandIndex]) then
    begin
      Inc(OperandIndex);
      Continue;
    end;
    Result := Result + ' ' + Text;
  end;
end;

procedure FailWithTrouble(const Message: string);
begin
  Report(Message);
  Report('Try ''diff --help'' for more information.');
  Halt(StatusTrouble);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  PathA, PathB: string;
  IsDirectoryA, IsDirectoryB: Boolean;
begin
  OutputFormat := FormatNormal;
  ContextLines := DefaultContext;
  Status := StatusSame;
  CommandLine := TCommandLine.Create([
    CommandOption('q', 'brief', False, OptionBrief),
    CommandOption('c', '', False, OptionContext),
    CommandOption('C', 'context', True, OptionContextLines),
    CommandOption('u', '', False, OptionUnified),
    CommandOption('U', 'unified', True, OptionUnifiedLines),
    CommandOption('r', 'recursive', False, OptionRecursive),
    CommandOption('N', 'new-file', False, OptionNewFile),
    CommandOption('i', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('b', 'ignore-space-change', False, OptionIgnoreSpaceChange),
    CommandOption('w', 'ignore-all-space', False, OptionIgnoreAllSpace),
    CommandOption('B', 'ignore-blank-lines', False, OptionIgnoreBlankLines)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBrief: Brief := True;
      OptionContext: OutputFormat := FormatContext;
      OptionContextLines:
        begin
          OutputFormat := FormatContext;
          SetContext(Value);
        end;
      OptionUnified: OutputFormat := FormatUnified;
      OptionUnifiedLines:
        begin
          OutputFormat := FormatUnified;
          SetContext(Value);
        end;
      OptionRecursive: Recursive := True;
      OptionNewFile: NewFile := True;
      OptionIgnoreCase: IgnoreCase := True;
      OptionIgnoreSpaceChange: IgnoreSpaceChange := True;
      OptionIgnoreAllSpace: IgnoreAllSpace := True;
      OptionIgnoreBlankLines: IgnoreBlankLines := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithTrouble('missing operand after ''diff''');
  if CommandLine.OperandCount = 1 then
    FailWithTrouble(Format('missing operand after ''%s''', [CommandLine.Operands[0]]));
  if CommandLine.OperandCount > 2 then
    FailWithTrouble(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
  HeaderOptions := CollectHeaderOptions(CommandLine.Operands);
  PathA := CommandLine.Operands[0];
  PathB := CommandLine.Operands[1];
  IsDirectoryA := (PathA <> '-') and IsDirectory(PChar(PathA));
  IsDirectoryB := (PathB <> '-') and IsDirectory(PChar(PathB));
  if IsDirectoryA and IsDirectoryB then
    CompareDirectories(PathA, PathB)
  else
  begin
    if IsDirectoryA then
      PathA := JoinPath(PathA, BaseName(PathB))
    else if IsDirectoryB then
      PathB := JoinPath(PathB, BaseName(PathA));
    CompareFiles(PathA, PathB, False);
  end;
  CommandLine.Free;
  Halt(Status);
end.
