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
  The ACPI namespace in the kernel: the AML interpreter's host, and
  loading the tables.

  The interpreter (Firmware.Aml*) reaches the machine through AmlHost;
  here that is the kernel heap, system memory through device mappings
  (a few pages kept mapped), port I/O, PCI configuration space of the
  functions PCI enumeration found (others read as all ones and ignore
  writes), the scheduler's sleep and the clock.

  LoadAcpiNamespace loads the DSDT and every SSDT, runs the devices'
  initialization (_STA, _INI), builds the PCI interrupt routing
  (Firmware.AcpiPciRouting) and records the platform devices
  (Io.AcpiDevices). The interpreter recurses as AML nests, so
  it is run on a thread with a large stack (Kernel.Startup does that).
}
unit Io.AcpiNamespace;

{$mode objfpc}
{$pointermath on}

interface

{ Loads the namespace and builds the routing; runs in a thread of its
  own (Context unused). }
procedure LoadAcpiNamespace(Context: Pointer);
{ True once the namespace is loaded. }
function AcpiNamespaceIsLoaded: Boolean;
{ The interpreter is not reentrant: everyone running AML after loading
  holds this. }
procedure LockAmlInterpreter;
procedure UnlockAmlInterpreter;

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Mutex,
  Hal.PortIo,
  Firmware.Acpi,
  Firmware.AmlHost,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiPciRouting,
  Io.Pci,
  Io.AcpiDevices,
  Io.AcpiEmbeddedController,
  Debug.Output;

const
  MappedPageCount = 16;
  PageMask = QWord($FFF);
  FadtDsdtOffset = 40;
  FadtExtendedDsdtOffset = 140;
  { No definition block is anywhere near this long. }
  MaximumAmlTableBytes = 16 * 1024 * 1024;

var
  MappedPhysical: array[0..MappedPageCount - 1] of QWord;
  MappedVirtual: array[0..MappedPageCount - 1] of PByte;
  MappedCount: Integer;
  NextMappingSlot: Integer;
  Loaded: Boolean;
  InterpreterLock: TMutex;

{ --- The host ------------------------------------------------------------------ }

function HostAllocate(ByteCount: PtrUInt): Pointer;
begin
  Result := AllocateZeroedKernelMemory(ByteCount);
end;

procedure HostFree(Block: Pointer);
begin
  if Block <> nil then
    FreeKernelMemory(Block);
end;

{ Where the page of Physical is mapped (mapping it if need be). }
function MappedAddress(Physical: QWord): PByte;
var
  Page: QWord;
  Index: Integer;
  Mapping: PByte;
begin
  Page := Physical and not PageMask;
  for Index := 0 to MappedCount - 1 do
    if MappedPhysical[Index] = Page then
      Exit(MappedVirtual[Index] + (Physical and PageMask));
  Mapping := PByte(MapDeviceMemory(Page, PageMask + 1));
  if Mapping = nil then
    Exit(nil);
  { Kept mapped; past the cache's size the oldest slot is reused and its
    mapping given back (firmware walking many pages would otherwise use
    up the device mapping space). }
  if MappedCount < MappedPageCount then
  begin
    Index := MappedCount;
    Inc(MappedCount);
  end
  else
  begin
    Index := NextMappingSlot;
    NextMappingSlot := (NextMappingSlot + 1) mod MappedPageCount;
    UnmapDeviceMemory(MappedVirtual[Index], PageMask + 1);
  end;
  MappedPhysical[Index] := Page;
  MappedVirtual[Index] := Mapping;
  Result := Mapping + (Physical and PageMask);
end;

{ True if an access of Width bits at Address is aligned to its width (so
  it does not cross a page, and device memory on AArch64 takes it). A
  region may start anywhere, so its units need not be. }
function AccessIsAligned(Address: QWord; Width: Byte): Boolean;
begin
  Result := (Address and (QWord(Width div 8) - 1)) = 0;
end;

