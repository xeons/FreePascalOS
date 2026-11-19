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
  What the Realtek gigabit (RTL8168/8111, Drivers.Rtl8168) and
  multi-gigabit (RTL8125/8126, Drivers.Rtl8125) drivers share: the card
  record, the rings (Drivers.RealtekGigabit.Rings), interrupts and the
  deferred routine, the statistics (the chip's tally counters), the
  adapter's routines and suspend to RAM.

  A chip unit describes its generation in a TRealtekChip: where its
  interrupt registers are and how wide, how to ring its transmit poll
  register, how to bring the chip from reset to running (BringUp, which
  calls the helpers here in the order the chip wants) and how to read
  its link.

  Interrupts come by MSI where the chip has it, else the PCI line; the
  handler acknowledges the status bits (written back) and queues the
  deferred routine. Every two seconds a timer reads the link and asks
  the chip for its tally counters (read on the next round, so nothing
  waits); while the link stays down the chip unit may log what its PHY
  says. Every wait is bounded.
}
unit Drivers.RealtekGigabit;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Io.Pci,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.RealtekGigabit.Registers,
  Drivers.RealtekGigabit.Rings;

type
  PRealtekCard = ^TRealtekCard;

  TRealtekChip = record
    InterruptMaskRegister: LongWord;
    InterruptStatusRegister: LongWord;
    { 32-bit interrupt registers (RTL8125/8126), else 16-bit. }
    WideInterruptRegisters: Boolean;
    TransmitPoll: TRealtekTransmitPoll;
    { From any state to running, interrupts masked: reset, set-up,
      station address, rings, receive and transmit on. Passive level,
      under the card's configuration lock. False if the chip did not
      answer (it is left quiet). }
    BringUp: function(Card: PRealtekCard): Boolean;
    ReadLink: procedure(Card: PRealtekCard; out Link: TNetworkLinkState);
    { Called every two seconds while the link is down (Seconds since it
      went down or the card started), at dispatch level; nil for none. }
    LinkStillDown: procedure(Card: PRealtekCard; Seconds: LongWord);
  end;

  TRealtekCard = record
    Card: TNetworkCard;
    Pci: PPciDevice;
    Registers: PByte;
    RegistersBytes: QWord;
    Address: TEthernetAddress;
    Chip: TRealtekChip;
    { The chip unit's own record (version, firmware). }
    ChipData: Pointer;
    Rings: TRealtekRings;
    Description: array[0..47] of Char;

    UsesInterrupts: Boolean;
    IsSuspended: Boolean;
    PendingStatus: PtrUInt;
    ServiceCall: TDeferredCall;
    PollTimer: TTimer;
    WatchCall: TDeferredCall;
    WatchTimer: TTimer;
    LinkDownSeconds: LongWord;

    Counters: PRealtekTallyCounters;
    CountersPhysical: QWord;
    PreviousCounters: TRealtekTallyCounters;
    CounterDumpPending: Boolean;

    { Bringing the chip up (start, waking, a firmware patch arriving) one
      at a time. }
    ConfigurationLock: TMutex;
    { The chip's indirect register windows (OCP), one access at a time. }
    IndirectAccessLock: TSpinLock;
  end;

{ Maps the card's registers and takes its memory. nil on failure
  (logged). }
function CreateRealtekCard(Pci: PPciDevice; const Chip: TRealtekChip; ChipData: Pointer): PRealtekCard;
{ Brings the card up, connects its interrupt, registers its adapter
  under Description and its power handler. Card^.Address must be set. }
function StartRealtekCard(Card: PRealtekCard; Description: PChar): Boolean;

{ Helpers for BringUp. }
function ResetRealtekChip(Card: PRealtekCard): Boolean;
procedure UnlockRealtekConfiguration(Card: PRealtekCard);
procedure LockRealtekConfiguration(Card: PRealtekCard);
{ Writes Card^.Address (configuration unlocked). }
procedure WriteRealtekStationAddress(Card: PRealtekCard);
{ The six bytes at Offset, if the register window reaches them and they
  make a usable address. }
function ReadRealtekStationAddress(Card: PRealtekCard; Offset: LongWord; out Address: TEthernetAddress): Boolean;
{ Every multicast group (the network layer filters). }
procedure AcceptAllMulticast(Card: PRealtekCard);
{ Waits until (Read8(Offset) and Mask) = Expected, at most
  Milliseconds. }
function WaitForRealtekRegister8(Card: PRealtekCard; Offset: LongWord; Mask, Expected: Byte;
  Milliseconds: QWord): Boolean;

procedure ReportRealtek(Card: PRealtekCard; Text: PChar);

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.Clock,
  Io.PciMessageInterrupts,
  Io.PciLineInterrupts,
  Io.PowerManagement,
  Drivers.NetworkBuffers,
  Debug.Output;

const
  ResetTimeoutMilliseconds = 100;
  PollIntervalMilliseconds = 10;
  WatchIntervalMilliseconds = 2000;

procedure ReportRealtek(Card: PRealtekCard; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('realtek');
  DebugWriteHex(Card^.Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Card^.Pci^.DeviceId, 4);
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ --- Helpers for the chip units ------------------------------------------------ }

function WaitForRealtekRegister8(Card: PRealtekCard; Offset: LongWord; Mask, Expected: Byte;
  Milliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(Milliseconds) + 1;
  repeat
    if (Read8(Card^.Registers, Offset) and Mask) = Expected then
      Exit(True);
    CpuRelax;
  until ClockTickCount > Deadline;
  Result := (Read8(Card^.Registers, Offset) and Mask) = Expected;
end;

function ResetRealtekChip(Card: PRealtekCard): Boolean;
begin
  Write8(Card^.Registers, RegisterCommand, CommandReset);
  Result := WaitForRealtekRegister8(Card, RegisterCommand, CommandReset, 0, ResetTimeoutMilliseconds);
end;

procedure UnlockRealtekConfiguration(Card: PRealtekCard);
begin
  Write8(Card^.Registers, RegisterConfigurationLock, ConfigurationUnlock);
end;

procedure LockRealtekConfiguration(Card: PRealtekCard);
begin
  Write8(Card^.Registers, RegisterConfigurationLock, ConfigurationLocked);
end;

procedure WriteRealtekStationAddress(Card: PRealtekCard);
begin
  { The high part first: writing the low part makes it take effect. }
  Write32(Card^.Registers, RegisterStationAddress4, LongWord(Card^.Address[4]) or (LongWord(Card^.Address[5]) shl 8));
  Write32(Card^.Registers, RegisterStationAddress0,
    LongWord(Card^.Address[0]) or (LongWord(Card^.Address[1]) shl 8) or (LongWord(Card^.Address[2]) shl 16) or
    (LongWord(Card^.Address[3]) shl 24));
end;

function ReadRealtekStationAddress(Card: PRealtekCard; Offset: LongWord; out Address: TEthernetAddress): Boolean;
var
  Index: Integer;
begin
  ZeroMemory(@Address, SizeOf(Address));
  if Offset + EthernetAddressLength > Card^.RegistersBytes then
    Exit(False);
  for Index := 0 to EthernetAddressLength - 1 do
    Address[Index] := Read8(Card^.Registers, Offset + LongWord(Index));
  Result := EthernetAddressIsUsable(Address);
end;

procedure AcceptAllMulticast(Card: PRealtekCard);
begin
  Write32(Card^.Registers, RegisterMulticast0, $FFFFFFFF);
  Write32(Card^.Registers, RegisterMulticast4, $FFFFFFFF);
end;

{ --- Interrupts ---------------------------------------------------------------- }

procedure WriteInterruptMask(Card: PRealtekCard; Mask: LongWord);
begin
  if Card^.Chip.WideInterruptRegisters then
    Write32(Card^.Registers, Card^.Chip.InterruptMaskRegister, Mask)
  else
    Write16(Card^.Registers, Card^.Chip.InterruptMaskRegister, Word(Mask));
end;

procedure HandleRealtekInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Card: PRealtekCard;
  Status: LongWord;
begin
  Card := PRealtekCard(Context);
  if Card^.Chip.WideInterruptRegisters then
  begin
    Status := Read32(Card^.Registers, Card^.Chip.InterruptStatusRegister);
    if (Status = 0) or (Status = $FFFFFFFF) then
      Exit;
    Write32(Card^.Registers, Card^.Chip.InterruptStatusRegister, Status);
  end
  else
  begin
    Status := Read16(Card^.Registers, Card^.Chip.InterruptStatusRegister);
    if (Status = 0) or (Status = $FFFF) then
      Exit;
    Write16(Card^.Registers, Card^.Chip.InterruptStatusRegister, Word(Status));
  end;
  AtomicOr(Card^.PendingStatus, Status);
  QueueDeferredCall(Card^.ServiceCall);
end;

procedure CheckLink(Card: PRealtekCard);
var
  Link: TNetworkLinkState;
begin
  Card^.Chip.ReadLink(Card, Link);
  UpdateNetworkCardLink(@Card^.Card, Link);
end;

procedure ServiceCard(Context: Pointer);
var
  Card: PRealtekCard;
  Status: PtrUInt;
  MoreReceived: Boolean;
begin
  Card := PRealtekCard(Context);
  if Card^.IsSuspended then
    Exit;
  Status := AtomicExchange(Card^.PendingStatus, 0);
  MoreReceived := ReceiveRealtekFrames(Card^.Rings);
  ReclaimRealtekTransmits(Card^.Rings);
  if ((Status and InterruptLinkChange) <> 0) or not Card^.UsesInterrupts then
    CheckLink(Card);
  if MoreReceived then
    QueueDeferredCall(Card^.ServiceCall)
  else if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

{ --- Statistics ------------------------------------------------------------------ }

procedure AccountCounters(Card: PRealtekCard);
var
  Current: TRealtekTallyCounters;
  PreviousLevel: TPriorityLevel;
begin
  Current := Card^.Counters^;
  PreviousLevel := AcquireSpinLock(Card^.Rings.ReceiveLock);
  with Card^.Card.Statistics do
  begin
    Inc(ReceiveErrors, LongWord(Current.ReceiveErrors - Card^.PreviousCounters.ReceiveErrors));
    Inc(ReceiveErrors, Word(Current.AlignmentErrors - Card^.PreviousCounters.AlignmentErrors));
    Inc(ReceiveMissed, Word(Current.ReceiveMissed - Card^.PreviousCounters.ReceiveMissed));
  end;
  ReleaseSpinLock(Card^.Rings.ReceiveLock, PreviousLevel);
  PreviousLevel := AcquireSpinLock(Card^.Rings.TransmitLock);
  with Card^.Card.Statistics do
  begin
    Inc(TransmitErrors, Current.TransmitErrors - Card^.PreviousCounters.TransmitErrors);
    Inc(Collisions, LongWord(Current.TransmitOneCollision - Card^.PreviousCounters.TransmitOneCollision));
    Inc(Collisions, LongWord(Current.TransmitMultipleCollisions - Card^.PreviousCounters.TransmitMultipleCollisions));
  end;
  ReleaseSpinLock(Card^.Rings.TransmitLock, PreviousLevel);
  Card^.PreviousCounters := Current;
end;

procedure UpdateCounters(Card: PRealtekCard);
begin
  if Card^.Counters = nil then
    Exit;
  if Card^.CounterDumpPending then
  begin
    if (Read32(Card^.Registers, RegisterCounterDumpLow) and CounterDumpStart) <> 0 then
      Exit;
    AccountCounters(Card);
  end;
  Write32(Card^.Registers, RegisterCounterDumpHigh, LongWord(Card^.CountersPhysical shr 32));
  Write32(Card^.Registers, RegisterCounterDumpLow, LongWord(Card^.CountersPhysical) or CounterDumpStart);
  Card^.CounterDumpPending := True;
end;

procedure WatchCard(Context: Pointer);
var
  Card: PRealtekCard;
begin
  Card := PRealtekCard(Context);
  if Card^.IsSuspended then
    Exit;
  UpdateCounters(Card);
  CheckLink(Card);
  if Card^.Card.Link.IsUp then
    Card^.LinkDownSeconds := 0
  else
  begin
    Inc(Card^.LinkDownSeconds, WatchIntervalMilliseconds div 1000);
    if Assigned(Card^.Chip.LinkStillDown) then
      Card^.Chip.LinkStillDown(Card, Card^.LinkDownSeconds);
  end;
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
end;

{ --- The adapter's routines ------------------------------------------------------- }

function TransmitFrame(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
begin
  Result := TransmitRealtekFrame(PRealtekCard(Context)^.Rings, Frame, Length);
end;

function LinkIsUp(Context: Pointer): Boolean;
var
  Card: PRealtekCard;
  Link: TNetworkLinkState;
begin
  Card := PRealtekCard(Context);
  if Card^.IsSuspended then
    Exit(False);
  Card^.Chip.ReadLink(Card, Link);
  Result := Link.IsUp;
end;

{ --- Running and stopping ---------------------------------------------------------- }

procedure QuietChip(Card: PRealtekCard);
begin
  WriteInterruptMask(Card, 0);
  Write8(Card^.Registers, RegisterCommand, 0);
end;

{ BringUp under the lock, then the counters start again from zero. }
function BringUpChip(Card: PRealtekCard): Boolean;
begin
  AcquireMutex(Card^.ConfigurationLock);
  Result := Card^.Chip.BringUp(Card);
  ReleaseMutex(Card^.ConfigurationLock);
  ZeroMemory(@Card^.PreviousCounters, SizeOf(Card^.PreviousCounters));
  Card^.CounterDumpPending := False;
  Card^.LinkDownSeconds := 0;
end;

procedure StartRunning(Card: PRealtekCard);
begin
  Card^.IsSuspended := False;
  if Card^.UsesInterrupts then
    WriteInterruptMask(Card, InterruptsUsed);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
  if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

procedure SuspendCard(Context: Pointer);
var
  Card: PRealtekCard;
begin
  Card := PRealtekCard(Context);
  Card^.IsSuspended := True;
  StopRealtekRings(Card^.Rings);
  QuietChip(Card);
  CancelTimer(Card^.WatchTimer);
  CancelTimer(Card^.PollTimer);
  CancelDeferredCall(Card^.ServiceCall);
  CancelDeferredCall(Card^.WatchCall);
end;

procedure ResumeCard(Context: Pointer);
var
  Card: PRealtekCard;
begin
  Card := PRealtekCard(Context);
  if not BringUpChip(Card) then
  begin
    ReportRealtek(Card, 'the chip did not come back after waking');
    Exit;
  end;
  Card^.PendingStatus := 0;
  NetworkCardWoke(@Card^.Card);
  StartRunning(Card);
  ReclaimRealtekTransmits(Card^.Rings);
  AtomicOr(Card^.PendingStatus, InterruptLinkChange);
  QueueDeferredCall(Card^.ServiceCall);
end;

{ --- Starting a card ---------------------------------------------------------------- }

{ The first memory BAR (the chips also decode their registers in I/O
  space, at BAR 0). }
function FindRegisterBar(Pci: PPciDevice; out Bar: TPciBar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while Index <= 5 do
  begin
    if PciReadBar(Pci, Index, Bar) then
    begin
      if not Bar.IsIoPort then
        Exit(True);
      Inc(Index);
    end
    else
      Inc(Index);
    if Bar.Is64Bit then
      Inc(Index);
  end;
  Result := False;
end;

function CreateRealtekCard(Pci: PPciDevice; const Chip: TRealtekChip; ChipData: Pointer): PRealtekCard;
var
  Card: PRealtekCard;
  Bar: TPciBar;
begin
  Result := nil;
  if not FindRegisterBar(Pci, Bar) then
    Exit;
  Card := PRealtekCard(AllocateZeroedKernelMemory(SizeOf(TRealtekCard)));
  if Card = nil then
    Exit;
  Card^.Pci := Pci;
  Card^.Chip := Chip;
  Card^.ChipData := ChipData;
  Card^.IsSuspended := True;
  InitializeMutex(Card^.ConfigurationLock);
  InitializeSpinLock(Card^.IndirectAccessLock);
  PciEnableDevice(Pci, True);
  Card^.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  Card^.RegistersBytes := Bar.SizeInBytes;
  if Card^.Registers = nil then
    Exit;
  if not AllocateRealtekRings(Card^.Rings, Card^.Registers, @Card^.Card, Chip.TransmitPoll) then
  begin
    ReportRealtek(Card, 'not enough memory for the rings');
    Exit;
  end;
  { Statistics are only lost without it. }
  Card^.CountersPhysical := AllocateZeroedPhysicalPageBelow(NetworkDmaLimit, PageUsageGeneral);
  if Card^.CountersPhysical <> 0 then
    Card^.Counters := PRealtekTallyCounters(PhysicalToVirtual(Card^.CountersPhysical));
  InitializeDeferredCall(Card^.ServiceCall, @ServiceCard, Card);
  InitializeDeferredCall(Card^.WatchCall, @WatchCard, Card);
  InitializeTimer(Card^.PollTimer);
  InitializeTimer(Card^.WatchTimer);
  Result := Card;
end;

procedure ConnectInterrupt(Card: PRealtekCard);
begin
  if ConnectPciMessageInterrupt(Card^.Pci, @HandleRealtekInterrupt, Card) then
  begin
    Card^.UsesInterrupts := True;
    Card^.Card.InterruptDescription := 'MSI';
  end
  else if ConnectPciLineInterrupt(Card^.Pci, @HandleRealtekInterrupt, Card) then
  begin
    Card^.UsesInterrupts := True;
    Card^.Card.InterruptDescription := 'line';
  end
  else
    Card^.Card.InterruptDescription := 'polling';
end;

function StartRealtekCard(Card: PRealtekCard; Description: PChar): Boolean;
var
  Routines: TNetworkDriverRoutines;
begin
  Result := False;
  CopyText(@Card^.Description[0], Description, SizeOf(Card^.Description));
  if not BringUpChip(Card) then
  begin
    QuietChip(Card);
    ReportRealtek(Card, 'the chip did not come up');
    Exit;
  end;
  ConnectInterrupt(Card);
  Card^.Chip.ReadLink(Card, Card^.Card.Link);
  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @LinkIsUp;
  Routines.Kind := NetworkAdapterKindEthernet;
  { Takes all multicast; the network layer filters by group. }
  Routines.SetMulticastFilter := nil;
  if not AddNetworkCard(@Card^.Card, Routines, Card, Card^.Address, @Card^.Description[0]) then
  begin
    StopRealtekRings(Card^.Rings);
    QuietChip(Card);
    ReportRealtek(Card, 'the adapter could not be registered');
    Exit;
  end;
  StartRunning(Card);
  RegisterPowerHandler('Realtek Ethernet', PowerStageDevices, @SuspendCard, @ResumeCard, Card);
  Result := True;
end;

end.
