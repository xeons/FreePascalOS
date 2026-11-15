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
  Kernel.Clock,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.Manager,
  Io.BlockDevice,
  Drivers.NvmeQueues,
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
    Registers: PByte;
    DoorbellStride: LongWord;
    Admin: TNvmeQueuePair;
    Io: TNvmeQueuePair;
    { Bytes per command: the bounce pages, or less if the controller
      says so. }
    MaximumTransfer: QWord;
    Model: array[0..40] of Char;
    ScratchPage: PByte;
    ScratchPagePhysical: QWord;
    PrpListPage: PQWord;
    PrpListPagePhysical: QWord;
    BouncePages: array[0..BouncePageCount - 1] of PByte;
    BouncePagesPhysical: array[0..BouncePageCount - 1] of QWord;
    UsesInterrupts: Boolean;
    { Interrupt driven requests. }
    StateLock: TSpinLock;
    Waiting: TRequestQueue;
    Current: PIoRequest;
    CurrentNamespace: PNvmeNamespace;
    CurrentDone: QWord;
    CurrentPiece: QWord;
    FinishCommand: TDeferredCall;
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

function Identify(Controller: PNvmeController; Kind, NamespaceId: LongWord): Boolean;
var
  Command: TNvmeCommand;
begin
  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminIdentify;
  Command.NamespaceId := NamespaceId;
  Command.DataPointer1 := Controller^.ScratchPagePhysical;
  Command.CommandDword10 := Kind;
  Result := ExecuteCommand(Controller^.Admin, Command, AdminTimeoutMilliseconds);
end;

function CreateIoQueues(Controller: PNvmeController): Boolean;
var
  Command: TNvmeCommand;
begin
  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminSetFeatures;
  Command.CommandDword10 := FeatureNumberOfQueues;
  Command.CommandDword11 := 0; { one submission and one completion queue }
  ExecuteCommand(Controller^.Admin, Command, AdminTimeoutMilliseconds);

  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminCreateCompletionQueue;
  Command.DataPointer1 := Controller^.Io.CompletionsPhysical;
  Command.CommandDword10 := (LongWord(NvmeQueueEntries - 1) shl 16) or Controller^.Io.Identifier;
  { Interrupt vector 0: the only MSI vector, or MSI-X table entry 0. }
  Command.CommandDword11 := QueuePhysicallyContiguous or QueueInterruptsEnabled;
  if not ExecuteCommand(Controller^.Admin, Command, AdminTimeoutMilliseconds) then
    Exit(False);

  ClearCommand(Command);
  Command.OpcodeAndIdentifier := AdminCreateSubmissionQueue;
  Command.DataPointer1 := Controller^.Io.SubmissionsPhysical;
  Command.CommandDword10 := (LongWord(NvmeQueueEntries - 1) shl 16) or Controller^.Io.Identifier;
  Command.CommandDword11 := (LongWord(Controller^.Io.Identifier) shl 16) or QueuePhysicallyContiguous;
  Result := ExecuteCommand(Controller^.Admin, Command, AdminTimeoutMilliseconds);
end;

{ --- I/O commands ------------------------------------------------------------ }

function PieceLength(Controller: PNvmeController; Request: PIoRequest; Done: QWord): QWord;
begin
  Result := Request^.Length - Done;
  if Result > Controller^.MaximumTransfer then
    Result := Controller^.MaximumTransfer;
end;

{ Submits the command for Piece bytes of Request, Done bytes in. }
procedure SubmitPiece(Controller: PNvmeController; Namespace: PNvmeNamespace; Request: PIoRequest;
  Done, Piece: QWord);
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
    Command.DataPointer1 := Controller^.BouncePagesPhysical[0];
    if PageCount = 2 then
      Command.DataPointer2 := Controller^.BouncePagesPhysical[1]
    else if PageCount > 2 then
    begin
      for PageIndex := 1 to PageCount - 1 do
        Controller^.PrpListPage[PageIndex - 1] := Controller^.BouncePagesPhysical[PageIndex];
      Command.DataPointer2 := Controller^.PrpListPagePhysical;
    end;
  end;
  SubmitCommand(Controller^.Io, Command);
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

{ --- Polled requests ------------------------------------------------------- }

function TransferPolled(Namespace: PNvmeNamespace; var Request: TIoRequest): LongInt;
var
  Controller: PNvmeController;
  Done: QWord;
  Piece: QWord;
  Status: Word;
  Deadline: QWord;
  Finished: Boolean;
