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
  Runs of free page frames, for physically contiguous allocations (DMA
  buffers and anything else a device reads in one piece).

  A bitmap with one bit per page frame, set while the frame is free
  (on the physical page allocator's free list), is searched for
  PageCount free frames in a row that also

    - start on a multiple of AlignmentPages (a power of two),
    - do not cross a multiple of BoundaryPages (a power of two, 0 for no
      boundary: a device whose descriptors cannot span a 64 KiB line),
    - lie in [LowestFrame, EndFrame) (a device that reaches only the low
      4 GiB, or a DMA window).

  The search goes a 64-frame word at a time where it can: words with no
  free frame are skipped whole, and a used frame inside a candidate run
  moves the candidate past it to the next aligned frame, so a request
  costs about one pass over the bitmap words of the range in the worst
  case and much less in the usual one.

  Plain Pascal without kernel units, so the host test
  (tools/FrameRunTest) runs the same code.
}
unit Memory.FrameRuns;

{$mode objfpc}
{$pointermath on}

interface

const
  FramesPerWord = 64;

type
  TFrameBitmap = record
    { (FrameCount + 63) div 64 words; bit (Frame mod 64) of word
      (Frame div 64) is set while Frame is free. }
    Words: PQWord;
    FrameCount: QWord;
  end;

  TFrameRunRequest = record
    PageCount: QWord;
    { A power of two; 0 counts as 1. }
    AlignmentPages: QWord;
    { A power of two, or 0 for none. }
    BoundaryPages: QWord;
    LowestFrame: QWord;
    { The first frame past the range (clipped to the bitmap). }
    EndFrame: QWord;
  end;

{ The words a bitmap of FrameCount frames takes. }
function FrameBitmapWords(FrameCount: QWord): QWord;
{ Uses Words (FrameBitmapWords(FrameCount) of them) with every frame used. }
procedure InitializeFrameBitmap(out Bitmap: TFrameBitmap; Words: PQWord; FrameCount: QWord);

procedure MarkFrameFree(var Bitmap: TFrameBitmap; Frame: QWord);
procedure MarkFrameUsed(var Bitmap: TFrameBitmap; Frame: QWord);
function FrameIsFree(const Bitmap: TFrameBitmap; Frame: QWord): Boolean;

{ True if Request's alignment and boundary are powers of two (or 0) and
  the run fits within one boundary. }
function FrameRunRequestIsValid(const Request: TFrameRunRequest): Boolean;
{ The first frame of the lowest run Request describes; False if none. }
function FindFreeFrameRun(const Bitmap: TFrameBitmap; const Request: TFrameRunRequest;
  out FirstFrame: QWord): Boolean;
{ The longest run of free frames (for the memory figures). }
function LongestFreeFrameRun(const Bitmap: TFrameBitmap): QWord;

implementation

function FrameBitmapWords(FrameCount: QWord): QWord;
begin
  Result := (FrameCount + FramesPerWord - 1) div FramesPerWord;
end;

procedure InitializeFrameBitmap(out Bitmap: TFrameBitmap; Words: PQWord; FrameCount: QWord);
var
  Index: QWord;
begin
  Bitmap.Words := Words;
  Bitmap.FrameCount := FrameCount;
  Index := 0;
  while Index < FrameBitmapWords(FrameCount) do
  begin
    Words[Index] := 0;
    Inc(Index);
  end;
end;

function BitOf(Frame: QWord): QWord; inline;
begin
  Result := QWord(1) shl (Frame and (FramesPerWord - 1));
end;

procedure MarkFrameFree(var Bitmap: TFrameBitmap; Frame: QWord);
begin
  if Frame < Bitmap.FrameCount then
    Bitmap.Words[Frame div FramesPerWord] := Bitmap.Words[Frame div FramesPerWord] or BitOf(Frame);
end;

procedure MarkFrameUsed(var Bitmap: TFrameBitmap; Frame: QWord);
begin
  if Frame < Bitmap.FrameCount then
    Bitmap.Words[Frame div FramesPerWord] := Bitmap.Words[Frame div FramesPerWord] and not BitOf(Frame);
end;

function FrameIsFree(const Bitmap: TFrameBitmap; Frame: QWord): Boolean;
begin
  Result := (Frame < Bitmap.FrameCount) and ((Bitmap.Words[Frame div FramesPerWord] and BitOf(Frame)) <> 0);
end;

function IsPowerOfTwo(Value: QWord): Boolean;
begin
  Result := (Value <> 0) and ((Value and (Value - 1)) = 0);
end;

