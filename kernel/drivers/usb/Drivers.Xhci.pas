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
  USB through xHCI controllers (PCI class 0Ch, subclass 03h, interface
  30h), and the little of the USB core that goes with it.

  Starting a controller: take it over from the firmware, stop and reset
  it, give it the device context array (and the scratchpad pages it asks
  for), a command ring and an event ring, connect its interrupt (MSI-X
  or MSI; else events are polled) and run it. Then every port with a
  device is reset and its device enumerated: a slot is enabled, the
  device addressed (with its default control endpoint), its device and
  configuration descriptors read and its first configuration set. The
  class drivers registered with RegisterUsbClassDriver are offered it in
  turn. Devices plugged in later are not noticed.

  Commands and transfers are waited for: the interrupt's deferred call
  takes the events off the event ring and wakes whoever waits for them.
  A device may also have one repeating interrupt IN endpoint (reports
  handed to a routine) and one isochronous OUT stream
  (Drivers.XhciIsochronous: packets fed by the class driver).
  A device does one transfer at a time; its data goes through DMA pages
  of its own (up to UsbMaximumTransfer bytes per transfer), so callers'
  buffers can be anywhere.
}
unit Drivers.Xhci;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Mutex,
  Kernel.Events,
  Drivers.XhciRings,
  Drivers.XhciIsochronous;

const
  UsbMaximumTransfer = 64 * 1024;
  MaximumEndpointContexts = 32;
  UsbDmaPages = UsbMaximumTransfer div 4096;

  UsbSpeedFull = 1;
  UsbSpeedLow = 2;
  UsbSpeedHigh = 3;
  UsbSpeedSuper = 4;

  UsbDescriptorDevice = 1;
  UsbDescriptorConfiguration = 2;
  UsbDescriptorInterface = 4;
  UsbDescriptorEndpoint = 5;

type
  PUsbDevice = ^TUsbDevice;
  { Called with each report of an interrupt IN endpoint, at dispatch
    level (it must not wait). }
  TUsbReportHandler = procedure(Device: PUsbDevice; Data: PByte; Length: LongWord; Context: Pointer);
  TUsbDevice = record
    Controller: Pointer;
    SlotId: LongWord;
    PortNumber: LongWord;
    Speed: LongWord;
    DeviceDescriptor: array[0..17] of Byte;
    { The whole configuration descriptor, interfaces and endpoints. }
    Configuration: PByte;
    ConfigurationLength: LongWord;

    { Private to the xHCI driver. }
    InputContext: PByte;
    InputContextPhysical: QWord;
    OutputContext: PByte;
    OutputContextPhysical: QWord;
    Rings: array[1..MaximumEndpointContexts - 1] of TProducerRing;
    EndpointMaximumPacket: array[1..MaximumEndpointContexts - 1] of Word;
    DmaPages: array[0..UsbDmaPages - 1] of PByte;
    DmaPagesPhysical: array[0..UsbDmaPages - 1] of QWord;
    TransferLock: TMutex;
    TransferDone: TEvent;
    { The TRBs of the transfer waited for, and how its event came out. }
    PendingTrbs: array[0..UsbDmaPages + 2] of QWord;
    PendingLengths: array[0..UsbDmaPages + 2] of LongWord;
    PendingCount: Integer;
    EventCode: LongWord;
    EventTrb: QWord;
    EventResidue: LongWord;
    { The highest endpoint context in use (for the slot context). }
    HighestContext: LongWord;
    { A repeating interrupt IN transfer: its endpoint, buffer, length,
      the TRB in flight and who gets the reports. }
    InterruptContext: LongWord;
    InterruptBuffer: PByte;
    InterruptBufferPhysical: QWord;
    InterruptLength: LongWord;
    InterruptTrb: QWord;
    InterruptHandler: TUsbReportHandler;
    InterruptHandlerContext: Pointer;
    { An isochronous OUT stream: its endpoint context (0 if none). }
    IsochronousContext: LongWord;
    Isochronous: TIsochronousStream;
  end;

  { Returns True if it took the device. }
  TUsbClassProbe = function(Device: PUsbDevice): Boolean;

procedure RegisterUsbClassDriver(Probe: TUsbClassProbe);
{ Starts every xHCI controller and enumerates its devices; returns how
  many devices were found. }
function InitializeXhciControllers: Integer;

{ A control transfer on endpoint 0: the setup packet's fields, and Length
  bytes of data from or to Buffer (direction from RequestType). }
function UsbControlTransfer(Device: PUsbDevice; RequestType, Request: Byte; Value, Index: Word;
  Buffer: Pointer; Length: Word): Boolean;
{ Makes the bulk endpoints InAddress (80h set) and OutAddress usable. }
function UsbOpenBulkEndpoints(Device: PUsbDevice; InAddress, OutAddress: Byte;
  InMaximumPacket, OutMaximumPacket: Word): Boolean;
{ Starts reading the interrupt IN endpoint Address (Interval as in its
  endpoint descriptor) over and over; Handler gets every report. One
  such endpoint per device. }
function UsbStartInterruptIn(Device: PUsbDevice; Address: Byte; MaximumPacket: Word; Interval: Byte;
  Handler: TUsbReportHandler; Context: Pointer): Boolean;
{ Makes the isochronous OUT endpoint Address (Interval as in its
  endpoint descriptor) usable for a stream fed by Routines. One per
  device. }
function UsbOpenIsochronousOut(Device: PUsbDevice; Address: Byte; MaximumPacket: Word; Interval: Byte;
  const Routines: TIsochronousRoutines; Context: Pointer): Boolean;
{ Starts and stops queueing the stream's packets (callable at dispatch
  level). }
