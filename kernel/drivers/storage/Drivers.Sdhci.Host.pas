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
  One slot of an SD host controller (SDHCI 2.00 / 3.00): its registers,
  clock, bus power and width, and running commands with or without
  data.

  Registers. Some controllers take only 32-bit accesses (the Arasan
  block of the BCM2835/BCM2711, QuirkRegisters32Bit): a narrower write
  becomes a read-modify-write of its 32-bit word. Registers that act
  when written, or whose bits clear when written with ones, are always
  written whole: block size with block count, transfer mode with the
  command (writing the command starts it), the interrupt status word.
  The same controller loses writes that follow each other within two SD
  clock cycles (QuirkWriteDelay): it gets a pause after each.

  Commands. The command and data lines must be free; the status bits
  collected so far are dropped; the argument, then transfer mode and
  command go out. The wait is for "command complete" (and "transfer
  complete" for a command with busy signalling or data) or an error
  bit. With an interrupt, its handler takes the status bits (writing
  them back clears them) into Pending and a deferred call wakes the
  waiter; without, the waiter reads and clears them itself. An error
  resets the command line (and the data line, for data errors) so the
  next command can go.

  Data moves by ADMA2 (32-bit descriptors) through the host's bounce
  buffer - one physically contiguous streaming DMA buffer below the
  controller's limits (Io.Dma: cleaned before the controller reads it,
  invalidated after it wrote it) - or, without ADMA2 (QuirkNoDma, a
  controller without the capability, or the kernel option "sdhcipio"),
  by the CPU through the buffer data port, a block at a time.
}
unit Drivers.Sdhci.Host;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Arch.TrapFrame,
  Kernel.SpinLock,
  Kernel.Events,
  Kernel.DeferredCalls,
  Io.Dma;

