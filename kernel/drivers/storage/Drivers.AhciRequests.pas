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
  AHCI requests: the driver object "ahci" and its disk devices.

  Every disk gets a device object without a name; the block device layer
  (Io.BlockDevice) sends it read, write and flush requests.

  Once the controller's interrupt is connected, requests are handled
  asynchronously, several at once. A request gets a free command slot and
  its first command is started; then the routine returns StatusPending.
  On disks with native command queuing, reads and writes are queued
  commands (READ/WRITE FPDMA QUEUED), up to the disk's queue depth at
  once; everything else - flushes, and every command on disks without
  NCQ - runs alone. Data moves straight to and from the request's pages;
  a buffer the kernel cannot translate (or an odd address) goes through
  the port's bounce buffer, which one command uses at a time. Requests
  that find no slot wait in a queue.

  When commands finish the port interrupts; the interrupt handler only
  notes the port's interrupt status and queues the port's deferred call,
  which looks at every running slot: a finished command's request gets
  its next piece started (a command moves at most 64 KiB) or completes,
  and waiting requests take the free slots.

  Commands have a deadline (5 s). A command that failed or is past its
  deadline fails every request running on the port with ErrorIo (which
  of several queued commands failed is not looked into), once the port
  was reset (RecoverPort) by the port's recovery thread: resetting
  waits for the controller (up to seconds), which the deferred call may
  not do at dispatch level, and the requests' buffers stay the
  controller's until the port stopped. Nothing else starts meanwhile; a
  port that did not come back fails later requests at once.

  Discard requests become DATA SET MANAGEMENT commands with TRIM on
  disks that report it: the ranges (up to 64 of 65535 sectors) go in
  one 512-byte block in the bounce buffer, and the command runs alone.

  ATAPI devices (optical drives) are read with SCSI READ(10) commands in
  ATAPI packets, one at a time; they cannot be written, and have nothing
  to flush.

  Before the interrupt is connected (while disks are identified), or if
  the controller has no MSI, commands are polled one at a time on slot 0
  and requests complete before the routine returns.
}
unit Drivers.AhciRequests;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Arch.TrapFrame,
  Io.Manager,
  Drivers.AhciPort;

