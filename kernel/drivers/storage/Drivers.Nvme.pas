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
  NVMe controllers (PCI class 01h, subclass 08h, interface 02h).

  Starting a controller: disable it, give it an admin queue pair, enable
  it, identify it (model, largest transfer) and its namespaces, then
  create one I/O queue pair (Drivers.NvmeQueues). Admin commands are
  polled; I/O commands complete by MSI-X or MSI interrupt (finished by a
  deferred call), or are polled if neither works.

  Each active namespace becomes a disk of its logical block size and a
  device object of the driver "nvme". Data goes through bounce pages of
  the controller's own, up to BouncePageCount pages (and no more than the
  controller's largest transfer) per command; longer requests are split.
  Pages are described to the controller with PRP entries: the first page
  in PRP1, the second in PRP2, or a list of the rest in a PRP list page.

  One command is in flight per controller; requests for all its
  namespaces wait in one queue.

  A controller that does not answer may only fail requests, never hand
  one request another's data: only the completion carrying the
  identifier of the command waited for counts (Drivers.NvmeQueues), and
  a command that times out (polled, or noticed by a timer when
  interrupt driven) resets the controller (disabled, its queues emptied
  and given to it again) before its bounce pages are used for anything
  else, which ends whatever it still had. The interrupt driven reset
  runs in a thread of its own (the timer's call runs at dispatch level,
  and a reset waits for the controller); requests wait meanwhile.

  All memory the controller reaches (queues, bounce pages, PRP list,
  identify data) is its DMA memory (Io.Dma, shared: uncached for a
  controller that does not snoop), handed over at bus addresses: behind
  the Pi 5's PCIe bridge those differ from physical ones.

  Discard requests become Dataset Management commands with the
  deallocate attribute, one range each, on controllers that report the
  command (ONCS bit 2).
}
unit Drivers.Nvme;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every NVMe controller on PCI; returns how many disks it found. }
function InitializeNvmeControllers: Integer;

implementation

uses
  Io.PowerManagement,
  Runtime.Memory,
  Runtime.Text,
  Runtime.Atomic,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.DeferredCalls,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Timers,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Processes.Thread,
  Io.Dma,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.PlatformDevices,
  Io.Manager,
  Io.BlockDevice,
  Drivers.NvmeQueues,
  Drivers.NvmeQueueMemory,
  Debug.Output;

const
  PciInterfaceNvme = $02;
  PageBytes = 4096;
  BouncePageCount = 32;
  MaximumNamespaces = 8;
  AdminTimeoutMilliseconds = 5000;
  IoTimeoutMilliseconds = 5000;

  RegisterCapabilities = $00;
  RegisterConfiguration = $14;
  RegisterStatus = $1C;
  RegisterAdminQueueAttributes = $24;
  RegisterAdminSubmissionQueue = $28;
  RegisterAdminCompletionQueue = $30;

  ConfigurationEnable = $1;
  { 64-byte commands, 16-byte completions (log2 in bits 16 and 20). }
  ConfigurationQueueEntrySizes = (6 shl 16) or (4 shl 20);
  StatusReady = $1;
  StatusFatal = $2;

  AdminCreateSubmissionQueue = $01;
  AdminCreateCompletionQueue = $05;
  AdminIdentify = $06;
  AdminSetFeatures = $09;
  FeatureNumberOfQueues = $07;
  IdentifyNamespace = 0;
  IdentifyController = 1;
  IdentifyActiveNamespaces = 2;

  CommandFlush = $00;
  CommandWrite = $01;
  CommandRead = $02;
  CommandDatasetManagement = $09;
  DatasetManagementDeallocate = $4;
  { Blocks one range of a Dataset Management command may cover. }
  LargestDeallocateBlocks = $FFFFFFFF;

  QueuePhysicallyContiguous = $1;
  QueueInterruptsEnabled = $2;

