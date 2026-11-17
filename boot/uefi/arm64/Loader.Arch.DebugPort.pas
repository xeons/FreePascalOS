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
  Finds the firmware's serial console (the UART the ACPI SPCR table
  names), so the loader can map its registers into the physical memory
  window: the kernel writes its first messages there before it can map
  devices itself. On QEMU's virt machine and on a Raspberry Pi 4 with
  UEFI firmware this is the PL011 (or the Pi's mini UART).

  The loader runs on the firmware's identity mapping, so the tables are
  read at their physical addresses.
}
unit Loader.Arch.DebugPort;

{$mode objfpc}
{$pointermath on}

interface

{ The physical address of the SPCR UART's registers, or zero if the
  firmware has no such table (or it describes an I/O port UART). }
function FindDebugPortRegisters(AcpiRootPointer: QWord): QWord;

implementation

type
  TTableHeader = packed record
    Signature: array[0..3] of Char;
    Length: LongWord;
    Revision: Byte;
    Checksum: Byte;
    OemId: array[0..5] of Char;
    OemTableId: array[0..7] of Char;
    OemRevision: LongWord;
    CreatorId: LongWord;
    CreatorRevision: LongWord;
  end;
  PTableHeader = ^TTableHeader;

  TRootPointer = packed record
    Signature: array[0..7] of Char;
    Checksum: Byte;
    OemId: array[0..5] of Char;
    Revision: Byte;
    RsdtAddress: LongWord;
    Length: LongWord;
    XsdtAddress: QWord;
  end;
  PRootPointer = ^TRootPointer;

  { The start of the SPCR table: its generic address of the registers. }
  TSerialPortTable = packed record
    Header: TTableHeader;
    InterfaceType: Byte;
    Reserved: array[0..2] of Byte;
    AddressSpace: Byte;
    RegisterBitWidth: Byte;
    RegisterBitOffset: Byte;
    AccessSize: Byte;
    Address: QWord;
  end;
  PSerialPortTable = ^TSerialPortTable;

const
  AddressSpaceSystemMemory = 0;

function IsSerialPortTable(Table: PTableHeader): Boolean;
begin
  Result := (Table <> nil) and (Table^.Signature[0] = 'S') and (Table^.Signature[1] = 'P') and
    (Table^.Signature[2] = 'C') and (Table^.Signature[3] = 'R');
end;

function FindTableInRoot(Root: PTableHeader; EntrySize: LongWord): PTableHeader;
var
  EntryCount: LongWord;
  Index: LongWord;
  Entries: PByte;
  Table: PTableHeader;
begin
  Result := nil;
  EntryCount := (Root^.Length - SizeOf(TTableHeader)) div EntrySize;
  Entries := PByte(Root) + SizeOf(TTableHeader);
  Index := 0;
  while Index < EntryCount do
  begin
    if EntrySize = 8 then
      Table := PTableHeader(PQWord(Entries + Index * 8)^)
    else
      Table := PTableHeader(QWord(PLongWord(Entries + Index * 4)^));
    if IsSerialPortTable(Table) then
      Exit(Table);
    Inc(Index);
  end;
end;

function FindDebugPortRegisters(AcpiRootPointer: QWord): QWord;
var
  RootPointer: PRootPointer;
  Table: PSerialPortTable;
begin
  Result := 0;
  if AcpiRootPointer = 0 then
    Exit;
  RootPointer := PRootPointer(AcpiRootPointer);
  if (RootPointer^.Revision >= 2) and (RootPointer^.XsdtAddress <> 0) then
    Table := PSerialPortTable(FindTableInRoot(PTableHeader(RootPointer^.XsdtAddress), 8))
  else
    Table := PSerialPortTable(FindTableInRoot(PTableHeader(QWord(RootPointer^.RsdtAddress)), 4));
  if (Table = nil) or (Table^.AddressSpace <> AddressSpaceSystemMemory) then
    Exit;
  Result := Table^.Address;
end;

end.
