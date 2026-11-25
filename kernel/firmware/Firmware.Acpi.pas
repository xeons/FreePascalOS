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
  Firmware.AcpiTableChecks,
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

{ A table's length is sound (it covers its header) and its checksum
  adds up (Firmware.AcpiTableChecks). }
function TableIsSound(Table: PAcpiTableHeader): Boolean;
begin
  Result := (Table <> nil) and AcpiTableIsSound(PByte(Table), Table^.Length);
end;

{ The first 20 bytes of the root pointer (ACPI 1.0's part) add up to 0. }
function RootPointerChecksumIsValid(Data: PByte): Boolean;
var
  Sum: Byte;
  Index: Integer;
begin
  Sum := 0;
  for Index := 0 to 19 do
    Sum := Byte(Sum + Data[Index]);
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
  EntryCount := AcpiRootEntryCount(RootTable^.Length, EntrySize, MaximumRootEntries);
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
    { An empty entry names no table. }
    if TableAddresses[TableCount] <> 0 then
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
  if not RootPointerChecksumIsValid(PByte(RootPointer)) then
    Exit;

  RootRevision := RootPointer^.Revision;
  if (RootPointer^.Revision >= 2) and (RootPointer^.XsdtAddress <> 0) then
  begin
    RootTable := PAcpiTableHeader(PhysicalToVirtual(RootPointer^.XsdtAddress));
    if TableIsSound(RootTable) then
      CollectRootEntries(RootTable, 8);
  end;

  if (TableCount = 0) and (RootPointer^.RsdtAddress <> 0) then
  begin
    RootTable := PAcpiTableHeader(PhysicalToVirtual(RootPointer^.RsdtAddress));
    if TableIsSound(RootTable) then
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
    if not TableIsSound(Table) then
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
