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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Paths,
  Util.Sorting;

const
  Usage: PChar = 'Usage: diff [OPTION]... FILES'#10 +
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
  TSide = record
    Path: PChar;
    Lines: TLineList;
    Keys: PPChar;          { lines as compared (after -i, -b, -w) }
    Hashes: PLongWord;
    ModificationTime: Int64;
    Exists: Boolean;
  end;

  { A run of changed lines: [AStart, AEnd) in FILE1 becomes
    [BStart, BEnd) in FILE2. }
  TChange = record
    AStart, AEnd: Integer;
    BStart, BEnd: Integer;
  end;
  PChange = ^TChange;

  PLongIntArray = ^LongInt;

var
  Format: TOutputFormat;
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
  HeaderOptions: TTextBuilder;
  Status: LongInt;

{ --- Reading --------------------------------------------------------- }

function IsBlank(Character: Char): Boolean;
begin
  Result := (Character = ' ') or (Character = #9) or (Character = #13) or (Character = #11) or (Character = #12);
end;

function MakeKey(Line: PChar): PChar;
var
  Builder: TTextBuilder;
  Position: PChar;
  PendingSpace: Boolean;
begin
  if not IgnoreCase and not IgnoreSpaceChange and not IgnoreAllSpace then
    Exit(Line);
  BeginText(Builder);
  Position := Line;
  PendingSpace := False;
  while Position^ <> #0 do
  begin
    if IsBlank(Position^) and (IgnoreAllSpace or IgnoreSpaceChange) then
    begin
      PendingSpace := IgnoreSpaceChange and not IgnoreAllSpace;
      Inc(Position);
      Continue;
    end;
    if PendingSpace then
    begin
      AppendCharacter(Builder, ' ');
      PendingSpace := False;
    end;
    if IgnoreCase then
      AppendCharacter(Builder, ToLowerCase(Position^))
    else
      AppendCharacter(Builder, Position^);
    Inc(Position);
  end;
  { Trailing white space is dropped (PendingSpace is not written). }
  Result := FinishText(Builder);
end;

function HashOf(Text: PChar; Terminated: Boolean): LongWord;
begin
  Result := 2166136261;
  while Text^ <> #0 do
  begin
    Result := (Result xor Byte(Text^)) * 16777619;
    Inc(Text);
  end;
  if not Terminated then
    Result := Result xor $5A5A5A5A;
end;

function LineTerminated(const Side: TSide; Index: Integer): Boolean;
begin
  Result := (Index < Side.Lines.Count - 1) or Side.Lines.LastLineTerminated;
end;

function ReadSide(Path: PChar; MayBeAbsent: Boolean; out Side: TSide): Boolean;
var
  Stream: PInputStream;
  Information: TFileInformation;
  Index: Integer;
begin
  ZeroMemory(@Side, SizeOf(Side));
  Side.Path := Path;
  BeginLineList(Side.Lines);
  Side.Lines.LastLineTerminated := True;
  Side.Exists := True;
  if MayBeAbsent and not TextIsEqual(Path, '-') and not PathExists(Path) then
  begin
    Side.Exists := False;
    Side.ModificationTime := 0;
  end
  else
  begin
    if TextIsEqual(Path, '-') then
      Side.ModificationTime := CurrentTime
    else if GetFileInformation(Path, Information) = ErrorNone then
      Side.ModificationTime := Information.ModificationTime;
    Stream := OpenInput(Path);
    if Stream = nil then
      Exit(False);
    ReadAllLines(Stream, Side.Lines);
    CloseInput(Stream);
  end;
  Side.Keys := PPChar(AllocateMemory(QWord(Side.Lines.Count + 1) * SizeOf(PChar)));
  Side.Hashes := PLongWord(AllocateMemory(QWord(Side.Lines.Count + 1) * SizeOf(LongWord)));
  for Index := 0 to Side.Lines.Count - 1 do
  begin
    Side.Keys[Index] := MakeKey(Side.Lines.Items[Index]);
    Side.Hashes[Index] := HashOf(Side.Keys[Index], LineTerminated(Side, Index));
  end;
  Result := True;
end;

procedure FreeSide(var Side: TSide);
var
  Index: Integer;
begin
  for Index := 0 to Side.Lines.Count - 1 do
    if Side.Keys[Index] <> Side.Lines.Items[Index] then
      FreeMemory(Side.Keys[Index]);
  FreeMemory(Side.Keys);
  FreeMemory(Side.Hashes);
  FreeLineList(Side.Lines);
end;

{ --- Comparing (Myers) ----------------------------------------------- }

var
  SideA: TSide;
  SideB: TSide;
  ChangedA: PBoolean;
  ChangedB: PBoolean;
  Changes: PChange;
  ChangeCount: Integer;

function LinesEqual(IndexA, IndexB: Integer): Boolean;
begin
  Result := (SideA.Hashes[IndexA] = SideB.Hashes[IndexB]) and
    TextIsEqual(SideA.Keys[IndexA], SideB.Keys[IndexB]) and
    (LineTerminated(SideA, IndexA) = LineTerminated(SideB, IndexB));
end;

{ Marks the lines of [LowA, HighA) and [LowB, HighB) that are not part
  of a longest common subsequence. }
procedure MarkChanges(LowA, HighA, LowB, HighB: Integer);
var
  N, M: Integer;
  MaximumD: Integer;
  Offset: Integer;
  V: PLongIntArray;
  Trace: ^PLongIntArray;
  D, K: Integer;
  X, Y: Integer;
  PreviousK: Integer;
  PreviousX, PreviousY: Integer;
  Previous: PLongIntArray;
  SnakeStartX: Integer;
  Found: Boolean;
  Index: Integer;
begin
  { Common lines at both ends need no search. }
  while (LowA < HighA) and (LowB < HighB) and LinesEqual(LowA, LowB) do
  begin
    Inc(LowA);
    Inc(LowB);
  end;
  while (LowA < HighA) and (LowB < HighB) and LinesEqual(HighA - 1, HighB - 1) do
  begin
    Dec(HighA);
    Dec(HighB);
  end;
  N := HighA - LowA;
  M := HighB - LowB;
  if (N = 0) or (M = 0) then
  begin
    for Index := LowA to HighA - 1 do
      ChangedA[Index] := True;
    for Index := LowB to HighB - 1 do
      ChangedB[Index] := True;
    Exit;
  end;

  MaximumD := N + M;
  Offset := MaximumD + 1;
  V := PLongIntArray(AllocateZeroedMemory(QWord(2 * MaximumD + 3) * SizeOf(LongInt)));
  Trace := AllocateZeroedMemory(QWord(MaximumD + 1) * SizeOf(PLongIntArray));
  V[Offset + 1] := 0;
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
      while (X < N) and (Y < M) and LinesEqual(LowA + X, LowB + Y) do
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
    Trace[D] := PLongIntArray(AllocateMemory(QWord(2 * D + 1) * SizeOf(LongInt)));
    for Index := -D to D do
      Trace[D][Index + D] := V[Offset + Index];
    if not Found then
      Inc(D);
  end;

  { Walk back from (N, M), marking each insertion and deletion. }
  X := N;
  Y := M;
  while D > 0 do
  begin
    K := X - Y;
    Previous := Trace[D - 1];
    if (K = -D) or ((K <> D) and (Previous[K - 1 + D - 1] < Previous[K + 1 + D - 1])) then
      PreviousK := K + 1
    else
      PreviousK := K - 1;
    PreviousX := Previous[PreviousK + D - 1];
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
      ChangedB[LowB + PreviousY] := True
    else
      ChangedA[LowA + PreviousX] := True;
    X := PreviousX;
    Y := PreviousY;
    Dec(D);
  end;

  for Index := 0 to MaximumD do
    if Trace[Index] <> nil then
      FreeMemory(Trace[Index]);
  FreeMemory(Trace);
  FreeMemory(V);
end;

function ChangeIsBlank(const Change: TChange): Boolean;
var
  Index: Integer;
begin
  for Index := Change.AStart to Change.AEnd - 1 do
    if SideA.Keys[Index]^ <> #0 then
      Exit(False);
  for Index := Change.BStart to Change.BEnd - 1 do
    if SideB.Keys[Index]^ <> #0 then
      Exit(False);
  Result := True;
end;

{ Turns the marks into runs of changes. }
procedure CollectChanges;
var
  IndexA, IndexB: Integer;
  Change: TChange;
begin
  Changes := PChange(AllocateMemory(QWord(SideA.Lines.Count + SideB.Lines.Count + 1) * SizeOf(TChange)));
  ChangeCount := 0;
  IndexA := 0;
  IndexB := 0;
  while (IndexA < SideA.Lines.Count) or (IndexB < SideB.Lines.Count) do
  begin
    if (IndexA < SideA.Lines.Count) and (IndexB < SideB.Lines.Count) and
       not ChangedA[IndexA] and not ChangedB[IndexB] then
    begin
      Inc(IndexA);
      Inc(IndexB);
      Continue;
    end;
    Change.AStart := IndexA;
    Change.BStart := IndexB;
    while (IndexA < SideA.Lines.Count) and ChangedA[IndexA] do
      Inc(IndexA);
    while (IndexB < SideB.Lines.Count) and ChangedB[IndexB] do
      Inc(IndexB);
    Change.AEnd := IndexA;
    Change.BEnd := IndexB;
    if (Change.AEnd = Change.AStart) and (Change.BEnd = Change.BStart) then
    begin
      { Should not happen; step on to stay safe. }
      if IndexA < SideA.Lines.Count then
        Inc(IndexA);
      if IndexB < SideB.Lines.Count then
        Inc(IndexB);
      Continue;
    end;
    if IgnoreBlankLines and ChangeIsBlank(Change) then
      Continue;
    Changes[ChangeCount] := Change;
    Inc(ChangeCount);
  end;
end;

{ --- Printing -------------------------------------------------------- }

procedure WriteRange(Start, Finish: Integer);
begin
  { 1-based; a single line prints as one number. }
  if Finish - Start <= 1 then
  begin
    if Finish - Start = 1 then
      WriteDecimal(StandardOutput, Start + 1)
    else
      WriteDecimal(StandardOutput, Start);
  end
  else
  begin
    WriteDecimal(StandardOutput, Start + 1);
    WriteCharacter(StandardOutput, ',');
    WriteDecimal(StandardOutput, Finish);
  end;
end;

procedure WriteLineWithPrefix(Prefix: PChar; const Side: TSide; Index: Integer);
begin
  WriteText(StandardOutput, Prefix);
  WriteLine(StandardOutput, Side.Lines.Items[Index]);
  if not LineTerminated(Side, Index) then
    WriteLine(StandardOutput, '\ No newline at end of file');
end;

procedure PrintNormal;
var
  Index: Integer;
  Line: Integer;
  Change: PChange;
begin
  for Index := 0 to ChangeCount - 1 do
  begin
    Change := @Changes[Index];
    if Change^.AEnd = Change^.AStart then
    begin
      WriteDecimal(StandardOutput, Change^.AStart);
      WriteCharacter(StandardOutput, 'a');
      WriteRange(Change^.BStart, Change^.BEnd);
    end
    else if Change^.BEnd = Change^.BStart then
    begin
      WriteRange(Change^.AStart, Change^.AEnd);
      WriteCharacter(StandardOutput, 'd');
      WriteDecimal(StandardOutput, Change^.BStart);
    end
    else
    begin
      WriteRange(Change^.AStart, Change^.AEnd);
      WriteCharacter(StandardOutput, 'c');
      WriteRange(Change^.BStart, Change^.BEnd);
    end;
    WriteCharacter(StandardOutput, #10);
    for Line := Change^.AStart to Change^.AEnd - 1 do
      WriteLineWithPrefix('< ', SideA, Line);
    if (Change^.AEnd > Change^.AStart) and (Change^.BEnd > Change^.BStart) then
      WriteLine(StandardOutput, '---');
    for Line := Change^.BStart to Change^.BEnd - 1 do
      WriteLineWithPrefix('> ', SideB, Line);
  end;
end;

procedure WriteFileHeader(Marker: PChar; const Side: TSide);
var
  DateTime: TDateTime;
begin
  DecodeTime(Side.ModificationTime, DateTime);
  WriteFormatted(StandardOutput, '%s %s'#9'%04d-%02d-%02d %02d:%02d:%02d.000000000 +0000'#10, [
    ArgumentText(Marker), ArgumentText(Side.Path), ArgumentNumber(DateTime.Year),
    ArgumentNumber(DateTime.Month), ArgumentNumber(DateTime.Day), ArgumentNumber(DateTime.Hour),
    ArgumentNumber(DateTime.Minute), ArgumentNumber(DateTime.Second)]);
end;

{ Unified ranges: "start,count", with ",1" left out; an empty range
  names the line before it. }
procedure WriteUnifiedRange(Start, Count: Integer);
begin
  if Count = 0 then
    WriteDecimal(StandardOutput, Start)
  else
    WriteDecimal(StandardOutput, Start + 1);
  if Count <> 1 then
  begin
    WriteCharacter(StandardOutput, ',');
    WriteDecimal(StandardOutput, Count);
  end;
end;

{ The changes First..Last form one hunk with its surrounding context. }
procedure HunkBounds(First, Last: Integer; out AStart, AEnd, BStart, BEnd: Integer);
begin
  AStart := Changes[First].AStart - ContextLines;
  if AStart < 0 then
    AStart := 0;
  BStart := Changes[First].BStart - (Changes[First].AStart - AStart);
  AEnd := Changes[Last].AEnd + ContextLines;
  if AEnd > SideA.Lines.Count then
    AEnd := SideA.Lines.Count;
  BEnd := Changes[Last].BEnd + (AEnd - Changes[Last].AEnd);
end;

function HunkEnd(First: Integer): Integer;
begin
  Result := First;
  while (Result + 1 < ChangeCount) and
        (Changes[Result + 1].AStart - Changes[Result].AEnd <= 2 * ContextLines) do
    Inc(Result);
end;

procedure PrintUnified;
var
  First, Last: Integer;
  AStart, AEnd, BStart, BEnd: Integer;
  Index: Integer;
  LineA: Integer;
  Line: Integer;
begin
  WriteFileHeader('---', SideA);
  WriteFileHeader('+++', SideB);
  First := 0;
  while First < ChangeCount do
  begin
    Last := HunkEnd(First);
    HunkBounds(First, Last, AStart, AEnd, BStart, BEnd);
    WriteText(StandardOutput, '@@ -');
    WriteUnifiedRange(AStart, AEnd - AStart);
    WriteText(StandardOutput, ' +');
    WriteUnifiedRange(BStart, BEnd - BStart);
    WriteText(StandardOutput, ' @@'#10);
    LineA := AStart;
    for Index := First to Last do
    begin
      while LineA < Changes[Index].AStart do
      begin
        WriteLineWithPrefix(' ', SideA, LineA);
        Inc(LineA);
      end;
      for Line := Changes[Index].AStart to Changes[Index].AEnd - 1 do
        WriteLineWithPrefix('-', SideA, Line);
      for Line := Changes[Index].BStart to Changes[Index].BEnd - 1 do
        WriteLineWithPrefix('+', SideB, Line);
      LineA := Changes[Index].AEnd;
    end;
    while LineA < AEnd do
    begin
      WriteLineWithPrefix(' ', SideA, LineA);
      Inc(LineA);
    end;
    First := Last + 1;
  end;
end;

procedure WriteContextRange(Start, Finish: Integer);
begin
  if Finish - Start = 0 then
    WriteDecimal(StandardOutput, Start)
  else if Finish - Start = 1 then
    WriteDecimal(StandardOutput, Start + 1)
  else
  begin
    WriteDecimal(StandardOutput, Start + 1);
    WriteCharacter(StandardOutput, ',');
    WriteDecimal(StandardOutput, Finish);
  end;
end;

procedure PrintContext;
var
  First, Last: Integer;
  AStart, AEnd, BStart, BEnd: Integer;
  Index: Integer;
  Line: Integer;
  Cursor: Integer;
  HasDeletions, HasInsertions: Boolean;
  Marker: PChar;
begin
  WriteFileHeader('***', SideA);
  WriteFileHeader('---', SideB);
  First := 0;
  while First < ChangeCount do
  begin
    Last := HunkEnd(First);
    HunkBounds(First, Last, AStart, AEnd, BStart, BEnd);
    HasDeletions := False;
    HasInsertions := False;
    for Index := First to Last do
    begin
      if Changes[Index].AEnd > Changes[Index].AStart then
        HasDeletions := True;
      if Changes[Index].BEnd > Changes[Index].BStart then
        HasInsertions := True;
    end;
    WriteLine(StandardOutput, '***************');
    WriteText(StandardOutput, '*** ');
    WriteContextRange(AStart, AEnd);
    WriteText(StandardOutput, ' ****'#10);
    if HasDeletions then
    begin
      Cursor := AStart;
      for Index := First to Last do
      begin
        while Cursor < Changes[Index].AStart do
        begin
          WriteLineWithPrefix('  ', SideA, Cursor);
          Inc(Cursor);
        end;
        if Changes[Index].BEnd > Changes[Index].BStart then
          Marker := '! '
        else
          Marker := '- ';
        for Line := Changes[Index].AStart to Changes[Index].AEnd - 1 do
          WriteLineWithPrefix(Marker, SideA, Line);
        Cursor := Changes[Index].AEnd;
      end;
      while Cursor < AEnd do
      begin
        WriteLineWithPrefix('  ', SideA, Cursor);
        Inc(Cursor);
      end;
    end;
    WriteText(StandardOutput, '--- ');
    WriteContextRange(BStart, BEnd);
    WriteText(StandardOutput, ' ----'#10);
    if HasInsertions then
    begin
      Cursor := BStart;
      for Index := First to Last do
      begin
        while Cursor < Changes[Index].BStart do
        begin
          WriteLineWithPrefix('  ', SideB, Cursor);
          Inc(Cursor);
        end;
        if Changes[Index].AEnd > Changes[Index].AStart then
          Marker := '! '
        else
          Marker := '+ ';
        for Line := Changes[Index].BStart to Changes[Index].BEnd - 1 do
          WriteLineWithPrefix(Marker, SideB, Line);
        Cursor := Changes[Index].BEnd;
      end;
      while Cursor < BEnd do
      begin
        WriteLineWithPrefix('  ', SideB, Cursor);
        Inc(Cursor);
      end;
    end;
    First := Last + 1;
  end;
end;

{ --- Files and directories ------------------------------------------- }

procedure NoteStatus(Value: LongInt);
begin
  if Value > Status then
    Status := Value;
end;

{ Compares two files; InsideDirectories prints the "diff ..." line
  before a difference. }
procedure CompareFiles(PathA, PathB: PChar; InsideDirectories: Boolean);
begin
  if not ReadSide(PathA, NewFile and InsideDirectories, SideA) then
  begin
    NoteStatus(StatusTrouble);
    Exit;
  end;
  if not ReadSide(PathB, NewFile and InsideDirectories, SideB) then
  begin
    FreeSide(SideA);
    NoteStatus(StatusTrouble);
    Exit;
  end;
  ChangedA := PBoolean(AllocateZeroedMemory(QWord(SideA.Lines.Count + 1)));
  ChangedB := PBoolean(AllocateZeroedMemory(QWord(SideB.Lines.Count + 1)));
  MarkChanges(0, SideA.Lines.Count, 0, SideB.Lines.Count);
  CollectChanges;
  if ChangeCount > 0 then
  begin
    NoteStatus(StatusDifferent);
    if Brief then
      WriteFormatted(StandardOutput, 'Files %s and %s differ'#10, [ArgumentText(PathA), ArgumentText(PathB)])
    else
    begin
      if InsideDirectories then
        WriteFormatted(StandardOutput, 'diff%s %s %s'#10, [ArgumentText(HeaderOptions.Text),
          ArgumentText(PathA), ArgumentText(PathB)]);
      case Format of
        FormatUnified: PrintUnified;
        FormatContext: PrintContext;
      else
        PrintNormal;
      end;
    end;
  end;
  FreeMemory(Changes);
  FreeMemory(ChangedA);
  FreeMemory(ChangedB);
  FreeSide(SideA);
  FreeSide(SideB);
end;

function CompareNames(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := CompareText(PChar(First), PChar(Second));
end;

function KindOf(Path: PChar; out Kind: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  Result := GetFileInformation(Path, Information) = ErrorNone;
  if Result then
    Kind := Information.Kind
  else
    Kind := 0;
end;

function KindName(Kind: LongWord): PChar;
begin
  if Kind = KindDirectory then
    Result := 'directory'
  else
    Result := 'regular file';
end;

procedure CompareDirectories(PathA, PathB: PChar);
var
  NamesA, NamesB: TLineList;
  IndexA, IndexB: Integer;
  Order: Integer;
  Name: PChar;
  ChildA, ChildB: PChar;
  KindA, KindB: LongWord;
  HaveA, HaveB: Boolean;
begin
  BeginLineList(NamesA);
  BeginLineList(NamesB);
  ListDirectory(PathA, NamesA);
  ListDirectory(PathB, NamesB);
  SortPointers(PPointer(NamesA.Items), NamesA.Count, @CompareNames, nil);
  SortPointers(PPointer(NamesB.Items), NamesB.Count, @CompareNames, nil);
  IndexA := 0;
  IndexB := 0;
  while (IndexA < NamesA.Count) or (IndexB < NamesB.Count) do
  begin
    if IndexA >= NamesA.Count then
      Order := 1
    else if IndexB >= NamesB.Count then
      Order := -1
    else
      Order := CompareText(NamesA.Items[IndexA], NamesB.Items[IndexB]);
    if Order < 0 then
      Name := NamesA.Items[IndexA]
    else
      Name := NamesB.Items[IndexB];
    ChildA := JoinPath(PathA, Name);
    ChildB := JoinPath(PathB, Name);
    HaveA := KindOf(ChildA, KindA);
    HaveB := KindOf(ChildB, KindB);
    if (Order <> 0) and not (NewFile and ((HaveA and (KindA <> KindDirectory)) or
       (HaveB and (KindB <> KindDirectory)))) then
    begin
      if Order < 0 then
        WriteFormatted(StandardOutput, 'Only in %s: %s'#10, [ArgumentText(PathA), ArgumentText(Name)])
      else
        WriteFormatted(StandardOutput, 'Only in %s: %s'#10, [ArgumentText(PathB), ArgumentText(Name)]);
      NoteStatus(StatusDifferent);
    end
    else if (Order = 0) and (KindA = KindDirectory) and (KindB = KindDirectory) then
    begin
      if Recursive then
        CompareDirectories(ChildA, ChildB)
      else
        WriteFormatted(StandardOutput, 'Common subdirectories: %s and %s'#10,
          [ArgumentText(ChildA), ArgumentText(ChildB)]);
    end
    else if (Order = 0) and ((KindA = KindDirectory) <> (KindB = KindDirectory)) then
    begin
      WriteFormatted(StandardOutput, 'File %s is a %s while file %s is a %s'#10, [ArgumentText(ChildA),
        ArgumentText(KindName(KindA)), ArgumentText(ChildB), ArgumentText(KindName(KindB))]);
      NoteStatus(StatusDifferent);
    end
    else
      CompareFiles(ChildA, ChildB, True);
    FreeMemory(ChildA);
    FreeMemory(ChildB);
    if Order <= 0 then
      Inc(IndexA);
    if Order >= 0 then
      Inc(IndexB);
  end;
  FreeLineList(NamesA);
  FreeLineList(NamesB);
end;

procedure SetContext(Value: PChar);
var
  Number: Int64;
begin
  if not ParseInteger(Value, Number) or (Number < 0) then
    FailWithUsageHint('invalid context length ''%s''', [ArgumentText(Value)]);
  ContextLines := Integer(Number);
end;

procedure CollectHeaderOptions(const Parser: TOptionParser);
var
  Index: Integer;
  Text: PChar;
begin
  BeginText(HeaderOptions);
  for Index := 1 to ArgumentTotal - 1 do
  begin
    Text := Argument(Index);
    if (Text = Parser.Operands[0]) or (Text = Parser.Operands[1]) then
      Continue;
    AppendCharacter(HeaderOptions, ' ');
    AppendText(HeaderOptions, Text);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  PathA, PathB: PChar;
  IsDirectoryA, IsDirectoryB: Boolean;
  Base: PChar;
begin
  Format := FormatNormal;
  ContextLines := DefaultContext;
  Status := StatusSame;
  BeginOptions(Parser, [
    OptionDefinition('q', 'brief', False, OptionBrief),
    OptionDefinition('c', nil, False, OptionContext),
    OptionDefinition('C', 'context', True, OptionContextLines),
    OptionDefinition('u', nil, False, OptionUnified),
    OptionDefinition('U', 'unified', True, OptionUnifiedLines),
    OptionDefinition('r', 'recursive', False, OptionRecursive),
    OptionDefinition('N', 'new-file', False, OptionNewFile),
    OptionDefinition('i', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('b', 'ignore-space-change', False, OptionIgnoreSpaceChange),
    OptionDefinition('w', 'ignore-all-space', False, OptionIgnoreAllSpace),
    OptionDefinition('B', 'ignore-blank-lines', False, OptionIgnoreBlankLines)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionBrief: Brief := True;
      OptionContext: Format := FormatContext;
      OptionContextLines:
        begin
          Format := FormatContext;
          SetContext(Value);
        end;
      OptionUnified: Format := FormatUnified;
      OptionUnifiedLines:
        begin
          Format := FormatUnified;
          SetContext(Value);
        end;
      OptionRecursive: Recursive := True;
      OptionNewFile: NewFile := True;
      OptionIgnoreCase: IgnoreCase := True;
      OptionIgnoreSpaceChange: IgnoreSpaceChange := True;
      OptionIgnoreAllSpace: IgnoreAllSpace := True;
      OptionIgnoreBlankLines: IgnoreBlankLines := True;
    end;
  if Parser.OperandCount < 2 then
  begin
    if Parser.OperandCount = 0 then
      Report('missing operand after ''diff''', [])
    else
      Report('missing operand after ''%s''', [ArgumentText(Parser.Operands[0])]);
    Report('Try ''diff --help'' for more information.', []);
    Halt(StatusTrouble);
  end;
  if Parser.OperandCount > 2 then
  begin
    Report('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
    Report('Try ''diff --help'' for more information.', []);
    Halt(StatusTrouble);
  end;
  CollectHeaderOptions(Parser);
  PathA := Parser.Operands[0];
  PathB := Parser.Operands[1];
  IsDirectoryA := not TextIsEqual(PathA, '-') and IsDirectory(PathA);
  IsDirectoryB := not TextIsEqual(PathB, '-') and IsDirectory(PathB);
  if IsDirectoryA and IsDirectoryB then
    CompareDirectories(PathA, PathB)
  else
  begin
    if IsDirectoryA then
    begin
      Base := BaseName(PathB);
      PathA := JoinPath(PathA, Base);
    end
    else if IsDirectoryB then
    begin
      Base := BaseName(PathA);
      PathB := JoinPath(PathB, Base);
    end;
    CompareFiles(PathA, PathB, False);
  end;
  Halt(Status);
end.
