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
  FrameRunTest: the search for runs of free page frames
  (kernel/memory/Memory.FrameRuns) on the host.

  Fixed cases (alignment, boundaries, ranges, the bitmap's last word),
  then many random bitmaps and requests, each answer compared with a
  plain frame-by-frame search: the run found must be the lowest one
  that is free, aligned, inside the range and inside one boundary, and
  "none" must mean there is none.
}
program FrameRunTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Memory.FrameRuns;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(Passed: Boolean; const Name: string);
begin
  Inc(Checks);
  if not Passed then
  begin
    Inc(Failures);
    WriteLn('FAIL ', Name);
  end;
end;

type
  TTestBitmap = record
    Bitmap: TFrameBitmap;
    Storage: array of QWord;
  end;

procedure MakeBitmap(out Test: TTestBitmap; FrameCount: QWord);
begin
  Test.Storage := nil;
  SetLength(Test.Storage, FrameBitmapWords(FrameCount) + 1);
  InitializeFrameBitmap(Test.Bitmap, @Test.Storage[0], FrameCount);
end;

procedure FreeRange(var Test: TTestBitmap; First, Count: QWord);
var
  Frame: QWord;
begin
  Frame := First;
  while Frame < First + Count do
  begin
    MarkFrameFree(Test.Bitmap, Frame);
    Inc(Frame);
  end;
end;

function Request(PageCount, Alignment, Boundary, Lowest, EndFrame: QWord): TFrameRunRequest;
begin
  Result.PageCount := PageCount;
  Result.AlignmentPages := Alignment;
  Result.BoundaryPages := Boundary;
  Result.LowestFrame := Lowest;
  Result.EndFrame := EndFrame;
end;

{ The answer frame by frame. }
function SlowFind(const Bitmap: TFrameBitmap; const Wanted: TFrameRunRequest; out First: QWord): Boolean;
var
  Alignment: QWord;
  Limit: QWord;
  Candidate: QWord;
  Offset: QWord;
  AllFree: Boolean;
begin
  Result := False;
  First := 0;
  if not FrameRunRequestIsValid(Wanted) then
    Exit;
  Alignment := Wanted.AlignmentPages;
  if Alignment = 0 then
    Alignment := 1;
  Limit := Wanted.EndFrame;
  if Limit > Bitmap.FrameCount then
    Limit := Bitmap.FrameCount;
  Candidate := Wanted.LowestFrame;
  while Candidate + Wanted.PageCount <= Limit do
  begin
    if (Candidate mod Alignment = 0) and ((Wanted.BoundaryPages = 0) or
       (Candidate div Wanted.BoundaryPages = (Candidate + Wanted.PageCount - 1) div Wanted.BoundaryPages)) then
    begin
      AllFree := True;
      Offset := 0;
      while AllFree and (Offset < Wanted.PageCount) do
      begin
        AllFree := FrameIsFree(Bitmap, Candidate + Offset);
        Inc(Offset);
      end;
      if AllFree then
      begin
        First := Candidate;
        Exit(True);
      end;
    end;
    Inc(Candidate);
  end;
end;

procedure ExpectRun(const Test: TTestBitmap; const Wanted: TFrameRunRequest; Expected: Int64; const Name: string);
var
  First: QWord;
  Found: Boolean;
begin
  Found := FindFreeFrameRun(Test.Bitmap, Wanted, First);
  if Expected < 0 then
    Check(not Found, Name + ' (none expected, got ' + IntToStr(First) + ')')
  else
    Check(Found and (First = QWord(Expected)), Name + ' (expected ' + IntToStr(Expected) + ', got ' +
      BoolToStr(Found, True) + ' ' + IntToStr(First) + ')');
end;

procedure TestFixedCases;
var
  Test: TTestBitmap;
