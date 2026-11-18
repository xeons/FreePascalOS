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
  USB through xHCI controllers, and the little of the USB core that goes
  with it. A controller is found on PCI (class 0Ch, subclass 03h,
  interface 30h) or as an ACPI platform device (PNP0D10: the Raspberry
  Pi 4's VL805, which its firmware set up behind the BCM2711 PCIe bridge
  and describes by its registers, interrupt, _CCA and _DMA). Both
  attachments share everything past finding the registers and the
  interrupt. All of the controller's memory (contexts, rings,
  scratchpads, each device's DMA pages) is DMA memory shared with it
  (Io.Dma): uncached for a controller that does not snoop the caches,
  and handed over at its bus address.

  Starting a controller: take it over from the firmware, stop and reset
  it, give it the device context array (and the scratchpad pages it asks
  for), a command ring and an event ring, connect its interrupt (MSI-X
  or MSI; else events are polled) and run it. Then every port with a
  device is reset and its device enumerated: a slot is enabled, the
  device addressed (with its default control endpoint), its device and
  configuration descriptors read and its first configuration set. The
  class drivers registered with RegisterUsbClassDriver are offered it in
  turn.

  Plugging in and unplugging: a port whose connection changes raises a
  port status change event, which wakes the port watcher thread
  (RunUsbPortWatcher, which also looks at every port once a second, for
  polled controllers and changes that raised no event). A device on a
  port that lost its connection is taken away: it is marked gone (its
  transfers fail, the one waited for at once), its slot disabled, and
  its class driver told (UsbSetRemovalHandler). A port that gained a
  connection gets its device enumerated as at startup, after the
  connection has settled. The record of a device taken away is kept,
  since its class driver may still hold it.

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
  { Called after waking from suspend to RAM, once the device has its
    address, configuration and endpoints again: the class driver's own
    setup (an interface's alternate setting, say). }
  TUsbResumeHandler = procedure(Device: PUsbDevice; Context: Pointer);
  { Called in the port watcher thread when the device was unplugged:
    its transfers fail from then on. }
  TUsbRemovalHandler = procedure(Device: PUsbDevice; Context: Pointer);
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
    InputContextBusAddress: QWord;
    OutputContext: PByte;
    OutputContextBusAddress: QWord;
    Rings: array[1..MaximumEndpointContexts - 1] of TProducerRing;
    EndpointMaximumPacket: array[1..MaximumEndpointContexts - 1] of Word;
    DmaPages: array[0..UsbDmaPages - 1] of PByte;
    DmaPagesBusAddress: array[0..UsbDmaPages - 1] of QWord;
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
    InterruptBufferBusAddress: QWord;
    InterruptLength: LongWord;
    InterruptTrb: QWord;
    InterruptHandler: TUsbReportHandler;
    InterruptHandlerContext: Pointer;
    { An isochronous OUT stream: its endpoint context (0 if none). }
    IsochronousContext: LongWord;
    Isochronous: TIsochronousStream;
    { What suspend to RAM needs to set the device up again: the
      configuration chosen, each endpoint opened (its type, 0 if none;
      interval exponent; average length) and the class driver's part. }
    ConfigurationValue: Byte;
    EndpointTypes: array[1..MaximumEndpointContexts - 1] of LongWord;
    EndpointIntervals: array[1..MaximumEndpointContexts - 1] of LongWord;
    EndpointAverages: array[1..MaximumEndpointContexts - 1] of Word;
    ResumeHandler: TUsbResumeHandler;
    ResumeContext: Pointer;
    { Unplugged: every transfer fails. }
    IsGone: Boolean;
    RemovalHandler: TUsbRemovalHandler;
    RemovalContext: Pointer;
  end;

  { Returns True if it took the device. }
  TUsbClassProbe = function(Device: PUsbDevice): Boolean;

procedure RegisterUsbClassDriver(Probe: TUsbClassProbe);
{ Starts every xHCI controller (on PCI, then the ACPI platform ones) and
  enumerates its devices; returns how many devices were found. }
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
{ The class driver's part of setting the device up after waking. }
procedure UsbSetResumeHandler(Device: PUsbDevice; Handler: TUsbResumeHandler; Context: Pointer);
{ What the class driver does when the device is unplugged. }
procedure UsbSetRemovalHandler(Device: PUsbDevice; Handler: TUsbRemovalHandler; Context: Pointer);
{ How many controllers run (the port watcher is needed if any). }
function XhciControllerCount: Integer;
{ The port watcher thread: notices devices plugged in and unplugged. }
procedure RunUsbPortWatcher(Context: Pointer);
procedure UsbStopIsochronous(Device: PUsbDevice);
{ Moves up to Length (at most UsbMaximumTransfer) bytes on the bulk
  endpoint EndpointAddress; Transferred says how many moved. }
function UsbBulkTransfer(Device: PUsbDevice; EndpointAddress: Byte; Buffer: Pointer; Length: LongWord;
  out Transferred: LongWord): Boolean;

implementation

uses
  Io.PowerManagement,
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
  Io.Dma,
  Io.PlatformDevices,
  Debug.Output;

const
  PciClassSerialBus = $0C;
  PciSubclassUsb = $03;
  PciInterfaceXhci = $30;

  MaximumClassDrivers = 8;
  MaximumEnabledSlots = 16;
  MaximumControllers = 4;
  MaximumRootPorts = 255;
  { A new connection settles for this long before the port is reset
    (the USB specification's debounce interval). }
  ConnectionSettleMilliseconds = 100;
  { The watcher looks at the ports at least this often. }
  PortWatchIntervalMilliseconds = 1000;
  { What a transfer of an unplugged device ends with (a USB transaction
    error). }
  CompletionDeviceGone = 4;
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
    { How it was found: on PCI, or as an ACPI platform device. }
    Pci: PPciDevice;
    Platform: PPlatformDevice;
    { What its DMA reaches and whether it snoops (Io.Dma). }
    Dma: TDmaAttributes;
    Capabilities: PByte;
    Operational: PByte;
    Runtime: PByte;
    Doorbells: PLongWord;
    MaximumSlots: LongWord;
    MaximumPorts: LongWord;
    ContextSize: LongWord;
    ContextArray: PQWord;
    ContextArrayBusAddress: QWord;
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
    { The device on each root port, and the ports whose device could not
      be set up (not tried again until it is unplugged). Guarded by
      PortLock, which the port watcher and waking hold. }
    PortDevices: array[1..MaximumRootPorts] of PUsbDevice;
    PortFailed: array[1..MaximumRootPorts] of Boolean;
    PortLock: TMutex;
    { From suspending until the controller is set up again after waking:
      its ports say nothing about the devices then, and are not looked
      at. }
    IsAsleep: Boolean;
  end;

var
  ClassDrivers: array[0..MaximumClassDrivers - 1] of TUsbClassProbe;
  ClassDriverCount: Integer;
  Controllers: array[0..MaximumControllers - 1] of PXhciController;
  ControllerCount: Integer;
  { Signaled by port status change events. }
  PortsChanged: TEvent;

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
  Device^.InterruptTrb := EnqueueTrb(Device^.Rings[Device^.InterruptContext], Device^.InterruptBufferBusAddress,
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
    TrbTypePortStatusChangeEvent:
      SignalEvent(PortsChanged);
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
  RingBusAddress: QWord; AverageLength: Word);
const
  ErrorCount = 3;
begin
  FillMemory(Context, 32, 0);
  Context[1] := (ErrorCount shl 1) or (EndpointType shl 3) or (LongWord(MaximumPacket) shl 16);
  Context[2] := LongWord(RingBusAddress) or 1; { dequeue cycle state }
  Context[3] := LongWord(RingBusAddress shr 32);
  Context[4] := AverageLength;
end;

function AllocateDmaPage(Controller: Pointer; out BusAddress: QWord): PByte; forward;

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
  { Checked under the event lock, which taking a device away holds. }
  if Device^.IsGone then
  begin
    ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
    ReleaseMutex(Device^.TransferLock);
    Exit(False);
  end;
  Device^.PendingCount := 0;
  EnqueueTrb(Device^.Rings[1], Setup, 8,
    (TrbTypeSetupStage shl TrbTypeShift) or TrbImmediateData or (TransferType shl 16));
  if Length > 0 then
  begin
    if IsIn then
      EnqueueTrb(Device^.Rings[1], Device^.DmaPagesBusAddress[0], Length,
        (TrbTypeDataStage shl TrbTypeShift) or DirectionIn)
    else
      EnqueueTrb(Device^.Rings[1], Device^.DmaPagesBusAddress[0], Length, TrbTypeDataStage shl TrbTypeShift);
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
  if Device^.IsGone then
  begin
    ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
    ReleaseMutex(Device^.TransferLock);
    Exit(False);
  end;
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
    Trb := EnqueueTrb(Device^.Rings[ContextIndex], Device^.DmaPagesBusAddress[PageIndex], Chunk, Control);
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

{ Gives the controller endpoint context ContextIndex as recorded in
  Device (its ring emptied): a Configure Endpoint command with the slot
  (for its context entries) and that endpoint. }
function ProgramEndpoint(Device: PUsbDevice; ContextIndex: LongWord): Boolean;
var
  Context: PLongWord;
  Slot: LongWord;
  EndpointType: LongWord;
  MaximumPacket: Word;
begin
  EndpointType := Device^.EndpointTypes[ContextIndex];
  MaximumPacket := Device^.EndpointMaximumPacket[ContextIndex];
  if ContextIndex > Device^.HighestContext then
    Device^.HighestContext := ContextIndex;
  FillMemory(Device^.InputContext, 4096, 0);
  InputControlContext(Device)[1] := 1 or (LongWord(1) shl ContextIndex);
  CopyMemory(InputSlotContext(Device), Device^.OutputContext, 32);
  InputSlotContext(Device)[0] := (InputSlotContext(Device)[0] and not (LongWord($1F) shl 27)) or
    (Device^.HighestContext shl 27);
  Context := InputEndpointContext(Device, ContextIndex);
  FillEndpointContext(Context, EndpointType, MaximumPacket, Device^.Rings[ContextIndex].BusAddress,
    Device^.EndpointAverages[ContextIndex]);
  Context[0] := Device^.EndpointIntervals[ContextIndex] shl 16;
  if EndpointType in [EndpointTypeInterruptIn, EndpointTypeIsochronousOut] then
    { The most bytes per service interval. }
    Context[4] := Context[4] or (LongWord(MaximumPacket) shl 16);
  if EndpointType = EndpointTypeIsochronousOut then
    { Isochronous transfers are not retried: the error count is 0. }
    Context[1] := Context[1] and not (LongWord(3) shl 1);
  Result := RunCommand(PXhciController(Device^.Controller), Device^.InputContextBusAddress,
    (TrbTypeConfigureEndpoint shl TrbTypeShift) or (Device^.SlotId shl 24), Slot);
end;

{ Adds endpoint Address (of EndpointType) with a fresh transfer ring,
  and records it. IntervalExponent: 125 us units, as a power of two. }
function ConfigureEndpoint(Device: PUsbDevice; Address: Byte; EndpointType: LongWord; MaximumPacket: Word;
  IntervalExponent: LongWord; AverageLength: Word): Boolean;
var
  ContextIndex: LongWord;
begin
  ContextIndex := ContextIndexOf(Address);
  if (ContextIndex >= MaximumEndpointContexts) or
     not AllocateProducerRing(PXhciController(Device^.Controller)^.Dma, Device^.Rings[ContextIndex]) then
    Exit(False);
  Device^.EndpointTypes[ContextIndex] := EndpointType;
  Device^.EndpointMaximumPacket[ContextIndex] := MaximumPacket;
  Device^.EndpointIntervals[ContextIndex] := IntervalExponent;
  Device^.EndpointAverages[ContextIndex] := AverageLength;
  Result := ProgramEndpoint(Device, ContextIndex);
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
  Device^.InterruptBuffer := AllocateDmaPage(Controller, Device^.InterruptBufferBusAddress);
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
  InitializeIsochronousStream(Device^.Isochronous, Device^.Rings[ContextIndex],
    @PXhciController(Device^.Controller)^.Dma, Routines, Context);
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

{ A zeroed page of DMA memory shared with the controller (uncached if it
  does not snoop the caches, so nothing else needs maintenance). }
function AllocateDmaPage(Controller: Pointer; out BusAddress: QWord): PByte;
var
  Buffer: TDmaBuffer;
begin
  BusAddress := 0;
  if not AllocateDmaBuffer(PXhciController(Controller)^.Dma, PageSize, DmaShared, Buffer) then
    Exit(nil);
  BusAddress := Buffer.DeviceAddress;
  Result := Buffer.Address;
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
  Device^.ConfigurationValue := Header[5];
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
  Result := RunCommand(PXhciController(Device^.Controller), Device^.InputContextBusAddress,
    (TrbTypeEvaluateContext shl TrbTypeShift) or (Device^.SlotId shl 24), Slot);
end;

{ Puts Device (its port reset, slot Slot enabled) in the slot: the slot
  context (one context entry, its port and speed) and the default
  control endpoint, Address Device, and the control endpoint's packet
  size. }
function AddressDevice(Controller: PXhciController; Device: PUsbDevice; Slot: LongWord): Boolean;
var
  Ignored: LongWord;
begin
  Device^.SlotId := Slot;
  Controller^.ContextArray[Slot] := Device^.OutputContextBusAddress;
  Controller^.Devices[Slot] := Device;
  FillMemory(Device^.InputContext, 4096, 0);
  InputControlContext(Device)[1] := 3;
  InputSlotContext(Device)[0] := (LongWord(1) shl 27) or (Device^.Speed shl 20);
  InputSlotContext(Device)[1] := Device^.PortNumber shl 16;
  FillEndpointContext(InputEndpointContext(Device, 1), EndpointTypeControl,
    DefaultControlPacketSize(Device^.Speed), Device^.Rings[1].BusAddress, 8);
  Result := RunCommand(Controller, Device^.InputContextBusAddress,
    (TrbTypeAddressDevice shl TrbTypeShift) or (Slot shl 24), Ignored);
  if not Result then
    Exit;
  Device^.HighestContext := 1;
  if Device^.Speed = UsbSpeedFull then
    Result := CorrectControlPacketSize(Device);
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
  Device^.InputContext := AllocateDmaPage(Controller, Device^.InputContextBusAddress);
  Device^.OutputContext := AllocateDmaPage(Controller, Device^.OutputContextBusAddress);
  if (Device^.InputContext = nil) or (Device^.OutputContext = nil) or
     not AllocateProducerRing(Controller^.Dma, Device^.Rings[1]) then
    Exit;
  for Index := 0 to UsbDmaPages - 1 do
  begin
    Device^.DmaPages[Index] := AllocateDmaPage(Controller, Device^.DmaPagesBusAddress[Index]);
    if Device^.DmaPages[Index] = nil then
      Exit;
  end;
  if not AddressDevice(Controller, Device, Slot) then
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

  { Before the class drivers: one may wait long enough for the device
    to be unplugged meanwhile. }
  Controller^.PortDevices[PortNumber] := Device;
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
  ArrayBusAddress: QWord;
  ScratchArray: PQWord;
  Index: LongWord;
begin
  Parameters := Read32(Controller^.Capabilities, StructuralParameters2);
  Count := (((Parameters shr 21) and $1F) shl 5) or ((Parameters shr 27) and $1F);
  if Count = 0 then
    Exit(True);
  ScratchArray := PQWord(AllocateDmaPage(Controller, ArrayBusAddress));
  if (ScratchArray = nil) or (Count > 512) then
    Exit(False);
  for Index := 0 to Count - 1 do
  begin
    if AllocateDmaPage(Controller, ScratchArray[Index]) = nil then
      Exit(False);
  end;
  Controller^.ContextArray[0] := ArrayBusAddress;
  Result := True;
end;

{ Stops the controller and resets it. }
function ResetHostController(Controller: PXhciController): Boolean;
begin
  Write32(Controller^.Operational, UsbCommand, Read32(Controller^.Operational, UsbCommand) and not CommandRun);
  Result := WaitForBits(Controller^.Operational, UsbStatus, StatusHalted, StatusHalted, 1000);
  if not Result then
    Exit;
  Write32(Controller^.Operational, UsbCommand, CommandReset);
  Result := WaitForBits(Controller^.Operational, UsbCommand, CommandReset, 0, 1000) and
    WaitForBits(Controller^.Operational, UsbStatus, StatusNotReady, 0, 1000);
end;

{ Gives the controller (just reset) its slots, device context array,
  command and event rings, enables its interrupter and runs it. }
function RunHostController(Controller: PXhciController): Boolean;
begin
  Write32(Controller^.Operational, ConfigureRegister, Controller^.MaximumSlots);
  Write64(Controller^.Operational, ContextArrayPointer, Controller^.ContextArrayBusAddress);
  Write64(Controller^.Operational, CommandRingControl, Controller^.CommandRing.BusAddress or 1);
  Write32(Interrupter(Controller), InterrupterSegmentTableSize, 1);
  Write64(Interrupter(Controller), InterrupterDequeuePointer, Controller^.EventRing.BusAddress);
  Write64(Interrupter(Controller), InterrupterSegmentTableBase, Controller^.EventRing.SegmentTableBusAddress);
  Write32(Interrupter(Controller), InterrupterManagement, ManagementEnable or ManagementPending);
  Write32(Controller^.Operational, UsbCommand, CommandRun or CommandInterrupterEnable);
  Result := WaitForBits(Controller^.Operational, UsbStatus, StatusHalted, 0, 1000);
end;

{ --- Suspend to RAM -------------------------------------------------------------- }

const
  PortReturnMilliseconds = 2000;

procedure ReportResumeFailure(Device: PUsbDevice; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(Device^.PortNumber);
  DebugWrite(': not set up again after waking: ');
  DebugWriteLine(Reason);
  DebugEndMessage;
end;

{ Sets a device up again after waking: the port reset, a slot (maybe
  another), its address, its configuration, every endpoint it had open
  (rings emptied), the class driver's own part, then the interrupt
  reads and isochronous state. }
procedure ResumeDevice(Controller: PXhciController; Device: PUsbDevice);
const
  RequestSetConfiguration = 9;
var
  Slot: LongWord;
  ContextIndex: LongWord;
  PreviousLevel: TPriorityLevel;
begin
  { The port comes back after the controller's reset (a USB 3 link takes
    a while to train). }
  if not WaitForBits(Controller^.Operational, PortRegisterBase + (Device^.PortNumber - 1) * PortRegisterStride,
       PortConnected, PortConnected, PortReturnMilliseconds) or
     not ResetPort(Controller, Device^.PortNumber) then
  begin
    ReportResumeFailure(Device, 'its port did not come back');
    Exit;
  end;
  if not RunCommand(Controller, 0, TrbTypeEnableSlot shl TrbTypeShift, Slot) or
     (Slot = 0) or (Slot > MaximumEnabledSlots) then
  begin
    ReportResumeFailure(Device, 'no slot');
    Exit;
  end;
  FillMemory(Device^.OutputContext, 4096, 0);
  ResetProducerRing(Device^.Rings[1]);
  if not AddressDevice(Controller, Device, Slot) or
     not UsbControlTransfer(Device, 0, RequestSetConfiguration, Device^.ConfigurationValue, 0, nil, 0) then
  begin
    ReportResumeFailure(Device, 'it did not take its address and configuration');
    Exit;
  end;
  for ContextIndex := 2 to MaximumEndpointContexts - 1 do
    if Device^.EndpointTypes[ContextIndex] <> 0 then
    begin
      ResetProducerRing(Device^.Rings[ContextIndex]);
      ProgramEndpoint(Device, ContextIndex);
    end;
  { The class driver's settings before reports flow again. }
  if Assigned(Device^.ResumeHandler) then
    Device^.ResumeHandler(Device, Device^.ResumeContext);
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.Isochronous.Oldest := 0;
  Device^.Isochronous.InFlight := 0;
  Device^.Isochronous.Streaming := False;
  if Device^.InterruptContext <> 0 then
    QueueInterruptRead(Device);
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
end;

{ Before sleeping: the port watcher leaves the ports alone until the
  controller is set up again, since the firmware resets it on waking
  and the ports look empty until then. }
procedure SuspendController(Context: Pointer);
var
  Controller: PXhciController;
begin
  Controller := PXhciController(Context);
  AcquireMutex(Controller^.PortLock);
  Controller^.IsAsleep := True;
  ReleaseMutex(Controller^.PortLock);
end;

{ Waking reset the controller and every device on it (the transfers
  were finished before: block I/O and audio stopped). The controller
  gets its rings again, emptied, in the same pages; then each device is
  set up again on its port. }
procedure ResumeController(Context: Pointer);
var
  Controller: PXhciController;
  Known: array[0..MaximumEnabledSlots] of PUsbDevice;
  Slot: LongWord;
begin
  Controller := PXhciController(Context);
  { The port watcher waits meanwhile; a device that does not come back
    is taken away by it afterwards. }
  AcquireMutex(Controller^.PortLock);
  TakeOverFromFirmware(Controller);
  Controller^.IsAsleep := False;
  if not ResetHostController(Controller) then
  begin
    ReleaseMutex(Controller^.PortLock);
    Exit;
  end;
  for Slot := 0 to MaximumEnabledSlots do
  begin
    Known[Slot] := Controller^.Devices[Slot];
    Controller^.Devices[Slot] := nil;
    if Slot > 0 then
      Controller^.ContextArray[Slot] := 0;
  end;
  ResetProducerRing(Controller^.CommandRing);
  ResetEventRing(Controller^.EventRing);
  Controller^.PendingCommandTrb := 0;
  if not RunHostController(Controller) then
  begin
    ReleaseMutex(Controller^.PortLock);
    Exit;
  end;
  { Devices need a moment after the ports power up. }
  SleepMilliseconds(100);
  for Slot := 1 to MaximumEnabledSlots do
    if Known[Slot] <> nil then
      ResumeDevice(Controller, Known[Slot]);
  ReleaseMutex(Controller^.PortLock);
end;

procedure UsbSetResumeHandler(Device: PUsbDevice; Handler: TUsbResumeHandler; Context: Pointer);
begin
  Device^.ResumeContext := Context;
  Device^.ResumeHandler := Handler;
end;

procedure UsbSetRemovalHandler(Device: PUsbDevice; Handler: TUsbRemovalHandler; Context: Pointer);
begin
  Device^.RemovalContext := Context;
  Device^.RemovalHandler := Handler;
end;

{ --- Plugging in and unplugging ------------------------------------------------ }

function PortOffset(PortNumber: LongWord): LongWord;
begin
  Result := PortRegisterBase + (PortNumber - 1) * PortRegisterStride;
end;

{ Clears the change bits that are set in Status (writing 1 clears them;
  writing 1 to the enable bit would disable the port). }
procedure ClearPortChanges(Controller: PXhciController; PortNumber: LongWord; Status: LongWord);
begin
  if (Status and PortChangeBits) = 0 then
    Exit;
  Write32(Controller^.Operational, PortOffset(PortNumber),
    (Status and not (PortChangeBits or PortEnabled)) or (Status and PortChangeBits));
end;

procedure ReportPortEvent(PortNumber: LongWord; What: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('usb');
  DebugWrite('Port ');
  DebugWriteDecimal(PortNumber);
  DebugWriteLine(What);
  DebugEndMessage;
end;

{ The device was unplugged: its transfers fail (the one waited for at
  once), the controller forgets its slot, and its class driver is told. }
procedure TakeDeviceAway(Controller: PXhciController; Device: PUsbDevice);
var
  PreviousLevel: TPriorityLevel;
  OwnsSlot: Boolean;
  Ignored: LongWord;
begin
  PreviousLevel := AcquireSpinLock(Controller^.EventLock);
  Device^.IsGone := True;
  { After waking from suspend the slot may belong to another device. }
  OwnsSlot := Controller^.Devices[Device^.SlotId] = Device;
  if OwnsSlot then
    Controller^.Devices[Device^.SlotId] := nil;
  Device^.InterruptTrb := 0;
  Device^.Isochronous.Streaming := False;
  if Device^.PendingCount > 0 then
  begin
    Device^.EventCode := CompletionDeviceGone;
    Device^.PendingCount := 0;
    SignalEvent(Device^.TransferDone);
  end;
  ReleaseSpinLock(Controller^.EventLock, PreviousLevel);
  if OwnsSlot then
  begin
    RunCommand(Controller, 0, (TrbTypeDisableSlot shl TrbTypeShift) or (Device^.SlotId shl 24), Ignored);
    Controller^.ContextArray[Device^.SlotId] := 0;
  end;
  ReportPortEvent(Device^.PortNumber, ': device unplugged');
  if Assigned(Device^.RemovalHandler) then
    Device^.RemovalHandler(Device, Device^.RemovalContext);
end;

{ A port gained a connection: once it has settled, the device is set
  up as at startup. }
procedure SetUpPluggedDevice(Controller: PXhciController; PortNumber: LongWord);
begin
  SleepMilliseconds(ConnectionSettleMilliseconds);
  if (Read32(Controller^.Operational, PortOffset(PortNumber)) and PortConnected) = 0 then
    Exit;
  ReportPortEvent(PortNumber, ': device plugged in');
  if not EnumerateDevice(Controller, PortNumber) then
  begin
    Controller^.PortFailed[PortNumber] := True;
    ReportPortEvent(PortNumber, ': the device could not be set up');
  end;
end;

procedure CheckPort(Controller: PXhciController; PortNumber: LongWord);
var
  Status: LongWord;
  IsConnected: Boolean;
begin
  Status := Read32(Controller^.Operational, PortOffset(PortNumber));
  ClearPortChanges(Controller, PortNumber, Status);
  IsConnected := (Status and PortConnected) <> 0;
  if not IsConnected then
  begin
    Controller^.PortFailed[PortNumber] := False;
    if Controller^.PortDevices[PortNumber] <> nil then
    begin
      TakeDeviceAway(Controller, Controller^.PortDevices[PortNumber]);
      Controller^.PortDevices[PortNumber] := nil;
    end;
  end
  else if (Controller^.PortDevices[PortNumber] = nil) and not Controller^.PortFailed[PortNumber] then
    SetUpPluggedDevice(Controller, PortNumber);
end;

procedure CheckPorts(Controller: PXhciController);
var
  PortNumber: LongWord;
begin
  AcquireMutex(Controller^.PortLock);
  if Controller^.IsAsleep then
  begin
    ReleaseMutex(Controller^.PortLock);
    Exit;
  end;
  { Without an interrupt nobody else takes the port events off the ring. }
  if not Controller^.UsesInterrupts then
    ProcessEvents(Controller);
  for PortNumber := 1 to Controller^.MaximumPorts do
    CheckPort(Controller, PortNumber);
  ReleaseMutex(Controller^.PortLock);
end;

function XhciControllerCount: Integer;
begin
  Result := ControllerCount;
end;

procedure RunUsbPortWatcher(Context: Pointer);
var
  Index: Integer;
begin
  while True do
  begin
    WaitForEventWithOptions(PortsChanged, PortWatchIntervalMilliseconds, False);
    for Index := 0 to ControllerCount - 1 do
      CheckPorts(Controllers[Index]);
  end;
end;

{ Describes the controller for its start-up line. }
procedure WriteControllerName(Controller: PXhciController);
begin
  if Controller^.Pci <> nil then
  begin
    DebugWriteHex(Controller^.Pci^.VendorId, 4);
    DebugWrite(':');
    DebugWriteHex(Controller^.Pci^.DeviceId, 4);
  end
  else
  begin
    DebugWrite(@Controller^.Platform^.Path[0]);
    if Controller^.Platform^.DeviceTreeNode = NoDeviceTreeNode then
      DebugWrite(' (ACPI ')
    else
      DebugWrite(' (DT ');
    DebugWrite(@Controller^.Platform^.HardwareId[0]);
    DebugWrite(')');
  end;
end;

{ Connects the controller's interrupt: MSI-X or MSI on PCI, the _CRS
  interrupt of a platform device. False if it is to be polled. }
function ConnectControllerInterrupt(Controller: PXhciController): Boolean;
begin
  if Controller^.Pci <> nil then
    Result := ConnectPciInterrupt(Controller^.Pci, @HandleXhciInterrupt, Controller) <> PciInterruptNone
  else
    Result := ConnectPlatformInterrupt(Controller^.Platform, 0, @HandleXhciInterrupt, Controller);
end;

{ Starts a controller whose registers are mapped at Capabilities (and
  whose Pci or Platform, and Dma, are filled in); returns how many
  devices it found. }
function StartController(Controller: PXhciController): Integer;
const
  CapabilityAddresses64 = 1;
var
  Parameters: LongWord;
  PortNumber: LongWord;
begin
  Result := 0;
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
  if Controller^.MaximumPorts > MaximumRootPorts then
    Controller^.MaximumPorts := MaximumRootPorts;
  InitializeMutex(Controller^.PortLock);
  Controller^.ContextSize := 32;
  if (Read32(Controller^.Capabilities, CapabilityParameters1) and 4) <> 0 then
    Controller^.ContextSize := 64;
  { A controller without 64-bit addressing reaches only the low 4 GiB. }
  if (Read32(Controller^.Capabilities, CapabilityParameters1) and CapabilityAddresses64) = 0 then
    LimitDmaBusAddresses(Controller^.Dma, QWord(1) shl 32);
  InitializeSpinLock(Controller^.EventLock);
  InitializeMutex(Controller^.CommandLock);
  InitializeEvent(Controller^.CommandDone, EventKindNotification, False);
  InitializeDeferredCall(Controller^.ProcessEventsCall, @ProcessEvents, Controller);

  TakeOverFromFirmware(Controller);
  if not ResetHostController(Controller) then
    Exit;
  Controller^.ContextArray := PQWord(AllocateDmaPage(Controller, Controller^.ContextArrayBusAddress));
  if (Controller^.ContextArray = nil) or not AllocateScratchpads(Controller) or
     not AllocateProducerRing(Controller^.Dma, Controller^.CommandRing) or
     not AllocateEventRing(Controller^.Dma, Controller^.EventRing) then
    Exit;
  Controller^.UsesInterrupts := ConnectControllerInterrupt(Controller);
  if not RunHostController(Controller) then
    Exit;

  DebugBeginMessage;
  DebugWriteTag('xhci');
  DebugWrite('Controller ');
  WriteControllerName(Controller);
  DebugWrite(', ');
  DebugWriteDecimal(Controller^.MaximumPorts);
  if Controller^.UsesInterrupts then
    DebugWrite(' ports, interrupts')
  else
    DebugWrite(' ports, polled');
  if not Controller^.Dma.Coherent then
  begin
    DebugWrite(', ');
    DebugWrite(DmaCoherenceText(Controller^.Dma));
  end;
  DebugWriteLine('');
  DebugEndMessage;

  RegisterPowerHandler('xHCI', PowerStageBuses, @SuspendController, @ResumeController, Controller);
  { Devices need a moment after the ports power up. }
  SleepMilliseconds(100);
  for PortNumber := 1 to Controller^.MaximumPorts do
    if ((Read32(Controller^.Operational, PortRegisterBase + (PortNumber - 1) * PortRegisterStride) and
        PortConnected) <> 0) and EnumerateDevice(Controller, PortNumber) then
      Inc(Result);
  { From here on a change bit means a device came or went. }
  for PortNumber := 1 to Controller^.MaximumPorts do
    ClearPortChanges(Controller, PortNumber, Read32(Controller^.Operational, PortOffset(PortNumber)));
  if ControllerCount < MaximumControllers then
  begin
    Controllers[ControllerCount] := Controller;
    Inc(ControllerCount);
  end;
end;

function StartPciController(Pci: PPciDevice): Integer;
var
  Controller: PXhciController;
  Bar: TPciBar;
begin
  Result := 0;
  if not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort then
    Exit;
  Controller := PXhciController(AllocateZeroedKernelMemory(SizeOf(TXhciController)));
  if Controller = nil then
    Exit;
  Controller^.Pci := Pci;
  GetPciDmaAttributes(Pci, Controller^.Dma);
  PciEnableDevice(Pci, True);
  Controller^.Capabilities := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Controller^.Capabilities = nil then
    Exit;
  Result := StartController(Controller);
end;

var
  { The devices the platform controllers found, for the caller. }
  PlatformDevicesFound: Integer;

function ProbePlatformController(Device: PPlatformDevice): Boolean;
var
  Controller: PXhciController;
  Length: QWord;
begin
  Result := False;
  Controller := PXhciController(AllocateZeroedKernelMemory(SizeOf(TXhciController)));
  if Controller = nil then
    Exit;
  Controller^.Platform := Device;
  Controller^.Dma := Device^.Dma;
  Controller^.Capabilities := PByte(MapPlatformMemory(Device, 0, Length));
  if (Controller^.Capabilities = nil) or (Length < PortRegisterBase) then
    Exit;
  PlatformDevicesFound := PlatformDevicesFound + StartController(Controller);
  Result := True;
end;

const
  { xHCI controllers with and without the USB debug capability. }
  PlatformControllerIds: array[0..2] of PChar = ('PNP0D10', 'PNP0D15', nil);
  PlatformControllerDriver: TPlatformDriver = (
    Name: 'xhci';
    Ids: @PlatformControllerIds[0];
    Probe: @ProbePlatformController);

function InitializeXhciControllers: Integer;
var
  Index: Integer;
begin
  Result := 0;
  InitializeEvent(PortsChanged, EventKindSynchronization, False);

  Index := FindPciDeviceByClass(PciClassSerialBus, PciSubclassUsb, PciInterfaceXhci, 0);
  while Index >= 0 do
  begin
    Result := Result + StartPciController(PciDeviceAt(Index));
    Index := FindPciDeviceByClass(PciClassSerialBus, PciSubclassUsb, PciInterfaceXhci, Index + 1);
  end;
  PlatformDevicesFound := 0;
  BindPlatformDriver(PlatformControllerDriver);
  Result := Result + PlatformDevicesFound;
end;

end.
