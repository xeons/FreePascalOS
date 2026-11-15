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
  AmlTest: runs the kernel's AML interpreter on the host, against a
  captured DSDT, and prints what it found.

    AmlTest TABLE.aml

  The table is loaded into a fresh namespace, its devices initialized,
  and the PCI interrupt routing built (APIC mode). Then, in PIC mode,
  the four LNKx link devices of a QEMU q35 table are asked for their
  current interrupt: their _CRS methods read the PIRQ routing registers
  through a PCI configuration region, which here is a fake
  configuration space with those registers set (q35's LPC bridge,
  device 31: A-D 10, 10, 11, 11 and E-H 5, 7, 9, 11; i440fx's PIIX,
  device 1: A-D 10, 10, 11, 11) and everything else reading as all ones.

  The output is compared with the expected one by "make aml-test".
}
program AmlTest;

{$mode objfpc}
{$pointermath on}

uses
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiResources,
  Firmware.AcpiPciRouting;

var
  { Bus 0's configuration space: 32 devices, 8 functions, 256 bytes. }
  Configuration: array[0..31, 0..7, 0..255] of Byte;

{ --- The host ------------------------------------------------------------------ }

function HostAllocate(ByteCount: PtrUInt): Pointer;
begin
  Result := AllocMem(ByteCount);
end;

procedure HostFree(Block: Pointer);
begin
  FreeMem(Block);
end;

function ConfigurationByte(Address: QWord; Offset: Integer; out Location: PByte): Boolean;
var
  Bus: Byte;
  Device: Byte;
  FunctionNumber: Byte;
  Register: LongWord;
begin
  Bus := Byte(Address shr 40);
  Device := Byte(Address shr 32);
  FunctionNumber := Byte(Address shr 24);
  Register := (Address and $FFFFFF) + LongWord(Offset);
  Result := (Bus = 0) and (Device < 32) and (FunctionNumber < 8) and (Register < 256);
  if Result then
    Location := @Configuration[Device, FunctionNumber, Register];
end;

function HostRead(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  Value := 0;
  Result := True;
  if Space <> AmlSpacePciConfiguration then
    Exit;
  for Index := Width div 8 - 1 downto 0 do
    if ConfigurationByte(Address, Index, Location) then
      Value := (Value shl 8) or Location^
    else
      Value := (Value shl 8) or $FF;
end;

function HostWrite(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
var
  Index: Integer;
  Location: PByte;
begin
  Result := True;
  if Space <> AmlSpacePciConfiguration then
    Exit;
  for Index := 0 to Width div 8 - 1 do
    if ConfigurationByte(Address, Index, Location) then
      Location^ := Byte(Value shr (Index * 8));
end;

procedure HostSleep(Milliseconds: QWord);
begin
end;

procedure HostStall(Microseconds: QWord);
begin
end;

function HostTimer: QWord;
begin
  Result := 0;
end;

procedure HostLog(Text: PChar);
begin
  WriteLn('log: ', Text);
end;

procedure SetUpHost;
const
  { The PIRQ routing registers of the q35 LPC bridge and the PIIX. }
  LpcDevice = $1F;
  PiixDevice = 1;
  PirqLow: array[0..3] of Byte = (10, 10, 11, 11);
  PirqHigh: array[0..3] of Byte = (5, 7, 9, 11);
var
  Index: Integer;
begin
  FillChar(Configuration, SizeOf(Configuration), $FF);
  for Index := 0 to 3 do
  begin
    Configuration[LpcDevice, 0, $60 + Index] := PirqLow[Index];
    Configuration[LpcDevice, 0, $68 + Index] := PirqHigh[Index];
    Configuration[PiixDevice, 0, $60 + Index] := PirqLow[Index];
  end;
  AmlHost.Allocate := @HostAllocate;
  AmlHost.Free := @HostFree;
  AmlHost.ReadSpace := @HostRead;
  AmlHost.WriteSpace := @HostWrite;
  AmlHost.Sleep := @HostSleep;
  AmlHost.Stall := @HostStall;
  AmlHost.Timer := @HostTimer;
  AmlHost.Log := @HostLog;
end;

{ --- The checks -------------------------------------------------------------------- }

function LoadTable(Path: string): PByte;
var
  TableFile: file of Byte;
  Size: Int64;
begin
  Assign(TableFile, Path);
  Reset(TableFile);
  Size := FileSize(TableFile);
  Result := AllocMem(Size);
  BlockRead(TableFile, Result^, Size);
  Close(TableFile);
end;

procedure ShowRoutes;
const
  Pins: array[0..3] of Char = 'ABCD';
  Triggers: array[Boolean] of string = ('edge', 'level');
  Kinds: array[Boolean] of string = ('GSI', 'IRQ');
  Polarities: array[Boolean] of string = ('high', 'low');
var
  Index: Integer;
  Route: PPciRoute;
begin
  for Index := 0 to PciRouteCount - 1 do
  begin
    Route := PciRouteAt(Index);
    WriteLn('route ', Route^.Bus, ':', Route^.Device, ' INT', Pins[Route^.Pin], ' -> ', Kinds[Route^.IsaInterrupt], ' ',
      Route^.GlobalInterrupt, ' ', Triggers[Route^.LevelTriggered], ' ', Polarities[Route^.ActiveLow]);
  end;
end;

procedure ShowLinksInPicMode;
const
  Links: array[0..3] of PChar = ('\_SB_.LNKA', '\_SB_.LNKB', '\_SB_.LNKC', '\_SB_.LNKD');
var
  Mode: TAmlValue;
  Ignored: TAmlValue;
  Resources: TAmlValue;
  Resource: TInterruptResource;
  Index: Integer;
  Link: PAmlNode;
begin
  Mode := MakeInteger(0);
  if EvaluatePath(nil, '\_PIC', @Mode, 1, Ignored) then
    ReleaseValue(Ignored);
  for Index := 0 to High(Links) do
  begin
    Link := LookupText(NamespaceRoot, Links[Index]);
    if (Link <> nil) and EvaluatePath(Link, '_CRS', nil, 0, Resources) and (Resources.Kind = AmlBuffer) and
       FindInterruptResource(Resources.Bytes^.Data, Resources.Bytes^.Length, Resource) and (Resource.Count > 0) then
      WriteLn('pic ', Links[Index], ' -> IRQ ', Resource.Interrupts[0])
    else
      WriteLn('pic ', Links[Index], ' -> none');
    ReleaseValue(Resources);
  end;
  { The table _PRT gives in PIC mode names the LNKx links. }
  if EvaluatePath(nil, '\_SB_.PCI0._PRT', nil, 0, Resources) and (Resources.Kind = AmlPackage) then
    WriteLn('pic _PRT entries: ', Resources.Package^.Count)
  else
    WriteLn('pic _PRT: none');
  ReleaseValue(Resources);
end;

var
  Table: PByte;
begin
  if ParamCount <> 1 then
  begin
    WriteLn('usage: AmlTest TABLE.aml');
    Halt(2);
  end;
  SetUpHost;
  Table := LoadTable(ParamStr(1));
  if not LoadAmlTable(Table) then
    WriteLn('load: failed');
  WriteLn('nodes: ', CountNodes);
  InitializeAmlDevices;
  WriteLn('routes: ', BuildPciRouting);
  ShowRoutes;
  ShowLinksInPicMode;
end.
