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
  Every resource in an ACPI resource template (the buffer a device's
  _CRS or _DMA returns), decoded into lists: memory ranges, I/O port
  ranges and interrupts.

  Memory comes in the 24-bit and 32-bit memory range descriptors, the
  32-bit fixed memory descriptor and the word, double word, quad word
  and extended address space descriptors (resource type 0); I/O ports in
  the I/O and fixed I/O descriptors and the address space descriptors of
  resource type 1. An address space descriptor also has a translation
  offset: the processor sees the range at minimum + offset (what Start
  holds) while the bus below sees it at the minimum (BusStart). That is
  how _DMA describes where a device's memory accesses land.

  Interrupts come from the IRQ descriptor (ISA IRQs, through the MADT's
  overrides) and the extended interrupt descriptor (global system
  interrupts: GIC INTIDs on AArch64), all of them, with their trigger
  mode and polarity.

  Plain Pascal (only the shared runtime units), so the host test (tools/AcpiDeviceTest)
  builds it too.
}
unit Firmware.AcpiResourceList;

{$mode objfpc}
{$pointermath on}
{ Translation offsets wrap around on purpose. }
{$overflowchecks off}
{$rangechecks off}

interface

const
  MaximumResourceRanges = 8;
  MaximumResourceInterrupts = 8;

