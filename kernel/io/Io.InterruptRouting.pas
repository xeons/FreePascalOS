{
  Connecting device interrupts to handlers.

  At startup the I/O APICs listed in the ACPI MADT are set up with every
  input masked (without a MADT, the standard single I/O APIC at
  0xFEC00000 is assumed). A driver then asks for its interrupt; it gets
  one of the device vectors (0x30-0x3F) and its handler runs there, at
  device level, on the boot processor.
}
unit Io.InterruptRouting;

{$mode objfpc}

interface

uses
  Kernel.Interrupts;

procedure InitializeInterruptRouting;
function InterruptRoutingIsAvailable: Boolean;

{ Connects ISA IRQ Irq (0-15) to Handler. Returns False if no vector is
  free or the IRQ cannot be routed. }
function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;

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

end.
