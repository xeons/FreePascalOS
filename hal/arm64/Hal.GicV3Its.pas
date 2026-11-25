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
  Message signalled interrupts on a GICv3: LPIs through the interrupt
  translation service (ITS).

  A PCIe device writes an event number to the ITS's GITS_TRANSLATER; the
  ITS knows the writer by its device id (the requester id, bus, device
  and function: QEMU's virt machine maps them one to one) and looks the
  event up in the device's interrupt translation table (ITT), which
  names an LPI (INTID 8192 and up) and a collection - a processor's
  redistributor. The tables are the kernel's memory, filled by commands
  the ITS reads from a queue:

    MAPD   device id -> its ITT (one page, 32 events)
    MAPC   collection -> redistributor (one per processor, by its index)
    MAPTI  device id + event -> LPI + collection
    INV    the LPI's configuration changed
    SYNC   wait until the redistributor saw everything before

  The LPIs' configuration (enable bit and priority, one byte each) is a
  table every redistributor reads (GICR_PROPBASER); each has a pending
  table of its own (GICR_PENDBASER, 64 KiB aligned). Where the GIC
  reads these without snooping the caches (its shareability reads back
  as non-shareable), every write the GIC is to see is cleaned first.

  The device and collection tables are the GITS_BASERn the ITS asks for:
  the device table flat, for device ids below 8192 (buses 0-31).
}
unit Hal.GicV3Its;

{$mode objfpc}

interface

uses
  Hal.GicV3Redistributors;

const
  FirstLpi = 8192;
  MaximumLpis = 256;

{ Maps the ITS at PhysicalAddress, gives it its tables and command queue
  and turns it on. False if any of it failed (message interrupts are
  then not available). }
function InitializeTranslationService(PhysicalAddress: QWord): Boolean;
function TranslationServiceIsReady: Boolean;
{ After waking: if the ITS lost its registers, gives it its tables and
  queue again (their memory kept every mapping) and maps the
  collections again. }