type
  TAcpiAddressRange = record
    { Where the processor sees the range. }
    Start: QWord;
    Length: QWord;
    { Where the bus below the device's parent sees it (Start minus the
      descriptor's translation offset; Start for the fixed kinds). }
    BusStart: QWord;
    { The descriptor says the device produces (bridges) rather than
      consumes the range. }
    IsProducer: Boolean;
  end;

  TAcpiInterrupt = record
    Number: LongWord;
    LevelTriggered: Boolean;
    ActiveLow: Boolean;
    Shared: Boolean;
    { An ISA IRQ (the small IRQ descriptor) rather than a global system
      interrupt. }
    IsIsaIrq: Boolean;
  end;

  TAcpiResourceList = record
    MemoryCount: Integer;
    Memory: array[0..MaximumResourceRanges - 1] of TAcpiAddressRange;
    IoCount: Integer;
    Io: array[0..MaximumResourceRanges - 1] of TAcpiAddressRange;
    InterruptCount: Integer;
    Interrupts: array[0..MaximumResourceInterrupts - 1] of TAcpiInterrupt;
  end;

{ Decodes the template at Data (Length bytes). False if it is damaged
  (what came before the damage is kept); resources beyond the lists'
  room are dropped. }
function ParseResourceTemplate(Data: PByte; Length: LongWord; out List: TAcpiResourceList): Boolean;

implementation

uses
  Runtime.Memory;

const
  SmallIrq = $04;
  SmallIo = $08;
  SmallFixedIo = $09;
  SmallEnd = $0F;

  LargeMemory24 = $01;
  LargeMemory32 = $05;
  LargeFixedMemory32 = $06;
  LargeDoubleWordAddress = $07;
  LargeWordAddress = $08;
  LargeExtendedInterrupt = $09;
  LargeQuadWordAddress = $0A;
  LargeExtendedAddress = $0B;

  AddressTypeMemory = 0;
  AddressTypeIo = 1;

function ReadLittleEndian(Data: PByte; ByteCount: Integer): QWord;
var
  Index: Integer;
begin
  Result := 0;
  Index := ByteCount;
  while Index > 0 do
  begin
    Dec(Index);
    Result := (Result shl 8) or Data[Index];
  end;
end;

procedure AddRange(var Count: Integer; var Ranges: array of TAcpiAddressRange; Start, Length, BusStart: QWord;
  IsProducer: Boolean);
begin
  if (Length = 0) or (Count > High(Ranges)) then
    Exit;
  Ranges[Count].Start := Start;
  Ranges[Count].Length := Length;
  Ranges[Count].BusStart := BusStart;
  Ranges[Count].IsProducer := IsProducer;
  Inc(Count);
end;

procedure AddInterrupt(var List: TAcpiResourceList; Number: LongWord; LevelTriggered, ActiveLow, Shared,
  IsIsaIrq: Boolean);
begin
  if List.InterruptCount >= MaximumResourceInterrupts then
    Exit;
  List.Interrupts[List.InterruptCount].Number := Number;
  List.Interrupts[List.InterruptCount].LevelTriggered := LevelTriggered;
  List.Interrupts[List.InterruptCount].ActiveLow := ActiveLow;
  List.Interrupts[List.InterruptCount].Shared := Shared;
  List.Interrupts[List.InterruptCount].IsIsaIrq := IsIsaIrq;
  Inc(List.InterruptCount);
end;

procedure DecodeSmall(var List: TAcpiResourceList; Kind: Byte; Body: PByte; Size: LongWord);
var
  Mask: Word;
  Flags: Byte;
  Bit: Integer;
begin
  case Kind of
    SmallIrq:
      if Size >= 2 then
      begin
        Mask := Body[0] or (Word(Body[1]) shl 8);
        { Without the flags byte: edge triggered, active high. }
        Flags := 1;
        if Size >= 3 then
          Flags := Body[2];
        for Bit := 0 to 15 do
          if (Mask and (1 shl Bit)) <> 0 then
            AddInterrupt(List, Bit, (Flags and 1) = 0, (Flags and 8) <> 0, (Flags and $10) <> 0, True);
      end;
    SmallIo:
      if Size >= 7 then
        AddRange(List.IoCount, List.Io, ReadLittleEndian(Body + 1, 2), Body[6], ReadLittleEndian(Body + 1, 2),
          False);
    SmallFixedIo:
      if Size >= 3 then
        AddRange(List.IoCount, List.Io, ReadLittleEndian(Body, 2) and $3FF, Body[2],
          ReadLittleEndian(Body, 2) and $3FF, False);
  end;
end;

{ An address space descriptor: FieldBytes is 2, 4 or 8; Fields points
  at its granularity (then minimum, maximum, translation, length). }
procedure DecodeAddressSpace(var List: TAcpiResourceList; ResourceType, GeneralFlags: Byte; Fields: PByte;
  FieldBytes: Integer);
var
  Minimum: QWord;
  Maximum: QWord;
  Translation: QWord;
  RangeLength: QWord;
  Start: QWord;
  IsProducer: Boolean;
begin
  Minimum := ReadLittleEndian(Fields + FieldBytes, FieldBytes);
  Maximum := ReadLittleEndian(Fields + 2 * FieldBytes, FieldBytes);
  Translation := ReadLittleEndian(Fields + 3 * FieldBytes, FieldBytes);
  RangeLength := ReadLittleEndian(Fields + 4 * FieldBytes, FieldBytes);
  if (RangeLength = 0) and (Maximum >= Minimum) then
    RangeLength := Maximum - Minimum + 1;
  { The offset is added modulo the descriptor's width, so a narrow
    descriptor can translate downwards too (QWord ones wrap at 2^64). }
  Start := Minimum + Translation;
  if FieldBytes < 8 then
    Start := Start and ((QWord(1) shl (FieldBytes * 8)) - 1);
  IsProducer := (GeneralFlags and 1) = 0;
  case ResourceType of
    AddressTypeMemory:
      AddRange(List.MemoryCount, List.Memory, Start, RangeLength, Minimum, IsProducer);
    AddressTypeIo:
      AddRange(List.IoCount, List.Io, Start, RangeLength, Minimum, IsProducer);
  end;
end;

procedure DecodeLarge(var List: TAcpiResourceList; Kind: Byte; Body: PByte; Size: LongWord);
var
  Flags: Byte;
  Count: LongWord;
  Index: LongWord;
begin
  case Kind of
    LargeMemory24:
      if Size >= 9 then
        AddRange(List.MemoryCount, List.Memory, ReadLittleEndian(Body + 1, 2) shl 8,
          ReadLittleEndian(Body + 7, 2) shl 8, ReadLittleEndian(Body + 1, 2) shl 8, False);
    LargeMemory32:
      if Size >= 17 then
        AddRange(List.MemoryCount, List.Memory, ReadLittleEndian(Body + 1, 4), ReadLittleEndian(Body + 13, 4),
          ReadLittleEndian(Body + 1, 4), False);
    LargeFixedMemory32:
      if Size >= 9 then
        AddRange(List.MemoryCount, List.Memory, ReadLittleEndian(Body + 1, 4), ReadLittleEndian(Body + 5, 4),
          ReadLittleEndian(Body + 1, 4), False);
    LargeWordAddress:
      if Size >= 13 then
        DecodeAddressSpace(List, Body[0], Body[1], Body + 3, 2);
    LargeDoubleWordAddress:
      if Size >= 23 then
        DecodeAddressSpace(List, Body[0], Body[1], Body + 3, 4);
    LargeQuadWordAddress:
      if Size >= 43 then
        DecodeAddressSpace(List, Body[0], Body[1], Body + 3, 8);
    LargeExtendedAddress:
      if Size >= 53 then
        DecodeAddressSpace(List, Body[0], Body[1], Body + 5, 8);
    LargeExtendedInterrupt:
      if Size >= 6 then
      begin
        Flags := Body[0];
        Count := Body[1];
        Index := 0;
        while (Index < Count) and (2 + Index * 4 + 4 <= Size) do
        begin
          AddInterrupt(List, LongWord(ReadLittleEndian(Body + 2 + Index * 4, 4)), (Flags and 2) = 0,
            (Flags and 4) <> 0, (Flags and 8) <> 0, False);
          Inc(Index);
        end;
      end;
  end;
end;

function ParseResourceTemplate(Data: PByte; Length: LongWord; out List: TAcpiResourceList): Boolean;
var
  Position: LongWord;
  Tag: Byte;
  Size: LongWord;
begin
  ZeroMemory(@List, SizeOf(List));
  Result := False;
  Position := 0;
  while Position < Length do
  begin
    Tag := Data[Position];
    if (Tag and $80) = 0 then
    begin
      Size := Tag and 7;
      if ((Tag shr 3) and $F) = SmallEnd then
        Exit(True);
      if Position + 1 + Size > Length then
        Exit;
      DecodeSmall(List, (Tag shr 3) and $F, Data + Position + 1, Size);
      Position := Position + 1 + Size;
    end
    else
    begin
      if Position + 3 > Length then
        Exit;
      Size := Data[Position + 1] or (LongWord(Data[Position + 2]) shl 8);
      if Position + 3 + Size > Length then
        Exit;
      DecodeLarge(List, Tag and $7F, Data + Position + 3, Size);
      Position := Position + 3 + Size;
    end;
  end;
  { No end tag, but nothing damaged either. }
  Result := True;
end;

end.