type
  PNvmeController = ^TNvmeController;

  PNvmeNamespace = ^TNvmeNamespace;
  TNvmeNamespace = record
    Controller: PNvmeController;
    Identifier: LongWord;
    BlockSize: LongWord;
    BlockCount: QWord;
    Device: PDeviceObject;
  end;

  TNvmeController = record
    Pci: PPciDevice;
    { What its DMA reaches and whether it snoops (Io.Dma). }
    Dma: TDmaAttributes;
    Registers: PByte;
    DoorbellStride: LongWord;
    Admin: TNvmeQueuePair;
    Io: TNvmeQueuePair;
    { Bytes per command: the bounce pages, or less if the controller
      says so. }
    MaximumTransfer: QWord;
    { The controller takes Dataset Management (deallocate). }
    SupportsDeallocate: Boolean;
    Model: array[0..40] of Char;
    { Bus addresses, as the controller is given them. }
    ScratchPage: PByte;
    ScratchPageBusAddress: QWord;
    PrpListPage: PQWord;
    PrpListPageBusAddress: QWord;
    BouncePages: array[0..BouncePageCount - 1] of PByte;
    BouncePagesBusAddress: array[0..BouncePageCount - 1] of QWord;
    UsesInterrupts: Boolean;
    { Interrupt driven requests. }
    StateLock: TSpinLock;
    Waiting: TRequestQueue;
    Current: PIoRequest;
    CurrentNamespace: PNvmeNamespace;
    CurrentDone: QWord;
    CurrentPiece: QWord;
    { The command in flight: its identifier and when it is overdue. }
    CurrentIdentifier: Word;
    CurrentDeadline: QWord;
    FinishCommand: TDeferredCall;
    Timeout: TTimer;
    TimeoutCall: TDeferredCall;
    { A command timed out: the recovery thread resets the controller;
      nothing is submitted or taken meanwhile. }
    Recovering: Boolean;
    RecoveryNeeded: TEvent;
    { Polled requests. }
    PollingLock: TMutex;
  end;

var
  NvmeDriver: PDriverObject;

{ --- Registers ------------------------------------------------------------- }

