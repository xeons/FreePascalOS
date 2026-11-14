{
  Connecting device interrupts to handlers.

  At startup the I/O APICs listed in the ACPI MADT are set up with every
  input masked (without a MADT, the standard single I/O APIC at
  0xFEC00000 is assumed). A driver then asks for its interrupt; it gets
  one of the device vectors (0x30-0x3F) and its handler runs there, at
  device level, on the boot processor.

  A PCI device can instead signal its interrupt by writing a message (a
  value to an address) that the processor's local APIC receives
  directly, with no I/O APIC in between. ConnectMessageInterrupt gives
  the address and value to program into the device
  (Io.PciMessageInterrupts).
}
unit Io.InterruptRouting;

{$mode objfpc}

interface

uses
  Kernel.Interrupts;

type
  { What a device writes, and where, to raise its interrupt. }
  TInterruptMessage = record
    Address: QWord;
    Data: LongWord;
  end;

procedure InitializeInterruptRouting;
function InterruptRoutingIsAvailable: Boolean;

{ Connects ISA IRQ Irq (0-15) to Handler. Returns False if no vector is
  free or the IRQ cannot be routed. }
function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;

{ Connects a message signalled interrupt to Handler. Returns False if no
  vector is free. }
function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;

implementation

uses
  Memory.Layout,
  Memory.DeviceMapping,
  Hal.InterruptVectors,
  Hal.IoApic,
  Hal.LocalApic,
  Firmware.Madt,
  Debug.Output;

const
  StandardIoApicAddress = $FEC00000;
  { Messages written into this window reach a local APIC; bits 12-19
    pick which one. The data is the vector (fixed delivery, edge). }
  MessageAddressBase = $FEE00000;
  MessageDestinationShift = 12;
  IoApicRegisterWindowSize = $1000;

var
  Available: Boolean = False;
  NextVector: Integer = DeviceInterruptVectorFirst;

procedure AddMappedIoApic(PhysicalAddress: TPhysicalAddress; GlobalInterruptBase: LongWord);
var
  Registers: Pointer;
begin
  Registers := MapDeviceMemory(PhysicalAddress, IoApicRegisterWindowSize);
  if Registers = nil then
    Exit;
  if AddIoApic(Registers, GlobalInterruptBase) then
    Available := True;
end;

procedure InitializeInterruptRouting;
var
  Index: Integer;
  Description: TIoApicDescription;
begin
  if ParseMadt then
    for Index := 0 to IoApicCount - 1 do
    begin
      Description := IoApicDescription(Index);
      AddMappedIoApic(Description.PhysicalAddress, Description.GlobalInterruptBase);
    end
  else
    AddMappedIoApic(StandardIoApicAddress, 0);

  DebugBeginMessage;
  DebugWriteTag('interrupts');
  if Available then
  begin
    DebugWrite('I/O APIC routing, ');
    DebugWriteDecimal(IoApicInputCount);
    DebugWriteLine(' inputs');
  end
  else
    DebugWriteLine('No I/O APIC; device interrupts unavailable');
  DebugEndMessage;
end;

function InterruptRoutingIsAvailable: Boolean;
begin
  Result := Available;
end;

function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;
var
  Routing: TIsaInterruptRouting;
  Vector: Byte;
begin
  if not Available or (NextVector >= DeviceInterruptVectorFirst + DeviceInterruptVectorCount) then
    Exit(False);
  Vector := Byte(NextVector);
  if not RegisterInterruptHandler(Vector, Handler, Context) then
    Exit(False);
  Routing := RoutingOfIsaInterrupt(Irq);
  if not RouteGlobalInterrupt(Routing.GlobalInterrupt, Vector, Byte(LocalApicId),
    Routing.ActiveLow, Routing.LevelTriggered) then
  begin
    UnregisterInterruptHandler(Vector);
    Exit(False);
  end;
  Inc(NextVector);
  Result := True;
end;

function AllocateVector(Handler: TInterruptHandler; Context: Pointer; out Vector: Byte): Boolean;
begin
  if NextVector >= DeviceInterruptVectorFirst + DeviceInterruptVectorCount then
    Exit(False);
  Vector := Byte(NextVector);
  if not RegisterInterruptHandler(Vector, Handler, Context) then
    Exit(False);
  Inc(NextVector);
  Result := True;
end;

function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;
var
  Vector: Byte;
begin
  Message.Address := 0;
  Message.Data := 0;
  if not AllocateVector(Handler, Context, Vector) then
    Exit(False);
  Message.Address := MessageAddressBase or (QWord(LocalApicId and $FF) shl MessageDestinationShift);
  Message.Data := Vector;
  Result := True;
end;

end.
