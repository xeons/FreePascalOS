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