procedure UsbStartIsochronous(Device: PUsbDevice);
procedure UsbStopIsochronous(Device: PUsbDevice);
{ Moves up to Length (at most UsbMaximumTransfer) bytes on the bulk
  endpoint EndpointAddress; Transferred says how many moved. }
function UsbBulkTransfer(Device: PUsbDevice; EndpointAddress: Byte; Buffer: Pointer; Length: LongWord;
  out Transferred: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.DeferredCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Io.Pci,
  Io.PciMessageInterrupts,
  Debug.Output;

const
  PciClassSerialBus = $0C;
  PciSubclassUsb = $03;
  PciInterfaceXhci = $30;

  MaximumClassDrivers = 8;
  MaximumEnabledSlots = 16;
  CommandTimeoutMilliseconds = 5000;
  TransferTimeoutMilliseconds = 5000;

  { Capability registers. }
  CapabilityLengthRegister = $00;
  StructuralParameters1 = $04;
  StructuralParameters2 = $08;
  CapabilityParameters1 = $10;
  DoorbellOffsetRegister = $14;
  RuntimeOffsetRegister = $18;

  { Operational registers. }
  UsbCommand = $00;
  UsbStatus = $04;
  CommandRingControl = $18;
  ContextArrayPointer = $30;
  ConfigureRegister = $38;
  PortRegisterBase = $400;
  PortRegisterStride = $10;

  CommandRun = LongWord(1) shl 0;
  CommandReset = LongWord(1) shl 1;
  CommandInterrupterEnable = LongWord(1) shl 2;
  StatusHalted = LongWord(1) shl 0;
  StatusEventInterrupt = LongWord(1) shl 3;
  StatusNotReady = LongWord(1) shl 11;

  { Port status and control. }
  PortConnected = LongWord(1) shl 0;
  PortEnabled = LongWord(1) shl 1;
  PortReset = LongWord(1) shl 4;
  PortPower = LongWord(1) shl 9;
  PortSpeedShift = 10;
  PortChangeBits = LongWord($00FE0000);
  PortResetChange = LongWord(1) shl 21;

  { Interrupter 0, in the runtime registers. }
  InterrupterBase = $20;
  InterrupterManagement = $00;
  InterrupterSegmentTableSize = $08;
  InterrupterSegmentTableBase = $10;
  InterrupterDequeuePointer = $18;
  ManagementPending = LongWord(1) shl 0;
  ManagementEnable = LongWord(1) shl 1;
  DequeueEventHandlerBusy = QWord(1) shl 3;

  ExtendedCapabilityLegacySupport = 1;
  LegacyBiosOwned = LongWord(1) shl 16;
  LegacyOsOwned = LongWord(1) shl 24;

  EndpointTypeControl = 4;
  EndpointTypeIsochronousOut = 1;
  EndpointTypeBulkOut = 2;
  EndpointTypeBulkIn = 6;
  EndpointTypeInterruptIn = 7;

type
  PXhciController = ^TXhciController;
  TXhciController = record
    Pci: PPciDevice;
    Capabilities: PByte;
    Operational: PByte;
    Runtime: PByte;
    Doorbells: PLongWord;
    MaximumSlots: LongWord;
    MaximumPorts: LongWord;
    ContextSize: LongWord;
    ContextArray: PQWord;
    ContextArrayPhysical: QWord;
    CommandRing: TProducerRing;
    EventRing: TEventRing;
    EventLock: TSpinLock;
    ProcessEventsCall: TDeferredCall;
    UsesInterrupts: Boolean;
    CommandLock: TMutex;
    CommandDone: TEvent;
    PendingCommandTrb: QWord;
    CommandCode: LongWord;
    CommandSlot: LongWord;
    Devices: array[0..MaximumEnabledSlots] of PUsbDevice;
  end;

var
  ClassDrivers: array[0..MaximumClassDrivers - 1] of TUsbClassProbe;
  ClassDriverCount: Integer;

procedure RegisterUsbClassDriver(Probe: TUsbClassProbe);
begin
  if ClassDriverCount < MaximumClassDrivers then
  begin
    ClassDrivers[ClassDriverCount] := Probe;
    Inc(ClassDriverCount);
  end;
end;

{ --- Registers -------------------------------------------------------------- }

function Read32(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write32(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

procedure Write64(Base: PByte; Offset: LongWord; Value: QWord);
begin
  Write32(Base, Offset, LongWord(Value));
  Write32(Base, Offset + 4, LongWord(Value shr 32));
end;

function WaitForBits(Base: PByte; Offset: LongWord; Mask, Expected: LongWord;
  TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while (Read32(Base, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

function Interrupter(Controller: PXhciController): PByte;
begin
  Result := Controller^.Runtime + InterrupterBase;
end;

procedure RingDoorbell(Device: PUsbDevice; ContextIndex: LongWord); forward;

{ --- Events ----------------------------------------------------------------- }

{ True if Trb is one of the device's pending transfer's TRBs; Index says
  which. }
function FindPendingTrb(Device: PUsbDevice; Trb: QWord; out Index: Integer): Boolean;
var
  Candidate: Integer;
begin
  Index := -1;
  for Candidate := 0 to Device^.PendingCount - 1 do
    if Device^.PendingTrbs[Candidate] = Trb then
    begin
      Index := Candidate;
      Exit(True);
    end;
  Result := False;
end;

{ Puts the next read of the device's interrupt endpoint on its ring.
  Caller holds the event lock. }
procedure QueueInterruptRead(Device: PUsbDevice);
begin
  Device^.InterruptTrb := EnqueueTrb(Device^.Rings[Device^.InterruptContext], Device^.InterruptBufferPhysical,
    Device^.InterruptLength, (TrbTypeNormal shl TrbTypeShift) or TrbInterruptOnCompletion or
    TrbInterruptOnShortPacket);
  FullMemoryBarrier;
  PXhciController(Device^.Controller)^.Doorbells[Device^.SlotId] := Device^.InterruptContext;
end;

{ A report arrived: the handler gets it and the next read is queued (a
  failed read ends the reading). }
procedure HandleInterruptReport(Controller: PXhciController; Device: PUsbDevice; const Event: TTrb);
var
  Code: LongWord;
  Residue: LongWord;
begin
  Code := CompletionCode(Event);
  Device^.InterruptTrb := 0;
  if (Code <> CompletionSuccess) and (Code <> CompletionShortPacket) then
    Exit;
  Residue := Event.Status and $FFFFFF;
  if Residue <= Device^.InterruptLength then
    Device^.InterruptHandler(Device, Device^.InterruptBuffer, Device^.InterruptLength - Residue,
      Device^.InterruptHandlerContext);
  QueueInterruptRead(Device);
end;

procedure HandleEvent(Controller: PXhciController; const Event: TTrb);
var
  Slot: LongWord;
  Device: PUsbDevice;
  Index: Integer;
begin
  case TrbType(Event) of
    TrbTypeCommandCompletionEvent:
      if Event.Parameter = Controller^.PendingCommandTrb then
      begin
        Controller^.CommandCode := CompletionCode(Event);
        Controller^.CommandSlot := Event.Control shr 24;
        Controller^.PendingCommandTrb := 0;
        SignalEvent(Controller^.CommandDone);
      end;
    TrbTypeTransferEvent:
      begin
        Slot := Event.Control shr 24;
        if Slot > MaximumEnabledSlots then
          Exit;
        Device := Controller^.Devices[Slot];
        if Device = nil then
          Exit;
        if (Device^.InterruptTrb <> 0) and (Event.Parameter = Device^.InterruptTrb) then
        begin
          HandleInterruptReport(Controller, Device, Event);
          Exit;
        end;
        if (Device^.IsochronousContext <> 0) and
           (((Event.Control shr 16) and $1F) = Device^.IsochronousContext) then
        begin
          if IsochronousEventArrived(Device^.Isochronous, Event) then
            RingDoorbell(Device, Device^.IsochronousContext);
          Exit;
        end;
        { Only an event for a TRB of the transfer waited for counts. }
        if not FindPendingTrb(Device, Event.Parameter, Index) then
          Exit;
        Device^.EventCode := CompletionCode(Event);
        Device^.EventTrb := Event.Parameter;
        Device^.EventResidue := Event.Status and $FFFFFF;
        Device^.PendingCount := 0;
        SignalEvent(Device^.TransferDone);
      end;
  end;
end;

procedure ProcessEvents(Context: Pointer);
var
  Controller: PXhciController;
  Event: TTrb;
  PreviousLevel: TPriorityLevel;
  Handled: Boolean;
begin
  Controller := PXhciController(Context);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Write32(Interrupter(Controller), InterrupterManagement,
    Read32(Interrupter(Controller), InterrupterManagement) or ManagementPending);
  Write32(Controller^.Operational, UsbStatus, StatusEventInterrupt);
  Handled := False;
  while NextEvent(Controller^.EventRing, Event) do
  begin
    HandleEvent(Controller, Event);
    Handled := True;
  end;
  if Handled then
    Write64(Interrupter(Controller), InterrupterDequeuePointer,
      EventDequeuePointer(Controller^.EventRing) or DequeueEventHandlerBusy);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
end;

procedure HandleXhciInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  QueueDeferredCall(PXhciController(Context)^.ProcessEventsCall);
end;

{ Waits for Event, taking events off the ring meanwhile if the controller
  has no interrupt. }
function WaitForCompletion(Controller: PXhciController; var Event: TEvent; TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  if Controller^.UsesInterrupts then
    Exit(WaitForEventWithOptions(Event, TimeoutMilliseconds, False) = WaitSignaled);
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  repeat
    ProcessEvents(Controller);
    if WaitForEventWithOptions(Event, 1, False) = WaitSignaled then
      Exit(True);
  until ClockTickCount > Deadline;
  Result := False;
end;

{ --- Commands ---------------------------------------------------------------- }

{ Runs a command TRB; True if it completed successfully. Slot returns the
  slot the completion names (for Enable Slot). }
function RunCommand(Controller: PXhciController; Parameter: QWord; Control: LongWord;
  out Slot: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  AcquireMutex(Controller^.CommandLock);
  ResetEvent(Controller^.CommandDone);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Controller^.PendingCommandTrb := EnqueueTrb(Controller^.CommandRing, Parameter, 0, Control);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
  Controller^.Doorbells[0] := 0;
  Result := WaitForCompletion(Controller, Controller^.CommandDone, CommandTimeoutMilliseconds) and
    (Controller^.CommandCode = CompletionSuccess);
  Slot := Controller^.CommandSlot;
  ReleaseMutex(Controller^.CommandLock);
end;

{ --- Contexts ---------------------------------------------------------------- }

function InputControlContext(Device: PUsbDevice): PLongWord;
begin
  Result := PLongWord(Device^.InputContext);
end;

function InputSlotContext(Device: PUsbDevice): PLongWord;
begin
  Result := PLongWord(Device^.InputContext + PXhciController(Device^.Controller)^.ContextSize);
end;

function InputEndpointContext(Device: PUsbDevice; ContextIndex: LongWord): PLongWord;
begin
  Result := PLongWord(Device^.InputContext + PXhciController(Device^.Controller)^.ContextSize *
    (ContextIndex + 1));
end;

{ The device context index of an endpoint address. }
function ContextIndexOf(EndpointAddress: Byte): LongWord;
begin
  Result := (EndpointAddress and $F) * 2;
  if (EndpointAddress and $80) <> 0 then
    Inc(Result);
end;

procedure FillEndpointContext(Context: PLongWord; EndpointType: LongWord; MaximumPacket: Word;
  RingPhysical: QWord; AverageLength: Word);
const
  ErrorCount = 3;
begin
  FillMemory(Context, 32, 0);
  Context[1] := (ErrorCount shl 1) or (EndpointType shl 3) or (LongWord(MaximumPacket) shl 16);
  Context[2] := LongWord(RingPhysical) or 1; { dequeue cycle state }
  Context[3] := LongWord(RingPhysical shr 32);
  Context[4] := AverageLength;
end;

function AllocatePage(out Physical: QWord): PByte; forward;

{ --- Transfers ---------------------------------------------------------------- }

procedure RingDoorbell(Device: PUsbDevice; ContextIndex: LongWord);
begin
  FullMemoryBarrier;
  PXhciController(Device^.Controller)^.Doorbells[Device^.SlotId] := ContextIndex;
end;

{ Notes TRB (of Length bytes) as part of the transfer about to be waited
  for. }
procedure NotePending(Device: PUsbDevice; Trb: QWord; Length: LongWord);
begin
  Device^.PendingTrbs[Device^.PendingCount] := Trb;
  Device^.PendingLengths[Device^.PendingCount] := Length;
  Inc(Device^.PendingCount);
end;

function UsbControlTransfer(Device: PUsbDevice; RequestType, Request: Byte; Value, Index: Word;
  Buffer: Pointer; Length: Word): Boolean;
const
  TransferTypeNoData = 0;
  TransferTypeOut = 2;
  TransferTypeIn = 3;
  DirectionIn = LongWord(1) shl 16;
var
  Controller: PXhciController;
  Setup: QWord;
  IsIn: Boolean;
  TransferType: LongWord;
  StatusDirection: LongWord;
  StatusTrb: QWord;
  PreviousLevel: TPriorityLevel;
begin
  Controller := PXhciController(Device^.Controller);
  if Length > 4096 then
    Exit(False);
  IsIn := (RequestType and $80) <> 0;
  Setup := QWord(RequestType) or (QWord(Request) shl 8) or (QWord(Value) shl 16) or
    (QWord(Index) shl 32) or (QWord(Length) shl 48);
  if Length = 0 then
    TransferType := TransferTypeNoData
  else if IsIn then
    TransferType := TransferTypeIn
  else
    TransferType := TransferTypeOut;
  AcquireMutex(Device^.TransferLock);
  if (Length > 0) and not IsIn then
    CopyMemory(Device^.DmaPages[0], Buffer, Length);
  ResetEvent(Device^.TransferDone);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.PendingCount := 0;
  EnqueueTrb(Device^.Rings[1], Setup, 8,
    (TrbTypeSetupStage shl TrbTypeShift) or TrbImmediateData or (TransferType shl 16));
  if Length > 0 then
  begin
    if IsIn then
      EnqueueTrb(Device^.Rings[1], Device^.DmaPagesPhysical[0], Length,
        (TrbTypeDataStage shl TrbTypeShift) or DirectionIn)
    else
      EnqueueTrb(Device^.Rings[1], Device^.DmaPagesPhysical[0], Length, TrbTypeDataStage shl TrbTypeShift);
  end;
  { The status stage goes the other way (in, without data). }
  StatusDirection := DirectionIn;
  if (Length > 0) and IsIn then
    StatusDirection := 0;
  StatusTrb := EnqueueTrb(Device^.Rings[1], 0, 0,
    (TrbTypeStatusStage shl TrbTypeShift) or TrbInterruptOnCompletion or StatusDirection);
  NotePending(Device, StatusTrb, 0);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
  RingDoorbell(Device, 1);
  Result := WaitForCompletion(Controller, Device^.TransferDone, TransferTimeoutMilliseconds) and
    (Device^.EventCode = CompletionSuccess);
  if Result and (Length > 0) and IsIn then
    CopyMemory(Buffer, Device^.DmaPages[0], Length);
  ReleaseMutex(Device^.TransferLock);
end;

function UsbBulkTransfer(Device: PUsbDevice; EndpointAddress: Byte; Buffer: Pointer; Length: LongWord;
  out Transferred: LongWord): Boolean;
var
  Controller: PXhciController;
  ContextIndex: LongWord;
  IsIn: Boolean;
  PageIndex: Integer;
  Chunk: LongWord;
  Remaining: LongWord;
  Control: LongWord;
  Trb: QWord;
  EventIndex: Integer;
  PreviousLevel: TPriorityLevel;
begin
  Transferred := 0;
  Controller := PXhciController(Device^.Controller);
  ContextIndex := ContextIndexOf(EndpointAddress);
  IsIn := (EndpointAddress and $80) <> 0;
  if (Length = 0) or (Length > UsbMaximumTransfer) or (Device^.Rings[ContextIndex].Trbs = nil) then
    Exit(False);
  AcquireMutex(Device^.TransferLock);
  if not IsIn then
    for PageIndex := 0 to Integer((Length - 1) div 4096) do
    begin
      Chunk := Length - LongWord(PageIndex) * 4096;
      if Chunk > 4096 then
        Chunk := 4096;
      CopyMemory(Device^.DmaPages[PageIndex], PByte(Buffer) + PageIndex * 4096, Chunk);
    end;
  ResetEvent(Device^.TransferDone);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.PendingCount := 0;
  Remaining := Length;
  PageIndex := 0;
  while Remaining > 0 do
  begin
    Chunk := Remaining;
    if Chunk > 4096 then
      Chunk := 4096;
    Remaining := Remaining - Chunk;
    Control := (TrbTypeNormal shl TrbTypeShift) or TrbInterruptOnShortPacket;
    if Remaining > 0 then
      Control := Control or TrbChain
    else
      Control := Control or TrbInterruptOnCompletion;
    Trb := EnqueueTrb(Device^.Rings[ContextIndex], Device^.DmaPagesPhysical[PageIndex], Chunk, Control);
    NotePending(Device, Trb, Chunk);
    Inc(PageIndex);
  end;
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
  RingDoorbell(Device, ContextIndex);
  Result := WaitForCompletion(Controller, Device^.TransferDone, TransferTimeoutMilliseconds) and
    ((Device^.EventCode = CompletionSuccess) or (Device^.EventCode = CompletionShortPacket));
  if Result then
  begin
    { Everything up to the TRB the event names, less what it left over. }
    for EventIndex := 0 to PageIndex - 1 do
    begin
      Transferred := Transferred + Device^.PendingLengths[EventIndex];
      if Device^.PendingTrbs[EventIndex] = Device^.EventTrb then
        Break;
    end;
    Transferred := Transferred - Device^.EventResidue;
    if IsIn then
      for EventIndex := 0 to Integer((Transferred + 4095) div 4096) - 1 do
      begin
        Chunk := Transferred - LongWord(EventIndex) * 4096;
        if Chunk > 4096 then
          Chunk := 4096;
        CopyMemory(PByte(Buffer) + EventIndex * 4096, Device^.DmaPages[EventIndex], Chunk);
      end;
  end;
  Device^.PendingCount := 0;
  ReleaseMutex(Device^.TransferLock);
end;

{ Adds endpoint Address (of EndpointType) with a fresh transfer ring:
  a Configure Endpoint command with the slot (for its context entries)
  and that endpoint. IntervalExponent: 125 us units, as a power of two. }
function ConfigureEndpoint(Device: PUsbDevice; Address: Byte; EndpointType: LongWord; MaximumPacket: Word;
  IntervalExponent: LongWord; AverageLength: Word): Boolean;
var
  ContextIndex: LongWord;
  Context: PLongWord;
  Slot: LongWord;
begin
  ContextIndex := ContextIndexOf(Address);
  if (ContextIndex >= MaximumEndpointContexts) or not AllocateProducerRing(Device^.Rings[ContextIndex]) then
    Exit(False);
  if ContextIndex > Device^.HighestContext then
    Device^.HighestContext := ContextIndex;
  FillMemory(Device^.InputContext, 4096, 0);
  InputControlContext(Device)[1] := 1 or (LongWord(1) shl ContextIndex);
  CopyMemory(InputSlotContext(Device), Device^.OutputContext, 32);
  InputSlotContext(Device)[0] := (InputSlotContext(Device)[0] and not (LongWord($1F) shl 27)) or
    (Device^.HighestContext shl 27);
  Context := InputEndpointContext(Device, ContextIndex);
  FillEndpointContext(Context, EndpointType, MaximumPacket, Device^.Rings[ContextIndex].Physical, AverageLength);
  Context[0] := IntervalExponent shl 16;
  if EndpointType in [EndpointTypeInterruptIn, EndpointTypeIsochronousOut] then
    { The most bytes per service interval. }
    Context[4] := Context[4] or (LongWord(MaximumPacket) shl 16);
  if EndpointType = EndpointTypeIsochronousOut then
    { Isochronous transfers are not retried: the error count is 0. }
    Context[1] := Context[1] and not (LongWord(3) shl 1);
  Device^.EndpointMaximumPacket[ContextIndex] := MaximumPacket;
  Result := RunCommand(PXhciController(Device^.Controller), Device^.InputContextPhysical,
    (TrbTypeConfigureEndpoint shl TrbTypeShift) or (Device^.SlotId shl 24), Slot);
end;

function UsbOpenBulkEndpoints(Device: PUsbDevice; InAddress, OutAddress: Byte;
  InMaximumPacket, OutMaximumPacket: Word): Boolean;
begin
  Result := ConfigureEndpoint(Device, InAddress, EndpointTypeBulkIn, InMaximumPacket, 0, 3072) and
    ConfigureEndpoint(Device, OutAddress, EndpointTypeBulkOut, OutMaximumPacket, 0, 3072);
end;

{ The interval exponent (125 us units) of an endpoint descriptor's
  bInterval: milliseconds on full and low speed, an exponent itself on
  high and super speed. }
function IntervalExponentFor(Device: PUsbDevice; Interval: Byte): LongWord;
var
  Microframes: LongWord;
begin
  if Interval = 0 then
    Interval := 1;
  if (Device^.Speed = UsbSpeedHigh) or (Device^.Speed = UsbSpeedSuper) then
    Exit(Interval - 1);
  Microframes := LongWord(Interval) * 8;
  Result := 0;
  while (LongWord(2) shl Result) <= Microframes do
    Inc(Result);
end;

function UsbStartInterruptIn(Device: PUsbDevice; Address: Byte; MaximumPacket: Word; Interval: Byte;
  Handler: TUsbReportHandler; Context: Pointer): Boolean;
var
  Controller: PXhciController;
  PreviousLevel: TPriorityLevel;
begin
  Controller := PXhciController(Device^.Controller);
  if (Device^.InterruptContext <> 0) or (MaximumPacket = 0) or (MaximumPacket > 1024) then
    Exit(False);
  Device^.InterruptBuffer := AllocatePage(Device^.InterruptBufferPhysical);
  if (Device^.InterruptBuffer = nil) or
     not ConfigureEndpoint(Device, Address, EndpointTypeInterruptIn, MaximumPacket,
       IntervalExponentFor(Device, Interval), MaximumPacket) then
    Exit(False);
  Device^.InterruptLength := MaximumPacket;
  Device^.InterruptHandler := Handler;
  Device^.InterruptHandlerContext := Context;
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.InterruptContext := ContextIndexOf(Address);
  QueueInterruptRead(Device);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
  Result := True;
end;

function UsbOpenIsochronousOut(Device: PUsbDevice; Address: Byte; MaximumPacket: Word; Interval: Byte;
  const Routines: TIsochronousRoutines; Context: Pointer): Boolean;
var
  ContextIndex: LongWord;
begin
  if (Device^.IsochronousContext <> 0) or (MaximumPacket = 0) or ((Address and $80) <> 0) then
    Exit(False);
  Result := ConfigureEndpoint(Device, Address, EndpointTypeIsochronousOut, MaximumPacket,
    IntervalExponentFor(Device, Interval), MaximumPacket);
  if not Result then
    Exit;
  ContextIndex := ContextIndexOf(Address);
  InitializeIsochronousStream(Device^.Isochronous, Device^.Rings[ContextIndex], Routines, Context);
  Device^.IsochronousContext := ContextIndex;
end;

procedure UsbStartIsochronous(Device: PUsbDevice);
var
  Controller: PXhciController;
  PreviousLevel: TPriorityLevel;
begin
  Controller := PXhciController(Device^.Controller);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.Isochronous.Streaming := True;
  if FillIsochronousStream(Device^.Isochronous) then
    RingDoorbell(Device, Device^.IsochronousContext);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
end;

procedure UsbStopIsochronous(Device: PUsbDevice);
var
  Controller: PXhciController;
  PreviousLevel: TPriorityLevel;
begin
  Controller := PXhciController(Device^.Controller);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.Isochronous.Streaming := False;
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
end;

{ --- Enumeration ---------------------------------------------------------------- }

function AllocatePage(out Physical: QWord): PByte;
begin
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit(nil);
  Result := PByte(PhysicalToVirtual(Physical));
end;

function DefaultControlPacketSize(Speed: LongWord): Word;
begin
  case Speed of
    UsbSpeedSuper: Result := 512;
    UsbSpeedHigh: Result := 64;
  else
    Result := 8;
  end;
end;

{ Resets a USB 2 port (USB 3 ports enable themselves); True if the port
  ends up enabled. }
function ResetPort(Controller: PXhciController; PortNumber: LongWord): Boolean;
var
  Offset: LongWord;
  Status: LongWord;
begin
  Offset := PortRegisterBase + (PortNumber - 1) * PortRegisterStride;
  Status := Read32(Controller^.Operational, Offset);
  if (Status and PortEnabled) = 0 then
  begin
    { Writing 1 to the enable or change bits would clear them. }
    Write32(Controller^.Operational, Offset,
      (Status and not (PortChangeBits or PortEnabled)) or PortReset);
    if not WaitForBits(Controller^.Operational, Offset, PortResetChange, PortResetChange, 500) then
      Exit(False);
    Status := Read32(Controller^.Operational, Offset);
    Write32(Controller^.Operational, Offset, (Status and not (PortChangeBits or PortEnabled)) or
      PortResetChange);
    { Reset recovery. }
    SleepMilliseconds(20);
  end;
  Result := (Read32(Controller^.Operational, Offset) and PortEnabled) <> 0;
end;

function GetDescriptor(Device: PUsbDevice; DescriptorType: Byte; Buffer: Pointer; Length: Word): Boolean;
const
  RequestGetDescriptor = 6;
begin
  Result := UsbControlTransfer(Device, $80, RequestGetDescriptor, Word(DescriptorType) shl 8, 0, Buffer, Length);
end;

{ Reads the configuration descriptor (all of it) and sets that
  configuration. }
function SetFirstConfiguration(Device: PUsbDevice): Boolean;
const
  RequestSetConfiguration = 9;
var
  Header: array[0..8] of Byte;
  TotalLength: Word;
begin
  Result := False;
  if not GetDescriptor(Device, UsbDescriptorConfiguration, @Header[0], 9) then
    Exit;
  TotalLength := Header[2] or (Word(Header[3]) shl 8);
  if (TotalLength < 9) or (TotalLength > 4096) then
    Exit;
  Device^.Configuration := PByte(AllocateKernelMemory(TotalLength));
  if (Device^.Configuration = nil) or
     not GetDescriptor(Device, UsbDescriptorConfiguration, Device^.Configuration, TotalLength) then
    Exit;
  Device^.ConfigurationLength := TotalLength;
  Result := UsbControlTransfer(Device, 0, RequestSetConfiguration, Header[5], 0, nil, 0);
end;

{ A full speed device's control endpoint takes 8, 16, 32 or 64 bytes a
  packet; the first 8 bytes of its device descriptor say which, and an
  Evaluate Context command tells the controller. }
function CorrectControlPacketSize(Device: PUsbDevice): Boolean;
var
  Start: array[0..7] of Byte;
  Slot: LongWord;
begin
  Result := GetDescriptor(Device, UsbDescriptorDevice, @Start[0], 8);
  if not Result or (Start[7] = 8) or (Start[7] = 0) then
    Exit;
  FillMemory(Device^.InputContext, 4096, 0);
  InputControlContext(Device)[1] := LongWord(1) shl 1;
  CopyMemory(InputEndpointContext(Device, 1), Device^.OutputContext + PXhciController(Device^.Controller)^.ContextSize, 32);
  InputEndpointContext(Device, 1)[1] := (InputEndpointContext(Device, 1)[1] and $FFFF) or (LongWord(Start[7]) shl 16);
  Result := RunCommand(PXhciController(Device^.Controller), Device^.InputContextPhysical,
    (TrbTypeEvaluateContext shl TrbTypeShift) or (Device^.SlotId shl 24), Slot);
end;

{ Gives the device on PortNumber a slot and an address, reads its
  descriptors and offers it to the class drivers. }
function EnumerateDevice(Controller: PXhciController; PortNumber: LongWord): Boolean;
var
  Device: PUsbDevice;
  Slot: LongWord;
  Index: Integer;
  PortStatus: LongWord;
begin
  Result := False;
  if not ResetPort(Controller, PortNumber) then
    Exit;
  if not RunCommand(Controller, 0, TrbTypeEnableSlot shl TrbTypeShift, Slot) or
     (Slot = 0) or (Slot > MaximumEnabledSlots) then
    Exit;
  Device := PUsbDevice(AllocateZeroedKernelMemory(SizeOf(TUsbDevice)));
  if Device = nil then
    Exit;
  Device^.Controller := Controller;
  Device^.SlotId := Slot;
  Device^.PortNumber := PortNumber;
  PortStatus := Read32(Controller^.Operational, PortRegisterBase + (PortNumber - 1) * PortRegisterStride);
  Device^.Speed := (PortStatus shr PortSpeedShift) and $F;
  InitializeMutex(Device^.TransferLock);
  InitializeEvent(Device^.TransferDone, EventKindNotification, False);
  Device^.InputContext := AllocatePage(Device^.InputContextPhysical);
  Device^.OutputContext := AllocatePage(Device^.OutputContextPhysical);
  if (Device^.InputContext = nil) or (Device^.OutputContext = nil) or
     not AllocateProducerRing(Device^.Rings[1]) then
    Exit;
  for Index := 0 to UsbDmaPages - 1 do
  begin
    Device^.DmaPages[Index] := AllocatePage(Device^.DmaPagesPhysical[Index]);
    if Device^.DmaPages[Index] = nil then
      Exit;
  end;
  Controller^.ContextArray[Slot] := Device^.OutputContextPhysical;
  Controller^.Devices[Slot] := Device;

  { Address Device: the slot (one context entry, its port and speed) and
    the default control endpoint. }
  InputControlContext(Device)[1] := 3;
  InputSlotContext(Device)[0] := (LongWord(1) shl 27) or (Device^.Speed shl 20);
  InputSlotContext(Device)[1] := PortNumber shl 16;
  FillEndpointContext(InputEndpointContext(Device, 1), EndpointTypeControl,
    DefaultControlPacketSize(Device^.Speed), Device^.Rings[1].Physical, 8);
  if not RunCommand(Controller, Device^.InputContextPhysical,
    (TrbTypeAddressDevice shl TrbTypeShift) or (Slot shl 24), Slot) then
    Exit;
  Device^.HighestContext := 1;
  if (Device^.Speed = UsbSpeedFull) and not CorrectControlPacketSize(Device) then
    Exit;
  if not GetDescriptor(Device, UsbDescriptorDevice, @Device^.DeviceDescriptor[0], 18) or
     not SetFirstConfiguration(Device) then
    Exit;

  DebugBeginMessage;
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(PortNumber);
  DebugWrite(': device ');
  DebugWriteHex(Device^.DeviceDescriptor[8] or (Word(Device^.DeviceDescriptor[9]) shl 8), 4);
  DebugWrite(':');
  DebugWriteHex(Device^.DeviceDescriptor[10] or (Word(Device^.DeviceDescriptor[11]) shl 8), 4);
  DebugWrite(', speed ');
  DebugWriteDecimal(Device^.Speed);
  DebugWriteLine('');
  DebugEndMessage;

  for Index := 0 to ClassDriverCount - 1 do
    if ClassDrivers[Index](Device) then
      Break;
  Result := True;
end;

{ --- Starting a controller ----------------------------------------------------- }

procedure TakeOverFromFirmware(Controller: PXhciController);
var
  Offset: LongWord;
  Capability: LongWord;
  Steps: Integer;
begin
  Offset := (Read32(Controller^.Capabilities, CapabilityParameters1) shr 16) * 4;
  Steps := 0;
  while (Offset <> 0) and (Steps < 64) do
  begin
    Capability := Read32(Controller^.Capabilities, Offset);
    if (Capability and $FF) = ExtendedCapabilityLegacySupport then
    begin
      Write32(Controller^.Capabilities, Offset, Capability or LegacyOsOwned);
      WaitForBits(Controller^.Capabilities, Offset, LegacyBiosOwned, 0, 1000);
      Exit;
    end;
    if ((Capability shr 8) and $FF) = 0 then
      Exit;
    Offset := Offset + ((Capability shr 8) and $FF) * 4;
    Inc(Steps);
  end;
end;

function AllocateScratchpads(Controller: PXhciController): Boolean;
var
  Parameters: LongWord;
  Count: LongWord;
  ArrayPhysical: QWord;
  ScratchArray: PQWord;
  Index: LongWord;
begin
  Parameters := Read32(Controller^.Capabilities, StructuralParameters2);
  Count := (((Parameters shr 21) and $1F) shl 5) or ((Parameters shr 27) and $1F);
  if Count = 0 then
    Exit(True);
  ScratchArray := PQWord(AllocatePage(ArrayPhysical));
  if (ScratchArray = nil) or (Count > 512) then
    Exit(False);
  for Index := 0 to Count - 1 do
  begin
    ScratchArray[Index] := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if ScratchArray[Index] = 0 then
      Exit(False);
  end;
  Controller^.ContextArray[0] := ArrayPhysical;
  Result := True;
end;

function StartController(Pci: PPciDevice): Integer;
var
  Controller: PXhciController;
  Bar: TPciBar;
  Parameters: LongWord;
  PortNumber: LongWord;
begin
  Result := 0;
  if not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort then
    Exit;
  Controller := PXhciController(AllocateZeroedKernelMemory(SizeOf(TXhciController)));
  if Controller = nil then
    Exit;
  Controller^.Pci := Pci;
  PciEnableDevice(Pci, True);
  Controller^.Capabilities := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Controller^.Capabilities = nil then
    Exit;
  Controller^.Operational := Controller^.Capabilities + Controller^.Capabilities[CapabilityLengthRegister];
  Controller^.Runtime := Controller^.Capabilities +
    (Read32(Controller^.Capabilities, RuntimeOffsetRegister) and not LongWord($1F));
  Controller^.Doorbells := PLongWord(Controller^.Capabilities +
    (Read32(Controller^.Capabilities, DoorbellOffsetRegister) and not LongWord(3)));
  Parameters := Read32(Controller^.Capabilities, StructuralParameters1);
  Controller^.MaximumSlots := Parameters and $FF;
  if Controller^.MaximumSlots > MaximumEnabledSlots then
    Controller^.MaximumSlots := MaximumEnabledSlots;
  Controller^.MaximumPorts := Parameters shr 24;
  Controller^.ContextSize := 32;
  if (Read32(Controller^.Capabilities, CapabilityParameters1) and 4) <> 0 then
    Controller^.ContextSize := 64;
  InitializeSpinLock(Controller^.EventLock);
  InitializeMutex(Controller^.CommandLock);
  InitializeEvent(Controller^.CommandDone, EventKindNotification, False);
  InitializeDeferredCall(Controller^.ProcessEventsCall, @ProcessEvents, Controller);

  TakeOverFromFirmware(Controller);
  { Stop, then reset. }
  Write32(Controller^.Operational, UsbCommand, Read32(Controller^.Operational, UsbCommand) and not CommandRun);
  if not WaitForBits(Controller^.Operational, UsbStatus, StatusHalted, StatusHalted, 1000) then
    Exit;
  Write32(Controller^.Operational, UsbCommand, CommandReset);
  if not WaitForBits(Controller^.Operational, UsbCommand, CommandReset, 0, 1000) or
     not WaitForBits(Controller^.Operational, UsbStatus, StatusNotReady, 0, 1000) then
    Exit;

  Controller^.ContextArray := PQWord(AllocatePage(Controller^.ContextArrayPhysical));
  if (Controller^.ContextArray = nil) or not AllocateScratchpads(Controller) or
     not AllocateProducerRing(Controller^.CommandRing) or not AllocateEventRing(Controller^.EventRing) then
    Exit;
  Write32(Controller^.Operational, ConfigureRegister, Controller^.MaximumSlots);
  Write64(Controller^.Operational, ContextArrayPointer, Controller^.ContextArrayPhysical);
  Write64(Controller^.Operational, CommandRingControl, Controller^.CommandRing.Physical or 1);
  Write32(Interrupter(Controller), InterrupterSegmentTableSize, 1);
  Write64(Interrupter(Controller), InterrupterDequeuePointer, Controller^.EventRing.Physical);
  Write64(Interrupter(Controller), InterrupterSegmentTableBase, Controller^.EventRing.SegmentTablePhysical);

  Controller^.UsesInterrupts :=
    ConnectPciInterrupt(Pci, @HandleXhciInterrupt, Controller) <> PciInterruptNone;
  Write32(Interrupter(Controller), InterrupterManagement, ManagementEnable or ManagementPending);
  Write32(Controller^.Operational, UsbCommand, CommandRun or CommandInterrupterEnable);
  if not WaitForBits(Controller^.Operational, UsbStatus, StatusHalted, 0, 1000) then
    Exit;

  DebugBeginMessage;
  DebugWriteTag('xhci');
  DebugWrite('Controller ');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  DebugWrite(', ');
  DebugWriteDecimal(Controller^.MaximumPorts);
  if Controller^.UsesInterrupts then
    DebugWriteLine(' ports, interrupts')
  else
    DebugWriteLine(' ports, polled');
  DebugEndMessage;

  { Devices need a moment after the ports power up. }
  SleepMilliseconds(100);
  for PortNumber := 1 to Controller^.MaximumPorts do
    if ((Read32(Controller^.Operational, PortRegisterBase + (PortNumber - 1) * PortRegisterStride) and
        PortConnected) <> 0) and EnumerateDevice(Controller, PortNumber) then
      Inc(Result);
end;

function InitializeXhciControllers: Integer;
var
  Index: Integer;
begin
  Result := 0;
  Index := FindPciDeviceByClass(PciClassSerialBus, PciSubclassUsb, PciInterfaceXhci, 0);
  while Index >= 0 do
  begin
    Result := Result + StartController(PciDeviceAt(Index));
    Index := FindPciDeviceByClass(PciClassSerialBus, PciSubclassUsb, PciInterfaceXhci, Index + 1);
  end;
end;

end.
