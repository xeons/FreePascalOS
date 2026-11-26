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
  CachePolicyTest

  On the host: the kernel's pure policies around memory and storage.

    * Io.BlockCacheSizing: the cache's bounds from the free memory and
      the kernel options (defaults, small machines, options, ceilings,
      the minimum never above the maximum);
    * FileSystem.DiscardRanges: batched discard ranges merge when they
      touch or overlap, stay sorted, cancel by cutting and splitting,
      report a full list - checked against a bitmap doing the same the
      slow way, over many random operations;
    * Processes.OutOfMemoryScores: the largest goes, the adjustment
      counts, protected and ending processes are skipped unless the
      culprit, the culprit goes last.

  Prints every failed check and exits with 1 if there was one.
}
program CachePolicyTest;

{$mode objfpc}

uses
  SysUtils,
  Io.BlockCacheSizing,
  FileSystem.DiscardRanges,
  Processes.OutOfMemoryScores;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  GeneratorState: QWord = $2545F4914F6CDD1D;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

function NextRandom(Limit: QWord): QWord;
begin
  GeneratorState := GeneratorState xor (GeneratorState shl 13);
  GeneratorState := GeneratorState xor (GeneratorState shr 7);
  GeneratorState := GeneratorState xor (GeneratorState shl 17);
  Result := GeneratorState mod Limit;
end;

{ --- Sizing --------------------------------------------------------------- }

function NoOptions: TBlockCacheSizingOptions;
begin
  Result.MaximumMegabytes := 0;
  Result.MinimumMegabytes := 0;
  Result.SharePercent := 0;
end;

procedure TestSizing;
const
  PagesPerMebibyte = 256;
var
  Options: TBlockCacheSizingOptions;
  Size: TBlockCacheSize;
  FreePages: QWord;
begin
  { 512 MiB free: 4 MiB minimum, half of it at most. }
  FreePages := 512 * PagesPerMebibyte;
  Size := ChooseBlockCacheSize(FreePages, NoOptions);
  Check(Size.MinimumLines = 4 * PagesPerMebibyte, 'default minimum is 4 MiB');
  Check(Size.MaximumLines = FreePages div 2, 'default maximum is half the free memory');

  { 32 MiB free: the minimum shrinks to a sixteenth. }
  FreePages := 32 * PagesPerMebibyte;
  Size := ChooseBlockCacheSize(FreePages, NoOptions);
  Check(Size.MinimumLines = FreePages div 16, 'small machine: minimum a sixteenth of free memory');
  Check(Size.MaximumLines >= Size.MinimumLines, 'small machine: maximum at least the minimum');

  { Almost nothing free: the smallest cache, never above the ceiling. }
  Size := ChooseBlockCacheSize(10, NoOptions);
  Check(Size.MinimumLines = SmallestCacheBytes div CachePageBytes, 'tiny machine: the smallest minimum');
  Check(Size.MaximumLines = Size.MinimumLines, 'tiny machine: maximum equals minimum');

  { Options. }
  FreePages := 1024 * PagesPerMebibyte;
  Options := NoOptions;
  Options.MaximumMegabytes := 64;
  Options.MinimumMegabytes := 8;
  Size := ChooseBlockCacheSize(FreePages, Options);
  Check(Size.MaximumLines = 64 * PagesPerMebibyte, 'blockcache=64 sets the maximum');
  Check(Size.MinimumLines = 8 * PagesPerMebibyte, 'blockcachemin=8 sets the minimum');
  Options := NoOptions;
  Options.SharePercent := 25;
  Size := ChooseBlockCacheSize(FreePages, Options);
  Check(Size.MaximumLines = FreePages div 4, 'blockcacheshare=25 takes a quarter');
  Options.SharePercent := 99;
  Size := ChooseBlockCacheSize(FreePages, Options);
  Check(Size.MaximumLines = FreePages div 2, 'a share above 90% falls back to the default');
  Options := NoOptions;
  Options.MaximumMegabytes := 100000;
  Size := ChooseBlockCacheSize(FreePages, Options);
  Check(Size.MaximumLines = FreePages * 90 div 100, 'the maximum stays below 90% of free memory');
  Options := NoOptions;
  Options.MinimumMegabytes := 512;
  Options.MaximumMegabytes := 16;
  Size := ChooseBlockCacheSize(FreePages, Options);
  Check(Size.MaximumLines = Size.MinimumLines, 'a maximum below the minimum is raised to it');
end;

{ --- Discard ranges -------------------------------------------------------- }

