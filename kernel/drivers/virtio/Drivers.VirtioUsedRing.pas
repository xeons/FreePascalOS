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
  What a virtio device writes into a split virtqueue's used ring is not
  trusted: an element's id must name a descriptor of the queue (else it
  is skipped, never used as an index) and the length it reports is
  clamped to the buffer the driver gave (a faulty device can never make
  the driver read past it). Also the queue size the driver uses: the
  ring indexes run modulo 65536, so the size must be a power of two.

  No kernel dependencies (tools/VirtioUsedRingTest tests it on the
  host).
}
unit Drivers.VirtioUsedRing;

{$mode objfpc}

interface

{ True if Id names one of the QueueSize descriptors. }
function UsedElementIsInRange(Id: LongWord; QueueSize: Word): Boolean;

{ Length, but never more than BufferBytes. }
function ClampUsedLength(Length: LongWord; BufferBytes: LongWord): LongWord;

{ The bytes after a HeaderBytes header in a buffer of BufferBytes the
  device says it wrote Length bytes into; False if not even the header
  is there. }
function UsedPayloadLength(Length: LongWord; BufferBytes: LongWord; HeaderBytes: LongWord;
  out PayloadLength: LongWord): Boolean;

{ The queue size to use for one the device offers with Offered entries:
  the largest power of two not above Offered or Maximum (0 for none). }
function UsableQueueSize(Offered: Word; Maximum: Word): Word;

implementation

function UsedElementIsInRange(Id: LongWord; QueueSize: Word): Boolean;
begin
  Result := Id < QueueSize;
end;

function ClampUsedLength(Length: LongWord; BufferBytes: LongWord): LongWord;
begin
  Result := Length;
  if Result > BufferBytes then
    Result := BufferBytes;
end;

function UsedPayloadLength(Length: LongWord; BufferBytes: LongWord; HeaderBytes: LongWord;
  out PayloadLength: LongWord): Boolean;
var
  Clamped: LongWord;
begin
  PayloadLength := 0;
  Clamped := ClampUsedLength(Length, BufferBytes);
  Result := Clamped >= HeaderBytes;
  if Result then
    PayloadLength := Clamped - HeaderBytes;
end;

function UsableQueueSize(Offered: Word; Maximum: Word): Word;
var
  Limit: Word;
begin
  Limit := Offered;
  if Maximum < Limit then
    Limit := Maximum;
  Result := 0;
  if Limit = 0 then
    Exit;
  Result := 1;
  while (Result <= Limit div 2) do
    Result := Result * 2;
end;

end.