const
  { Quirks. }
  QuirkRegisters32Bit = LongWord(1) shl 0;
  QuirkWriteDelay = LongWord(1) shl 1;
  { The card detect signal is not wired: a card is assumed present. }
  QuirkBrokenCardDetect = LongWord(1) shl 2;
  { Clocking at 50 MHz works but the host control high speed bit must
    stay clear. }
  QuirkNoHighSpeedBit = LongWord(1) shl 3;
  QuirkNoDma = LongWord(1) shl 4;
  { The capabilities name no voltage: 3.3 V. }
  QuirkVoltage33Only = LongWord(1) shl 5;
  { Without a _DMA saying otherwise, DMA reaches only the low 1 GiB
    (the BCM2711's EMMC2 on early chips). }
  QuirkDmaBelow1GiB = LongWord(1) shl 6;
  { The base clock comes from the VideoCore firmware (FirmwareClockId). }
  QuirkClockFromFirmware = LongWord(1) shl 7;

  OptionSdhciPio = 'sdhcipio';

  { The bounce buffer: the most one command moves. }
  SdhciBounceBytes = 128 * 1024;
  { The ADMA2 descriptor table (room for 512 descriptors). }
  AdmaTableBytes = 4096;

  { Clock rates. }
  IdentificationClockHertz = 400000;
  DefaultSpeedClockHertz = 25000000;
  HighSpeedClockHertz = 50000000;

type
  TSdhciQuirks = record
    Flags: LongWord;
    FirmwareClockId: LongWord;
    { Used when neither the firmware nor the capabilities give one. }
    FallbackClockHertz: LongWord;
  end;

  PSdhciHost = ^TSdhciHost;
  TSdhciHost = record
    Registers: PByte;
    Quirks: TSdhciQuirks;
    { The low byte of the host version register. }
    Version: Byte;
    Capabilities: LongWord;
    BaseClockHertz: LongWord;
    ClockHertz: LongWord;
    Dma: TDmaAttributes;
    UsesAdma: Boolean;
    AdmaTable: TDmaBuffer;
    Bounce: TDmaBuffer;
    UsesInterrupts: Boolean;
    { Status bits the interrupt handler took, not yet looked at. }
    Pending: PtrUInt;
    StatusArrived: TEvent;
    WakeWaiter: TDeferredCall;
    { Signaled on card insertion and removal interrupts (CardChangeSeen
      carries them from the handler to its deferred call). }
    CardChanged: TEvent;
    CardChangeSeen: PtrUInt;
    { Status bits the waiter took and has not used yet. }
    Collected: LongWord;
    Response: array[0..3] of LongWord;
    { The last command's failing status bits (for the log). }
    LastError: LongWord;
  end;

{ Reads version and capabilities, resets the slot, chooses how data
  moves (allocating the DMA buffers) and finds the base clock. False if
  the slot does not reset or has no usable clock. Host^.Registers,
  Quirks and Dma are filled in by the caller. }
function InitializeHost(Host: PSdhciHost): Boolean;
{ Turns bus power on at 3.3 V (3.0 V if that is all it has), signals at
  3.3 V, clocks the card for identification and enables the status bits
  (and their interrupt, if UsesInterrupts). }
function PowerUpCard(Host: PSdhciHost): Boolean;
procedure PowerDownCard(Host: PSdhciHost);
{ Programs the card clock at Hertz or the fastest rate below it. }
function SetCardClock(Host: PSdhciHost; Hertz: LongWord): Boolean;
procedure SetFourBitBus(Host: PSdhciHost);
procedure SetHighSpeedTiming(Host: PSdhciHost);

{ Runs a command without data. ResponseKind is CommandResponse* with
  CommandCrcCheck / CommandIndexCheck as the response type needs. The
  response is in Host^.Response. }
function RunCommand(Host: PSdhciHost; Index: Byte; Argument: LongWord; ResponseKind: Word): Boolean;
{ Runs a command that moves BlockCount blocks of BlockSize bytes between
  the card and Buffer (at most SdhciBounceBytes); multiple blocks end
  with an automatic CMD12. }
function RunDataCommand(Host: PSdhciHost; Index: Byte; Argument: LongWord; IsRead: Boolean;
  BlockCount, BlockSize: LongWord; Buffer: PByte): Boolean;

function CardIsInserted(Host: PSdhciHost): Boolean;
function CardIsWriteProtected(Host: PSdhciHost): Boolean;

{ The interrupt handler (connect it with Host as the context, then set
  Host^.UsesInterrupts). }
procedure HandleSdhciInterrupt(Frame: PTrapFrame; Context: Pointer);

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Options,
  Kernel.Scheduler,
  Drivers.Sdhci.Registers,
  Drivers.VideoCoreMailbox;

const
  CommandTimeoutMilliseconds = 1000;
  DataTimeoutMilliseconds = 5000;
  ResetTimeoutMilliseconds = 100;
  ClockStableTimeoutMilliseconds = 20;
  { A little more than two SD clock cycles at 400 kHz. }
  WriteDelayMicroseconds = 6;

{ --- Registers -------------------------------------------------------------- }

procedure StallMicroseconds(Microseconds: QWord);
var
  Deadline: QWord;
begin
  Deadline := ClockNanoseconds + Microseconds * 1000;
  while ClockNanoseconds < Deadline do
    CpuRelax;
end;

function Read32(Host: PSdhciHost; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Host^.Registers + Offset)^;
  FullMemoryBarrier;
end;

function Read16(Host: PSdhciHost; Offset: LongWord): Word;
begin
  if (Host^.Quirks.Flags and QuirkRegisters32Bit) <> 0 then
    Result := Word(Read32(Host, Offset and not LongWord(3)) shr ((Offset and 2) * 8))
  else
  begin
    Result := PWord(Host^.Registers + Offset)^;
    FullMemoryBarrier;
  end;
end;

function Read8(Host: PSdhciHost; Offset: LongWord): Byte;
begin
  if (Host^.Quirks.Flags and QuirkRegisters32Bit) <> 0 then
    Result := Byte(Read32(Host, Offset and not LongWord(3)) shr ((Offset and 3) * 8))
  else
  begin
    Result := (Host^.Registers + Offset)^;
    FullMemoryBarrier;
  end;
end;

procedure AfterWrite(Host: PSdhciHost);
begin
  if (Host^.Quirks.Flags and QuirkWriteDelay) <> 0 then
    StallMicroseconds(WriteDelayMicroseconds);
end;

procedure Write32(Host: PSdhciHost; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Host^.Registers + Offset)^ := Value;
  AfterWrite(Host);
end;

{ The bits of the 32-bit word holding Offset other than its own Width
  bytes, as they are now (for read-modify-write). }
function MergedWord(Host: PSdhciHost; Offset: LongWord; Width: LongWord; Value: LongWord): LongWord;
var
  Shift: LongWord;
  Mask: LongWord;
begin
  Shift := (Offset and 3) * 8;
  if Width = 1 then
    Mask := LongWord($FF) shl Shift
  else
    Mask := LongWord($FFFF) shl Shift;
  Result := (Read32(Host, Offset and not LongWord(3)) and not Mask) or ((Value shl Shift) and Mask);
end;

procedure Write16(Host: PSdhciHost; Offset: LongWord; Value: Word);
begin
  if (Host^.Quirks.Flags and QuirkRegisters32Bit) <> 0 then
    Write32(Host, Offset and not LongWord(3), MergedWord(Host, Offset, 2, Value))
  else
  begin
    FullMemoryBarrier;
    PWord(Host^.Registers + Offset)^ := Value;
    AfterWrite(Host);
  end;
end;

procedure Write8(Host: PSdhciHost; Offset: LongWord; Value: Byte);
begin
  if (Host^.Quirks.Flags and QuirkRegisters32Bit) <> 0 then
    Write32(Host, Offset and not LongWord(3), MergedWord(Host, Offset, 1, Value))
  else
  begin
    FullMemoryBarrier;
    (Host^.Registers + Offset)^ := Value;
    AfterWrite(Host);
  end;
end;

function WaitForRegister8(Host: PSdhciHost; Offset: LongWord; Mask, Expected: Byte;
  TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds) + 1;
  while (Read8(Host, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

function ResetLines(Host: PSdhciHost; Lines: Byte): Boolean;
begin
  Write8(Host, SdhciSoftwareReset, Lines);
  Result := WaitForRegister8(Host, SdhciSoftwareReset, Lines, 0, ResetTimeoutMilliseconds);
end;

{ --- Status ------------------------------------------------------------------ }

procedure WakeStatusWaiter(Context: Pointer);
var
  Host: PSdhciHost;
begin
  Host := PSdhciHost(Context);
  if AtomicExchange(Host^.CardChangeSeen, 0) <> 0 then
    SignalEvent(Host^.CardChanged);
  SignalEvent(Host^.StatusArrived);
end;

procedure HandleSdhciInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Host: PSdhciHost;
  Status: LongWord;
begin
  Host := PSdhciHost(Context);
  Status := Read32(Host, SdhciInterruptStatus) and InterruptsUsed;
  { (A shared line: nothing set means another device raised it.) }
  if Status = 0 then
    Exit;
  Write32(Host, SdhciInterruptStatus, Status);
  if (Status and (InterruptCardInsertion or InterruptCardRemoval)) <> 0 then
    AtomicOr(Host^.CardChangeSeen, 1);
  AtomicOr(Host^.Pending, Status);
  QueueDeferredCall(Host^.WakeWaiter);
end;

{ Moves new status bits into Collected. }
procedure CollectStatus(Host: PSdhciHost);
var
  Status: LongWord;
begin
  if Host^.UsesInterrupts then
    Status := LongWord(AtomicExchange(Host^.Pending, 0))
  else
  begin
    Status := Read32(Host, SdhciInterruptStatus) and InterruptsUsed;
    if Status <> 0 then
      Write32(Host, SdhciInterruptStatus, Status);
  end;
  Host^.Collected := Host^.Collected or Status;
end;

{ Waits until a bit of Mask (or an error) has been collected; returns
  the status then and takes Mask's bits (and the errors) out of
  Collected. Zero on timeout. }
function WaitForStatus(Host: PSdhciHost; Mask: LongWord; TimeoutMilliseconds: QWord): LongWord;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds) + 1;
  repeat
    CollectStatus(Host);
    if (Host^.Collected and (Mask or ErrorsAll)) <> 0 then
    begin
      Result := Host^.Collected;
      Host^.Collected := Host^.Collected and not (Mask or ErrorsAll or InterruptError);
      Exit;
    end;
    if ClockTickCount > Deadline then
      Exit(0);
    if Host^.UsesInterrupts then
      WaitForEventWithOptions(Host^.StatusArrived, 10, False)
    else
      CpuRelax;
  until False;
end;

{ Drops whatever status is left from before. }
procedure ClearStatus(Host: PSdhciHost);
begin
  CollectStatus(Host);
  Host^.Collected := 0;
end;

{ --- Setting up --------------------------------------------------------------- }

function InitializeHost(Host: PSdhciHost): Boolean;
var
  FirmwareHertz: LongWord;
  CapabilityMegahertz: LongWord;
begin
  Result := False;
  InitializeEvent(Host^.StatusArrived, EventKindSynchronization, False);
  InitializeEvent(Host^.CardChanged, EventKindSynchronization, False);
  InitializeDeferredCall(Host^.WakeWaiter, @WakeStatusWaiter, Host);
  Host^.Version := Byte(Read16(Host, SdhciHostVersion));
  Host^.Capabilities := Read32(Host, SdhciCapabilities);
  if not ResetLines(Host, ResetAll) then
    Exit;

  { The base clock: the firmware's word for it, else the capabilities
    (8 bits of MHz from version 3, 6 before), else the fallback. }
  Host^.BaseClockHertz := 0;
  if ((Host^.Quirks.Flags and QuirkClockFromFirmware) <> 0) and
     QueryClockRate(Host^.Quirks.FirmwareClockId, FirmwareHertz) then
    Host^.BaseClockHertz := FirmwareHertz;
  if Host^.BaseClockHertz = 0 then
  begin
    CapabilityMegahertz := (Host^.Capabilities shr CapabilityBaseClockShift) and $FF;
    if Host^.Version < SpecificationVersion300 then
      CapabilityMegahertz := CapabilityMegahertz and $3F;
    Host^.BaseClockHertz := CapabilityMegahertz * 1000000;
  end;
  if Host^.BaseClockHertz = 0 then
    Host^.BaseClockHertz := Host^.Quirks.FallbackClockHertz;
  if Host^.BaseClockHertz = 0 then
    Exit;

  { How data moves: ADMA2 through the bounce buffer where possible. }
  if (Host^.Quirks.Flags and QuirkDmaBelow1GiB) <> 0 then
    LimitDmaBusAddresses(Host^.Dma, QWord(1) shl 30);
  { 32-bit descriptors carry 32-bit addresses. }
  LimitDmaBusAddresses(Host^.Dma, QWord(1) shl 32);
  Host^.UsesAdma := ((Host^.Capabilities and CapabilityAdma2) <> 0) and
    ((Host^.Quirks.Flags and QuirkNoDma) = 0) and not KernelOptionIsSet(OptionSdhciPio);
  if Host^.UsesAdma then
    Host^.UsesAdma := AllocateDmaBuffer(Host^.Dma, SdhciBounceBytes, DmaStreaming, Host^.Bounce) and
      AllocateDmaBuffer(Host^.Dma, AdmaTableBytes, DmaShared, Host^.AdmaTable);
  Result := True;
end;

function CardVoltageBits(Host: PSdhciHost): Byte;
begin
  if ((Host^.Capabilities and CapabilityVoltage33) <> 0) or
     ((Host^.Quirks.Flags and QuirkVoltage33Only) <> 0) or
     ((Host^.Capabilities and CapabilityVoltage30) = 0) then
    Result := PowerVoltage33
  else
    Result := PowerVoltage30;
end;

procedure PowerDownCard(Host: PSdhciHost);
begin
  Write16(Host, SdhciClockControl, Read16(Host, SdhciClockControl) and not ClockCardEnable);
  Write8(Host, SdhciPowerControl, 0);
end;

function PowerUpCard(Host: PSdhciHost): Boolean;
var
  Voltage: Byte;
begin
  { A card left signalling at 1.8 V by whoever ran before only comes
    back to 3.3 V through losing power: off for a moment first. }
  PowerDownCard(Host);
  if Host^.Version >= SpecificationVersion300 then
    Write16(Host, SdhciHostControl2, Read16(Host, SdhciHostControl2) and
      not (HostControl2SignalVoltage18 or HostControl2PresetValueEnable));
  SleepMilliseconds(10);
  Voltage := CardVoltageBits(Host);
  Write8(Host, SdhciPowerControl, Voltage);
  Write8(Host, SdhciPowerControl, Voltage or PowerBusOn);
  Write8(Host, SdhciHostControl1, 0);
  Write8(Host, SdhciTimeoutControl, TimeoutLongest);
  Write32(Host, SdhciInterruptStatus, InterruptsUsed);
  Write32(Host, SdhciInterruptStatusEnable, InterruptsUsed);
  if Host^.UsesInterrupts then
    Write32(Host, SdhciInterruptSignalEnable, InterruptsUsed)
  else
    Write32(Host, SdhciInterruptSignalEnable, 0);
  Result := SetCardClock(Host, IdentificationClockHertz);
  { The card wants 74 clock cycles (and its power ramp) before CMD0. }
  SleepMilliseconds(10);
end;

{ The clock control bits for the fastest card clock at or below Hertz;
  Actual says what it is. }
function ClockDivider(Host: PSdhciHost; Hertz: LongWord; out Actual: LongWord): Word;
var
  Divisor: LongWord;
  Field: LongWord;
begin
  if Host^.BaseClockHertz <= Hertz then
  begin
    Actual := Host^.BaseClockHertz;
    Exit(0);
  end;
  if Host^.Version >= SpecificationVersion300 then
  begin
    { 10-bit divided clock: base / (2 N). }
    Field := (Host^.BaseClockHertz + 2 * Hertz - 1) div (2 * Hertz);
    if Field > $3FF then
      Field := $3FF;
    Actual := Host^.BaseClockHertz div (2 * Field);
    Result := Word(((Field and $FF) shl 8) or (((Field shr 8) and 3) shl 6));
  end
  else
  begin
    { A power of two from 2 to 256, written halved. }
    Divisor := 2;
    while (Divisor < 256) and (Host^.BaseClockHertz div Divisor > Hertz) do
      Divisor := Divisor * 2;
    Actual := Host^.BaseClockHertz div Divisor;
    Result := Word((Divisor div 2) shl 8);
  end;
end;

function SetCardClock(Host: PSdhciHost; Hertz: LongWord): Boolean;
var
  Divider: Word;
  Actual: LongWord;
  Deadline: QWord;
begin
  Divider := ClockDivider(Host, Hertz, Actual);
  Write16(Host, SdhciClockControl, 0);
  Write16(Host, SdhciClockControl, Divider or ClockInternalEnable);
  Deadline := ClockTickCount + MillisecondsToTicks(ClockStableTimeoutMilliseconds) + 1;
  while (Read16(Host, SdhciClockControl) and ClockInternalStable) = 0 do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Write16(Host, SdhciClockControl, Divider or ClockInternalEnable or ClockCardEnable);
  Host^.ClockHertz := Actual;
  Result := True;
end;

procedure SetFourBitBus(Host: PSdhciHost);
begin
  Write8(Host, SdhciHostControl1, Read8(Host, SdhciHostControl1) or HostControlFourBitBus);
end;

procedure SetHighSpeedTiming(Host: PSdhciHost);
begin
  if (Host^.Quirks.Flags and QuirkNoHighSpeedBit) = 0 then
    Write8(Host, SdhciHostControl1, Read8(Host, SdhciHostControl1) or HostControlHighSpeed);
end;

function CardIsInserted(Host: PSdhciHost): Boolean;
begin
  if (Host^.Quirks.Flags and QuirkBrokenCardDetect) <> 0 then
    Exit(True);
  Result := (Read32(Host, SdhciPresentState) and PresentCardInserted) <> 0;
end;

function CardIsWriteProtected(Host: PSdhciHost): Boolean;
begin
  { Without card detect there is no write protect switch either (microSD
    slots have none). }
  if (Host^.Quirks.Flags and QuirkBrokenCardDetect) <> 0 then
    Exit(False);
  Result := (Read32(Host, SdhciPresentState) and PresentWriteEnabled) = 0;
end;

{ --- Commands ------------------------------------------------------------------ }

function WaitForLinesFree(Host: PSdhciHost; Lines: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds) + 1;
  while (Read32(Host, SdhciPresentState) and Lines) <> 0 do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure ReadResponse(Host: PSdhciHost);
var
  Index: Integer;
begin
  for Index := 0 to 3 do
    Host^.Response[Index] := Read32(Host, SdhciResponse + LongWord(Index) * 4);
end;

{ After a failed command: the lines it used are reset. }
procedure RecoverFromError(Host: PSdhciHost; Status: LongWord; UsedData: Boolean);
begin
  Host^.LastError := Status;
  if Status = 0 then
    Host^.LastError := ErrorCommandTimeout or ErrorDataTimeout;
  ResetLines(Host, ResetCommandLine);
  if UsedData or ((Status and ErrorsOfData) <> 0) then
    ResetLines(Host, ResetDataLine);
  ClearStatus(Host);
end;

{ Sends the command (the argument, then transfer mode and command in
  one write) and waits for it to complete. }
function IssueCommand(Host: PSdhciHost; Index: Byte; Argument: LongWord; ResponseKind: Word;
  TransferMode: Word; UsesData: Boolean): Boolean;
var
  Lines: LongWord;
  Command: LongWord;
  Status: LongWord;
begin
  Result := False;
  Lines := PresentCommandInhibit;
  if UsesData or ((ResponseKind and 3) = CommandResponse48Busy) then
    Lines := Lines or PresentDataInhibit;
  if not WaitForLinesFree(Host, Lines) then
  begin
    RecoverFromError(Host, 0, UsesData);
    Exit;
  end;
  ClearStatus(Host);
  Command := (LongWord(Index) shl CommandIndexShift) or ResponseKind;
  if UsesData then
    Command := Command or CommandDataPresent;
  Write32(Host, SdhciArgument, Argument);
  Write32(Host, SdhciTransferMode, TransferMode or (Command shl 16));
  Status := WaitForStatus(Host, InterruptCommandComplete, CommandTimeoutMilliseconds);
  if (Status and InterruptCommandComplete) = 0 then
  begin
    RecoverFromError(Host, Status, UsesData);
    Exit;
  end;
  ReadResponse(Host);
  Result := True;
end;

function RunCommand(Host: PSdhciHost; Index: Byte; Argument: LongWord; ResponseKind: Word): Boolean;
var
  Status: LongWord;
begin
  Result := IssueCommand(Host, Index, Argument, ResponseKind, 0, False);
  if not Result or ((ResponseKind and 3) <> CommandResponse48Busy) then
    Exit;
  { The busy signal ends with "transfer complete". }
  Status := WaitForStatus(Host, InterruptTransferComplete, DataTimeoutMilliseconds);
  Result := (Status and InterruptTransferComplete) <> 0;
  if not Result then
    RecoverFromError(Host, Status, True);
end;

{ ADMA2 descriptors for ByteCount bytes of the bounce buffer. }
procedure BuildAdmaTable(Host: PSdhciHost; ByteCount: LongWord);
var
  Descriptors: PLongWord;
  Offset: LongWord;
  Piece: LongWord;
  Attributes: LongWord;
  Index: LongWord;
begin
  Descriptors := PLongWord(Host^.AdmaTable.Address);
  Offset := 0;
  Index := 0;
  while Offset < ByteCount do
  begin
    Piece := ByteCount - Offset;
    if Piece > AdmaPieceBytes then
      Piece := AdmaPieceBytes;
    Attributes := AdmaValid or AdmaTransfer;
    if Offset + Piece >= ByteCount then
      Attributes := Attributes or AdmaEnd;
    Descriptors[Index * 2] := Attributes or (Piece shl 16);
    Descriptors[Index * 2 + 1] := LongWord(Host^.Bounce.DeviceAddress + Offset);
    Offset := Offset + Piece;
    Inc(Index);
  end;
  FullMemoryBarrier;
end;

{ Moves the data of the command just issued through the buffer data
  port, a block at a time. }
function TransferByProcessor(Host: PSdhciHost; IsRead: Boolean; BlockCount, BlockSize: LongWord;
  Buffer: PByte): Boolean;
var
  Block: LongWord;
  Word32: LongWord;
  Status: LongWord;
  ReadyBit: LongWord;
  Words: PLongWord;
begin
  Result := False;
  if IsRead then
    ReadyBit := InterruptBufferReadReady
  else
    ReadyBit := InterruptBufferWriteReady;
  for Block := 1 to BlockCount do
  begin
    Status := WaitForStatus(Host, ReadyBit, DataTimeoutMilliseconds);
    if (Status and ReadyBit) = 0 then
    begin
      Host^.LastError := Status;
      Exit;
    end;
    Words := PLongWord(Buffer + (Block - 1) * BlockSize);
    for Word32 := 1 to BlockSize div 4 do
      if IsRead then
        Words[Word32 - 1] := Read32(Host, SdhciBufferData)
      else
        Write32(Host, SdhciBufferData, Words[Word32 - 1]);
  end;
  Result := True;
end;

function RunDataCommand(Host: PSdhciHost; Index: Byte; Argument: LongWord; IsRead: Boolean;
  BlockCount, BlockSize: LongWord; Buffer: PByte): Boolean;
var
  ByteCount: LongWord;
  TransferMode: Word;
  Status: LongWord;
  Control: Byte;
begin
  Result := False;
  ByteCount := BlockCount * BlockSize;
  if (BlockCount = 0) or (ByteCount > SdhciBounceBytes) or (BlockCount > $FFFF) then
    Exit;
  TransferMode := TransferBlockCountEnable;
  if IsRead then
    TransferMode := TransferMode or TransferRead;
  if BlockCount > 1 then
    TransferMode := TransferMode or TransferMultipleBlocks or TransferAutoCommand12;

  Control := Read8(Host, SdhciHostControl1) and not HostControlDmaMask;
  if Host^.UsesAdma then
  begin
    if IsRead then
      PrepareDmaFromDevice(Host^.Dma, Host^.Bounce.Address, ByteCount)
    else
    begin
      CopyMemory(Host^.Bounce.Address, Buffer, ByteCount);
      PrepareDmaToDevice(Host^.Dma, Host^.Bounce.Address, ByteCount);
    end;
    BuildAdmaTable(Host, ByteCount);
    Write32(Host, SdhciAdmaAddress, LongWord(Host^.AdmaTable.DeviceAddress));
    Write32(Host, SdhciAdmaAddressHigh, LongWord(Host^.AdmaTable.DeviceAddress shr 32));
    Control := Control or HostControlAdma32;
    TransferMode := TransferMode or TransferDmaEnable;
  end;
  Write8(Host, SdhciHostControl1, Control);
  Write32(Host, SdhciBlockSize, (BlockSize and $FFF) or BlockSizeBoundary512K or (BlockCount shl 16));

  if not IssueCommand(Host, Index, Argument, CommandResponse48 or CommandCrcCheck or CommandIndexCheck,
    TransferMode, True) then
    Exit;
  if not Host^.UsesAdma and not TransferByProcessor(Host, IsRead, BlockCount, BlockSize, Buffer) then
  begin
    RecoverFromError(Host, Host^.LastError, True);
    if BlockCount > 1 then
      RunCommand(Host, SdStopTransmission, 0, CommandResponse48Busy or CommandTypeAbort);
    Exit;
  end;
  Status := WaitForStatus(Host, InterruptTransferComplete, DataTimeoutMilliseconds);
  if ((Status and InterruptTransferComplete) = 0) or ((Status and ErrorsAll) <> 0) then
  begin
    RecoverFromError(Host, Status, True);
    if BlockCount > 1 then
      RunCommand(Host, SdStopTransmission, 0, CommandResponse48Busy or CommandTypeAbort);
    Exit;
  end;
  if Host^.UsesAdma and IsRead then
  begin
    FinishDmaFromDevice(Host^.Dma, Host^.Bounce.Address, ByteCount);
    CopyMemory(Buffer, Host^.Bounce.Address, ByteCount);
  end;
  Result := True;
end;

end.
