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
  What the AML interpreter needs from its surroundings.

  The interpreter (Firmware.Aml*) is plain Pascal: it allocates memory,
  reaches hardware and tells the time only through AmlHost, which the
  kernel fills in (Firmware.AcpiKernelHost), and so does the host-side
  test program (tools/AmlTest), which runs it against captured tables.

  Address spaces are ACPI's: system memory, system I/O and PCI
  configuration space. A PCI configuration address packs the segment
  (bits 48-63), bus (40-47), device (32-39), function (24-31) and the
  register (0-23). Widths are in bits: 8, 16, 32 or 64.
}
unit Firmware.AmlHost;

{$mode objfpc}

interface

const
  AmlSpaceSystemMemory = 0;
  AmlSpaceSystemIo = 1;
  AmlSpacePciConfiguration = 2;
  AmlSpaceEmbeddedController = 3;
  AmlSpaceSmbus = 4;
  AmlSpaceCmos = 5;
  AmlSpacePciBar = 6;

type
  TAmlHost = record
    { Zeroed memory, or nil. }
    Allocate: function(ByteCount: PtrUInt): Pointer;
    Free: procedure(Block: Pointer);
    { False if the space or the address cannot be reached. }
    ReadSpace: function(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
    WriteSpace: function(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
    Sleep: procedure(Milliseconds: QWord);
    Stall: procedure(Microseconds: QWord);
    { Time in 100 ns units (the Timer opcode). }
    Timer: function: QWord;
    { One line of the interpreter's own messages, and of Debug stores. }
    Log: procedure(Text: PChar);
    { AML's Notify: Node (a PAmlNode) told Value (0x80 on a power button:
      pressed; 1: check the device; ...). May be nil. }
    Notify: procedure(Node: Pointer; Value: QWord);
  end;

var
  AmlHost: TAmlHost;

function PciConfigurationAddress(Segment: Word; Bus, Device, FunctionNumber: Byte; Register: LongWord): QWord;

implementation

function PciConfigurationAddress(Segment: Word; Bus, Device, FunctionNumber: Byte; Register: LongWord): QWord;
begin
  Result := (QWord(Segment) shl 48) or (QWord(Bus) shl 40) or (QWord(Device) shl 32) or
    (QWord(FunctionNumber) shl 24) or (Register and $FFFFFF);
end;

end.