function ReadMemoryBytes(Address: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  Value := 0;
  for Index := Width div 8 - 1 downto 0 do
  begin
    Location := MappedAddress(Address + QWord(Index));
    if Location = nil then
      Exit(False);
    Value := (Value shl 8) or Location^;
  end;
  Result := True;
end;

function WriteMemoryBytes(Address: QWord; Width: Byte; Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  for Index := 0 to Width div 8 - 1 do
  begin
    Location := MappedAddress(Address + QWord(Index));
    if Location = nil then
      Exit(False);
    Location^ := Byte(Value shr (8 * Index));
  end;
  Result := True;
end;

function ReadMemory(Address: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Location: PByte;
begin
  Value := 0;
  if not AccessIsAligned(Address, Width) then
    Exit(ReadMemoryBytes(Address, Width, Value));
  Location := MappedAddress(Address);
  Result := Location <> nil;
  if not Result then
    Exit;
  case Width of
    8: Value := Location^;
    16: Value := PWord(Location)^;
    32: Value := PLongWord(Location)^;
  else
    Value := PQWord(Location)^;
  end;
end;

function WriteMemory(Address: QWord; Width: Byte; Value: QWord): Boolean;
var
  Location: PByte;
begin
  if not AccessIsAligned(Address, Width) then
    Exit(WriteMemoryBytes(Address, Width, Value));
  Location := MappedAddress(Address);
  Result := Location <> nil;
  if not Result then
    Exit;
  case Width of
    8: Location^ := Byte(Value);
    16: PWord(Location)^ := Word(Value);
    32: PLongWord(Location)^ := LongWord(Value);
  else
    PQWord(Location)^ := Value;
  end;
end;

function ReadPort(Port: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  Result := Port <= $FFFF;
  Value := 0;
  if not Result then
    Exit;
  case Width of
    8: Value := ReadPortByte(Word(Port));
    16: Value := ReadPortWord(Word(Port));
    32: Value := ReadPortLongWord(Word(Port));
  else
    Value := ReadPortLongWord(Word(Port)) or (QWord(ReadPortLongWord(Word(Port + 4))) shl 32);
  end;
end;

function WritePort(Port: QWord; Width: Byte; Value: QWord): Boolean;
begin
  Result := Port <= $FFFF;
  if not Result then
    Exit;
  case Width of
    8: WritePortByte(Word(Port), Byte(Value));
    16: WritePortWord(Word(Port), Word(Value));
    32: WritePortLongWord(Word(Port), LongWord(Value));
  else
    begin
      WritePortLongWord(Word(Port), LongWord(Value));
      WritePortLongWord(Word(Port + 4), LongWord(Value shr 32));
    end;
  end;
end;

{ The configuration space byte of a function PCI found, or nil. }
function ConfigurationLocation(Address: QWord): PByte;
var
  Device: PPciDevice;
  Register: LongWord;
begin
  Result := nil;
  Register := Address and $FFFFFF;
  if Register >= 4096 then
    Exit;
  Device := FindPciFunction(Word(Address shr 48), Byte(Address shr 40), Byte(Address shr 32),
    Byte(Address shr 24));
  if Device <> nil then
    Result := Device^.Configuration + Register;
end;

function ReadConfiguration(Address: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Location: PByte;
begin
  Location := ConfigurationLocation(Address);
  Result := True;
  if Location = nil then
  begin
    Value := High(QWord) shr (64 - Width);
    Exit;
  end;
  case Width of
    8: Value := Location^;
    16: Value := PWord(Location)^;
    32: Value := PLongWord(Location)^;
  else
    Value := PLongWord(Location)^ or (QWord(PLongWord(Location + 4)^) shl 32);
  end;
end;

function WriteConfiguration(Address: QWord; Width: Byte; Value: QWord): Boolean;
var
  Location: PByte;
begin
  Location := ConfigurationLocation(Address);
  Result := True;
  if Location = nil then
    Exit;
  case Width of
    8: Location^ := Byte(Value);
    16: PWord(Location)^ := Word(Value);
    32: PLongWord(Location)^ := LongWord(Value);
  else
    begin
      PLongWord(Location)^ := LongWord(Value);
      PLongWord(Location + 4)^ := LongWord(Value shr 32);
    end;
  end;
end;

function HostRead(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  case Space of
    AmlSpaceSystemMemory: Result := ReadMemory(Address, Width, Value);
    AmlSpaceSystemIo: Result := ReadPort(Address, Width, Value);
    AmlSpacePciConfiguration: Result := ReadConfiguration(Address, Width, Value);
    AmlSpaceEmbeddedController: Result := ReadEmbeddedControllerAddress(Address, Width, Value);
  else
    begin
      Value := 0;
      Result := False;
    end;
  end;
end;

function HostWrite(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
begin
  case Space of
    AmlSpaceSystemMemory: Result := WriteMemory(Address, Width, Value);
    AmlSpaceSystemIo: Result := WritePort(Address, Width, Value);
    AmlSpacePciConfiguration: Result := WriteConfiguration(Address, Width, Value);
    AmlSpaceEmbeddedController: Result := WriteEmbeddedControllerAddress(Address, Width, Value);
  else
    Result := False;
  end;
end;

procedure HostSleep(Milliseconds: QWord);
begin
  SleepMilliseconds(Milliseconds);
end;

procedure HostStall(Microseconds: QWord);
var
  Deadline: QWord;
  Spins: QWord;
begin
  if Microseconds >= 1000 then
  begin
    Deadline := ClockTickCount + MillisecondsToTicks((Microseconds + 999) div 1000);
    while ClockTickCount < Deadline do
      CpuRelax;
    Exit;
  end;
  { Short stalls: a few pauses a microsecond, roughly. }
  for Spins := 1 to Microseconds * 64 do
    CpuRelax;
end;

function HostTimer: QWord;
begin
  Result := UptimeMilliseconds * 10000;
end;

procedure HostLog(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

procedure InstallHost;
begin
  AmlHost.Allocate := @HostAllocate;
  AmlHost.Free := @HostFree;
  AmlHost.ReadSpace := @HostRead;
  AmlHost.WriteSpace := @HostWrite;
  AmlHost.Sleep := @HostSleep;
  AmlHost.Stall := @HostStall;
  AmlHost.Timer := @HostTimer;
  AmlHost.Log := @HostLog;
end;

{ --- Loading ----------------------------------------------------------------------- }

procedure ReportBadDsdt(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

function TableChecksumIsValid(Table: PByte): Boolean;
var
  Sum: Byte;
  Index: LongWord;
begin
  Sum := 0;
  for Index := 0 to PAcpiTableHeader(Table)^.Length - 1 do
    Sum := Byte(Sum + Table[Index]);
  Result := Sum = 0;
end;

{ The DSDT, from the FADT (its 64-bit address if it has one). }
function FindDsdt: PByte;
var
  Fadt: PByte;
  Physical: QWord;
begin
  Result := nil;
  Fadt := PByte(FindAcpiTable('FACP', 0));
  if Fadt = nil then
    Exit;
  Physical := 0;
  if PAcpiTableHeader(Fadt)^.Length >= FadtExtendedDsdtOffset + 8 then
    Physical := PQWord(Fadt + FadtExtendedDsdtOffset)^;
  if (Physical = 0) and (PAcpiTableHeader(Fadt)^.Length >= FadtDsdtOffset + 4) then
    Physical := PLongWord(Fadt + FadtDsdtOffset)^;
  if Physical = 0 then
    Exit;
  Result := PByte(PhysicalToVirtual(Physical));
  { What the FADT points at must look like a DSDT; a wrong checksum is
    only reported (as Linux does), firmware gets that wrong. }
  if not MemoryIsEqual(Result, PChar('DSDT'), 4) or
     (PAcpiTableHeader(Result)^.Length < SizeOf(TAcpiTableHeader)) or
     (PAcpiTableHeader(Result)^.Length > MaximumAmlTableBytes) then
  begin
    ReportBadDsdt('not a DSDT where the FADT points');
    Exit(nil);
  end;
  if not TableChecksumIsValid(Result) then
    ReportBadDsdt('DSDT checksum is wrong (used anyway)');
end;

procedure ReportLoad(Tables: Integer; Failures: Integer; Routes: Integer);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWrite('AML: ');
  DebugWriteDecimal(Tables);
  DebugWrite(' tables');
  if Failures > 0 then
  begin
    DebugWrite(' (');
    DebugWriteDecimal(Failures);
    DebugWrite(' with errors)');
  end;
  DebugWrite(', ');
  DebugWriteDecimal(CountNodes);
  DebugWrite(' objects; PCI interrupt routing: ');
  DebugWriteDecimal(Routes);
  DebugWriteLine(' entries');
  DebugEndMessage;
end;

procedure ReportPlatformDevices(Count: Integer);
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  DebugWriteDecimal(Count);
  DebugWriteLine(' platform devices (with a _HID)');
  DebugEndMessage;
end;

procedure LoadAcpiNamespace(Context: Pointer);
var
  Table: PByte;
  Instance: Integer;
  Tables: Integer;
  Failures: Integer;
begin
  InitializeMutex(InterpreterLock);
  if not AcpiIsAvailable then
    Exit;
  InstallHost;
  if not InitializeNamespace then
    Exit;
  Tables := 0;
  Failures := 0;
  Table := FindDsdt;
  if Table <> nil then
  begin
    Inc(Tables);
    if not LoadAmlTable(Table) then
      Inc(Failures);
  end;
  Instance := 0;
  repeat
    Table := PByte(FindAcpiTable('SSDT', Instance));
    if Table <> nil then
    begin
      Inc(Tables);
      if not LoadAmlTable(Table) then
        Inc(Failures);
    end;
    Inc(Instance);
  until Table = nil;
  if Tables = 0 then
    Exit;
  { Before the devices' _INI, which may read it. }
  ConnectEmbeddedController;
  InitializeAmlDevices;
  ReportLoad(Tables, Failures, BuildPciRouting);
  ReportPlatformDevices(EnumerateAcpiDevices);
  Loaded := True;
end;

function AcpiNamespaceIsLoaded: Boolean;
begin
  Result := Loaded;
end;

procedure LockAmlInterpreter;
begin
  AcquireMutex(InterpreterLock);
end;

procedure UnlockAmlInterpreter;
begin
  ReleaseMutex(InterpreterLock);
end;

end.
