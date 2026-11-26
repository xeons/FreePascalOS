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
  Which process to end when memory runs out (Processes.OutOfMemory).

  A process's score is its share of memory in thousandths - its
  resident and committed pages over all the pages there are - plus its
  adjustment (-1000 to 1000, ProcessLimitOomScoreAdjust). The highest
  score goes; on equal scores the larger process. Never chosen: a
  process already being ended, and - unless it is the culprit (the one
  whose allocation failed) - a protected one (the initial program, the
  adjustment OomScoreAdjustNever) or one whose score is not above
  zero. The culprit, if nothing else may go, goes itself.

  What kind of process it is moves its adjustment too (OomKindAdjust):
  a sandboxed one (a browser's renderer) and one in the Idle or
  Background class go before ordinary programs, one the user drives the
  system with (Interactive class: the desktop, the task manager) after
  them; one in the System class (the display server) is protected.

  Pure arithmetic, for the host test (tools/CachePolicyTest).
}
unit Processes.OutOfMemoryScores;

{$mode objfpc}

interface

const
  OomAdjustLowest = -1000;
  OomAdjustHighest = 1000;
  { Added by OomKindAdjust. }
  SandboxedOomAdjust = 150;
  BackgroundOomAdjust = 150;
  EssentialOomAdjust = -300;
  { No score: may not be chosen. }
  OomNotEligible = Low(Int64);

type
  TOomCandidate = record
    FootprintPages: QWord;
    ScoreAdjust: LongInt;
    IsProtected: Boolean;
    IsCulprit: Boolean;
    IsEnding: Boolean;
  end;

{ The candidate's score among TotalPages pages; OomNotEligible if it may
  not be chosen. The culprit always has a score (its share, at least 1). }
function OomScore(const Candidate: TOomCandidate; TotalPages: QWord): Int64;
{ The process's own adjustment Adjust moved for its kind: sandboxed,
  in a background class (Idle, Background), essential (Interactive);
  kept within -1000 .. 1000, and -1000 stays -1000 (never). }
function OomKindAdjust(Adjust: LongInt; IsSandboxed, IsBackground, IsEssential: Boolean): LongInt;
{ True if a candidate with Score and Footprint should be chosen over the
  best so far (BestScore, BestFootprint; OomNotEligible for none). }
function OomBeatsBest(Score: Int64; Footprint: QWord; BestScore: Int64; BestFootprint: QWord): Boolean;

implementation

function OomScore(const Candidate: TOomCandidate; TotalPages: QWord): Int64;
var
  Share: Int64;
  Adjust: LongInt;
begin
  if Candidate.IsEnding then
    Exit(OomNotEligible);
  if TotalPages = 0 then
    TotalPages := 1;
  if Candidate.FootprintPages >= TotalPages then
    Share := 1000
  else
    Share := Int64((Candidate.FootprintPages * 1000) div TotalPages);
  Adjust := Candidate.ScoreAdjust;
  if Adjust < OomAdjustLowest then
    Adjust := OomAdjustLowest;
  if Adjust > OomAdjustHighest then
    Adjust := OomAdjustHighest;
  if Candidate.IsCulprit then
  begin
    { Last in line if it is protected, but always eligible. }
    if Candidate.IsProtected or (Adjust = OomAdjustLowest) then
      Exit(0);
    Result := Share + Adjust;
    if Result < 1 then
      Result := 1;
    Exit;
  end;
  if Candidate.IsProtected or (Adjust = OomAdjustLowest) then
    Exit(OomNotEligible);
  Result := Share + Adjust;
  { A process with nothing to give back is not worth ending. }
  if (Result <= 0) or (Candidate.FootprintPages = 0) then
    Result := OomNotEligible;
end;

function OomKindAdjust(Adjust: LongInt; IsSandboxed, IsBackground, IsEssential: Boolean): LongInt;
begin
  if Adjust <= OomAdjustLowest then
    Exit(OomAdjustLowest);
  Result := Adjust;
  if IsSandboxed then
    Result := Result + SandboxedOomAdjust;
  if IsBackground then
    Result := Result + BackgroundOomAdjust;
  if IsEssential then
    Result := Result + EssentialOomAdjust;
  if Result > OomAdjustHighest then
    Result := OomAdjustHighest;
  { Lowered by its kind, it still stays eligible. }
  if Result <= OomAdjustLowest then
    Result := OomAdjustLowest + 1;
end;

function OomBeatsBest(Score: Int64; Footprint: QWord; BestScore: Int64; BestFootprint: QWord): Boolean;
begin
  if Score = OomNotEligible then
    Exit(False);
  if BestScore = OomNotEligible then
    Exit(True);
  if Score <> BestScore then
    Exit(Score > BestScore);
  Result := Footprint > BestFootprint;
end;

end.