const
  ModelBytes = 4096;

type
  TModel = array[0..ModelBytes - 1] of Boolean;

function ListMatchesModel(const List: TDiscardRangeList; const Model: TModel): Boolean;
var
  Expected: TModel;
  Index: Integer;
  Position: QWord;
begin
  FillChar(Expected, SizeOf(Expected), 0);
  for Index := 0 to List.Count - 1 do
  begin
    if List.Ranges[Index].Count = 0 then
      Exit(False);
    { Sorted, apart (not even touching). }
    if (Index > 0) and (List.Ranges[Index - 1].Start + List.Ranges[Index - 1].Count >= List.Ranges[Index].Start) then
      Exit(False);
    Position := List.Ranges[Index].Start;
    while Position < List.Ranges[Index].Start + List.Ranges[Index].Count do
    begin
      Expected[Position] := True;
      Inc(Position);
    end;
  end;
  for Index := 0 to ModelBytes - 1 do
    if Expected[Index] <> Model[Index] then
      Exit(False);
  Result := True;
end;

procedure MarkModel(var Model: TModel; Start, Count: QWord; Value: Boolean);
var
  Position: QWord;
begin
  Position := Start;
  while Position < Start + Count do
  begin
    Model[Position] := Value;
    Inc(Position);
  end;
end;

procedure TestDiscardRanges;
var
  List: TDiscardRangeList;
  Other: TDiscardRangeList;
  Model: TModel;
  Round: Integer;
  Start: QWord;
  Count: QWord;
  Added: Boolean;
  Index: Integer;
  Consistent: Boolean;
begin
  ClearDiscardRanges(List);
  Check(AddDiscardRange(List, 100, 10) and AddDiscardRange(List, 110, 10) and (List.Count = 1) and
    (List.Ranges[0].Start = 100) and (List.Ranges[0].Count = 20), 'touching ranges merge');
  Check(AddDiscardRange(List, 50, 10) and (List.Count = 2) and (List.Ranges[0].Start = 50), 'ranges stay sorted');
  Check(AddDiscardRange(List, 55, 50) and (List.Count = 1) and (List.Ranges[0].Start = 50) and
    (List.Ranges[0].Count = 70), 'a range over two swallows both');
  Check(CancelDiscardRange(List, 60, 10) and (List.Count = 2) and (List.Ranges[0].Count = 10) and
    (List.Ranges[1].Start = 70) and (List.Ranges[1].Count = 50), 'cancelling the middle splits a range');
  Check(CancelDiscardRange(List, 0, 1000) and (List.Count = 0), 'cancelling everything empties the list');
  Check(DiscardRangeBytes(List) = 0, 'an empty list holds no bytes');

  { A full list refuses a range apart from the others. }
  ClearDiscardRanges(List);
  for Index := 0 to DiscardRangeCapacity - 1 do
    AddDiscardRange(List, QWord(Index) * 10, 5);
  Check(List.Count = DiscardRangeCapacity, 'the list fills to its capacity');
  Check(not AddDiscardRange(List, 100000, 5), 'a full list refuses a new range');
  Check(AddDiscardRange(List, 5, 5) and (List.Count = DiscardRangeCapacity - 1),
    'a full list still merges a range that touches others');

  { Random adds and cancels against a bitmap. }
  ClearDiscardRanges(List);
  FillChar(Model, SizeOf(Model), 0);
  Consistent := True;
  for Round := 1 to 200000 do
  begin
    Count := 1 + NextRandom(40);
    Start := NextRandom(ModelBytes - Count);
    if NextRandom(3) = 0 then
    begin
      if CancelDiscardRange(List, Start, Count) then
        MarkModel(Model, Start, Count, False)
      else
      begin
        { A split found no room: the whole range went; rebuild the model. }
        FillChar(Model, SizeOf(Model), 0);
        for Index := 0 to List.Count - 1 do
          MarkModel(Model, List.Ranges[Index].Start, List.Ranges[Index].Count, True);
      end;
    end
    else
    begin
      Added := AddDiscardRange(List, Start, Count);
      if Added then
        MarkModel(Model, Start, Count, True);
    end;
    if not ListMatchesModel(List, Model) then
    begin
      Consistent := False;
      Break;
    end;
  end;
  Check(Consistent, 'random adds and cancels match a bitmap');

  { Merging one list into another. }
  ClearDiscardRanges(List);
  ClearDiscardRanges(Other);
  AddDiscardRange(List, 0, 10);
  AddDiscardRange(Other, 10, 10);
  AddDiscardRange(Other, 40, 5);
  Check(MergeDiscardRanges(List, Other) and (List.Count = 2) and (DiscardRangeBytes(List) = 25),
    'merging lists joins what touches');
