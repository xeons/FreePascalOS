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
  TCP windows: the arithmetic of window scaling (RFC 7323) and of the
  buffers that grow with the connection.

  With window scaling agreed, the 16-bit window field counts units of
  2^shift bytes. Ours is OwnWindowShift (7: 128-byte units, so the
  largest window, 65535 units, is 8 MiB - room for the 4 MiB receive
  buffer). A window rounded down to whole units could move the right
  edge we promised to the left, which RFC 7323 2.4 forbids: the field
  is raised to cover what was already promised.

  Buffers start at 64 KiB. The receive buffer grows to hold what the
  reader takes in a round trip, twice over (the bandwidth-delay
  product, with room for the sender's slow start to double it), and
  the send buffer to twice the window the connection could fill (the
  smaller of the congestion window and the peer's); both double at a
  step, up to 4 MiB. A buffer set by its socket's option does not grow.

  Pure: no kernel units, so the host test (tools/TcpTest) builds it.
}
unit Network.TcpWindows;

{$mode objfpc}

interface

const
  OwnWindowShift = 7;
  InitialReceiveBufferBytes = 64 * 1024;
  InitialSendBufferBytes = 64 * 1024;
  MaximumReceiveBufferBytes = 4 * 1024 * 1024;
  MaximumSendBufferBytes = 4 * 1024 * 1024;
  { The smallest buffer a socket option may ask for. }
  MinimumBufferBytes = 2 * 1024;
  { The largest window without scaling. }
  UnscaledWindowLimit = 65535;

{ The largest window a shift can express. }
function LargestWindow(Shift: Byte): LongWord;
{ The window field to send: Available bytes (the room we have) in units
  of 2^Shift, raised to cover Promised (what the last advertisement
  still promises beyond the next expected byte), at most 65535. }
function ScaledWindowField(Available, Promised: LongWord; Shift: Byte): Word;
{ The window a field from the peer means. }
function WindowFromField(Field: Word; Shift: Byte): LongWord;
{ The receive buffer for a reader that took BytesPerRoundTrip in the
  last round trip: Capacity, or more (doubling) up to Limit. }
function TunedReceiveBuffer(Capacity, BytesPerRoundTrip, Limit: LongWord): LongWord;
{ The send buffer for a connection that could have CongestionWindow and
  PeerWindow bytes in flight: Capacity, or more up to Limit. }
function TunedSendBuffer(Capacity, CongestionWindow, PeerWindow, Limit: LongWord): LongWord;

implementation

function LargestWindow(Shift: Byte): LongWord;
begin
  Result := LongWord(QWord(UnscaledWindowLimit) shl Shift);
end;

function ScaledWindowField(Available, Promised: LongWord; Shift: Byte): Word;
var
  Units: QWord;
  PromisedUnits: QWord;
  UnitBytes: QWord;
begin
  UnitBytes := QWord(1) shl Shift;
  Units := QWord(Available) shr Shift;
  PromisedUnits := (QWord(Promised) + UnitBytes - 1) shr Shift;
  if PromisedUnits > Units then
    Units := PromisedUnits;
  if Units > UnscaledWindowLimit then
    Units := UnscaledWindowLimit;
  Result := Word(Units);
end;

function WindowFromField(Field: Word; Shift: Byte): LongWord;
begin
  Result := LongWord(QWord(Field) shl Shift);
end;

function GrowTo(Capacity, Target, Limit: LongWord): LongWord;
var
  Size: QWord;
begin
  if Target <= Capacity then
    Exit(Capacity);
  Size := Capacity;
  if Size < MinimumBufferBytes then
    Size := MinimumBufferBytes;
  while (Size < Target) and (Size < Limit) do
    Size := Size * 2;
  if Size > Limit then
    Size := Limit;
  if Size < Capacity then
    Size := Capacity;
  Result := LongWord(Size);
end;

function TargetOf(Bytes: QWord): LongWord;
begin
  Bytes := Bytes * 4;
  if Bytes > High(LongWord) then
    Bytes := High(LongWord);
  Result := LongWord(Bytes);
end;

function TunedReceiveBuffer(Capacity, BytesPerRoundTrip, Limit: LongWord): LongWord;
begin
  { Twice what a round trip carries, twice again for the sender to
    grow into. }
  Result := GrowTo(Capacity, TargetOf(BytesPerRoundTrip), Limit);
end;

function TunedSendBuffer(Capacity, CongestionWindow, PeerWindow, Limit: LongWord): LongWord;
var
  Window: QWord;
begin
  Window := CongestionWindow;
  if PeerWindow < Window then
    Window := PeerWindow;
  Window := Window * 2;
  if Window > High(LongWord) then
    Window := High(LongWord);
  Result := GrowTo(Capacity, LongWord(Window), Limit);
end;

end.
