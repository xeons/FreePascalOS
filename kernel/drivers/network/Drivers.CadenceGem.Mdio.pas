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
  The Cadence GEM's MDIO bus as a TMdioBus (Drivers.EthernetPhy): the
  PHY maintenance register takes a clause 22 frame (start 01, read 10 or
  write 01, PHY and register address, the fixed code 10, the data); the
  network status register's idle bit says when it is done, and a read
  leaves the data in the low 16 bits. The management port must be
  enabled in the network control register and the MDC divider set in
  the network configuration (Drivers.CadenceGem does both first).
}
unit Drivers.CadenceGem.Mdio;

{$mode objfpc}

interface

uses
  Drivers.EthernetPhy;

{ The GEM whose registers are mapped at Registers as an MDIO bus. }
function GemMdioBus(Registers: PByte): TMdioBus;

implementation

uses
  Runtime.Atomic,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Drivers.CadenceGem.Registers;

const
  MdioTimeoutNanoseconds = 2000000;

function ReadGem(Registers: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteGem(Registers: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

function WaitForIdle(Registers: PByte): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockNanoseconds + MdioTimeoutNanoseconds;
  repeat
    if (ReadGem(Registers, GemNetworkStatus) and StatusManagementIdle) <> 0 then
      Exit(True);
    CpuRelax;
  until ClockNanoseconds > Deadline;
  Result := False;
end;

function Frame(Operation, PhyAddress, RegisterNumber: LongWord; Data: Word): LongWord;
begin
  Result := (MaintenanceStartClause22 shl MaintenanceStartShift) or (Operation shl MaintenanceOperationShift) or
    ((PhyAddress and $1F) shl MaintenancePhyShift) or ((RegisterNumber and $1F) shl MaintenanceRegisterShift) or
    (MaintenanceCode shl MaintenanceCodeShift) or Data;
end;

function BusRead(Context: Pointer; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
var
  Registers: PByte;
begin
  Value := $FFFF;
  Registers := PByte(Context);
  Result := WaitForIdle(Registers);
  if not Result then
    Exit;
  WriteGem(Registers, GemPhyMaintenance, Frame(MaintenanceOperationRead, PhyAddress, RegisterNumber, 0));
  Result := WaitForIdle(Registers);
  if Result then
    Value := Word(ReadGem(Registers, GemPhyMaintenance) and MaintenanceDataMask);
end;

function BusWrite(Context: Pointer; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;
var
  Registers: PByte;
begin
  Registers := PByte(Context);
  Result := WaitForIdle(Registers);
  if not Result then
    Exit;
  WriteGem(Registers, GemPhyMaintenance, Frame(MaintenanceOperationWrite, PhyAddress, RegisterNumber, Value));
  Result := WaitForIdle(Registers);
end;

function GemMdioBus(Registers: PByte): TMdioBus;
begin
  Result.Read := @BusRead;
  Result.Write := @BusWrite;
  Result.Context := Registers;
end;

end.