begin
  Controller := Namespace^.Controller;
  Result := ErrorNone;
  Done := 0;
  AcquireMutex(Controller^.PollingLock);
  repeat
    Piece := PieceLength(Controller, @Request, Done);
    SubmitPiece(Controller, Namespace, @Request, Done, Piece);
    Deadline := ClockTickCount + MillisecondsToTicks(IoTimeoutMilliseconds);
    repeat
      Finished := TakeCompletion(Controller^.Io, Status);
      if not Finished then
        CpuRelax;
    until Finished or (ClockTickCount > Deadline);
    if not Finished or (Status <> 0) then
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

{ Caller holds StateLock. }
procedure BeginRequestLocked(Controller: PNvmeController; Request: PIoRequest);
begin
  Controller^.Current := Request;
  Controller^.CurrentNamespace := PNvmeNamespace(Request^.Device^.Extension);
  Controller^.CurrentDone := 0;
  Controller^.CurrentPiece := PieceLength(Controller, Request, 0);
  SubmitPiece(Controller, Controller^.CurrentNamespace, Request, 0, Controller^.CurrentPiece);
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
  if (Request = nil) or not TakeCompletion(Controller^.Io, Status) then
  begin
    ReleaseSpinLock(Controller^.StateLock, PreviousLevel);
    Exit;
  end;
  if Status = 0 then
  begin
    CopyReadData(Controller, Request, Controller^.CurrentDone, Controller^.CurrentPiece);
    Controller^.CurrentDone := Controller^.CurrentDone + Controller^.CurrentPiece;
    if Controller^.CurrentDone < Request^.Length then
    begin
      Controller^.CurrentPiece := PieceLength(Controller, Request, Controller^.CurrentDone);
      SubmitPiece(Controller, Controller^.CurrentNamespace, Request, Controller^.CurrentDone,
        Controller^.CurrentPiece);
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
  if Controller^.Current = nil then
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
  NvmeDriver := CreateDriver('nvme', Dispatch);
end;

{ --- Starting a controller ---------------------------------------------------- }

function AllocatePage(out Physical: QWord): Pointer;
begin
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit(nil);
  Result := PhysicalToVirtual(Physical);
end;

function AllocateControllerPages(Controller: PNvmeController): Boolean;
var
  Index: Integer;
begin
  Controller^.ScratchPage := PByte(AllocatePage(Controller^.ScratchPagePhysical));
  Controller^.PrpListPage := PQWord(AllocatePage(Controller^.PrpListPagePhysical));
  Result := (Controller^.ScratchPage <> nil) and (Controller^.PrpListPage <> nil);
  for Index := 0 to BouncePageCount - 1 do
  begin
    Controller^.BouncePages[Index] := PByte(AllocatePage(Controller^.BouncePagesPhysical[Index]));
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
  WriteRegister64(Controller, RegisterAdminSubmissionQueue, Controller^.Admin.SubmissionsPhysical);
  WriteRegister64(Controller, RegisterAdminCompletionQueue, Controller^.Admin.CompletionsPhysical);
  WriteRegister32(Controller, RegisterConfiguration, ConfigurationQueueEntrySizes or ConfigurationEnable);
  Result := WaitForReady(Controller, True);
end;

function EnableController(Controller: PNvmeController): Boolean;
var
  Capabilities: QWord;
begin
  Capabilities := ReadCapabilities(Controller);
  Controller^.DoorbellStride := LongWord(4) shl ((Capabilities shr 32) and $F);
  if not AllocateQueuePair(0, Controller^.Registers, Controller^.DoorbellStride, Controller^.Admin) or
     not AllocateQueuePair(1, Controller^.Registers, Controller^.DoorbellStride, Controller^.Io) then
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

{ Waking reset it: empty queues, the admin queue, then the I/O queues
  again (the namespaces and everything else are still known). }
procedure ResumeController(Context: Pointer);
var
  Controller: PNvmeController;
begin
  Controller := PNvmeController(Context);
  ResetQueuePair(Controller^.Admin);
  ResetQueuePair(Controller^.Io);
  if ProgramAdminQueue(Controller) then
    CreateIoQueues(Controller);
end;

procedure ReadControllerIdentity(Controller: PNvmeController);
const
  ModelOffset = 24;
  ModelLength = 40;
  MaximumTransferOffset = 77;
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
    DebugWriteLine(' KiB per command, interrupts')
  else
    DebugWriteLine(' KiB per command, polled');
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
  PciEnableDevice(Pci, True);
  Controller^.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  InitializeSpinLock(Controller^.StateLock);
  InitializeMutex(Controller^.PollingLock);
  InitializeRequestQueue(Controller^.Waiting);
  InitializeDeferredCall(Controller^.FinishCommand, @FinishCommand, Controller);
  if (Controller^.Registers = nil) or not AllocateControllerPages(Controller) or
     not EnableController(Controller) or not Identify(Controller, IdentifyController, 0) then
    Exit;
  ReadControllerIdentity(Controller);
  if not CreateIoQueues(Controller) then
    Exit;
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
