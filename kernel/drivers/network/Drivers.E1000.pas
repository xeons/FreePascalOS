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
  Intel gigabit Ethernet controllers (e1000 and e1000e families): the
  82540EM of QEMU's e1000, the 82574L of QEMU's e1000e (the q35
  machine's own network card) and the parts listed in
  Drivers.E1000.Models.

  Each controller found on PCI is reset (Drivers.E1000.Hardware), its
  station address read, its rings set up (Drivers.E1000.Rings), and it
  is registered as a network adapter (Drivers.NetworkCards). It raises
  its interrupt by MSI where it can (the PCI Express parts), else on its
  PCI interrupt line (shared, so the handler checks the interrupt cause
  register, whose read also clears it); without either, a timer polls
  it. The handler only records the causes and queues the deferred
  routine, which takes the received frames, reclaims sent ones and
  follows the link. A second timer reads the statistics registers and
  the link every two seconds, so a lost link interrupt is caught too.

  Suspend to RAM: the controller is quieted (interrupts masked, receive
  and transmit off, the rings stopped so the network layer's frames are
  refused); waking, it is reset and set up again exactly as at the
  start, with the same adapter, and the link coming back is announced.
}
unit Drivers.E1000;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every supported Intel controller; returns how many. }
function InitializeE1000Adapters: Integer;

implementation

uses
  Runtime.Atomic,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.TrapFrame,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Io.Pci,
  Io.Dma,
  Io.PlatformDevices,
  Io.PciMessageInterrupts,
  Io.PciLineInterrupts,
  Io.PowerManagement,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.NetworkBuffers,
  Drivers.E1000.Registers,
  Drivers.E1000.Models,
  Drivers.E1000.Hardware,
  Drivers.E1000.Rings,
  Debug.Output;

const
  PciClassNetwork = $02;
  PollIntervalMilliseconds = 10;
  WatchIntervalMilliseconds = 2000;

type
  PE1000Card = ^TE1000Card;
  TE1000Card = record
    Card: TNetworkCard;
    Pci: PPciDevice;
    Model: PE1000Model;
    Registers: PByte;
    Dma: TDmaAttributes;
    Address: TEthernetAddress;
    Rings: TE1000Rings;
    UsesInterrupts: Boolean;
    { Causes the interrupt handler read, for the deferred routine. }
    PendingCauses: PtrUInt;
    ServiceCall: TDeferredCall;
    PollTimer: TTimer;
    WatchCall: TDeferredCall;
    WatchTimer: TTimer;
    IsSuspended: Boolean;
  end;