{ Creates the driver object; called once, before the first disk. }
procedure CreateAhciDriver;
{ Creates Port's device object (Port^.Device). False if memory is short. }
function CreateAhciDevice(Port: PAhciPort): Boolean;
{ Switches Port to interrupt driven requests; its interrupts must be on. }
procedure UseInterruptsForPort(Port: PAhciPort);
{ The controller's interrupt handler; Context is the PAhciController. }
procedure HandleAhciInterrupt(Frame: PTrapFrame; Context: Pointer);

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Arch.PageTables,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Mutex,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Clock,
  Kernel.Events,
  Kernel.Threads,
  Io.Dma,
  Kernel.Scheduler,
  Processes.Thread,
  Debug.Output;

const
  PortInterruptErrors = PortInterruptInterfaceFatal or PortInterruptHostBusData or
    PortInterruptHostBusFatal or PortInterruptTaskFileError;

var
  AhciDriver: PDriverObject;

function PortOf(Device: PDeviceObject): PAhciPort;
begin
  Result := PAhciPort(Device^.Extension);
end;

function PieceLength(Port: PAhciPort; Request: PIoRequest; Done: QWord): QWord;
begin
  Result := Request^.Length - Done;
  if Request^.Operation = IoFunctionDiscard then
  begin
    if Result div Port^.BlockSize > TrimRangesPerCommand * TrimSectorsPerRange then
      Result := QWord(TrimRangesPerCommand * TrimSectorsPerRange) * Port^.BlockSize;
    Exit;
  end;
  if Result > MaximumBytesPerCommand then
    Result := MaximumBytesPerCommand - MaximumBytesPerCommand mod Port^.BlockSize;
end;

function RequestIsValid(Port: PAhciPort; var Request: TIoRequest): Boolean;
begin
  { A flush moves no data: one command without a transfer. }
  if Request.Operation = IoFunctionFlush then
    Exit(Request.Length = 0);
  if (Request.Operation = IoFunctionDiscard) and not Port^.SupportsTrim then
    Exit(False);
  Result := (Request.Length > 0) and (Request.Length mod Port^.BlockSize = 0) and
    (Request.Offset mod Port^.BlockSize = 0) and
    (Request.Offset div Port^.BlockSize < Port^.BlockCount) and
    (Request.Length div Port^.BlockSize <= Port^.BlockCount - Request.Offset div Port^.BlockSize);
end;

procedure ReportRecovery(Port: PAhciPort; Reason: PChar; Recovered: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('ahci');
  DebugWrite('Port ');
  DebugWriteDecimal(Port^.PortNumber);
  DebugWrite(': ');
  DebugWrite(Reason);
  if Recovered then
    DebugWriteLine(', port reset')
  else
    DebugWriteLine(', the port did not come back');
  DebugEndMessage;
end;

{ --- TRIM ------------------------------------------------------------------ }

{ Writes the TRIM ranges for ByteCount bytes at Offset into the first
  bounce page: one 512-byte block of 48-bit LBAs with 16-bit counts. }
procedure FillTrimRanges(Port: PAhciPort; Offset, ByteCount: QWord);
var
  Ranges: PQWord;
  Lba: QWord;
  Remaining: QWord;
  Count: QWord;
  Index: Integer;
begin
  Ranges := PQWord(BounceBufferStart(Port));
  ZeroMemory(Ranges, 512);
  Lba := Offset div Port^.BlockSize;
  Remaining := ByteCount div Port^.BlockSize;
  Index := 0;
  while (Remaining > 0) and (Index < TrimRangesPerCommand) do
  begin
    Count := Remaining;
    if Count > TrimSectorsPerRange then
      Count := TrimSectorsPerRange;
    Ranges[Index] := (Lba and QWord($FFFFFFFFFFFF)) or (Count shl 48);
    Lba := Lba + Count;
    Remaining := Remaining - Count;
    Inc(Index);
  end;
end;

{ Builds the TRIM command for the ranges in the bounce buffer in Slot. }
procedure BuildTrimCommand(Port: PAhciPort; Slot: LongWord);
var
  Segments: TDataSegments;
begin
  Segments[0].BusAddress := Port^.BouncePageBuffers[0].DeviceAddress;
  Segments[0].Length := 512;
  BuildCommand(Port, Slot, AtaCommandDataSetManagement, 0, 1, Segments, 1, True, False);
  SetCommandFeatures(Port, Slot, DataSetManagementTrim);
end;

function TrimPolled(Port: PAhciPort; Offset, ByteCount: QWord): Boolean;
begin
  Result := False;
  if not WaitForRegister(Port^.Registers, PortTaskFileData, TaskFileBusy or TaskFileDataRequest, 0,
    CommandTimeoutMilliseconds) then
    Exit;
  FillTrimRanges(Port, Offset, ByteCount);
  BuildTrimCommand(Port, 0);
  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
  IssueSlots(Port, 1, False);
  Result := WaitForCommand(Port);
end;

{ --- Polled requests ------------------------------------------------------ }

function AtaCommandFor(Request: PIoRequest): Byte;
begin
  case Request^.Operation of
    IoFunctionWrite: Result := AtaCommandWriteDmaExtended;
    IoFunctionFlush: Result := AtaCommandFlushCacheExtended;
  else
    Result := AtaCommandReadDmaExtended;
  end;
end;

function ExecuteReadPacket(Port: PAhciPort; Lba, BlockCount, ByteCount: QWord): Boolean;
var
  Packet: TPacket;
begin
  MakeRead10Packet(Packet, LongWord(Lba), Word(BlockCount));
  Result := ExecutePacketCommand(Port, Packet, ByteCount);
end;

function TransferPolled(Port: PAhciPort; var Request: TIoRequest): LongInt;
var
  Done: QWord;
  Piece: QWord;
  IsWrite: Boolean;
  Succeeded: Boolean;
begin
  IsWrite := Request.Operation = IoFunctionWrite;
  Result := ErrorNone;
  Done := 0;
  AcquireMutex(Port^.PollingLock);
  if (Request.Operation = IoFunctionFlush) and
     not ExecuteCommand(Port, AtaCommandFlushCacheExtended, 0, 0, 0, False) then
  begin
    ReportRecovery(Port, 'flush failed', RecoverPort(Port));
    Result := ErrorIo;
  end;
  while (Request.Operation = IoFunctionDiscard) and (Done < Request.Length) do
  begin
    Piece := PieceLength(Port, @Request, Done);
    if not TrimPolled(Port, Request.Offset + Done, Piece) then
    begin
      ReportRecovery(Port, 'TRIM failed', RecoverPort(Port));
      Result := ErrorIo;
      Break;
    end;
    Done := Done + Piece;
  end;
  while (Request.Operation <> IoFunctionDiscard) and (Done < Request.Length) do
  begin
    Piece := PieceLength(Port, @Request, Done);
    if IsWrite then
      CopyToBounceBuffer(Port, PByte(Request.Buffer) + Done, Piece);
    if Port^.IsPacketDevice then
      Succeeded := ExecuteReadPacket(Port, (Request.Offset + Done) div Port^.BlockSize,
        Piece div Port^.BlockSize, Piece)
    else
      Succeeded := ExecuteCommand(Port, AtaCommandFor(@Request), (Request.Offset + Done) div Port^.BlockSize,
        Word(Piece div Port^.BlockSize), Piece, IsWrite);
    if not Succeeded then
    begin
      ReportRecovery(Port, 'command failed', RecoverPort(Port));
      Result := ErrorIo;
      Break;
    end;
    if not IsWrite then
      CopyFromBounceBuffer(Port, PByte(Request.Buffer) + Done, Piece);
    Done := Done + Piece;
  end;
  ReleaseMutex(Port^.PollingLock);
  Request.Information := Int64(Done);
end;

{ --- Building commands ----------------------------------------------------- }

{ The pieces of ByteCount bytes at Buffer as the controller reaches them
  (bus addresses, Io.Dma): one segment per page, pages that follow each
  other merged. False if a page cannot be translated or reached by the
  controller, the address is odd, or there are too many (the bounce
  buffer is used then). }
function DescribeBuffer(Port: PAhciPort; Buffer: PByte; ByteCount: QWord; out Segments: TDataSegments;
  out SegmentCount: Integer): Boolean;
var
  Address: QWord;
  Physical: TPhysicalAddress;
  BusAddress: QWord;
  Chunk: QWord;
begin
  SegmentCount := 0;
  Address := QWord(Buffer);
  if (Address and 1) <> 0 then
    Exit(False);
  while ByteCount > 0 do
  begin
    Chunk := PageSize - (Address and (PageSize - 1));
    if Chunk > ByteCount then
      Chunk := ByteCount;
    if not TranslateVirtualAddress(Address, Physical) or
       not TranslateDmaAddress(Port^.Dma, Physical, Chunk, BusAddress) then
      Exit(False);
    if (SegmentCount > 0) and
       (Segments[SegmentCount - 1].BusAddress + Segments[SegmentCount - 1].Length = BusAddress) then
      Segments[SegmentCount - 1].Length := Segments[SegmentCount - 1].Length + Chunk
    else
    begin
      if SegmentCount = MaximumPrdtEntries then
        Exit(False);
      Segments[SegmentCount].BusAddress := BusAddress;
      Segments[SegmentCount].Length := Chunk;
      Inc(SegmentCount);
    end;
    Address := Address + Chunk;
    ByteCount := ByteCount - Chunk;
  end;
  Result := True;
end;

function BounceSegments(Port: PAhciPort; ByteCount: QWord; out Segments: TDataSegments): Integer;
begin
  Result := 0;
  while ByteCount > 0 do
  begin
    Segments[Result].BusAddress := Port^.BouncePageBuffers[Result].DeviceAddress;
    Segments[Result].Length := ByteCount;
    if Segments[Result].Length > PageSize then
      Segments[Result].Length := PageSize;
    ByteCount := ByteCount - Segments[Result].Length;
    Inc(Result);
  end;
end;

{ True if Request can only run alone on Port. }
function NeedsExclusiveUse(Port: PAhciPort; Request: PIoRequest): Boolean;
begin
  Result := (Port^.QueueDepth = 0) or (Request^.Operation = IoFunctionFlush) or
    (Request^.Operation = IoFunctionDiscard);
end;

function ActiveCount(Port: PAhciPort): LongWord;
var
  Mask: LongWord;
begin
  Result := 0;
  Mask := Port^.ActiveSlots;
  while Mask <> 0 do
  begin
    Inc(Result);
    Mask := Mask and (Mask - 1);
  end;
end;

function FreeSlot(Port: PAhciPort): LongInt;
var
  Slot: LongWord;
begin
  for Slot := 0 to Port^.SlotCount - 1 do
    if (Port^.ActiveSlots and (LongWord(1) shl Slot)) = 0 then
      Exit(Slot);
  Result := -1;
end;

{ Builds and issues the next piece of the request in Slot (Done and
  Piece set). Caller holds StateLock. False if it needs the bounce buffer
  and that is busy (nothing is issued then). }
function IssuePieceLocked(Port: PAhciPort; Slot: LongWord): Boolean;
var
  State: ^TAhciSlot;
  Request: PIoRequest;
  Segments: TDataSegments;
  SegmentCount: Integer;
  Command: Byte;
  IsWrite: Boolean;
  Packet: TPacket;
begin
  State := @Port^.Slots[Slot];
  Request := State^.Request;
  if Request^.Operation = IoFunctionDiscard then
  begin
    { Runs alone, so the bounce buffer is free. }
    if Port^.BounceBusy then
      Exit(False);
    Port^.BounceBusy := True;
    State^.UsesBounce := True;
    FillTrimRanges(Port, Request^.Offset + State^.Done, State^.Piece);
    BuildTrimCommand(Port, Slot);
    State^.Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
    IssueSlots(Port, LongWord(1) shl Slot, False);
    Exit(True);
  end;
  IsWrite := Request^.Operation = IoFunctionWrite;
  State^.UsesBounce := False;
  SegmentCount := 0;
  if (State^.Piece > 0) and
     DescribeBuffer(Port, PByte(Request^.Buffer) + State^.Done, State^.Piece, Segments, SegmentCount) then
  begin
    { Straight to the request's pages: through the caches' maintenance
      for a controller that does not snoop. }
    if IsWrite then
      PrepareDmaToDevice(Port^.Dma, PByte(Request^.Buffer) + State^.Done, State^.Piece)
    else
      PrepareDmaFromDevice(Port^.Dma, PByte(Request^.Buffer) + State^.Done, State^.Piece);
  end
  else if State^.Piece > 0 then
  begin
    if Port^.BounceBusy then
      Exit(False);
    Port^.BounceBusy := True;
    State^.UsesBounce := True;
    if IsWrite then
      CopyToBounceBuffer(Port, PByte(Request^.Buffer) + State^.Done, State^.Piece);
    SegmentCount := BounceSegments(Port, State^.Piece, Segments);
  end;

  if Port^.IsPacketDevice then
  begin
    MakeRead10Packet(Packet, LongWord((Request^.Offset + State^.Done) div Port^.BlockSize),
      Word(State^.Piece div Port^.BlockSize));
    BuildPacketCommand(Port, Slot, Packet, Segments, SegmentCount);
  end
  else
  begin
    if State^.Queued then
    begin
      if IsWrite then
        Command := AtaCommandWriteFpdmaQueued
      else
        Command := AtaCommandReadFpdmaQueued;
    end
    else
      Command := AtaCommandFor(Request);
    BuildCommand(Port, Slot, Command, (Request^.Offset + State^.Done) div Port^.BlockSize,
      Word(State^.Piece div Port^.BlockSize), Segments, SegmentCount, IsWrite, State^.Queued);
  end;
  State^.Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
  IssueSlots(Port, LongWord(1) shl Slot, State^.Queued);
  Result := True;
end;

{ Starts Request in a free slot if the port's state allows it. Caller
  holds StateLock. }
function TryStartLocked(Port: PAhciPort; Request: PIoRequest): Boolean;
var
  Slot: LongInt;
  Exclusive: Boolean;
begin
  Result := False;
  if Port^.ExclusiveActive or Port^.CommandFailed or Port^.Recovering then
    Exit;
  Exclusive := NeedsExclusiveUse(Port, Request);
  if Exclusive and (Port^.ActiveSlots <> 0) then
    Exit;
  if not Exclusive and (ActiveCount(Port) >= Port^.QueueDepth) then
    Exit;
  Slot := FreeSlot(Port);
  if Slot < 0 then
    Exit;
  Port^.Slots[Slot].Request := Request;
  Port^.Slots[Slot].Done := 0;
  Port^.Slots[Slot].Piece := PieceLength(Port, Request, 0);
  Port^.Slots[Slot].Queued := not Exclusive;
  if not IssuePieceLocked(Port, Slot) then
    Exit;
  { The first running command arms the timer; it re-arms itself while
    commands run. }
  if Port^.ActiveSlots = 0 then
    SetTimer(Port^.Timeout, CommandTimeoutMilliseconds div 5, Port^.TimeoutCall);
  Port^.ActiveSlots := Port^.ActiveSlots or (LongWord(1) shl Slot);
  Port^.ExclusiveActive := Exclusive;
  if ActiveCount(Port) > Port^.MostActive then
    Port^.MostActive := ActiveCount(Port);
  Result := True;
end;

{ Starts waiting requests while slots allow. Caller holds StateLock. }
procedure StartWaitingLocked(Port: PAhciPort);
begin
  repeat
    if Port^.Held = nil then
      Port^.Held := TakeQueuedRequest(Port^.Waiting);
    if Port^.Held = nil then
      Exit;
    if not TryStartLocked(Port, Port^.Held) then
      Exit;
    Port^.Held := nil;
  until False;
end;

{ --- Finishing commands ----------------------------------------------------- }

type
  TFinishedRequests = record
    Requests: array[0..MaximumSlots - 1] of PIoRequest;
    Statuses: array[0..MaximumSlots - 1] of LongInt;
    Count: Integer;
  end;

procedure NoteFinished(var Finished: TFinishedRequests; Request: PIoRequest; Status: LongInt);
begin
  Finished.Requests[Finished.Count] := Request;
  Finished.Statuses[Finished.Count] := Status;
  Inc(Finished.Count);
end;

procedure ReleaseSlotLocked(Port: PAhciPort; Slot: LongWord);
begin
  if Port^.Slots[Slot].UsesBounce then
    Port^.BounceBusy := False;
  Port^.Slots[Slot].Request := nil;
  Port^.ActiveSlots := Port^.ActiveSlots and not (LongWord(1) shl Slot);
  if Port^.ActiveSlots = 0 then
    Port^.ExclusiveActive := False;
end;

{ Hands the port to its recovery thread. Caller holds StateLock. }
procedure BeginRecoveryLocked(Port: PAhciPort);
begin
  Port^.CommandFailed := False;
  if Port^.Recovering then
    Exit;
  Port^.Recovering := True;
  SignalEvent(Port^.RecoveryNeeded);
end;

{ Fails every running request (the port reset). Caller holds
  StateLock. }
procedure FailAllLocked(Port: PAhciPort; var Finished: TFinishedRequests);
var
  Slot: LongWord;
begin
  Port^.CommandTimedOut := False;
  Port^.CommandFailed := False;
  for Slot := 0 to MaximumSlots - 1 do
    if (Port^.ActiveSlots and (LongWord(1) shl Slot)) <> 0 then
    begin
      Port^.Slots[Slot].Request^.Information := Int64(Port^.Slots[Slot].Done);
      NoteFinished(Finished, Port^.Slots[Slot].Request, ErrorIo);
      ReleaseSlotLocked(Port, Slot);
    end;
end;

{ Handles the slots whose commands the controller has finished. Caller
  holds StateLock. }
procedure CollectFinishedLocked(Port: PAhciPort; var Finished: TFinishedRequests);
var
  Running: LongWord;
  Slot: LongWord;
  State: ^TAhciSlot;
begin
  Running := ReadRegister(Port^.Registers, PortCommandIssue) or
    ReadRegister(Port^.Registers, PortSataActive);
  for Slot := 0 to MaximumSlots - 1 do
  begin
    if ((Port^.ActiveSlots and (LongWord(1) shl Slot)) = 0) or ((Running and (LongWord(1) shl Slot)) <> 0) then
      Continue;
    State := @Port^.Slots[Slot];
    if State^.UsesBounce and (State^.Request^.Operation = IoFunctionRead) then
      CopyFromBounceBuffer(Port, PByte(State^.Request^.Buffer) + State^.Done, State^.Piece)
    else if (State^.Request^.Operation = IoFunctionRead) and (State^.Piece > 0) then
      FinishDmaFromDevice(Port^.Dma, PByte(State^.Request^.Buffer) + State^.Done, State^.Piece);
    if State^.UsesBounce then
    begin
      Port^.BounceBusy := False;
      State^.UsesBounce := False;
    end;
    State^.Done := State^.Done + State^.Piece;
    if State^.Done < State^.Request^.Length then
    begin
      State^.Piece := PieceLength(Port, State^.Request, State^.Done);
      if IssuePieceLocked(Port, Slot) then
        Continue;
      { The bounce buffer is taken: this request fails rather than wait. }
      State^.Request^.Information := Int64(State^.Done);
      NoteFinished(Finished, State^.Request, ErrorIo);
      ReleaseSlotLocked(Port, Slot);
      Continue;
    end;
    State^.Request^.Information := Int64(State^.Done);
    NoteFinished(Finished, State^.Request, ErrorNone);
    ReleaseSlotLocked(Port, Slot);
  end;
end;

function TakeSeenStatus(Port: PAhciPort): LongWord;
begin
  Result := LongWord(AtomicExchange(Port^.SeenInterruptStatus, 0));
end;

{ Deferred call, after the port interrupted (or a command failed to
  start or timed out). }
procedure FinishPortCommands(Context: Pointer);
var
  Port: PAhciPort;
  Seen: LongWord;
  PreviousLevel: TPriorityLevel;
  Finished: TFinishedRequests;
  Index: Integer;
begin
  Port := PAhciPort(Context);
  Finished.Count := 0;
  Seen := TakeSeenStatus(Port);
  PreviousLevel := AcquireSpinLock(Port^.StateLock);
  if Port^.Recovering then
  begin
    { The recovery thread has the port. }
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    Exit;
  end;
  if Port^.ActiveSlots <> 0 then
  begin
    if Port^.CommandFailed or ((Seen and PortInterruptErrors) <> 0) then
    begin
      BeginRecoveryLocked(Port);
      CancelTimer(Port^.Timeout);
      ReleaseSpinLock(Port^.StateLock, PreviousLevel);
      Exit;
    end;
    CollectFinishedLocked(Port, Finished);
  end;
  Port^.CommandFailed := False;
  if Port^.ActiveSlots = 0 then
    CancelTimer(Port^.Timeout);
  StartWaitingLocked(Port);
  ReleaseSpinLock(Port^.StateLock, PreviousLevel);
  { Outside the lock: whoever waits for a request may send the next one
    at once. }
  for Index := 0 to Finished.Count - 1 do
    CompleteRequest(Finished.Requests[Index]^, Finished.Statuses[Index]);
end;

{ Timer call: fails the port's commands if one is past its deadline. }
procedure HandleCommandTimeout(Context: Pointer);
var
  Port: PAhciPort;
  PreviousLevel: TPriorityLevel;
  Now: QWord;
  Slot: LongWord;
  Overdue: Boolean;
  Running: LongWord;
begin
  Port := PAhciPort(Context);
  PreviousLevel := AcquireSpinLock(Port^.StateLock);
  if Port^.Recovering then
  begin
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    Exit;
  end;
  Now := ClockTickCount;
  Overdue := False;
  Running := ReadRegister(Port^.Registers, PortCommandIssue) or
    ReadRegister(Port^.Registers, PortSataActive);
  for Slot := 0 to MaximumSlots - 1 do
    if ((Port^.ActiveSlots and Running and (LongWord(1) shl Slot)) <> 0) and
       (Now >= Port^.Slots[Slot].Deadline) then
      Overdue := True;
  if Overdue then
  begin
    Port^.CommandFailed := True;
    Port^.CommandTimedOut := True;
    QueueDeferredCall(Port^.FinishCommand);
  end
  else if Port^.ActiveSlots <> 0 then
  begin
    { Finished ones (their interrupt is on the way, or was lost) are
      collected too. }
    if (Port^.ActiveSlots and not Running) <> 0 then
      QueueDeferredCall(Port^.FinishCommand);
    SetTimer(Port^.Timeout, CommandTimeoutMilliseconds div 5, Port^.TimeoutCall);
  end;
  ReleaseSpinLock(Port^.StateLock, PreviousLevel);
end;

{ A port that did not come back: every waiting request fails. }
procedure FailWaitingRequests(Port: PAhciPort);
var
  PreviousLevel: TPriorityLevel;
  Request: PIoRequest;
begin
  repeat
    PreviousLevel := AcquireSpinLock(Port^.StateLock);
    Request := TakeQueuedRequest(Port^.Waiting);
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    if Request <> nil then
      CompleteRequest(Request^, ErrorIo);
  until Request = nil;
end;

{ The port's recovery thread: resets the port after a failed or timed
  out command, then fails what was running and starts what waits. }
procedure RunPortRecovery(Context: Pointer);
var
  Port: PAhciPort;
  PreviousLevel: TPriorityLevel;
  Finished: TFinishedRequests;
  Recovered: Boolean;
  TimedOut: Boolean;
  Index: Integer;
begin
  Port := PAhciPort(Context);
  while True do
  begin
    WaitForEventWithOptions(Port^.RecoveryNeeded, InfiniteTimeout, False);
    TimedOut := Port^.CommandTimedOut;
    Recovered := RecoverPort(Port);
    if TimedOut then
      ReportRecovery(Port, 'command timed out', Recovered)
    else
      ReportRecovery(Port, 'command failed', Recovered);
    Finished.Count := 0;
    PreviousLevel := AcquireSpinLock(Port^.StateLock);
    FailAllLocked(Port, Finished);
    Port^.IsDead := not Recovered;
    Port^.Recovering := False;
    if Port^.IsDead then
    begin
      { Everything waiting fails too. }
      if Port^.Held <> nil then
        NoteFinished(Finished, Port^.Held, ErrorIo);
      Port^.Held := nil;
    end
    else
      StartWaitingLocked(Port);
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    for Index := 0 to Finished.Count - 1 do
      CompleteRequest(Finished.Requests[Index]^, Finished.Statuses[Index]);
    if Port^.IsDead then
      FailWaitingRequests(Port);
  end;
end;

function TransferWithInterrupts(Port: PAhciPort; var Request: TIoRequest): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  if Port^.IsDead then
    Exit(ErrorIo);
  Result := StatusPending;
  PreviousLevel := AcquireSpinLock(Port^.StateLock);
  if (Port^.Held <> nil) or not TryStartLocked(Port, @Request) then
    if not QueueRequest(Port^.Waiting, Request) then
      Result := ErrorInterrupted;
  ReleaseSpinLock(Port^.StateLock, PreviousLevel);
end;

procedure HandleAhciInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Controller: PAhciController;
  Pending: LongWord;
  PortNumber: LongWord;
  Port: PAhciPort;
  PortStatus: LongWord;
  Seen: PtrUInt;
begin
  Controller := PAhciController(Context);
  Pending := ReadRegister(Controller^.Registers, RegisterInterruptStatus);
  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    if (Pending and (LongWord(1) shl PortNumber)) = 0 then
      Continue;
    Port := Controller^.Ports[PortNumber];
    if Port = nil then
      Continue;
    PortStatus := ReadRegister(Port^.Registers, PortInterruptStatus);
    WriteRegister(Port^.Registers, PortInterruptStatus, PortStatus);
    repeat
      Seen := AtomicLoad(Port^.SeenInterruptStatus);
    until AtomicCompareExchange(Port^.SeenInterruptStatus, Seen or PortStatus, Seen) = Seen;
    QueueDeferredCall(Port^.FinishCommand);
  end;
  { Port status first: a port whose status is still set would raise the
    controller's bit again. }
  WriteRegister(Controller^.Registers, RegisterInterruptStatus, Pending);
end;

{ --- The driver ------------------------------------------------------------ }

function TransferAhciDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Port: PAhciPort;
begin
  Port := PortOf(Device);
  if not RequestIsValid(Port, Request) then
    Exit(ErrorInvalidArgument);
  if Port^.IsPacketDevice then
    case Request.Operation of
      IoFunctionWrite: Exit(ErrorReadOnly);
      IoFunctionFlush: Exit(ErrorNone);
    end;
  if Port^.InterruptDriven then
    Result := TransferWithInterrupts(Port, Request)
  else
    Result := TransferPolled(Port, Request);
end;

procedure CreateAhciDriver;
var
  Dispatch: TDispatchTable;
begin
  if AhciDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferAhciDevice;
  Dispatch[IoFunctionWrite] := @TransferAhciDevice;
  Dispatch[IoFunctionFlush] := @TransferAhciDevice;
  Dispatch[IoFunctionDiscard] := @TransferAhciDevice;
  AhciDriver := CreateDriver('ahci', Dispatch);
end;

function CreateAhciDevice(Port: PAhciPort): Boolean;
const
  NobodyMayOpen = 0;
begin
  InitializeMutex(Port^.PollingLock);
  InitializeSpinLock(Port^.StateLock);
  InitializeRequestQueue(Port^.Waiting);
  InitializeDeferredCall(Port^.FinishCommand, @FinishPortCommands, Port);
  InitializeTimer(Port^.Timeout);
  InitializeDeferredCall(Port^.TimeoutCall, @HandleCommandTimeout, Port);
  Port^.Device := CreateDevice(AhciDriver, nil, DeviceKindBlock, NobodyMayOpen, 0);
  if Port^.Device = nil then
    Exit(False);
  Port^.Device^.Extension := Port;
  Result := True;
end;

procedure UseInterruptsForPort(Port: PAhciPort);
begin
  InitializeEvent(Port^.RecoveryNeeded, EventKindSynchronization, False);
  { Interrupt driven requests need the recovery thread: without it the
    port keeps polling (and recovers in place). }
  if CreateSystemThread(@RunPortRecovery, Port, DefaultThreadPriority + 4, 'AhciRecovery', False) = nil then
    Exit;
  { Wait for a polled request that is still running. }
  AcquireMutex(Port^.PollingLock);
  Port^.InterruptDriven := True;
  ReleaseMutex(Port^.PollingLock);
end;

end.