function ReadRegister32(Controller: PNvmeController; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Controller^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteRegister32(Controller: PNvmeController; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Controller^.Registers + Offset)^ := Value;
end;

procedure WriteRegister64(Controller: PNvmeController; Offset: LongWord; Value: QWord);
begin
  WriteRegister32(Controller, Offset, LongWord(Value));
  WriteRegister32(Controller, Offset + 4, LongWord(Value shr 32));
end;

function ReadCapabilities(Controller: PNvmeController): QWord;
begin
  Result := QWord(ReadRegister32(Controller, RegisterCapabilities)) or
    (QWord(ReadRegister32(Controller, RegisterCapabilities + 4)) shl 32);
end;

{ Waits for the ready bit to become Ready, as long as the controller's
  timeout (500 ms units) allows. }
function WaitForReady(Controller: PNvmeController; Ready: Boolean): Boolean;
var
  Deadline: QWord;
  Timeout: QWord;
  Status: LongWord;
begin
  Timeout := ((ReadCapabilities(Controller) shr 24) and $FF) * 500 + 500;
  Deadline := ClockTickCount + MillisecondsToTicks(Timeout);
  repeat
    Status := ReadRegister32(Controller, RegisterStatus);
    if (Status and StatusFatal) <> 0 then
      Exit(False);
    if ((Status and StatusReady) <> 0) = Ready then
      Exit(True);
    CpuRelax;
  until ClockTickCount > Deadline;
  Result := False;
end;

{ --- Admin commands --------------------------------------------------------- }

procedure ClearCommand(out Command: TNvmeCommand);
begin
  FillMemory(@Command, SizeOf(Command), 0);
end;

{ An admin command, polled. }
function RunAdminCommand(Controller: PNvmeController; var Command: TNvmeCommand): Boolean;
var
  TimedOut: Boolean;
begin
  Result := ExecuteCommand(Controller^.Admin, Command, AdminTimeoutMilliseconds, TimedOut);
end;

function Identify(Controller: PNvmeController; Kind, NamespaceId: LongWord): Boolean;
var
  Command: TNvmeCommand;
begin
  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminIdentify;
  Command.NamespaceId := NamespaceId;
  Command.DataPointer1 := Controller^.ScratchPageBusAddress;
  Command.CommandDword10 := Kind;
  Result := RunAdminCommand(Controller, Command);
end;

function CreateIoQueues(Controller: PNvmeController): Boolean;
var
  Command: TNvmeCommand;
begin
  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminSetFeatures;
  Command.CommandDword10 := FeatureNumberOfQueues;
  Command.CommandDword11 := 0; { one submission and one completion queue }
  RunAdminCommand(Controller, Command);

  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminCreateCompletionQueue;
  Command.DataPointer1 := Controller^.Io.CompletionsBusAddress;
  Command.CommandDword10 := (LongWord(NvmeQueueEntries - 1) shl 16) or Controller^.Io.Identifier;
  { Interrupt vector 0: the only MSI vector, or MSI-X table entry 0. }
  Command.CommandDword11 := QueuePhysicallyContiguous or QueueInterruptsEnabled;
  if not RunAdminCommand(Controller, Command) then
    Exit(False);

  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminCreateSubmissionQueue;
  Command.DataPointer1 := Controller^.Io.SubmissionsBusAddress;
  Command.CommandDword10 := (LongWord(NvmeQueueEntries - 1) shl 16) or Controller^.Io.Identifier;
  Command.CommandDword11 := (LongWord(Controller^.Io.Identifier) shl 16) or QueuePhysicallyContiguous;
  Result := RunAdminCommand(Controller, Command);
end;

{ --- I/O commands ------------------------------------------------------------ }

function PieceLength(Controller: PNvmeController; Request: PIoRequest; Done: QWord): QWord;
var
  Namespace: PNvmeNamespace;
begin
  Result := Request^.Length - Done;
  if Request^.Operation = IoFunctionDiscard then
  begin
    { No data moves: only the range's length is limited. }
    Namespace := PNvmeNamespace(Request^.Device^.Extension);
    if Result div Namespace^.BlockSize > LargestDeallocateBlocks then
      Result := LargestDeallocateBlocks * Namespace^.BlockSize;
    Exit;
  end;
  if Result > Controller^.MaximumTransfer then
    Result := Controller^.MaximumTransfer;
end;

{ A Dataset Management command deallocating Piece bytes at Offset: its
  one range goes in the first bounce page. }
procedure BuildDeallocate(Controller: PNvmeController; Namespace: PNvmeNamespace; Offset, Piece: QWord;
  var Command: TNvmeCommand);
var
  Range: PLongWord;
  FirstBlock: QWord;
begin
  FirstBlock := Offset div Namespace^.BlockSize;
  Range := PLongWord(Controller^.BouncePages[0]);
  ZeroMemory(Range, 16);
  { Context attributes, length in blocks, starting block. }
  Range[1] := LongWord(Piece div Namespace^.BlockSize);
  PQWord(@Range[2])^ := FirstBlock;
  Command.OpcodeAndIdentifier := CommandDatasetManagement;
  Command.CommandDword10 := 0;
  Command.CommandDword11 := DatasetManagementDeallocate;
  Command.DataPointer1 := Controller^.BouncePagesBusAddress[0];
end;

{ Submits the command for Piece bytes of Request, Done bytes in; returns
  its identifier. }
function SubmitPiece(Controller: PNvmeController; Namespace: PNvmeNamespace; Request: PIoRequest;
  Done, Piece: QWord): Word;
var
  Command: TNvmeCommand;
  PageCount: Integer;
  PageIndex: Integer;
  Chunk: QWord;
  FirstBlock: QWord;
begin
  ClearCommand(Command);
  Command.NamespaceId := Namespace^.Identifier;
  PageCount := Integer((Piece + PageBytes - 1) div PageBytes);
  if Request^.Operation = IoFunctionFlush then
    Command.OpcodeAndIdentifier := CommandFlush
  else if Request^.Operation = IoFunctionDiscard then
    BuildDeallocate(Controller, Namespace, Request^.Offset + Done, Piece, Command)
  else
  begin
    if Request^.Operation = IoFunctionWrite then
    begin
      Command.OpcodeAndIdentifier := CommandWrite;
      for PageIndex := 0 to PageCount - 1 do
      begin
        Chunk := Piece - QWord(PageIndex) * PageBytes;
        if Chunk > PageBytes then
          Chunk := PageBytes;
        CopyMemory(Controller^.BouncePages[PageIndex],
          PByte(Request^.Buffer) + Done + QWord(PageIndex) * PageBytes, Chunk);
      end;
    end
    else
      Command.OpcodeAndIdentifier := CommandRead;
    FirstBlock := (Request^.Offset + Done) div Namespace^.BlockSize;
    Command.CommandDword10 := LongWord(FirstBlock);
    Command.CommandDword11 := LongWord(FirstBlock shr 32);
    Command.CommandDword12 := LongWord(Piece div Namespace^.BlockSize - 1);
    Command.DataPointer1 := Controller^.BouncePagesBusAddress[0];
    if PageCount = 2 then
      Command.DataPointer2 := Controller^.BouncePagesBusAddress[1]
    else if PageCount > 2 then
    begin
      for PageIndex := 1 to PageCount - 1 do
        Controller^.PrpListPage[PageIndex - 1] := Controller^.BouncePagesBusAddress[PageIndex];
      Command.DataPointer2 := Controller^.PrpListPageBusAddress;
    end;
  end;
  Result := SubmitCommand(Controller^.Io, Command);
end;

procedure CopyReadData(Controller: PNvmeController; Request: PIoRequest; Done, Piece: QWord);
var
  PageIndex: Integer;
  Chunk: QWord;
begin
  if Request^.Operation <> IoFunctionRead then
    Exit;
  PageIndex := 0;
  while QWord(PageIndex) * PageBytes < Piece do
  begin
    Chunk := Piece - QWord(PageIndex) * PageBytes;
    if Chunk > PageBytes then
      Chunk := PageBytes;
    CopyMemory(PByte(Request^.Buffer) + Done + QWord(PageIndex) * PageBytes,
      Controller^.BouncePages[PageIndex], Chunk);
    Inc(PageIndex);
  end;
end;

{ --- Recovery ------------------------------------------------------------------ }

function ResetController(Controller: PNvmeController): Boolean; forward;

procedure ReportReset(Controller: PNvmeController; Succeeded: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('nvme');
  DebugWrite(@Controller^.Model[0]);
  if Succeeded then
    DebugWriteLine(': a command timed out; the controller was reset')
  else
    DebugWriteLine(': a command timed out; the controller could not be reset');
  DebugEndMessage;
end;

{ --- Polled requests ------------------------------------------------------- }

function TransferPolled(Namespace: PNvmeNamespace; var Request: TIoRequest): LongInt;
var
  Controller: PNvmeController;
  Done: QWord;
  Piece: QWord;
  Status: Word;
  Identifier: Word;
  Deadline: QWord;
  Finished: Boolean;
begin
  Controller := Namespace^.Controller;
  Result := ErrorNone;
  Done := 0;
  AcquireMutex(Controller^.PollingLock);
  repeat
    Piece := PieceLength(Controller, @Request, Done);
    Identifier := SubmitPiece(Controller, Namespace, @Request, Done, Piece);
    Deadline := ClockTickCount + MillisecondsToTicks(IoTimeoutMilliseconds);
    repeat
      Finished := TakeCompletionFor(Controller^.Io, Identifier, Status);
      if not Finished then
        CpuRelax;
    until Finished or (ClockTickCount > Deadline);
    if not Finished then
    begin
      { Ends the command before the bounce pages are used again. }
      ReportReset(Controller, ResetController(Controller));
      Result := ErrorIo;
      Break;
    end;
    if Status <> 0 then
    begin
      Result := ErrorIo;
      Break;
    end;
    CopyReadData(Controller, @Request, Done, Piece);
    Done := Done + Piece;
  until Done >= Request.Length;
  ReleaseMutex(Controller^.PollingLock);
  Request.Information := Int64(Done);
end;

{ --- Interrupt driven requests ---------------------------------------------- }

{ Submits the current request's next piece and arms the timeout. Caller
  holds StateLock. }
procedure SubmitCurrentPieceLocked(Controller: PNvmeController);
begin
  Controller^.CurrentIdentifier := SubmitPiece(Controller, Controller^.CurrentNamespace, Controller^.Current,
    Controller^.CurrentDone, Controller^.CurrentPiece);
  Controller^.CurrentDeadline := ClockTickCount + MillisecondsToTicks(IoTimeoutMilliseconds);
  SetTimer(Controller^.Timeout, IoTimeoutMilliseconds, Controller^.TimeoutCall);
end;

{ Caller holds StateLock. }
procedure BeginRequestLocked(Controller: PNvmeController; Request: PIoRequest);
begin
  Controller^.Current := Request;
  Controller^.CurrentNamespace := PNvmeNamespace(Request^.Device^.Extension);
  Controller^.CurrentDone := 0;
  Controller^.CurrentPiece := PieceLength(Controller, Request, 0);
  SubmitCurrentPieceLocked(Controller);
end;

procedure FinishCommand(Context: Pointer);
var
  Controller: PNvmeController;
  Request: PIoRequest;
  Status: Word;
  Outcome: LongInt;
  PreviousLevel: TPriorityLevel;
begin
  Controller := PNvmeController(Context);
  PreviousLevel := AcquireSpinLock(Controller^.StateLock);
  Request := Controller^.Current;
  { Only the current command's own completion counts; others (late ones
    of a command given up) are dropped. }
  if (Request = nil) or Controller^.Recovering or
     not TakeCompletionFor(Controller^.Io, Controller^.CurrentIdentifier, Status) then
  begin
    ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
    Exit;
  end;
  CancelTimer(Controller^.Timeout);
  if Status = 0 then
  begin
    CopyReadData(Controller, Request, Controller^.CurrentDone, Controller^.CurrentPiece);
    Controller^.CurrentDone := Controller^.CurrentDone + Controller^.CurrentPiece;
    if Controller^.CurrentDone < Request^.Length then
    begin
      Controller^.CurrentPiece := PieceLength(Controller, Request, Controller^.CurrentDone);
      SubmitCurrentPieceLocked(Controller);
      ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
      Exit;
    end;
    Outcome := ErrorNone;
  end
  else
    Outcome := ErrorIo;
  Request^.Information := Int64(Controller^.CurrentDone);
  Controller^.Current := TakeQueuedRequest(Controller^.Waiting);
  if Controller^.Current <> nil then
    BeginRequestLocked(Controller, Controller^.Current);
  ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
  CompleteRequest(Request^, Outcome);
end;

{ Timer call: the current command is overdue (it may have finished
  meanwhile, or the timer been set again for a later piece). }
procedure HandleCommandTimeout(Context: Pointer);
var
  Controller: PNvmeController;
  PreviousLevel: TPriorityLevel;
  Overdue: Boolean;
begin
  Controller := PNvmeController(Context);
  PreviousLevel := AcquireSpinLock(Controller^.StateLock);
  Overdue := (Controller^.Current <> nil) and not Controller^.Recovering and
    (ClockTickCount >= Controller^.CurrentDeadline);
  if Overdue then
    Controller^.Recovering := True
  else if (Controller^.Current <> nil) and not Controller^.Recovering then
    SetTimer(Controller^.Timeout, IoTimeoutMilliseconds div 5, Controller^.TimeoutCall);
  ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
  if Overdue then
    SignalEvent(Controller^.RecoveryNeeded);
end;

{ The recovery thread: resets the controller after a timeout, fails the
  request that timed out and starts the next one. }
procedure RunNvmeRecovery(Context: Pointer);
var
  Controller: PNvmeController;
  PreviousLevel: TPriorityLevel;
  Request: PIoRequest;
  Done: QWord;
begin
  Controller := PNvmeController(Context);
  while True do
  begin
    WaitForEventWithOptions(Controller^.RecoveryNeeded, InfiniteTimeout, False);
    ReportReset(Controller, ResetController(Controller));
    PreviousLevel := AcquireSpinLock(Controller^.StateLock);
    Request := Controller^.Current;
    Done := Controller^.CurrentDone;
    Controller^.Recovering := False;
    Controller^.Current := TakeQueuedRequest(Controller^.Waiting);
    if Controller^.Current <> nil then
      BeginRequestLocked(Controller, Controller^.Current);
    ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
    if Request <> nil then
    begin
      Request^.Information := Int64(Done);
      CompleteRequest(Request^, ErrorIo);
    end;
  end;
end;

procedure HandleNvmeInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  QueueDeferredCall(PNvmeController(Context)^.FinishCommand);
end;

function TransferWithInterrupts(Controller: PNvmeController; var Request: TIoRequest): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := StatusPending;
  PreviousLevel := AcquireSpinLock(Controller^.StateLock);
  if (Controller^.Current = nil) and not Controller^.Recovering then
    BeginRequestLocked(Controller, @Request)
  else if not QueueRequest(Controller^.Waiting, Request) then
    Result := ErrorInterrupted;
  ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
end;

{ --- The driver -------------------------------------------------------------- }

function RequestIsValid(Namespace: PNvmeNamespace; var Request: TIoRequest): Boolean;
begin
  if Request.Operation = IoFunctionFlush then
    Exit(Request.Length = 0);
  Result := (Request.Length > 0) and (Request.Length mod Namespace^.BlockSize = 0) and
    (Request.Offset mod Namespace^.BlockSize = 0) and
    (Request.Offset div Namespace^.BlockSize < Namespace^.BlockCount) and
    (Request.Length div Namespace^.BlockSize <= Namespace^.BlockCount - Request.Offset div Namespace^.BlockSize);
end;

function TransferNvme(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Namespace: PNvmeNamespace;
begin
  Namespace := PNvmeNamespace(Device^.Extension);
  if not RequestIsValid(Namespace, Request) then
    Exit(ErrorInvalidArgument);
  if Namespace^.Controller^.UsesInterrupts then
    Result := TransferWithInterrupts(Namespace^.Controller, Request)
  else
    Result := TransferPolled(Namespace, Request);
end;

procedure CreateNvmeDriver;
var
  Dispatch: TDispatchTable;
begin
  if NvmeDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferNvme;
  Dispatch[IoFunctionWrite] := @TransferNvme;
  Dispatch[IoFunctionFlush] := @TransferNvme;
  Dispatch[IoFunctionDiscard] := @TransferNvme;
  NvmeDriver := CreateDriver('nvme', Dispatch);
end;

{ --- Starting a controller ---------------------------------------------------- }

{ A page of the controller's DMA memory (shared: uncached if it does
  not snoop, so no cache maintenance is needed around transfers). }
function AllocatePage(Controller: PNvmeController; out BusAddress: QWord): Pointer;
var
  Buffer: TDmaBuffer;
begin
  BusAddress := 0;
  if not AllocateDmaBuffer(Controller^.Dma, PageBytes, DmaShared, Buffer) then
    Exit(nil);
  BusAddress := Buffer.DeviceAddress;
  Result := Buffer.Address;
end;

function AllocateControllerPages(Controller: PNvmeController): Boolean;
var
  Index: Integer;
begin
  Controller^.ScratchPage := PByte(AllocatePage(Controller, Controller^.ScratchPageBusAddress));
  Controller^.PrpListPage := PQWord(AllocatePage(Controller, Controller^.PrpListPageBusAddress));
  Result := (Controller^.ScratchPage <> nil) and (Controller^.PrpListPage <> nil);
  for Index := 0 to BouncePageCount - 1 do
  begin
    Controller^.BouncePages[Index] := PByte(AllocatePage(Controller, Controller^.BouncePagesBusAddress[Index]));
    if Controller^.BouncePages[Index] = nil then
      Result := False;
  end;
end;

{ Disables the controller, gives it the admin queue and enables it. }
function ProgramAdminQueue(Controller: PNvmeController): Boolean;
begin
  WriteRegister32(Controller, RegisterConfiguration, 0);
  if not WaitForReady(Controller, False) then
    Exit(False);
  WriteRegister32(Controller, RegisterAdminQueueAttributes,
    (LongWord(NvmeQueueEntries - 1) shl 16) or (NvmeQueueEntries - 1));
  WriteRegister64(Controller, RegisterAdminSubmissionQueue, Controller^.Admin.SubmissionsBusAddress);
  WriteRegister64(Controller, RegisterAdminCompletionQueue, Controller^.Admin.CompletionsBusAddress);
  WriteRegister32(Controller, RegisterConfiguration, ConfigurationQueueEntrySizes or ConfigurationEnable);
  Result := WaitForReady(Controller, True);
end;

function EnableController(Controller: PNvmeController): Boolean;
var
  Capabilities: QWord;
begin
  Capabilities := ReadCapabilities(Controller);
  Controller^.DoorbellStride := LongWord(4) shl ((Capabilities shr 32) and $F);
  if not AllocateQueuePair(Controller^.Dma, 0, Controller^.Registers, Controller^.DoorbellStride,
       Controller^.Admin) or
     not AllocateQueuePair(Controller^.Dma, 1, Controller^.Registers, Controller^.DoorbellStride,
       Controller^.Io) then
    Exit(False);
  Result := ProgramAdminQueue(Controller);
end;

{ --- Suspend to RAM ---------------------------------------------------------- }

const
  ConfigurationShutdownNormal = LongWord(1) shl 14;
  StatusShutdownMask = LongWord(3) shl 2;
  StatusShutdownComplete = LongWord(2) shl 2;
  ShutdownTimeoutMilliseconds = 2000;

{ Block I/O is stopped (nothing in flight): the controller is told it is
  being turned off, so it writes out what it caches. }
procedure SuspendController(Context: Pointer);
var
  Controller: PNvmeController;
  Deadline: QWord;
begin
  Controller := PNvmeController(Context);
  WriteRegister32(Controller, RegisterConfiguration,
    ReadRegister32(Controller, RegisterConfiguration) or ConfigurationShutdownNormal);
  Deadline := ClockTickCount + MillisecondsToTicks(ShutdownTimeoutMilliseconds);
  while ((ReadRegister32(Controller, RegisterStatus) and StatusShutdownMask) <> StatusShutdownComplete) and
        (ClockTickCount < Deadline) do
    CpuRelax;
end;

{ Empty queues, the admin queue (disabling the controller first, which
  ends every command it had), then the I/O queues again (the namespaces
  and everything else are still known). }
function ResetController(Controller: PNvmeController): Boolean;
begin
  WriteRegister32(Controller, RegisterConfiguration, 0);
  WaitForReady(Controller, False);
  ResetQueuePair(Controller^.Admin);
  ResetQueuePair(Controller^.Io);
  Result := ProgramAdminQueue(Controller) and CreateIoQueues(Controller);
end;

{ Waking reset it: set up again as after a timeout. }
procedure ResumeController(Context: Pointer);
begin
  ResetController(PNvmeController(Context));
end;

procedure ReadControllerIdentity(Controller: PNvmeController);
const
  ModelOffset = 24;
  ModelLength = 40;
  MaximumTransferOffset = 77;
  OptionalCommandsOffset = 520;
  OptionalDatasetManagement = $4;
var
  Index: Integer;
  Exponent: Byte;
  ControllerLimit: QWord;
begin
  for Index := 0 to ModelLength - 1 do
    Controller^.Model[Index] := Char(Controller^.ScratchPage[ModelOffset + Index]);
  Index := ModelLength;
  while (Index > 0) and (Controller^.Model[Index - 1] in [' ', #0]) do
    Dec(Index);
  Controller^.Model[Index] := #0;
  Controller^.SupportsDeallocate :=
    (PWord(Controller^.ScratchPage + OptionalCommandsOffset)^ and OptionalDatasetManagement) <> 0;
  Controller^.MaximumTransfer := BouncePageCount * PageBytes;
  Exponent := Controller^.ScratchPage[MaximumTransferOffset];
  if (Exponent <> 0) and (Exponent < 20) then
  begin
    ControllerLimit := (QWord(1) shl Exponent) * PageBytes;
    if ControllerLimit < Controller^.MaximumTransfer then
      Controller^.MaximumTransfer := ControllerLimit;
  end;
end;

{ Creates the disk of namespace NamespaceId if it is usable. }
function AddNamespace(Controller: PNvmeController; NamespaceId: LongWord): Boolean;
const
  SizeOffset = 0;
  FormattedLbaSizeOffset = 26;
  LbaFormatsOffset = 128;
var
  Namespace: PNvmeNamespace;
  FormatIndex: Byte;
  DataSizeExponent: Byte;
  BlockDevice: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := False;
  if not Identify(Controller, IdentifyNamespace, NamespaceId) then
    Exit;
  Namespace := PNvmeNamespace(AllocateZeroedKernelMemory(SizeOf(TNvmeNamespace)));
  if Namespace = nil then
    Exit;
  Namespace^.Controller := Controller;
  Namespace^.Identifier := NamespaceId;
  Namespace^.BlockCount := PQWord(Controller^.ScratchPage + SizeOffset)^;
  FormatIndex := Controller^.ScratchPage[FormattedLbaSizeOffset] and $F;
  DataSizeExponent := Controller^.ScratchPage[LbaFormatsOffset + FormatIndex * 4 + 2];
  if (Namespace^.BlockCount = 0) or (DataSizeExponent < 9) or (DataSizeExponent > 12) then
  begin
    FreeKernelMemory(Namespace);
    Exit;
  end;
  Namespace^.BlockSize := LongWord(1) shl DataSizeExponent;

  Namespace^.Device := CreateDevice(NvmeDriver, nil, DeviceKindBlock, 0, 0);
  if Namespace^.Device = nil then
    Exit;
  Namespace^.Device^.Extension := Namespace;
  Namespace^.Device^.SizeInBytes := Namespace^.BlockCount * Namespace^.BlockSize;
  GenerateDiskName(@Name[0]);
  BlockDevice := CreateBlockDevice(@Name[0]);
  if BlockDevice = nil then
    Exit;
  CopyText(@BlockDevice^.Model[0], @Controller^.Model[0], BlockDeviceModelLength);
  BlockDevice^.BlockSize := Namespace^.BlockSize;
  BlockDevice^.BlockCount := Namespace^.BlockCount;
  BlockDevice^.StorageDevice := Namespace^.Device;
  BlockDevice^.SupportsDiscard := Controller^.SupportsDeallocate;
  BlockDevice^.MaximumDiscardBlocks := LargestDeallocateBlocks;
  RegisterBlockDevice(BlockDevice);
  WriteBlockDeviceDescription(BlockDevice);
  Result := True;
end;

procedure ReportController(Controller: PNvmeController; DiskCount: Integer);
begin
  DebugBeginMessage;
  DebugWriteTag('nvme');
  DebugWrite(@Controller^.Model[0]);
  DebugWrite(': ');
  DebugWriteDecimal(DiskCount);
  DebugWrite(' namespaces, ');
  DebugWriteDecimal(Controller^.MaximumTransfer div 1024);
  if Controller^.UsesInterrupts then
    DebugWrite(' KiB per command, interrupts')
  else
    DebugWrite(' KiB per command, polled');
  if Controller^.SupportsDeallocate then
    DebugWrite(', deallocates');
  DebugWriteLine('');
  DebugEndMessage;
end;

function StartController(Pci: PPciDevice): Integer;
var
  Controller: PNvmeController;
  Bar: TPciBar;
  NamespaceList: array[0..MaximumNamespaces - 1] of LongWord;
  Index: Integer;
begin
  Result := 0;
  if not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort then
    Exit;
  Controller := PNvmeController(AllocateZeroedKernelMemory(SizeOf(TNvmeController)));
  if Controller = nil then
    Exit;
  Controller^.Pci := Pci;
  GetPciDmaAttributes(Pci, Controller^.Dma);
  PciEnableDevice(Pci, True);
  Controller^.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  InitializeSpinLock(Controller^.StateLock);
  InitializeMutex(Controller^.PollingLock);
  InitializeRequestQueue(Controller^.Waiting);
  InitializeDeferredCall(Controller^.FinishCommand, @FinishCommand, Controller);
  InitializeTimer(Controller^.Timeout);
  InitializeDeferredCall(Controller^.TimeoutCall, @HandleCommandTimeout, Controller);
  InitializeEvent(Controller^.RecoveryNeeded, EventKindSynchronization, False);
  if (Controller^.Registers = nil) or not AllocateControllerPages(Controller) or
     not EnableController(Controller) or not Identify(Controller, IdentifyController, 0) then
    Exit;
  ReadControllerIdentity(Controller);
  if not CreateIoQueues(Controller) then
    Exit;
  { Interrupt driven requests need the recovery thread (else they are
    polled, and recovered from in place). }
  if CreateSystemThread(@RunNvmeRecovery, Controller, DefaultThreadPriority + 4, 'NvmeRecovery', False) <> nil then
    Controller^.UsesInterrupts := ConnectPciInterrupt(Pci, @HandleNvmeInterrupt, Controller) <> PciInterruptNone;

  if not Identify(Controller, IdentifyActiveNamespaces, 0) then
    Exit;
  { The scratch page is reused by each namespace's identify. }
  CopyMemory(@NamespaceList[0], Controller^.ScratchPage, SizeOf(NamespaceList));
  for Index := 0 to MaximumNamespaces - 1 do
    if (NamespaceList[Index] <> 0) and AddNamespace(Controller, NamespaceList[Index]) then
      Inc(Result);
  ReportController(Controller, Result);
  RegisterPowerHandler('NVMe', PowerStageDevices, @SuspendController, @ResumeController, Controller);
end;

function InitializeNvmeControllers: Integer;
var
  Index: Integer;
begin
  Result := 0;
  Index := FindPciDeviceByClass(PciClassMassStorage, PciSubclassNvm, PciInterfaceNvme, 0);
  while Index >= 0 do
  begin
    CreateNvmeDriver;
    Result := Result + StartController(PciDeviceAt(Index));
    Index := FindPciDeviceByClass(PciClassMassStorage, PciSubclassNvm, PciInterfaceNvme, Index + 1);
  end;
end;

end.