{ The position of the lowest set bit of a word that is not zero. }
function LowestSetBit(Value: QWord): QWord;
begin
  Result := 0;
  if (Value and $FFFFFFFF) = 0 then
  begin
    Value := Value shr 32;
    Inc(Result, 32);
  end;
  if (Value and $FFFF) = 0 then
  begin
    Value := Value shr 16;
    Inc(Result, 16);
  end;
  if (Value and $FF) = 0 then
  begin
    Value := Value shr 8;
    Inc(Result, 8);
  end;
  if (Value and $F) = 0 then
  begin
    Value := Value shr 4;
    Inc(Result, 4);
  end;
  if (Value and $3) = 0 then
  begin
    Value := Value shr 2;
    Inc(Result, 2);
  end;
  if (Value and $1) = 0 then
    Inc(Result);
end;

{ The bits of a word at and above position Bit. }
function MaskFrom(Bit: QWord): QWord; inline;
begin
  Result := (not QWord(0)) shl Bit;
end;

{ The first frame in [From, Limit) whose bit says free (WantFree) or
  used; Limit if there is none. Limit is at most the bitmap's frames. }
function FindNextFrame(const Bitmap: TFrameBitmap; From, Limit: QWord; WantFree: Boolean): QWord;
var
  WordIndex: QWord;
  Bits: QWord;
begin
  if From >= Limit then
    Exit(Limit);
  WordIndex := From div FramesPerWord;
  Bits := Bitmap.Words[WordIndex];
  if not WantFree then
    Bits := not Bits;
  Bits := Bits and MaskFrom(From and (FramesPerWord - 1));
  while Bits = 0 do
  begin
    Inc(WordIndex);
    if WordIndex * FramesPerWord >= Limit then
      Exit(Limit);
    Bits := Bitmap.Words[WordIndex];
    if not WantFree then
      Bits := not Bits;
  end;
  Result := WordIndex * FramesPerWord + LowestSetBit(Bits);
  if Result > Limit then
    Result := Limit;
end;

function AlignUp(Value, Alignment: QWord): QWord; inline;
begin
  Result := (Value + Alignment - 1) and not (Alignment - 1);
end;

function FrameRunRequestIsValid(const Request: TFrameRunRequest): Boolean;
begin
  Result := (Request.PageCount > 0) and
    ((Request.AlignmentPages = 0) or IsPowerOfTwo(Request.AlignmentPages)) and
    ((Request.BoundaryPages = 0) or (IsPowerOfTwo(Request.BoundaryPages) and
      (Request.PageCount <= Request.BoundaryPages)));
end;

function FindFreeFrameRun(const Bitmap: TFrameBitmap; const Request: TFrameRunRequest;
  out FirstFrame: QWord): Boolean;
var
  Alignment: QWord;
  Limit: QWord;
  Candidate: QWord;
  NextBoundary: QWord;
  Used: QWord;
begin
  Result := False;
  FirstFrame := 0;
  if not FrameRunRequestIsValid(Request) then
    Exit;
  Alignment := Request.AlignmentPages;
  if Alignment = 0 then
    Alignment := 1;
  Limit := Request.EndFrame;
  if Limit > Bitmap.FrameCount then
    Limit := Bitmap.FrameCount;
  Candidate := AlignUp(Request.LowestFrame, Alignment);
  while (Candidate < Limit) and (Request.PageCount <= Limit - Candidate) do
  begin
    { Skip used frames up to the next free one. }
    if not FrameIsFree(Bitmap, Candidate) then
    begin
      Candidate := AlignUp(FindNextFrame(Bitmap, Candidate, Limit, True), Alignment);
      Continue;
    end;
    if Request.BoundaryPages <> 0 then
    begin
      NextBoundary := (Candidate div Request.BoundaryPages + 1) * Request.BoundaryPages;
      if Request.PageCount > NextBoundary - Candidate then
      begin
        Candidate := AlignUp(NextBoundary, Alignment);
        Continue;
      end;
    end;
    Used := FindNextFrame(Bitmap, Candidate, Candidate + Request.PageCount, False);
    if Used = Candidate + Request.PageCount then
    begin
      FirstFrame := Candidate;
      Exit(True);
    end;
    Candidate := AlignUp(Used + 1, Alignment);
  end;
end;

function LongestFreeFrameRun(const Bitmap: TFrameBitmap): QWord;
var
  Start: QWord;
  Finish: QWord;
begin
  Result := 0;
  Start := FindNextFrame(Bitmap, 0, Bitmap.FrameCount, True);
  while Start < Bitmap.FrameCount do
  begin
    Finish := FindNextFrame(Bitmap, Start, Bitmap.FrameCount, False);
    if Finish - Start > Result then
      Result := Finish - Start;
    Start := FindNextFrame(Bitmap, Finish, Bitmap.FrameCount, True);
  end;
end;

end.
