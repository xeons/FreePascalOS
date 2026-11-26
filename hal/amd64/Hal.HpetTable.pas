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
  The ACPI HPET table (the "IA-PC HPET" description): where an event
  timer block's registers are, how many comparators it has, whether its
  counter is 64 bits wide and whether it can take over the legacy timer
  lines (legacy replacement), its sequence number (the PNP0103 device's
  _UID) and the smallest periodic tick the firmware vouches for.

    Offset  Size  Field
       0     36   Standard table header ("HPET")
      36      4   Event timer block id: bits 0-7 hardware revision,
                  8-12 comparators less one, 13 64-bit counter,
                  15 legacy replacement capable, 16-31 PCI vendor id
      40     12   Base address (Generic Address Structure: space id,
                  bit width, bit offset, access size, 64-bit address)
      52      1   HPET number (sequence)
      53      2   Main counter minimum clock tick in periodic mode
      55      1   Page protection and OEM attributes

  Plain Pascal: tools/HpetTest checks it on the host.
}
unit Hal.HpetTable;

{$mode objfpc}
{$pointermath on}

interface

const
  HpetTableMinimumLength = 56;
  { Generic Address Structure space ids. }
  AddressSpaceSystemMemory = 0;

type
  THpetTableInformation = record
    BaseAddress: QWord;
    HardwareRevision: Byte;
    ComparatorCount: LongWord;
    CounterIs64Bit: Boolean;
    LegacyReplacementCapable: Boolean;
    VendorId: Word;
    SequenceNumber: Byte;
    MinimumTick: Word;
    PageProtection: Byte;
  end;

{ Reads the HPET table of Length bytes at Table (header included; its
  checksum was checked by whoever found it). False if it is too short,
  is not an HPET table, or the registers are not in memory space at a
  page aligned, non-zero address. }
function ParseHpetTable(Table: PByte; Length: LongWord; out Information: THpetTableInformation): Boolean;

implementation

function ReadLongWord(Data: PByte): LongWord;
begin
  Result := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or
    (LongWord(Data[3]) shl 24);
end;

function ReadQWord(Data: PByte): QWord;
begin
  Result := QWord(ReadLongWord(Data)) or (QWord(ReadLongWord(Data + 4)) shl 32);
end;

function ParseHpetTable(Table: PByte; Length: LongWord; out Information: THpetTableInformation): Boolean;
const
  BlockIdOffset = 36;
  AddressOffset = 40;
  NumberOffset = 52;
  MinimumTickOffset = 53;
  ProtectionOffset = 55;
  PageMask = $FFF;
var
  BlockId: LongWord;
begin
  Information.BaseAddress := 0;
  Information.HardwareRevision := 0;
  Information.ComparatorCount := 0;
  Information.CounterIs64Bit := False;
  Information.LegacyReplacementCapable := False;
  Information.VendorId := 0;
  Information.SequenceNumber := 0;
  Information.MinimumTick := 0;
  Information.PageProtection := 0;
  Result := False;
  if (Table = nil) or (Length < HpetTableMinimumLength) then
    Exit;
  if (Table[0] <> Ord('H')) or (Table[1] <> Ord('P')) or (Table[2] <> Ord('E')) or (Table[3] <> Ord('T')) then
    Exit;
  if Table[AddressOffset] <> AddressSpaceSystemMemory then
    Exit;
  BlockId := ReadLongWord(Table + BlockIdOffset);
  Information.HardwareRevision := Byte(BlockId and $FF);
  Information.ComparatorCount := ((BlockId shr 8) and $1F) + 1;
  Information.CounterIs64Bit := (BlockId and (LongWord(1) shl 13)) <> 0;
  Information.LegacyReplacementCapable := (BlockId and (LongWord(1) shl 15)) <> 0;
  Information.VendorId := Word(BlockId shr 16);
  Information.BaseAddress := ReadQWord(Table + AddressOffset + 4);
  Information.SequenceNumber := Table[NumberOffset];
  Information.MinimumTick := Word(LongWord(Table[MinimumTickOffset]) or (LongWord(Table[MinimumTickOffset + 1]) shl 8));
  Information.PageProtection := Table[ProtectionOffset];
  if (Information.BaseAddress = 0) or ((Information.BaseAddress and PageMask) <> 0) then
    Exit;
  Result := True;
end;

end.
