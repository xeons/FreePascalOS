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
  AHCI hardware access: registers, port state and running commands.

  An AHCI controller (the "HBA") has generic registers followed by one
  register block per port. A command is submitted by filling a command
  header and a command table in memory and setting a bit in the port's
  command issue register; the controller then moves data directly to and
  from memory through the physical region descriptor table (PRDT).

  One command slot per port is used, and data always goes through the
  port's bounce buffer of single pages, so the buffers of requests need
  no particular alignment or physical layout. When the command finishes
  the port raises an interrupt, if its interrupts are enabled; otherwise
  the driver polls (WaitForCommand).

  A command that fails or never ends leaves the port stopped with the
  error latched; RecoverPort brings it back as the AHCI specification
  describes: stop the command list, clear the errors, reset the link if
  the device is still busy, and start again.
}
unit Drivers.AhciPort;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout,
  Kernel.Mutex,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Io.Manager;

const
  MaximumPorts = 32;

  { Generic host control registers. }
  RegisterCapabilities = $00;
  RegisterGlobalControl = $04;
  RegisterInterruptStatus = $08;
  RegisterPortsImplemented = $0C;
  RegisterVersion = $10;
  RegisterCapabilities2 = $24;
  RegisterHandoffControl = $28;

  GlobalControlInterruptEnable = LongWord(1) shl 1;
  GlobalControlAhciEnable = LongWord(1) shl 31;
  Capabilities2BiosHandoff = LongWord(1) shl 0;
  HandoffOsOwnership = LongWord(1) shl 1;
  HandoffBiosOwnership = LongWord(1) shl 0;

  { Port registers, relative to the port's register block. }
  PortRegisterBase = $100;
  PortRegisterStride = $80;
  PortCommandListBase = $00;
  PortCommandListBaseUpper = $04;
  PortFisBase = $08;
  PortFisBaseUpper = $0C;
  PortInterruptStatus = $10;
  PortInterruptEnable = $14;
  PortCommand = $18;
  PortTaskFileData = $20;
  PortSignature = $24;
  PortSataStatus = $28;
  PortSataControl = $2C;
  PortSataError = $30;
  PortCommandIssue = $38;

  PortCommandStart = LongWord(1) shl 0;
  PortCommandFisReceiveEnable = LongWord(1) shl 4;
  PortCommandFisReceiveRunning = LongWord(1) shl 14;
  PortCommandListRunning = LongWord(1) shl 15;

  { Port interrupts: a register FIS from the device (how a DMA command
    ends), and the errors. }
  PortInterruptDeviceToHostRegister = LongWord(1) shl 0;
  PortInterruptInterfaceFatal = LongWord(1) shl 27;
  PortInterruptHostBusData = LongWord(1) shl 28;
  PortInterruptHostBusFatal = LongWord(1) shl 29;
  PortInterruptTaskFileError = LongWord(1) shl 30;
  PortInterruptsWanted = PortInterruptDeviceToHostRegister or PortInterruptInterfaceFatal or
    PortInterruptHostBusData or PortInterruptHostBusFatal or PortInterruptTaskFileError;

  TaskFileBusy = $80;
  TaskFileDataRequest = $08;
  TaskFileError = $01;

  { ATA commands. }
  AtaCommandIdentifyDevice = $EC;
  AtaCommandReadDmaExtended = $25;
  AtaCommandWriteDmaExtended = $35;
  AtaCommandFlushCacheExtended = $EA;

  { Layout of the per-port control page. }
  CommandListOffset = $000;  { 32 headers of 32 bytes, 1 KiB aligned }
  ReceivedFisOffset = $400;  { 256 bytes, 256 byte aligned }
  CommandTableOffset = $800; { 128 byte aligned }

  BounceBufferPages = 16;
  MaximumBytesPerCommand = BounceBufferPages * PageSize;

  CommandTimeoutMilliseconds = 5000;
  RegisterTimeoutMilliseconds = 1000;

type
  PAhciPort = ^TAhciPort;
  TAhciPort = record
    Registers: PByte;
    PortNumber: LongWord;
    ControlPagePhysical: QWord;
    ControlPage: PByte;
    BouncePagesPhysical: array[0..BounceBufferPages - 1] of QWord;
    BlockSize: LongWord;
    BlockCount: QWord;
    { The disk's device object (Drivers.AhciRequests). }
    Device: PDeviceObject;

    { Set once the controller's interrupt is connected; before that,
      and on controllers without MSI, commands are polled under
      PollingLock. }
    InterruptDriven: Boolean;
    PollingLock: TMutex;

    { Interrupt driven: the request whose command is running, how much
      of it is done and how big the running piece is; the requests
      waiting for their turn. Guarded by StateLock. }
    StateLock: TSpinLock;
    Current: PIoRequest;
    CurrentDone: QWord;
    CurrentPiece: QWord;
    { The command for Current could not be started or timed out; the
      deferred call fails the request. }
    CommandFailed: Boolean;
    CommandTimedOut: Boolean;
    Waiting: TRequestQueue;
    { Port interrupt status the interrupt handler saw (and cleared) and
      the deferred call has not looked at yet. }
    SeenInterruptStatus: PtrUInt;
    { Runs after the port interrupted. }
    FinishCommand: TDeferredCall;
    { Set while a command runs; its call fails the request if the
      command is still running at CommandDeadline (a clock tick). }
    Timeout: TTimer;
    TimeoutCall: TDeferredCall;
    CommandDeadline: QWord;
    RecoveryCount: QWord;
  end;

  PAhciController = ^TAhciController;
  TAhciController = record
    Registers: PByte;
    Ports: array[0..MaximumPorts - 1] of PAhciPort;
  end;

function ReadRegister(Base: PByte; Offset: LongWord): LongWord;
procedure WriteRegister(Base: PByte; Offset: LongWord; Value: LongWord);
{ Waits until (register and Mask) = Expected. Returns False on timeout. }
function WaitForRegister(Base: PByte; Offset: LongWord; Mask: LongWord; Expected: LongWord;
  TimeoutMilliseconds: QWord): Boolean;

{ Starts one command on slot 0 that moves ByteCount bytes through the
  bounce buffer (written to it beforehand, or read from it afterwards).
  Returns False if the device stayed busy. }
function IssueCommand(Port: PAhciPort; Command: Byte; Lba: QWord; SectorCount: Word;
  ByteCount: QWord; IsWrite: Boolean): Boolean;
{ True while the issued command has neither finished nor failed. }
function CommandIsRunning(Port: PAhciPort): Boolean;
{ After the command stopped running: True if it worked. }
function CommandSucceeded(Port: PAhciPort): Boolean;
{ Polls until the issued command ends; True if it worked. }
function WaitForCommand(Port: PAhciPort): Boolean;
{ IssueCommand and WaitForCommand. }
function ExecuteCommand(Port: PAhciPort; Command: Byte; Lba: QWord; SectorCount: Word;
  ByteCount: QWord; IsWrite: Boolean): Boolean;

{ Brings the port back after a failed or hung command; any command is
  dropped. False if the device does not come back. Spins for up to a
  few seconds, so it is for error paths only. }
function RecoverPort(Port: PAhciPort): Boolean;

procedure CopyFromBounceBuffer(Port: PAhciPort; Destination: PByte; ByteCount: QWord);
procedure CopyToBounceBuffer(Port: PAhciPort; Source: PByte; ByteCount: QWord);

implementation

uses
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Clock;

const
  FisTypeRegisterHostToDevice = $27;
  FisCommandBit = $80;
  DeviceLbaMode = $40;

  PrdtOffsetInTable = $80;

  CommandFisLengthInDoublewords = 5;
  CommandHeaderWrite = LongWord(1) shl 6;

type
  TCommandHeader = record
    Flags: LongWord;            { FIS length, write bit, PRDT length (high 16 bits) }
    BytesTransferred: LongWord;
    TableAddressLow: LongWord;
    TableAddressHigh: LongWord;
    Reserved: array[0..3] of LongWord;
  end;
  PCommandHeader = ^TCommandHeader;

  TPrdtEntry = record
    DataAddressLow: LongWord;
    DataAddressHigh: LongWord;
    Reserved: LongWord;
    ByteCountMinusOne: LongWord;
  end;
  PPrdtEntry = ^TPrdtEntry;

function ReadRegister(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
end;

procedure WriteRegister(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  PLongWord(Base + Offset)^ := Value;
end;

function WaitForRegister(Base: PByte; Offset: LongWord; Mask: LongWord; Expected: LongWord;
  TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while (ReadRegister(Base, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure BuildRegisterFis(Fis: PByte; Command: Byte; Lba: QWord; SectorCount: Word);
begin
  ZeroMemory(Fis, 64);
  Fis[0] := FisTypeRegisterHostToDevice;
  Fis[1] := FisCommandBit;
  Fis[2] := Command;
  Fis[4] := Byte(Lba);
  Fis[5] := Byte(Lba shr 8);
  Fis[6] := Byte(Lba shr 16);
  Fis[7] := DeviceLbaMode;
  Fis[8] := Byte(Lba shr 24);
  Fis[9] := Byte(Lba shr 32);
  Fis[10] := Byte(Lba shr 40);
  Fis[12] := Byte(SectorCount);
  Fis[13] := Byte(SectorCount shr 8);
end;

function IssueCommand(Port: PAhciPort; Command: Byte; Lba: QWord; SectorCount: Word;
  ByteCount: QWord; IsWrite: Boolean): Boolean;
var
  Header: PCommandHeader;
  Table: PByte;
  Prdt: PPrdtEntry;
  TablePhysical: QWord;
  PrdtCount: LongWord;
  RemainingBytes: QWord;
  ChunkBytes: QWord;
  Flags: LongWord;
begin
  Result := False;
  if not WaitForRegister(Port^.Registers, PortTaskFileData, TaskFileBusy or TaskFileDataRequest, 0,
    CommandTimeoutMilliseconds) then
    Exit;

  Table := Port^.ControlPage + CommandTableOffset;
  TablePhysical := Port^.ControlPagePhysical + CommandTableOffset;
  BuildRegisterFis(Table, Command, Lba, SectorCount);

  Prdt := PPrdtEntry(Table + PrdtOffsetInTable);
  PrdtCount := 0;
  RemainingBytes := ByteCount;
  while RemainingBytes > 0 do
  begin
    ChunkBytes := RemainingBytes;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    Prdt[PrdtCount].DataAddressLow := LongWord(Port^.BouncePagesPhysical[PrdtCount]);
    Prdt[PrdtCount].DataAddressHigh := LongWord(Port^.BouncePagesPhysical[PrdtCount] shr 32);
    Prdt[PrdtCount].Reserved := 0;
    Prdt[PrdtCount].ByteCountMinusOne := LongWord(ChunkBytes - 1);
    RemainingBytes := RemainingBytes - ChunkBytes;
    Inc(PrdtCount);
  end;

  Flags := CommandFisLengthInDoublewords or (PrdtCount shl 16);
  if IsWrite then
    Flags := Flags or CommandHeaderWrite;

  Header := PCommandHeader(Port^.ControlPage + CommandListOffset);
  Header^.Flags := Flags;
  Header^.BytesTransferred := 0;
  Header^.TableAddressLow := LongWord(TablePhysical);
  Header^.TableAddressHigh := LongWord(TablePhysical shr 32);

  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
  WriteRegister(Port^.Registers, PortCommandIssue, 1);
  Result := True;
end;

function CommandHasFailed(Port: PAhciPort): Boolean;
begin
  Result := (ReadRegister(Port^.Registers, PortInterruptStatus) and PortInterruptTaskFileError) <> 0;
end;

function CommandIsRunning(Port: PAhciPort): Boolean;
begin
  Result := ((ReadRegister(Port^.Registers, PortCommandIssue) and 1) <> 0) and
    not CommandHasFailed(Port);
end;

function CommandSucceeded(Port: PAhciPort): Boolean;
begin
  Result := ((ReadRegister(Port^.Registers, PortCommandIssue) and 1) = 0) and
    ((ReadRegister(Port^.Registers, PortTaskFileData) and TaskFileError) = 0);
end;

function WaitForCommand(Port: PAhciPort): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
  while CommandIsRunning(Port) do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := (not CommandHasFailed(Port)) and CommandSucceeded(Port);
end;

function ExecuteCommand(Port: PAhciPort; Command: Byte; Lba: QWord; SectorCount: Word;
  ByteCount: QWord; IsWrite: Boolean): Boolean;
begin
  Result := IssueCommand(Port, Command, Lba, SectorCount, ByteCount, IsWrite) and
    WaitForCommand(Port);
end;

const
  SataControlDetectionMask = $0F;
  SataControlResetLink = $01;
  SataStatusDetectionMask = $0F;
  SataStatusDevicePresent = $03;

{ Spins until at least Ticks whole clock ticks have passed. }
procedure SpinForTicks(Ticks: QWord);
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + Ticks + 1;
  while ClockTickCount < Deadline do
    CpuRelax;
end;

{ COMRESET: the link is reset and the device starts afresh. }
procedure ResetLink(Port: PAhciPort);
var
  Control: LongWord;
begin
  Control := ReadRegister(Port^.Registers, PortSataControl) and not SataControlDetectionMask;
  WriteRegister(Port^.Registers, PortSataControl, Control or SataControlResetLink);
  { At least a millisecond. }
  SpinForTicks(1);
  WriteRegister(Port^.Registers, PortSataControl, Control);
  WaitForRegister(Port^.Registers, PortSataStatus, SataStatusDetectionMask,
    SataStatusDevicePresent, RegisterTimeoutMilliseconds);
end;

function RecoverPort(Port: PAhciPort): Boolean;
begin
  Inc(Port^.RecoveryCount);
  WriteRegister(Port^.Registers, PortCommand,
    ReadRegister(Port^.Registers, PortCommand) and not PortCommandStart);
  WaitForRegister(Port^.Registers, PortCommand, PortCommandListRunning, 0,
    RegisterTimeoutMilliseconds);
  WriteRegister(Port^.Registers, PortSataError, $FFFFFFFF);
  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);

  if (ReadRegister(Port^.Registers, PortTaskFileData) and (TaskFileBusy or TaskFileDataRequest)) <> 0 then
  begin
    ResetLink(Port);
    WriteRegister(Port^.Registers, PortSataError, $FFFFFFFF);
    WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
  end;
  Result := WaitForRegister(Port^.Registers, PortTaskFileData, TaskFileBusy or TaskFileDataRequest, 0,
    CommandTimeoutMilliseconds);
  if Result then
    WriteRegister(Port^.Registers, PortCommand,
      ReadRegister(Port^.Registers, PortCommand) or PortCommandStart);
end;

procedure CopyFromBounceBuffer(Port: PAhciPort; Destination: PByte; ByteCount: QWord);
var
  PageIndex: Integer;
  ChunkBytes: QWord;
begin
  PageIndex := 0;
  while ByteCount > 0 do
  begin
    ChunkBytes := ByteCount;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    CopyMemory(Destination, PhysicalToVirtual(Port^.BouncePagesPhysical[PageIndex]), ChunkBytes);
    Destination := Destination + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
    Inc(PageIndex);
  end;
end;

procedure CopyToBounceBuffer(Port: PAhciPort; Source: PByte; ByteCount: QWord);
var
  PageIndex: Integer;
  ChunkBytes: QWord;
begin
  PageIndex := 0;
  while ByteCount > 0 do
  begin
    ChunkBytes := ByteCount;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    CopyMemory(PhysicalToVirtual(Port^.BouncePagesPhysical[PageIndex]), Source, ChunkBytes);
    Source := Source + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
    Inc(PageIndex);
  end;
end;

end.
