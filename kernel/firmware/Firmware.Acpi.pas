{
  ACPI table discovery.

  The loader passes the physical address of the RSDP, which points at the
  root table (XSDT, or the older RSDT). The root table lists every other
  system description table; FindAcpiTable looks one up by its four
  character signature, for example 'APIC' (MADT), 'MCFG' or 'HPET'.

  ACPI tables live in RAM that the firmware reports as ACPI memory, which
  the physical memory window covers, so they are read through it.
}
unit Firmware.Acpi;

{$mode objfpc}

interface

uses
  Memory.Layout;

type
  TAcpiSignature = array[0..3] of Char;

  TAcpiTableHeader = packed record
    Signature: TAcpiSignature;
    Length: LongWord;
    Revision: Byte;
    Checksum: Byte;
    OemId: array[0..5] of Char;
    OemTableId: array[0..7] of Char;
    OemRevision: LongWord;
    CreatorId: LongWord;
    CreatorRevision: LongWord;
  end;
  PAcpiTableHeader = ^TAcpiTableHeader;

procedure InitializeAcpi(RootPointerPhysical: TPhysicalAddress);
function AcpiIsAvailable: Boolean;

{ Returns the Instance'th table (counting from zero) with the given
  signature, or nil. Tables with a bad checksum are skipped. }
function FindAcpiTable(Signature: PChar; Instance: Integer): PAcpiTableHeader;

procedure WriteAcpiSummary;

implementation

uses
  Debug.Output;

const
  RootPointerSignature = 'RSD PTR ';
  MaximumRootEntries = 128;

type
  TAcpiRootPointer = packed record
    Signature: array[0..7] of Char;
    Checksum: Byte;
    OemId: array[0..5] of Char;
    Revision: Byte;
    RsdtAddress: LongWord;
    { Fields below exist from revision 2 (ACPI 2.0) on. }
    Length: LongWord;
    XsdtAddress: QWord;
    ExtendedChecksum: Byte;
    Reserved: array[0..2] of Byte;
  end;
  PAcpiRootPointer = ^TAcpiRootPointer;

var
  TableAddresses: array[0..MaximumRootEntries - 1] of TPhysicalAddress;
  TableCount: Integer;
  Available: Boolean;
  RootRevision: Byte;

function ChecksumIsValid(Data: PByte; Length: LongWord): Boolean;
var
  Sum: Byte;
  Index: LongWord;
begin
  Sum := 0;
  Index := 0;
  while Index < Length do
  begin
    Sum := Byte(Sum + Data[Index]);
    Inc(Index);
  end;
  Result := Sum = 0;
end;

function SignatureMatches(const Actual: array of Char; Expected: PChar): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Actual) do
  begin
    if Actual[Index] <> Expected[Index] then
      Exit(False);
  end;
  Result := True;
end;

procedure CollectRootEntries(RootTable: PAcpiTableHeader; EntrySize: Integer);
var
  EntryCount: Integer;
  EntryIndex: Integer;
  EntryAddress: PByte;
begin
  EntryCount := Integer((RootTable^.Length - SizeOf(TAcpiTableHeader)) div LongWord(EntrySize));
  EntryAddress := PByte(RootTable) + SizeOf(TAcpiTableHeader);
  TableCount := 0;

  for EntryIndex := 1 to EntryCount do
  begin
    if TableCount >= MaximumRootEntries then
      Break;
    if EntrySize = 8 then
      TableAddresses[TableCount] := PQWord(EntryAddress)^
    else
      TableAddresses[TableCount] := PLongWord(EntryAddress)^;
    Inc(TableCount);
    Inc(EntryAddress, EntrySize);
  end;
end;

procedure InitializeAcpi(RootPointerPhysical: TPhysicalAddress);
var
  RootPointer: PAcpiRootPointer;
  RootTable: PAcpiTableHeader;
begin
  Available := False;
  TableCount := 0;
  if RootPointerPhysical = 0 then
    Exit;

  RootPointer := PAcpiRootPointer(PhysicalToVirtual(RootPointerPhysical));
  if not SignatureMatches(RootPointer^.Signature, RootPointerSignature) then
    Exit;
  if not ChecksumIsValid(PByte(RootPointer), 20) then
    Exit;

  RootRevision := RootPointer^.Revision;
  if (RootPointer^.Revision >= 2) and (RootPointer^.XsdtAddress <> 0) then
  begin
    RootTable := PAcpiTableHeader(PhysicalToVirtual(RootPointer^.XsdtAddress));
    if ChecksumIsValid(PByte(RootTable), RootTable^.Length) then
      CollectRootEntries(RootTable, 8);
  end;

  if TableCount = 0 then
  begin
    RootTable := PAcpiTableHeader(PhysicalToVirtual(RootPointer^.RsdtAddress));
    if ChecksumIsValid(PByte(RootTable), RootTable^.Length) then
      CollectRootEntries(RootTable, 4);
  end;

  Available := TableCount > 0;
end;

function AcpiIsAvailable: Boolean;
begin
  Result := Available;
end;

function FindAcpiTable(Signature: PChar; Instance: Integer): PAcpiTableHeader;
var
  TableIndex: Integer;
  Table: PAcpiTableHeader;
  MatchesSoFar: Integer;
begin
  MatchesSoFar := 0;
  for TableIndex := 1 to TableCount do
  begin
    Table := PAcpiTableHeader(PhysicalToVirtual(TableAddresses[TableIndex - 1]));
    if not SignatureMatches(Table^.Signature, Signature) then
      Continue;
    if not ChecksumIsValid(PByte(Table), Table^.Length) then
      Continue;
    if MatchesSoFar = Instance then
      Exit(Table);
    Inc(MatchesSoFar);
  end;
  Result := nil;
end;

procedure WriteAcpiSummary;
var
  TableIndex: Integer;
  Table: PAcpiTableHeader;
  Signature: array[0..4] of Char;
begin
  DebugBeginMessage;
  DebugWriteTag('acpi');
  if not Available then
  begin
    DebugWriteLine('No ACPI tables found');
    DebugEndMessage;
    Exit;
  end;

  DebugWrite('Revision ');
  DebugWriteDecimal(RootRevision);
  DebugWrite(', tables:');
  Signature[4] := #0;
  for TableIndex := 1 to TableCount do
  begin
    Table := PAcpiTableHeader(PhysicalToVirtual(TableAddresses[TableIndex - 1]));
    Signature[0] := Table^.Signature[0];
    Signature[1] := Table^.Signature[1];
    Signature[2] := Table^.Signature[2];
    Signature[3] := Table^.Signature[3];
    DebugWrite(' ');
    DebugWrite(@Signature[0]);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
