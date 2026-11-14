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
  Legacy 8259 programmable interrupt controller pair.

  The kernel uses the local APIC (and later the I/O APIC) instead. The
  8259s are still present on PC compatible machines, so they are remapped
  away from the processor exception vectors and every line is masked.
}
unit Hal.LegacyPic;

{$mode objfpc}

interface

procedure RemapAndMaskLegacyPic(MasterVectorBase: Byte; SlaveVectorBase: Byte);

implementation

uses
  Hal.PortIo;

const
  MasterCommandPort = $20;
  MasterDataPort = $21;
  SlaveCommandPort = $A0;
  SlaveDataPort = $A1;

  InitializationCommandWithFourthWord = $11;
  CascadeLineOnMaster = $04;  { slave is wired to line 2 (bit mask) }
  CascadeIdentityOfSlave = $02; { slave identity is 2 }
  Mode8086 = $01;
  MaskAllLines = $FF;

procedure RemapAndMaskLegacyPic(MasterVectorBase: Byte; SlaveVectorBase: Byte);
begin
  { The initialization sequence is four words per controller. }
  WritePortByte(MasterCommandPort, InitializationCommandWithFourthWord);
  WaitForPortIo;
  WritePortByte(SlaveCommandPort, InitializationCommandWithFourthWord);
  WaitForPortIo;

  WritePortByte(MasterDataPort, MasterVectorBase);
  WaitForPortIo;
  WritePortByte(SlaveDataPort, SlaveVectorBase);
  WaitForPortIo;

  WritePortByte(MasterDataPort, CascadeLineOnMaster);
  WaitForPortIo;
  WritePortByte(SlaveDataPort, CascadeIdentityOfSlave);
  WaitForPortIo;

  WritePortByte(MasterDataPort, Mode8086);
  WaitForPortIo;
  WritePortByte(SlaveDataPort, Mode8086);
  WaitForPortIo;

  WritePortByte(MasterDataPort, MaskAllLines);
  WritePortByte(SlaveDataPort, MaskAllLines);
end;

end.