end;

{ --- Out-of-memory scores ---------------------------------------------------- }

function Candidate(Footprint: QWord; Adjust: LongInt; IsProtected, IsCulprit, IsEnding: Boolean): TOomCandidate;
begin
  Result.FootprintPages := Footprint;
  Result.ScoreAdjust := Adjust;
  Result.IsProtected := IsProtected;
  Result.IsCulprit := IsCulprit;
  Result.IsEnding := IsEnding;
end;

{ The index of the chosen one among Candidates, or -1. }
function Choose(const Candidates: array of TOomCandidate; TotalPages: QWord): Integer;
var
  Index: Integer;
  Score: Int64;
  BestScore: Int64;
  BestFootprint: QWord;
begin
  Result := -1;
  BestScore := OomNotEligible;
  BestFootprint := 0;
  for Index := 0 to High(Candidates) do
  begin
    Score := OomScore(Candidates[Index], TotalPages);
    if OomBeatsBest(Score, Candidates[Index].FootprintPages, BestScore, BestFootprint) then
    begin
      Result := Index;
      BestScore := Score;
      BestFootprint := Candidates[Index].FootprintPages;
    end;
  end;
end;

procedure TestScores;
const
  Total = 100000;
begin
  Check(Choose([Candidate(100, 0, False, False, False), Candidate(5000, 0, False, False, False),
    Candidate(300, 0, False, True, False)], Total) = 1, 'the largest goes');
  Check(Choose([Candidate(100, 1000, False, False, False), Candidate(50000, 0, False, False, False)], Total) = 0,
    'the adjustment 1000 goes first');
  Check(Choose([Candidate(90000, -1000, False, False, False), Candidate(100, 0, False, False, False)], Total) = 1,
    'the adjustment -1000 is never chosen');
  Check(Choose([Candidate(90000, 0, True, False, False), Candidate(100, 0, False, False, False)], Total) = 1,
    'a protected process is skipped');
  Check(Choose([Candidate(90000, 0, False, False, True), Candidate(100, 0, False, False, False)], Total) = 1,
    'a process already ending is skipped');
  Check(Choose([Candidate(90000, 0, True, True, False), Candidate(100, 0, False, False, False)], Total) = 1,
    'a protected culprit goes only if nobody else may');
  Check(Choose([Candidate(90000, 0, True, True, False), Candidate(100, 0, True, False, False)], Total) = 0,
    'a protected culprit goes when nobody else may');
  Check(Choose([Candidate(0, 0, False, False, False)], Total) = -1, 'a process without memory is not ended');
  Check(Choose([Candidate(500, 0, False, False, False), Candidate(800, 0, False, False, False)], Total) = 1,
    'equal scores: the larger one');
  Check(OomScore(Candidate(Total * 2, 0, False, False, False), Total) = 1000, 'the share is at most 1000');
  Check(OomScore(Candidate(100, 0, False, False, True), Total) = OomNotEligible, 'ending: no score');
  { The kind of process (OomKindAdjust). }
  Check(OomKindAdjust(0, True, False, False) = SandboxedOomAdjust, 'a sandboxed process goes earlier');
  Check(OomKindAdjust(0, False, True, False) = BackgroundOomAdjust, 'a background process goes earlier');
  Check(OomKindAdjust(0, False, False, True) = EssentialOomAdjust, 'the desktop goes later');
  Check(OomKindAdjust(950, True, True, False) = OomAdjustHighest, 'never above 1000');
  Check(OomKindAdjust(-1000, True, True, False) = OomAdjustLowest, '-1000 stays never');
  Check(OomKindAdjust(-800, False, False, True) > OomAdjustLowest, 'lowered by its kind it stays eligible');
  Check(Choose([Candidate(30000, OomKindAdjust(0, False, False, True), False, False, False),
    Candidate(20000, OomKindAdjust(300, True, False, False), False, False, False)], Total) = 1,
    'a sandboxed renderer goes before a larger desktop');
  Check(Choose([Candidate(30000, OomKindAdjust(0, False, False, False), False, False, False),
    Candidate(25000, OomKindAdjust(0, False, True, False), False, False, False)], Total) = 1,
    'a background process goes before a slightly larger program');
end;

begin
  TestSizing;
  TestDiscardRanges;
  TestScores;
  WriteLn(Format('CachePolicyTest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
end.
