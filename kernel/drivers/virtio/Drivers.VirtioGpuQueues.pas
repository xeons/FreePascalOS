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
  A virtio GPU's two queues: commands and their answers on the control
  queue, cursor commands on the cursor queue.

  Control commands go in batches: each is begun in a slot of its own (a
  page: the request at its start, the answer after it, each slot two
  descriptors), then the batch is sent with one notification and waited
  for until every answer is in. The device carries out a queue's
  commands in order, so a batch can copy a rectangle to the host and
  then show it. The wait sleeps on an event the queue interrupt signals
  (MSI-X, through a deferred call), looking again every few
  milliseconds; without interrupts, or while waking from suspend, it
  polls.

  Cursor commands are not answered: each takes one of a few small
  slots, offered and notified at once; a slot is free again when the
  device has used it.

  A batch not answered within two seconds marks the device failed: its
  queue can no longer be trusted, so nothing more is sent until waking
  from suspend resets it.

  The caller holds the device's lock around a batch or a cursor command.
}
unit Drivers.VirtioGpuQueues;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  Kernel.Events,
  Kernel.PriorityBoosts,
  Kernel.DeferredCalls,
  Drivers.VirtioPci,
  Drivers.VirtioGpuProtocol;

const
  GpuCommandSlots = 8;
  GpuCursorSlots = 16;
  { The request's room at the start of a slot's page; the answer has the
    rest. }
  GpuRequestRoom = 1024;
  GpuAnswerRoom = 4096 - GpuRequestRoom;
  GpuCursorCommandRoom = 64;

type
  PGpuDevice = ^TGpuDevice;
  TGpuDevice = record
    Virtio: TVirtioDevice;
    ControlQueue: TVirtqueue;
    CursorQueue: TVirtqueue;
    CommandSlotCount: LongInt;
    SlotPages: array[0..GpuCommandSlots - 1] of PByte;
    SlotPhysical: array[0..GpuCommandSlots - 1] of QWord;
    { The commands begun in the batch being made. }
    BatchCount: LongInt;
    CursorSlotCount: LongInt;
    CursorPage: PByte;
    CursorPagePhysical: QWord;
    CursorSlotBusy: array[0..GpuCursorSlots - 1] of Boolean;
    Lock: TMutex;
    Completion: TDeferredCall;
    Answered: TEvent;
    { Waking from suspend: no sleeping. }
    PollOnly: Boolean;
    HasEdid: Boolean;
    NextResourceId: LongWord;
    { A batch was not answered in time: the queue cannot be trusted, so
      nothing more is sent (until waking resets the device). }
    Failed: Boolean;
  end;

{ Sets up both queues of a device that is open with its features
  agreed, and its interrupt; then starts it. False if it cannot be used. }
function SetUpGpuQueues(Device: PGpuDevice): Boolean;
{ After waking: resets the device and gives it its queues again. }
function RestartGpuQueues(Device: PGpuDevice): Boolean;
{ Begins a command of RequestBytes in the next slot: the request,
  zeroed with its type set, to fill in; nil when the batch is full. }
function BeginGpuCommand(Device: PGpuDevice; CommandType: LongWord; RequestBytes: LongWord): Pointer;
{ Sends the batch and waits for every answer; True if each is an OK_*
  answer. The batch is empty again either way. }
function RunGpuCommands(Device: PGpuDevice): Boolean;
{ The answer to command Index (from 0) of the batch run last. }
function GpuAnswer(Device: PGpuDevice; Index: LongInt): Pointer;
{ Sends a cursor command (not waited for). }
function SendGpuCursorCommand(Device: PGpuDevice; const Command: TGpuUpdateCursor): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Memory.Layout,
  Memory.PhysicalPages;

const
  AnswerTimeoutMilliseconds = 2000;
  SleepMilliseconds = 5;
  AnswerOkFirst = $1100;
  AnswerOkLast = $11FF;

procedure SignalAnswered(Context: Pointer);
begin
  { A display wait: the waiter gets the display boost. }
  SignalEventWithBoost(PGpuDevice(Context)^.Answered, BoostDisplay);
