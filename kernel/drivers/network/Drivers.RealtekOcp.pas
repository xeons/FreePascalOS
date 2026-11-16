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
  The OCP windows of the later Realtek chips (RTL8168G on, RTL8125,
  RTL8126): two registers through which the driver reaches the MAC's
  internal registers (the MAC OCP window at B0h) and the PHY's (the PHY
  OCP window at B8h), each by a 16-bit even address.

  A window register takes the address in bits 15 and up (address
  shl 15), the data in the low 16 bits, and bit 31 as the flag: set to
  write. A PHY access then waits for the flag to flip (cleared when a
  write is done, set when read data is ready); MAC accesses take effect
  at once. Each access holds the card's indirect access lock, so
  accesses from the deferred routine and from set-up do not mix; the
  wait is bounded.

  The standard PHY registers (MII registers 0-15) are at A400h + 2 x
  register number.
}
unit Drivers.RealtekOcp;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.RealtekGigabit;

const
  PhyOcpStandardBase = $A400;
  PhyOcpBasicControl = $A400;
  PhyOcpBasicStatus = $A402;
  PhyOcpAdvertisement = $A408;
  PhyOcpGigabitControl = $A412;
  BasicControlReset = $8000;
  BasicControlAutoNegotiationEnable = $1000;
  BasicControlPowerDown = $0800;
  BasicControlRestartAutoNegotiation = $0200;

function ReadMacOcp(Card: PRealtekCard; Address: Word): Word;
procedure WriteMacOcp(Card: PRealtekCard; Address: Word; Value: Word);
{ Clears ClearBits and sets SetBits. }
procedure ModifyMacOcp(Card: PRealtekCard; Address: Word; ClearBits, SetBits: Word);

{ False if the PHY did not answer in time. }
function ReadPhyOcp(Card: PRealtekCard; Address: Word; out Value: Word): Boolean;
function WritePhyOcp(Card: PRealtekCard; Address: Word; Value: Word): Boolean;
function ModifyPhyOcp(Card: PRealtekCard; Address: Word; ClearBits, SetBits: Word): Boolean;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Drivers.RealtekGigabit.Registers;

const
  RegisterMacOcp = $B0;
  RegisterPhyOcp = $B8;
  OcpFlag = LongWord($80000000);
  OcpAddressShift = 15;
  { The PHY answers within a few tens of microseconds. }
  PhyOcpPollLimit = 20000;

function ReadMacOcp(Card: PRealtekCard; Address: Word): Word;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Card^.IndirectAccessLock);
  Write32(Card^.Registers, RegisterMacOcp, LongWord(Address and $FFFE) shl OcpAddressShift);
  Result := Word(Read32(Card^.Registers, RegisterMacOcp));
  ReleaseSpinLock(Card^.IndirectAccessLock, PreviousLevel);
end;

procedure WriteMacOcp(Card: PRealtekCard; Address: Word; Value: Word);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Card^.IndirectAccessLock);
  Write32(Card^.Registers, RegisterMacOcp, OcpFlag or (LongWord(Address and $FFFE) shl OcpAddressShift) or Value);
  ReleaseSpinLock(Card^.IndirectAccessLock, PreviousLevel);
end;

procedure ModifyMacOcp(Card: PRealtekCard; Address: Word; ClearBits, SetBits: Word);
begin
  WriteMacOcp(Card, Address, (ReadMacOcp(Card, Address) and not ClearBits) or SetBits);
end;

{ Waits until the PHY window's flag is FlagSet (lock held). }
function WaitForPhyFlag(Card: PRealtekCard; FlagSet: Boolean): Boolean;
var
  Polls: Integer;
begin
  for Polls := 1 to PhyOcpPollLimit do
  begin
    if ((Read32(Card^.Registers, RegisterPhyOcp) and OcpFlag) <> 0) = FlagSet then
      Exit(True);
    CpuRelax;
  end;
  Result := False;
end;

function ReadPhyOcp(Card: PRealtekCard; Address: Word; out Value: Word): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Card^.IndirectAccessLock);
  Write32(Card^.Registers, RegisterPhyOcp, LongWord(Address and $FFFE) shl OcpAddressShift);
  Result := WaitForPhyFlag(Card, True);
  Value := Word(Read32(Card^.Registers, RegisterPhyOcp));
  ReleaseSpinLock(Card^.IndirectAccessLock, PreviousLevel);
  if not Result then
    Value := 0;
end;

function WritePhyOcp(Card: PRealtekCard; Address: Word; Value: Word): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Card^.IndirectAccessLock);
  Write32(Card^.Registers, RegisterPhyOcp, OcpFlag or (LongWord(Address and $FFFE) shl OcpAddressShift) or Value);
  Result := WaitForPhyFlag(Card, False);
  ReleaseSpinLock(Card^.IndirectAccessLock, PreviousLevel);
end;

function ModifyPhyOcp(Card: PRealtekCard; Address: Word; ClearBits, SetBits: Word): Boolean;
var
  Value: Word;
begin
  Result := ReadPhyOcp(Card, Address, Value) and
    WritePhyOcp(Card, Address, (Value and not ClearBits) or SetBits);
end;

end.