procedure RestoreTranslationService;
{ Gives Redistributor the LPI tables and enables LPIs on it (each
  processor's own, once the ITS is set up). }
procedure EnableLpisOn(constref Redistributor: TRedistributor);
{ Maps an event of the device with RequesterId to a new LPI with
  Vector's priority, sent to the processor whose redistributor is
  Target (and whose kernel index is ProcessorIndex). Address and Data
  are what the device writes. False when the LPIs or the device's
  events are used up, or the ITS refused. }
function MapMessageInterrupt(RequesterId: LongWord; Vector: Byte; constref Target: TRedistributor;
  ProcessorIndex: LongWord; out Address: QWord; out Data: LongWord): Boolean;
{ The vector of LPI IntId (SpuriousInterruptVector if it has none). }
function VectorOfLpi(IntId: LongWord): Byte;
procedure DisableLpi(IntId: LongWord);

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Hal.InterruptVectors;

const
  { One pending table per processor's redistributor. }
  MaximumPendingTables = 64;
  ItsRegisterBytes = $20000;
  ItsControl = $0000;
  ItsType = $0008;
  ItsCommandBase = $0080;
  ItsCommandWriter = $0088;
  ItsCommandReader = $0090;
  ItsTableBase = $0100;
  ItsTableCount = 8;
  ItsTranslater = $10040;

  ItsControlEnabled = 1;
  ItsControlQuiescent = LongWord($80000000);
  CommandReaderStalled = 1;

  TableValid = QWord(1) shl 63;
  TableTypeShift = 56;
  TableTypeDevices = 1;
  TableTypeCollections = 4;
  TableEntrySizeShift = 48;
  TablePageSizeShift = 8;
  CacheWriteBackShift = 59;
  RedistributorCacheShift = 7;
  CacheWriteBack = 7;
  ShareabilityShift = 10;
  ShareabilityMask = QWord(3) shl ShareabilityShift;
  ShareabilityInner = QWord(1) shl ShareabilityShift;
  AddressMask = QWord($000FFFFFFFFFF000);
  PendingTableZeroed = QWord(1) shl 62;

  { Configuration bytes cover INTIDs below 2^(LpiIdBits + 1). }
  LpiIdBits = 13;
  PropertyTableBytes = (1 shl (LpiIdBits + 1)) - FirstLpi;
  PendingAlignmentPages = 16;
  PropertyEnable = 1;
  PropertyReserved = 2;

  DeviceTableBytes = 65536;
  EventBits = 5;
  CommandQueueBytes = 4096;
  CommandBytes = 32;
  CommandWaitSpins = 50000000;
  CommandMapDevice = $08;
  CommandMapCollection = $09;
  CommandMapTranslatedInterrupt = $0A;
  CommandInvalidate = $0C;
  CommandSynchronize = $05;

  MaximumDevices = 32;
  MaximumCollections = 64;

type
  TCommand = array[0..3] of QWord;

  TMappedDevice = record
    RequesterId: LongWord;
    NextEvent: LongWord;
  end;

var
  Registers: PByte = nil;
  ItsPhysical: QWord;
  Ready: Boolean = False;
  NotCoherent: Boolean = False;
  TargetsByAddress: Boolean = False;
  Lock: TSpinLock;
  CommandQueue: PByte;
  CommandWriter: LongWord;
  PropertyTable: PByte;
  PropertyTablePhysical: QWord;
  Devices: array[0..MaximumDevices - 1] of TMappedDevice;
  DeviceCount: LongWord;
  CollectionMapped: array[0..MaximumCollections - 1] of Boolean;
  CollectionTargets: array[0..MaximumCollections - 1] of TRedistributor;
  TableValues: array[0..ItsTableCount - 1] of QWord;
  CommandBaseValue: QWord;
  LpiVectors: array[0..MaximumLpis - 1] of Byte;
  LpiDevices: array[0..MaximumLpis - 1] of LongWord;
  LpiEvents: array[0..MaximumLpis - 1] of LongWord;
  NextLpi: LongWord = 0;
  IttEntryBytes: LongWord;
  { Each redistributor's LPI pending table, kept across suspend to RAM:
    waking turns LPIs off, and turning them on again reuses the table
    rather than taking a new page each time. }
  PendingRedistributors: array[0..MaximumPendingTables - 1] of QWord;
  PendingTables: array[0..MaximumPendingTables - 1] of QWord;
  PendingTableCount: LongWord = 0;

function TranslationServiceIsReady: Boolean;
begin
  Result := Ready;
end;

function ReadIts64(Offset: LongWord): QWord;
begin
  Result := PQWord(Registers + Offset)^;
end;

procedure WriteIts64(Offset: LongWord; Value: QWord);
begin
  PQWord(Registers + Offset)^ := Value;
end;

{ Memory the GIC reads must have reached it. }
procedure MakeVisible(Address: Pointer; SizeInBytes: QWord);
begin
  if NotCoherent then
    CleanDataCache(Address, SizeInBytes);
  DataSynchronizationBarrier;
end;

{ PageCount zeroed pages starting on a multiple of AlignPages pages;
  the pages of the run around them are given back. }
function AllocateAlignedPages(PageCount, AlignPages: QWord): QWord;
var
  Run: QWord;
  First: QWord;
  Page: QWord;
begin
  Run := AllocateZeroedContiguousPhysicalPages(PageCount + AlignPages - 1, High(QWord), PageUsageGeneral);
  if Run = 0 then
    Exit(0);
  First := (Run + AlignPages * PageSize - 1) and not (AlignPages * PageSize - 1);
  Page := Run;
  while Page < Run + (PageCount + AlignPages - 1) * PageSize do
  begin
    if (Page < First) or (Page >= First + PageCount * PageSize) then
      FreePhysicalPage(Page);
    Page := Page + PageSize;
  end;
  Result := First;
end;

{ --- The command queue ------------------------------------------------- }

{ Queues Command and waits until the ITS took it. The lock is held. }
function SendCommand(constref Command: TCommand): Boolean;
var
  Slot: PQWord;
  Spins: LongWord;
  Reader: QWord;
begin
  Slot := PQWord(CommandQueue + CommandWriter);
  Slot[0] := Command[0];
  Slot[1] := Command[1];
  Slot[2] := Command[2];
  Slot[3] := Command[3];
  MakeVisible(Slot, CommandBytes);
  CommandWriter := (CommandWriter + CommandBytes) mod CommandQueueBytes;
  WriteIts64(ItsCommandWriter, CommandWriter);
  Spins := 0;
  repeat
    Reader := ReadIts64(ItsCommandReader);
    if (Reader and CommandReaderStalled) <> 0 then
      Exit(False);
    if (Reader and $FFFE0) = CommandWriter then
      Exit(True);
    CpuRelax;
    Inc(Spins);
  until Spins >= CommandWaitSpins;
  Result := False;
end;

function TargetAddressOf(constref Target: TRedistributor): QWord;
begin
  if TargetsByAddress then
    Result := Target.PhysicalAddress shr 16
  else
    Result := Target.ProcessorNumber;
end;

function MapCollection(Collection: LongWord; constref Target: TRedistributor): Boolean;
var
  Command: TCommand;
begin
  Command[0] := CommandMapCollection;
  Command[1] := 0;
  Command[2] := TableValid or (TargetAddressOf(Target) shl 16) or Collection;
  Command[3] := 0;
  Result := SendCommand(Command);
end;

function MapDevice(DeviceId: LongWord; Table: QWord): Boolean;
var
  Command: TCommand;
begin
  Command[0] := CommandMapDevice or (QWord(DeviceId) shl 32);
  Command[1] := EventBits - 1;
  Command[2] := TableValid or (Table and QWord($000FFFFFFFFFFF00));
  Command[3] := 0;
  Result := SendCommand(Command);
end;

function MapEvent(DeviceId, EventId, IntId, Collection: LongWord): Boolean;
var
  Command: TCommand;
begin
  Command[0] := CommandMapTranslatedInterrupt or (QWord(DeviceId) shl 32);
  Command[1] := EventId or (QWord(IntId) shl 32);
  Command[2] := Collection;
  Command[3] := 0;
  Result := SendCommand(Command);
end;

function InvalidateEvent(DeviceId, EventId: LongWord): Boolean;
var
  Command: TCommand;
begin
  Command[0] := CommandInvalidate or (QWord(DeviceId) shl 32);
  Command[1] := EventId;
  Command[2] := 0;
  Command[3] := 0;
  Result := SendCommand(Command);
end;

function Synchronize(constref Target: TRedistributor): Boolean;
var
  Command: TCommand;
begin
  Command[0] := CommandSynchronize;
  Command[1] := 0;
  Command[2] := TargetAddressOf(Target) shl 16;
  Command[3] := 0;
  Result := SendCommand(Command);
end;

{ --- Set up ------------------------------------------------------------- }

{ Gives table register Index the memory it asks for (devices and
  collections; other kinds stay invalid). }
function SetUpTable(Index: LongWord): Boolean;
var
  Offset: LongWord;
  Value: QWord;
  Kind: LongWord;
  PageBytes: QWord;
  Units: QWord;
  Physical: QWord;
  Written: QWord;
begin
  Result := True;
  Offset := ItsTableBase + Index * 8;
  Value := ReadIts64(Offset);
  Kind := LongWord((Value shr TableTypeShift) and 7);
  if (Kind <> TableTypeDevices) and (Kind <> TableTypeCollections) then
    Exit;
  { 4 KiB pages if the ITS takes them, else the size it insists on. }
  WriteIts64(Offset, Value and not (QWord(3) shl TablePageSizeShift));
  case (ReadIts64(Offset) shr TablePageSizeShift) and 3 of
    0: PageBytes := 4096;
    1: PageBytes := 16384;
  else
    PageBytes := 65536;
  end;
  if Kind = TableTypeDevices then
    Units := (DeviceTableBytes + PageBytes - 1) div PageBytes
  else
    Units := 1;
  Physical := AllocateAlignedPages(Units * (PageBytes div PageSize), PageBytes div PageSize);
  if Physical = 0 then
    Exit(False);
  Written := TableValid or (QWord(CacheWriteBack) shl CacheWriteBackShift) or (Value and (QWord($FF) shl 48)) or
    (Physical and AddressMask) or ShareabilityInner or (ReadIts64(Offset) and (QWord(3) shl TablePageSizeShift)) or
    (Units - 1);
  WriteIts64(Offset, Written);
  TableValues[Index] := ReadIts64(Offset);
  if (ReadIts64(Offset) and ShareabilityMask) = 0 then
    NotCoherent := True;
  if NotCoherent then
    CleanDataCache(PhysicalToVirtual(Physical), Units * PageBytes);
  Result := (ReadIts64(Offset) and TableValid) <> 0;
end;

function SetUpCommandQueue: Boolean;
var
  Physical: QWord;
begin
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit(False);
  CommandQueue := PByte(PhysicalToVirtual(Physical));
  CommandWriter := 0;
  WriteIts64(ItsCommandBase, TableValid or (QWord(CacheWriteBack) shl CacheWriteBackShift) or
    (Physical and AddressMask) or ShareabilityInner);
  CommandBaseValue := ReadIts64(ItsCommandBase);
  if (ReadIts64(ItsCommandBase) and ShareabilityMask) = 0 then
    NotCoherent := True;
  MakeVisible(CommandQueue, CommandQueueBytes);
  WriteIts64(ItsCommandWriter, 0);
  Result := True;
end;

function SetUpPropertyTable: Boolean;
var
  Index: LongWord;
begin
  PropertyTablePhysical := AllocateZeroedContiguousPhysicalPages(PropertyTableBytes div PageSize, High(QWord),
    PageUsageGeneral);
  if PropertyTablePhysical = 0 then
    Exit(False);
  PropertyTable := PByte(PhysicalToVirtual(PropertyTablePhysical));
  for Index := 0 to MaximumLpis - 1 do
    LpiVectors[Index] := SpuriousInterruptVector;
  Result := True;
end;

function InitializeTranslationService(PhysicalAddress: QWord): Boolean;
var
  Index: LongWord;
  Spins: LongWord;
begin
  Result := False;
  if PhysicalAddress = 0 then
    Exit;
  Registers := PByte(MapDeviceMemory(PhysicalAddress, ItsRegisterBytes));
  if Registers = nil then
    Exit;
  ItsPhysical := PhysicalAddress;
  InitializeSpinLock(Lock);
  { Off (and quiet) while it is given its tables. }
  PLongWord(Registers + ItsControl)^ := 0;
  Spins := 0;
  while ((PLongWord(Registers + ItsControl)^ and ItsControlQuiescent) = 0) and (Spins < CommandWaitSpins) do
  begin
    CpuRelax;
    Inc(Spins);
  end;
  TargetsByAddress := (ReadIts64(ItsType) and (QWord(1) shl 19)) <> 0;
  IttEntryBytes := LongWord((ReadIts64(ItsType) shr 4) and $F) + 1;
  if (IttEntryBytes shl EventBits) > PageSize then
    Exit;
  for Index := 0 to ItsTableCount - 1 do
    if not SetUpTable(Index) then
      Exit;
  if not SetUpCommandQueue or not SetUpPropertyTable then
    Exit;
  PLongWord(Registers + ItsControl)^ := ItsControlEnabled;
  Ready := True;
  Result := True;
end;

procedure RestoreTranslationService;
var
  Index: LongWord;
begin
  if not Ready or ((PLongWord(Registers + ItsControl)^ and ItsControlEnabled) <> 0) then
    Exit;
  for Index := 0 to ItsTableCount - 1 do
    if (TableValues[Index] and TableValid) <> 0 then
      WriteIts64(ItsTableBase + Index * 8, TableValues[Index]);
  WriteIts64(ItsCommandBase, CommandBaseValue);
  CommandWriter := 0;
  WriteIts64(ItsCommandWriter, 0);
  PLongWord(Registers + ItsControl)^ := ItsControlEnabled;
  for Index := 0 to MaximumCollections - 1 do
    if CollectionMapped[Index] then
      MapCollection(Index, CollectionTargets[Index]);
end;

{ Redistributor's pending table: the one it had before (cleared), or a
  new one. 0 if memory ran out. }
function PendingTableOf(constref Redistributor: TRedistributor): QWord;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < PendingTableCount do
  begin
    if PendingRedistributors[Index] = Redistributor.PhysicalAddress then
    begin
      { Nothing is pending after waking: the table says so again. }
      ZeroMemory(PhysicalToVirtual(PendingTables[Index]), PageSize);
      Exit(PendingTables[Index]);
    end;
    Inc(Index);
  end;
  Result := AllocateAlignedPages(1, PendingAlignmentPages);
  if (Result <> 0) and (PendingTableCount < MaximumPendingTables) then
  begin
    PendingRedistributors[PendingTableCount] := Redistributor.PhysicalAddress;
    PendingTables[PendingTableCount] := Result;
    Inc(PendingTableCount);
  end;
end;

procedure EnableLpisOn(constref Redistributor: TRedistributor);
var
  Pending: QWord;
  Control: LongWord;
begin
  if not Ready then
    Exit;
  Control := ReadRedistributor(Redistributor, RedistributorControl);
  if (Control and RedistributorControlEnableLpis) <> 0 then
    Exit;
  Pending := PendingTableOf(Redistributor);
  if Pending = 0 then
    Exit;
  MakeVisible(PhysicalToVirtual(Pending), PageSize);
  MakeVisible(PropertyTable, PropertyTableBytes);
  WriteRedistributor64(Redistributor, RedistributorPropertiesBase, (PropertyTablePhysical and AddressMask) or
    ShareabilityInner or (QWord(CacheWriteBack) shl RedistributorCacheShift) or LpiIdBits);
  if (ReadRedistributor64(Redistributor, RedistributorPropertiesBase) and ShareabilityMask) = 0 then
    NotCoherent := True;
  WriteRedistributor64(Redistributor, RedistributorPendingBase, (Pending and QWord($000FFFFFFFFF0000)) or
    PendingTableZeroed or ShareabilityInner or (QWord(CacheWriteBack) shl RedistributorCacheShift));
  DataSynchronizationBarrier;
  WriteRedistributor(Redistributor, RedistributorControl, Control or RedistributorControlEnableLpis);
  DataSynchronizationBarrier;
end;

{ The device's slot, taking a new one (and its ITT) the first time. The
  lock is held. }
function FindOrMapDevice(RequesterId: LongWord): Integer;
var
  Index: LongWord;
  Table: QWord;
begin
  Index := 0;
  while Index < DeviceCount do
  begin
    if Devices[Index].RequesterId = RequesterId then
      Exit(Index);
    Inc(Index);
  end;
  if (DeviceCount >= MaximumDevices) or (RequesterId >= DeviceTableBytes div 8) then
    Exit(-1);
  Table := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Table = 0 then
    Exit(-1);
  MakeVisible(PhysicalToVirtual(Table), PageSize);
  if not MapDevice(RequesterId, Table) then
  begin
    FreePhysicalPage(Table);
    Exit(-1);
  end;
  Devices[DeviceCount].RequesterId := RequesterId;
  Devices[DeviceCount].NextEvent := 0;
  Result := DeviceCount;
  Inc(DeviceCount);
end;

function MapMessageInterrupt(RequesterId: LongWord; Vector: Byte; constref Target: TRedistributor;
  ProcessorIndex: LongWord; out Address: QWord; out Data: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Slot: Integer;
  EventId: LongWord;
  Lpi: LongWord;
begin
  Address := 0;
  Data := 0;
  Result := False;
  if not Ready or (ProcessorIndex >= MaximumCollections) then
    Exit;
  PreviousLevel := AcquireSpinLock(Lock);
  Slot := FindOrMapDevice(RequesterId);
  if (Slot >= 0) and (Devices[Slot].NextEvent < (1 shl EventBits)) and (NextLpi < MaximumLpis) and
     (CollectionMapped[ProcessorIndex] or MapCollection(ProcessorIndex, Target)) then
  begin
    CollectionMapped[ProcessorIndex] := True;
    CollectionTargets[ProcessorIndex] := Target;
    EventId := Devices[Slot].NextEvent;
    Lpi := NextLpi;
    LpiVectors[Lpi] := Vector;
    LpiDevices[Lpi] := RequesterId;
    LpiEvents[Lpi] := EventId;
    PropertyTable[Lpi] := (GicPriorityOfLevel(ArchPriorityLevelOfVector(Vector)) and $FC) or PropertyReserved or
      PropertyEnable;
    MakeVisible(@PropertyTable[Lpi], 1);
    if MapEvent(RequesterId, EventId, FirstLpi + Lpi, ProcessorIndex) and InvalidateEvent(RequesterId, EventId) and
       Synchronize(Target) then
    begin
      Inc(Devices[Slot].NextEvent);
      Inc(NextLpi);
      Address := ItsPhysical + ItsTranslater;
      Data := EventId;
      Result := True;
    end
    else
    begin
      PropertyTable[Lpi] := PropertyReserved;
      LpiVectors[Lpi] := SpuriousInterruptVector;
    end;
  end;
  ReleaseSpinLock(Lock, PreviousLevel);
end;

function VectorOfLpi(IntId: LongWord): Byte;
begin
  if (IntId < FirstLpi) or (IntId >= FirstLpi + MaximumLpis) then
    Exit(SpuriousInterruptVector);
  Result := LpiVectors[IntId - FirstLpi];
end;

procedure DisableLpi(IntId: LongWord);
var
  Lpi: LongWord;
  PreviousLevel: TPriorityLevel;
begin
  if not Ready or (IntId < FirstLpi) or (IntId >= FirstLpi + MaximumLpis) then
    Exit;
  Lpi := IntId - FirstLpi;
  PreviousLevel := AcquireSpinLock(Lock);
  PropertyTable[Lpi] := PropertyTable[Lpi] and not PropertyEnable;
  MakeVisible(@PropertyTable[Lpi], 1);
  InvalidateEvent(LpiDevices[Lpi], LpiEvents[Lpi]);
  ReleaseSpinLock(Lock, PreviousLevel);
end;

end.