{ --- The adapter's routines ---------------------------------------------- }

function TransmitFrame(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
begin
  Result := TransmitE1000Frame(PE1000Card(Context)^.Rings, Frame, Length);
end;

function LinkIsUp(Context: Pointer): Boolean;
var
  Card: PE1000Card;
begin
  Card := PE1000Card(Context);
  Result := not Card^.IsSuspended and ((ReadRegister(Card^.Registers, RegisterStatus) and StatusLinkUp) <> 0);
end;

{ --- Interrupts and the deferred routines ------------------------------------ }

procedure CheckLink(Card: PE1000Card);
var
  Link: TNetworkLinkState;
begin
  ReadE1000Link(Card^.Registers, Link);
  UpdateNetworkCardLink(@Card^.Card, Link);
end;

procedure HandleE1000Interrupt(Frame: PTrapFrame; Context: Pointer);
var
  Card: PE1000Card;
  Causes: LongWord;
begin
  Card := PE1000Card(Context);
  Causes := ReadRegister(Card^.Registers, RegisterInterruptCause);
  { Not this card (the line is shared), or the card is gone. }
  if (Causes = 0) or (Causes = $FFFFFFFF) then
    Exit;
  AtomicOr(Card^.PendingCauses, Causes);
  QueueDeferredCall(Card^.ServiceCall);
end;

procedure ServiceCard(Context: Pointer);
var
  Card: PE1000Card;
  Causes: PtrUInt;
  MoreReceived: Boolean;
begin
  Card := PE1000Card(Context);
  if Card^.IsSuspended then
    Exit;
  Causes := AtomicExchange(Card^.PendingCauses, 0);
  MoreReceived := ReceiveE1000Frames(Card^.Rings);
  ReclaimE1000Transmits(Card^.Rings);
  if ((Causes and InterruptLinkStatusChange) <> 0) or not Card^.UsesInterrupts then
    CheckLink(Card);
  if MoreReceived then
    QueueDeferredCall(Card^.ServiceCall)
  else if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

procedure WatchCard(Context: Pointer);
var
  Card: PE1000Card;
  PreviousLevel: TPriorityLevel;
begin
  Card := PE1000Card(Context);
  if Card^.IsSuspended then
    Exit;
  PreviousLevel := AcquireSpinLock(Card^.Rings.ReceiveLock);
  ReadE1000ReceiveCounters(Card^.Registers, Card^.Card.Statistics);
  ReleaseSpinLock(Card^.Rings.ReceiveLock, PreviousLevel);
  PreviousLevel := AcquireSpinLock(Card^.Rings.TransmitLock);
  ReadE1000TransmitCounters(Card^.Registers, Card^.Card.Statistics);
  ReleaseSpinLock(Card^.Rings.TransmitLock, PreviousLevel);
  CheckLink(Card);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
end;

{ --- Setting the card up ---------------------------------------------------- }

{ Everything but enabling receive and the interrupts, from reset. }
function PrepareHardware(Card: PE1000Card): Boolean;
begin
  Result := ResetE1000(Card^.Registers, Card^.Model^.Family);
  WriteE1000Address(Card^.Registers, Card^.Address);
  ConfigureE1000Link(Card^.Registers);
  ProgramE1000Rings(Card^.Rings);
  ConfigureE1000Transmit(Card^.Registers, Card^.Model^.Family);
end;

procedure EnableInterrupts(Card: PE1000Card);
begin
  if Card^.UsesInterrupts then
    WriteRegister(Card^.Registers, RegisterInterruptMaskSet, InterruptsUsed);
end;

procedure StartTimers(Card: PE1000Card);
begin
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
  if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

procedure ReportFailure(Pci: PPciDevice; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('e1000');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ --- Suspend to RAM --------------------------------------------------------- }

procedure SuspendCard(Context: Pointer);
var
  Card: PE1000Card;
begin
  Card := PE1000Card(Context);
  Card^.IsSuspended := True;
  StopE1000Rings(Card^.Rings);
  DisableE1000ReceiveAndTransmit(Card^.Registers);
  CancelTimer(Card^.WatchTimer);
  CancelTimer(Card^.PollTimer);
  CancelDeferredCall(Card^.ServiceCall);
  CancelDeferredCall(Card^.WatchCall);
end;

procedure ResumeCard(Context: Pointer);
var
  Card: PE1000Card;
begin
  Card := PE1000Card(Context);
  if not PrepareHardware(Card) then
    ReportFailure(Card^.Pci, 'the reset after waking did not finish');
  Card^.PendingCauses := 0;
  NetworkCardWoke(@Card^.Card);
  Card^.IsSuspended := False;
  EnableE1000Receive(Card^.Registers);
  EnableInterrupts(Card);
  StartTimers(Card);
  { Frames refused while asleep may go now; the link is looked at. }
  ReclaimE1000Transmits(Card^.Rings);
  AtomicOr(Card^.PendingCauses, InterruptLinkStatusChange);
  QueueDeferredCall(Card^.ServiceCall);
end;

{ --- Finding cards ------------------------------------------------------------ }

procedure ConnectInterrupt(Card: PE1000Card);
begin
  if ConnectPciMessageInterrupt(Card^.Pci, @HandleE1000Interrupt, Card) then
  begin
    Card^.UsesInterrupts := True;
    Card^.Card.InterruptDescription := 'MSI';
  end
  else if ConnectPciLineInterrupt(Card^.Pci, @HandleE1000Interrupt, Card) then
  begin
    Card^.UsesInterrupts := True;
    Card^.Card.InterruptDescription := 'line';
  end
  else
    Card^.Card.InterruptDescription := 'polling';
end;

function StartCard(Pci: PPciDevice; Model: PE1000Model): Boolean;
var
  Card: PE1000Card;
  Bar: TPciBar;
  Routines: TNetworkDriverRoutines;
begin
  Result := False;
  if not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort then
    Exit;
  Card := PE1000Card(AllocateZeroedKernelMemory(SizeOf(TE1000Card)));
  if Card = nil then
    Exit;
  Card^.Pci := Pci;
  Card^.Model := Model;
  GetPciDmaAttributes(Pci, Card^.Dma);
  { The conventional PCI parts are given 32-bit addresses (as Linux
    does: 64-bit DMA is unreliable on some of them); the PCI Express
    ones take 64-bit addresses. }
  if (Model^.Family = FamilyClassic) or (Model^.Family = FamilyClassicLater) then
    LimitNetworkCardDma(Card^.Dma);
  PciEnableDevice(Pci, True);
  Card^.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Card^.Registers = nil then
    Exit;
  if not ResetE1000(Card^.Registers, Model^.Family) then
    ReportFailure(Pci, 'the reset did not finish; going on');
  if not ReadE1000Address(Card^.Registers, Model^.Family, Pci^.FunctionNumber, Card^.Address) then
  begin
    ReportFailure(Pci, 'no valid station address');
    Exit;
  end;
  if not AllocateE1000Rings(Card^.Rings, Card^.Registers, @Card^.Card, Card^.Dma) then
  begin
    ReportFailure(Pci, 'not enough memory for the rings');
    Exit;
  end;
  InitializeDeferredCall(Card^.ServiceCall, @ServiceCard, Card);
  InitializeDeferredCall(Card^.WatchCall, @WatchCard, Card);
  InitializeTimer(Card^.PollTimer);
  InitializeTimer(Card^.WatchTimer);
  PrepareHardware(Card);
  ConnectInterrupt(Card);
  ReadE1000Link(Card^.Registers, Card^.Card.Link);

  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @LinkIsUp;
  Routines.Kind := NetworkAdapterKindEthernet;
  { Takes all multicast; the network layer filters by group. }
  Routines.SetMulticastFilter := nil;
  if not AddNetworkCard(@Card^.Card, Routines, Card, Card^.Address, Model^.Name) then
  begin
    DisableE1000ReceiveAndTransmit(Card^.Registers);
    StopE1000Rings(Card^.Rings);
    ReportFailure(Pci, 'the adapter could not be registered');
    Exit;
  end;
  EnableE1000Receive(Card^.Registers);
  EnableInterrupts(Card);
  StartTimers(Card);
  RegisterPowerHandler('e1000', PowerStageDevices, @SuspendCard, @ResumeCard, Card);
  Result := True;
end;

function InitializeE1000Adapters: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
  Model: PE1000Model;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.VendorId <> IntelVendorId) or (Pci^.ClassCode <> PciClassNetwork) then
      Continue;
    Model := FindE1000Model(Pci^.DeviceId);
    if (Model <> nil) and StartCard(Pci, Model) then
      Inc(Result);
  end;
end;

end.
