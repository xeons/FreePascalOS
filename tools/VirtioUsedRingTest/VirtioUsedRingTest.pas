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
  Host test of the checks on what a virtio device writes into a used
  ring (make virtio-used-ring-test, Drivers.VirtioUsedRing): ids inside
  and outside the queue, lengths clamped to the buffer, a network
  card's frame after its 12-byte header (an empty one, a short one, one
  claiming far more than the buffer holds), and the power-of-two queue
  sizes made from what a device offers.

  Prints every failed check and exits with 1 if there was one.
}
program VirtioUsedRingTest;

{$mode objfpc}

uses
  SysUtils,
  Drivers.VirtioUsedRing;

const
  BufferBytes = 2048;
  NetHeaderBytes = 12;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('VIRTIO USED RING TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  Check(Actual = Expected, What + ' is ' + IntToStr(Actual) + ', expected ' + IntToStr(Expected));
end;

procedure TestIds;
begin
  Check(UsedElementIsInRange(0, 64), 'id 0 of a queue of 64');
  Check(UsedElementIsInRange(63, 64), 'id 63 of a queue of 64');
  Check(not UsedElementIsInRange(64, 64), 'id 64 is past a queue of 64');
  Check(not UsedElementIsInRange($FFFFFFFF, 64), 'an id of all ones');
  Check(not UsedElementIsInRange($10000, 64), 'an id that would wrap to 0 as a Word');
  Check(not UsedElementIsInRange(0, 0), 'no id is in an empty queue');
end;

procedure TestLengths;
begin
  CheckNumber(ClampUsedLength(100, BufferBytes), 100, 'a length inside the buffer');
  CheckNumber(ClampUsedLength(BufferBytes, BufferBytes), BufferBytes, 'a full buffer');
  CheckNumber(ClampUsedLength(BufferBytes + 1, BufferBytes), BufferBytes, 'one byte too many');
  CheckNumber(ClampUsedLength($FFFFFFFF, BufferBytes), BufferBytes, 'a length of all ones');
  CheckNumber(ClampUsedLength(0, BufferBytes), 0, 'nothing written');
end;

procedure TestFrames;
var
  Payload: LongWord;
begin
  Check(UsedPayloadLength(NetHeaderBytes + 60, BufferBytes, NetHeaderBytes, Payload), 'a 60-byte frame');
  CheckNumber(Payload, 60, 'its length');
  Check(UsedPayloadLength(NetHeaderBytes, BufferBytes, NetHeaderBytes, Payload), 'a header alone');
  CheckNumber(Payload, 0, 'a header alone carries nothing');
  Check(not UsedPayloadLength(NetHeaderBytes - 1, BufferBytes, NetHeaderBytes, Payload), 'shorter than the header');
  CheckNumber(Payload, 0, 'nothing of a short one');
  Check(not UsedPayloadLength(0, BufferBytes, NetHeaderBytes, Payload), 'nothing written at all');
  Check(UsedPayloadLength($FFFFFFF0, BufferBytes, NetHeaderBytes, Payload), 'a length far past the buffer');
  CheckNumber(Payload, BufferBytes - NetHeaderBytes, 'clamped to the buffer after the header');
  Check(UsedPayloadLength(NetHeaderBytes + 1514, BufferBytes, NetHeaderBytes, Payload), 'the largest frame');
  CheckNumber(Payload, 1514, 'its length');
end;

procedure TestQueueSizes;
begin
  CheckNumber(UsableQueueSize(256, 64), 64, 'a big queue, limited');
  CheckNumber(UsableQueueSize(64, 64), 64, 'exactly the limit');
  CheckNumber(UsableQueueSize(16, 64), 16, 'a small queue');
  CheckNumber(UsableQueueSize(48, 64), 32, 'not a power of two: rounded down');
  CheckNumber(UsableQueueSize(100, 64), 64, 'not a power of two, past the limit');
  CheckNumber(UsableQueueSize(1, 64), 1, 'one entry');
  CheckNumber(UsableQueueSize(0, 64), 0, 'no queue');
  CheckNumber(UsableQueueSize(65535, 64), 64, 'the largest offer');
  CheckNumber(UsableQueueSize(65535, 65535), 32768, 'the largest offer, no limit');
end;

begin
  TestIds;
  TestLengths;
  TestFrames;
  TestQueueSizes;
  if Failures > 0 then
  begin
    WriteLn('VIRTIO USED RING TEST: ', Failures, ' failed');
    Halt(1);
  end;
  WriteLn('VIRTIO USED RING TEST: all passed');
end.