begin
  MakeBitmap(Test, 1000);
  ExpectRun(Test, Request(1, 1, 0, 0, 1000), -1, 'nothing free');
  FreeRange(Test, 10, 5);
  FreeRange(Test, 64, 64);
  FreeRange(Test, 200, 300);
  FreeRange(Test, 990, 10);
  ExpectRun(Test, Request(1, 1, 0, 0, 1000), 10, 'lowest single frame');
  ExpectRun(Test, Request(5, 1, 0, 0, 1000), 10, 'exact fit');
  ExpectRun(Test, Request(6, 1, 0, 0, 1000), 64, 'too short a run skipped');
  ExpectRun(Test, Request(64, 64, 0, 0, 1000), 64, 'a whole word, aligned');
  ExpectRun(Test, Request(65, 1, 0, 0, 1000), 200, 'longer than a word');
  ExpectRun(Test, Request(16, 16, 0, 0, 1000), 64, 'alignment 16');
  ExpectRun(Test, Request(16, 128, 0, 0, 1000), 256, 'alignment 128');
  ExpectRun(Test, Request(32, 1, 32, 70, 1000), 96, 'boundary pushes past a line');
  ExpectRun(Test, Request(40, 1, 32, 0, 1000), -1, 'larger than the boundary');
  ExpectRun(Test, Request(3, 1, 0, 11, 1000), 11, 'from a low limit');
  ExpectRun(Test, Request(10, 1, 0, 0, 1000), 64, 'from the start');
  ExpectRun(Test, Request(10, 1, 0, 0, 74), 64, 'inside an end limit');
  ExpectRun(Test, Request(10, 1, 0, 0, 73), -1, 'end limit too low');
  ExpectRun(Test, Request(10, 1, 0, 980, 1000), 990, 'the last frames');
  ExpectRun(Test, Request(11, 1, 0, 980, 1000), -1, 'past the last frame');
  ExpectRun(Test, Request(10, 1, 0, 980, 5000), 990, 'end limit past the bitmap');
  ExpectRun(Test, Request(4, 3, 0, 0, 1000), -1, 'alignment not a power of two');
  ExpectRun(Test, Request(4, 1, 6, 0, 1000), -1, 'boundary not a power of two');
  ExpectRun(Test, Request(0, 1, 0, 0, 1000), -1, 'zero pages');
  MarkFrameUsed(Test.Bitmap, 300);
  ExpectRun(Test, Request(150, 1, 0, 0, 1000), 301, 'a used frame inside a run');
  Check(LongestFreeFrameRun(Test.Bitmap) = 199, 'longest run');
end;

procedure TestRandomCases;
const
  Rounds = 4000;
var
  Round: Integer;
  Test: TTestBitmap;
  FrameCount: QWord;
  Frame: QWord;
  Density: Integer;
  Wanted: TFrameRunRequest;
  FastFirst: QWord;
  SlowFirst: QWord;
  FastFound: Boolean;
  SlowFound: Boolean;
begin
  RandSeed := 20261125;
  for Round := 1 to Rounds do
  begin
    FrameCount := 1 + QWord(Random(700));
    MakeBitmap(Test, FrameCount);
    Density := 1 + Random(99);
    Frame := 0;
    while Frame < FrameCount do
    begin
      if Random(100) < Density then
        MarkFrameFree(Test.Bitmap, Frame);
      Inc(Frame);
    end;
    Wanted.PageCount := 1 + QWord(Random(40));
    Wanted.AlignmentPages := QWord(1) shl Random(7);
    if Random(3) = 0 then
      Wanted.BoundaryPages := 0
    else
      Wanted.BoundaryPages := QWord(1) shl Random(8);
    Wanted.LowestFrame := QWord(Random(LongInt(FrameCount)));
    if Random(4) = 0 then
      Wanted.LowestFrame := 0;
    Wanted.EndFrame := Wanted.LowestFrame + QWord(Random(LongInt(FrameCount) + 50));
    FastFound := FindFreeFrameRun(Test.Bitmap, Wanted, FastFirst);
    SlowFound := SlowFind(Test.Bitmap, Wanted, SlowFirst);
    Check((FastFound = SlowFound) and (not FastFound or (FastFirst = SlowFirst)),
      Format('random round %d: %d pages, alignment %d, boundary %d, [%d, %d) of %d: %s %d, expected %s %d',
        [Round, Wanted.PageCount, Wanted.AlignmentPages, Wanted.BoundaryPages, Wanted.LowestFrame,
         Wanted.EndFrame, FrameCount, BoolToStr(FastFound, True), FastFirst, BoolToStr(SlowFound, True),
         SlowFirst]));
  end;
end;

begin
  TestFixedCases;
  TestRandomCases;
  WriteLn(Format('FrameRunTest: %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
end.
