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
  TCP sequence numbers: 32-bit counters that wrap, compared as RFC 793
  does, by the sign of the 32-bit difference (so two numbers compare
  right while they are less than 2^31 apart). Used by the connection
  code and by the pure helpers (options, the SACK scoreboard, windows)
  that the host test builds without the kernel.
}
unit Network.TcpSequences;

{$mode objfpc}

interface

function SequenceBefore(First, Second: LongWord): Boolean;
function SequenceBeforeOrEqual(First, Second: LongWord): Boolean;
function SequenceAfter(First, Second: LongWord): Boolean;
function SequenceAfterOrEqual(First, Second: LongWord): Boolean;
{ The later and the earlier of two sequence numbers. }
function LaterSequence(First, Second: LongWord): LongWord;
function EarlierSequence(First, Second: LongWord): LongWord;
{ Bytes from First up to Second (Second not before First). }
function SequenceDistance(First, Second: LongWord): LongWord;

implementation

function SignedDifference(First, Second: LongWord): LongInt;
begin
  Result := LongInt(LongWord(QWord(First) - QWord(Second)));
end;

function SequenceBefore(First, Second: LongWord): Boolean;
begin
  Result := SignedDifference(First, Second) < 0;
end;

function SequenceBeforeOrEqual(First, Second: LongWord): Boolean;
begin
  Result := SignedDifference(First, Second) <= 0;
end;

function SequenceAfter(First, Second: LongWord): Boolean;
begin
  Result := SignedDifference(First, Second) > 0;
end;

function SequenceAfterOrEqual(First, Second: LongWord): Boolean;
begin
  Result := SignedDifference(First, Second) >= 0;
end;

function LaterSequence(First, Second: LongWord): LongWord;
begin
  if SequenceAfter(First, Second) then
    Result := First
  else
    Result := Second;
end;

function EarlierSequence(First, Second: LongWord): LongWord;
begin
  if SequenceBefore(First, Second) then
    Result := First
  else
    Result := Second;
end;

function SequenceDistance(First, Second: LongWord): LongWord;
begin
  Result := LongWord(QWord(Second) - QWord(First));
end;

end.