end;

procedure HandleGpuInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  QueueDeferredCall(PGpuDevice(Context)^.Completion);
end;

function AllocatePage(out Physical: QWord): PByte;
begin
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit(nil);
  Result := PByte(PhysicalToVirtual(Physical));
end;

function SetUpGpuQueues(Device: PGpuDevice): Boolean;
var
  Index: LongInt;
  Queues: array[0..1] of PVirtqueue;
begin
  Result := False;
  if not SetUpVirtqueue(Device^.Virtio, GpuControlQueue, Device^.ControlQueue) or
     not SetUpVirtqueue(Device^.Virtio, GpuCursorQueue, Device^.CursorQueue) then
    Exit;
  Device^.CommandSlotCount := Device^.ControlQueue.Size div 2;
  if Device^.CommandSlotCount > GpuCommandSlots then
    Device^.CommandSlotCount := GpuCommandSlots;
  Device^.CursorSlotCount := Device^.CursorQueue.Size;
  if Device^.CursorSlotCount > GpuCursorSlots then
    Device^.CursorSlotCount := GpuCursorSlots;
  if (Device^.CommandSlotCount < 2) or (Device^.CursorSlotCount < 1) then
    Exit;
  for Index := 0 to Device^.CommandSlotCount - 1 do
  begin
    Device^.SlotPages[Index] := AllocatePage(Device^.SlotPhysical[Index]);
    if Device^.SlotPages[Index] = nil then
      Exit;
  end;
  Device^.CursorPage := AllocatePage(Device^.CursorPagePhysical);
  if Device^.CursorPage = nil then
    Exit;
  InitializeMutex(Device^.Lock);
  InitializeEvent(Device^.Answered, EventKindSynchronization, False);
  InitializeDeferredCall(Device^.Completion, @SignalAnswered, Device);
  Device^.NextResourceId := 1;
  Queues[0] := @Device^.ControlQueue;
  Queues[1] := @Device^.CursorQueue;
  ConnectVirtioQueuesInterrupt(Device^.Virtio, @Queues[0], 2, False, @HandleGpuInterrupt, Device);
  StartVirtioDevice(Device^.Virtio);
  Result := True;
end;

function RestartGpuQueues(Device: PGpuDevice): Boolean;
var
  Queues: array[0..1] of PVirtqueue;
  Index: LongInt;
begin
  Queues[0] := @Device^.ControlQueue;
  Queues[1] := @Device^.CursorQueue;
  Device^.BatchCount := 0;
  for Index := 0 to GpuCursorSlots - 1 do
    Device^.CursorSlotBusy[Index] := False;
  Result := RestartVirtioDeviceQueues(Device^.Virtio, @Queues[0], 2);
  Device^.Failed := not Result;
end;

function BeginGpuCommand(Device: PGpuDevice; CommandType: LongWord; RequestBytes: LongWord): Pointer;
var
  Slot: LongInt;
  Request: PByte;
  Request0: PVirtqueueDescriptor;
  Answer: PVirtqueueDescriptor;
begin
  if (Device^.BatchCount >= Device^.CommandSlotCount) or (RequestBytes > GpuRequestRoom) or
     (RequestBytes < SizeOf(TGpuHeader)) then
    Exit(nil);
  Slot := Device^.BatchCount;
  Request := Device^.SlotPages[Slot];
  FillMemory(Request, 4096, 0);
  PLongWord(Request)^ := CommandType;
  Request0 := @Device^.ControlQueue.Descriptors[Slot * 2];
  Answer := @Device^.ControlQueue.Descriptors[Slot * 2 + 1];
  Request0^.Address := Device^.SlotPhysical[Slot];
  Request0^.Length := RequestBytes;
  Request0^.Flags := VirtqueueDescriptorNext;
  Request0^.Next := Word(Slot * 2 + 1);
  Answer^.Address := Device^.SlotPhysical[Slot] + GpuRequestRoom;
  Answer^.Length := GpuAnswerRoom;
  Answer^.Flags := VirtqueueDescriptorWrite;
  Answer^.Next := 0;
  Inc(Device^.BatchCount);
  Result := Request;
