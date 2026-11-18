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
  The Broadcom STB reset controllers a device tree node names in its
  "resets"/"reset-names" (the BCM2712's PCIe root complexes use both):

  - "brcm,brcmstb-reset" (#reset-cells 1): banks of 32 lines, 18h bytes
    each; 00h SET asserts the lines written as ones, 04h CLEAR
    deasserts them, 08h STATUS shows which are asserted. After a
    deassert the block wants 100-200 us before it is used.
  - "brcm,bcm7216-pcie-sata-rescal" (#reset-cells 0): the SerDes
    resistor calibration. "Resetting" it runs the calibration: 00h bit 0
    starts it, 08h bit 0 says it is done, then the start bit is cleared.

  Every wait has a timeout; nothing here touches the device the line
  resets. A line is looked up once (FindResetLine), its controller's
  registers stay mapped.
}
unit Drivers.BrcmResets;

{$mode objfpc}
{$pointermath on}

interface

type
  TResetControllerKind = (ResetControllerUnknown, ResetControllerStbLines, ResetControllerRescal);

  PResetLine = ^TResetLine;
  TResetLine = record
    Kind: TResetControllerKind;
    Controller: LongInt;
    { The line number (STB lines; 0 for rescal). }
    Line: LongWord;
    Physical: QWord;
    Registers: PByte;
    MappedBytes: QWord;
  end;

{ The "resets" entry called Name in Node's "reset-names". False if there
  is none, or its controller cannot be mapped; Problem then says why
  (nil: the node simply names no such line). }
function FindResetLine(Node: LongInt; Name: PChar; out Line: TResetLine; out Problem: PChar): Boolean;

function AssertResetLine(var Line: TResetLine): Boolean;
{ Deasserts and waits the 100-200 us the block needs. }
function DeassertResetLine(var Line: TResetLine): Boolean;
{ An STB line's STATUS bit; False for anything else. }
function ResetLineIsAsserted(var Line: TResetLine): Boolean;
{ An STB line asserted, held a few microseconds, deasserted; a rescal
  controller's calibration run. False if the calibration never finished
  (Status: its status register) or the start bit did not stick. }
function PulseResetLine(var Line: TResetLine; out Status: LongWord): Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree;

const
  MaximumResetEntries = 16;

  StbBankBytes = $18;
  StbSet = $00;
  StbClear = $04;
  StbStatus = $08;
  StbDeassertSettleMicroseconds = 150;
  StbPulseMicroseconds = 2;

  RescalStart = $0;
  RescalStartBit = $1;
  RescalStatus = $8;
  RescalStatusBit = $1;
  RescalBytes = $C;
  RescalTimeoutMicroseconds = 1000;

procedure WaitMicroseconds(Microseconds: QWord);
var
  Deadline: QWord;
begin
  Deadline := ClockNanoseconds + Microseconds * 1000;
  while ClockNanoseconds < Deadline do
    CpuRelax;
end;

function ReadLineRegister(constref Line: TResetLine; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Line.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteLineRegister(constref Line: TResetLine; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Line.Registers + Offset)^ := Value;
  FullMemoryBarrier;
end;

function KindOf(Controller: LongInt): TResetControllerKind;
begin
  if NodeIsCompatible(SystemDeviceTree^, Controller, 'brcm,brcmstb-reset') then
    Result := ResetControllerStbLines
  else if NodeIsCompatible(SystemDeviceTree^, Controller, 'brcm,bcm7216-pcie-sata-rescal') then
    Result := ResetControllerRescal
  else
    Result := ResetControllerUnknown;
end;

{ Bytes of the controller a line needs. }
function BytesNeeded(constref Line: TResetLine): QWord;
begin
  if Line.Kind = ResetControllerStbLines then
    Result := QWord(Line.Line shr 5) * StbBankBytes + StbStatus + 4
  else
    Result := RescalBytes;
end;

function MapLine(var Line: TResetLine; out Problem: PChar): Boolean;
var
  Size: QWord;
begin
  Result := False;
  Line.Kind := KindOf(Line.Controller);
  if Line.Kind = ResetControllerUnknown then
  begin
    Problem := 'its reset controller is of a kind not driven';
    Exit;
  end;
  if not NodeRegisterPhysical(SystemDeviceTree^, Line.Controller, 0, Line.Physical, Size) then
  begin
    Problem := 'its reset controller has no registers';
    Exit;
  end;
  Line.MappedBytes := BytesNeeded(Line);
  if Line.MappedBytes > Size then
  begin
    Problem := 'its line lies beyond the reset controller''s registers';
    Exit;
  end;
  Line.Registers := PByte(MapDeviceMemory(Line.Physical, Line.MappedBytes));
  if Line.Registers = nil then
  begin
    Problem := 'its reset controller cannot be mapped';
    Exit;
  end;
  Result := True;
end;

function FindResetLine(Node: LongInt; Name: PChar; out Line: TResetLine; out Problem: PChar): Boolean;
var
  Tree: PDeviceTree;
  Names: TDeviceTreeProperty;
  Resets: TDeviceTreeProperty;
  Entry: LongWord;
  Cell: LongWord;
  Cells: LongWord;
  Candidate: LongInt;
begin
  Result := False;
  Problem := nil;
  Line.Kind := ResetControllerUnknown;
  Line.Controller := NoNode;
  Line.Line := 0;
  Line.Physical := 0;
  Line.Registers := nil;
  Line.MappedBytes := 0;
  Tree := SystemDeviceTree;
  if not FindProperty(Tree^, Node, 'reset-names', Names) or not FindProperty(Tree^, Node, 'resets', Resets) then
    Exit;
  Entry := 0;
  Cell := 0;
  while (Entry < MaximumResetEntries) and (Cell < PropertyCellCount(Resets)) do
  begin
    Candidate := FindNodeByPhandle(Tree^, PropertyCell(Resets, Cell));
    if (Candidate = NoNode) or not ReadCellProperty(Tree^, Candidate, '#reset-cells', Cells) then
    begin
      Problem := 'a "resets" entry before it names no reset controller';
      Exit;
    end;
    if DeviceTreeTextIsEqual(PropertyString(Names, Entry), Name) then
    begin
      Line.Controller := Candidate;
      if Cells > 0 then
      begin
        if Cell + 1 >= PropertyCellCount(Resets) then
        begin
          Problem := 'its "resets" entry is cut short';
          Exit;
        end;
        Line.Line := PropertyCell(Resets, Cell + 1);
      end;
      Exit(MapLine(Line, Problem));
    end;
    Cell := Cell + 1 + Cells;
    Inc(Entry);
  end;
end;

function StbBankOffset(constref Line: TResetLine): LongWord;
begin
  Result := (Line.Line shr 5) * StbBankBytes;
end;

function StbBit(constref Line: TResetLine): LongWord;
begin
  Result := LongWord(1) shl (Line.Line and 31);
end;

function AssertResetLine(var Line: TResetLine): Boolean;
begin
  Result := (Line.Kind = ResetControllerStbLines) and (Line.Registers <> nil);
  if Result then
    WriteLineRegister(Line, StbBankOffset(Line) + StbSet, StbBit(Line));
end;

function DeassertResetLine(var Line: TResetLine): Boolean;
begin
  Result := (Line.Kind = ResetControllerStbLines) and (Line.Registers <> nil);
  if not Result then
    Exit;
  WriteLineRegister(Line, StbBankOffset(Line) + StbClear, StbBit(Line));
  WaitMicroseconds(StbDeassertSettleMicroseconds);
end;

function ResetLineIsAsserted(var Line: TResetLine): Boolean;
begin
  Result := (Line.Kind = ResetControllerStbLines) and (Line.Registers <> nil) and
    ((ReadLineRegister(Line, StbBankOffset(Line) + StbStatus) and StbBit(Line)) <> 0);
end;

function RunCalibration(var Line: TResetLine; out Status: LongWord): Boolean;
var
  Deadline: QWord;
begin
  Status := 0;
  WriteLineRegister(Line, RescalStart, ReadLineRegister(Line, RescalStart) or RescalStartBit);
  if (ReadLineRegister(Line, RescalStart) and RescalStartBit) = 0 then
    Exit(False);
  Deadline := ClockNanoseconds + RescalTimeoutMicroseconds * 1000;
  repeat
    Status := ReadLineRegister(Line, RescalStatus);
    if (Status and RescalStatusBit) <> 0 then
      Break;
    WaitMicroseconds(10);
  until ClockNanoseconds > Deadline;
  WriteLineRegister(Line, RescalStart, ReadLineRegister(Line, RescalStart) and not RescalStartBit);
  Result := (Status and RescalStatusBit) <> 0;
end;

function PulseResetLine(var Line: TResetLine; out Status: LongWord): Boolean;
begin
  Status := 0;
  Result := False;
  if Line.Registers = nil then
    Exit;
  case Line.Kind of
    ResetControllerStbLines:
      begin
        AssertResetLine(Line);
        WaitMicroseconds(StbPulseMicroseconds);
        Result := DeassertResetLine(Line);
      end;
    ResetControllerRescal:
      Result := RunCalibration(Line, Status);
  end;
end;

end.
