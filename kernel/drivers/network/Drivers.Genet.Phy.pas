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
  The MDIO bus of a GENET controller, in its MAC block
  (Drivers.Genet.Registers), as a TMdioBus for Drivers.EthernetPhy: on
  the Raspberry Pi 4 a Broadcom BCM54213PE at address 1, wired by RGMII
  ("rgmii-rxid": the PHY delays the receive clock, the MAC transmit).

  A command (operation, PHY address, register, data for a write) is
  written, then the start bit set; the controller clears it when the
  transfer is done, and a read leaves the data in the low 16 bits (with
  a "read failed" bit if no PHY answered).
}
unit Drivers.Genet.Phy;

{$mode objfpc}

interface

uses
  Drivers.EthernetPhy;

function MdioRead(Registers: PByte; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
function MdioWrite(Registers: PByte; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;

{ The controller whose registers are mapped at Registers as an MDIO bus. }
function GenetMdioBus(Registers: PByte): TMdioBus;

implementation

uses
  Runtime.Atomic,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Drivers.Genet.Registers;

const
  MdioTimeoutNanoseconds = 2000000;

function ReadMdioRegister(Registers: PByte): LongWord;
begin
  Result := PLongWord(Registers + MacMdioCommand)^;
  FullMemoryBarrier;
end;

procedure WriteMdioRegister(Registers: PByte; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + MacMdioCommand)^ := Value;
end;

{ Starts the command written last and waits for it; the final register
  value, or False on time out. }
function RunMdioCommand(Registers: PByte; Command: LongWord; out Final: LongWord): Boolean;
var
  Deadline: QWord;
begin
  WriteMdioRegister(Registers, Command);
  WriteMdioRegister(Registers, Command or MdioStartBusy);
  Deadline := ClockNanoseconds + MdioTimeoutNanoseconds;
  repeat
    Final := ReadMdioRegister(Registers);
    if (Final and MdioStartBusy) = 0 then
      Exit(True);
    CpuRelax;
  until ClockNanoseconds > Deadline;
  Result := False;
end;

function MdioRead(Registers: PByte; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
var
  Final: LongWord;
begin
  Value := $FFFF;
  Result := RunMdioCommand(Registers, MdioOperationRead or ((PhyAddress and $1F) shl MdioPhyShift) or
    ((RegisterNumber and $1F) shl MdioRegisterShift), Final) and ((Final and MdioReadFailed) = 0);
  if Result then
    Value := Word(Final and MdioDataMask);
end;

function MdioWrite(Registers: PByte; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;
var
  Final: LongWord;
begin
  Result := RunMdioCommand(Registers, MdioOperationWrite or ((PhyAddress and $1F) shl MdioPhyShift) or
    ((RegisterNumber and $1F) shl MdioRegisterShift) or Value, Final);
end;

function BusRead(Context: Pointer; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
begin
  Result := MdioRead(PByte(Context), PhyAddress, RegisterNumber, Value);
end;

function BusWrite(Context: Pointer; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;
begin
  Result := MdioWrite(PByte(Context), PhyAddress, RegisterNumber, Value);
end;

function GenetMdioBus(Registers: PByte): TMdioBus;
begin
  Result.Read := @BusRead;
  Result.Write := @BusWrite;
  Result.Context := Registers;
end;

end.