end;

function GpuAnswer(Device: PGpuDevice; Index: LongInt): Pointer;
begin
  Result := Device^.SlotPages[Index] + GpuRequestRoom;
end;

{ Takes finished chains off the used ring until Count were taken. }
function WaitForAnswers(Device: PGpuDevice; Count: LongInt): Boolean;
var
  Deadline: QWord;
  Head: Word;
  Length: LongWord;
  Taken: LongInt;
begin
  Taken := 0;
  Deadline := ClockTickCount + MillisecondsToTicks(AnswerTimeoutMilliseconds);
  while Taken < Count do
  begin
    if TakeVirtqueueUsedChain(Device^.ControlQueue, Head, Length) then
    begin
      Inc(Taken);
      Continue;
    end;
    if ClockTickCount > Deadline then
      Exit(False);
    if Device^.Virtio.UsesInterrupts and not Device^.PollOnly then
      WaitForEventWithOptions(Device^.Answered, SleepMilliseconds, False)
    else
      CpuRelax;
  end;
  Result := True;
end;

function RunGpuCommands(Device: PGpuDevice): Boolean;
var
  Index: LongInt;
  Count: LongInt;
  AnswerType: LongWord;
begin
  Count := Device^.BatchCount;
  Device^.BatchCount := 0;
  if Device^.Failed then
    Exit(False);
  if Count = 0 then
    Exit(True);
  for Index := 0 to Count - 1 do
    OfferVirtqueueChain(Device^.ControlQueue, Word(Index * 2));
  NotifyVirtqueue(Device^.ControlQueue);
  Result := WaitForAnswers(Device, Count);
  if not Result then
  begin
    Device^.Failed := True;
    Exit;
  end;
  for Index := 0 to Count - 1 do
  begin
    AnswerType := PLongWord(GpuAnswer(Device, Index))^;
    if (AnswerType < AnswerOkFirst) or (AnswerType > AnswerOkLast) then
      Result := False;
  end;
end;

procedure ReclaimCursorSlots(Device: PGpuDevice);
var
  Head: Word;
  Length: LongWord;
begin
  while TakeVirtqueueUsedChain(Device^.CursorQueue, Head, Length) do
    if Head < GpuCursorSlots then
      Device^.CursorSlotBusy[Head] := False;
end;

function FreeCursorSlot(Device: PGpuDevice): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Device^.CursorSlotCount - 1 do
    if not Device^.CursorSlotBusy[Index] then
      Exit(Index);
  Result := -1;
end;

function SendGpuCursorCommand(Device: PGpuDevice; const Command: TGpuUpdateCursor): Boolean;
var
  Slot: LongInt;
  Deadline: QWord;
  Descriptor: PVirtqueueDescriptor;
begin
  if Device^.Failed then
    Exit(False);
  ReclaimCursorSlots(Device);
  Slot := FreeCursorSlot(Device);
  Deadline := ClockTickCount + MillisecondsToTicks(AnswerTimeoutMilliseconds);
  while Slot < 0 do
  begin
    if ClockTickCount > Deadline then
    begin
      Device^.Failed := True;
      Exit(False);
    end;
    CpuRelax;
    ReclaimCursorSlots(Device);
    Slot := FreeCursorSlot(Device);
  end;
  CopyMemory(Device^.CursorPage + Slot * GpuCursorCommandRoom, @Command, SizeOf(Command));
  Descriptor := @Device^.CursorQueue.Descriptors[Slot];
  Descriptor^.Address := Device^.CursorPagePhysical + QWord(Slot) * GpuCursorCommandRoom;
  Descriptor^.Length := SizeOf(Command);
  Descriptor^.Flags := 0;
  Descriptor^.Next := 0;
  Device^.CursorSlotBusy[Slot] := True;
  OfferVirtqueueChain(Device^.CursorQueue, Word(Slot));
  NotifyVirtqueue(Device^.CursorQueue);
  Result := True;
end;

end.
