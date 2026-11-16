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
  Which Intel gigabit controllers the e1000 driver takes, and what sets
  their families apart:

  - Classic: the first 8254x parts on PCI (82540, 82545, 82546), with
    the old layout of the EEPROM read register. QEMU's e1000 is an
    82540EM.
  - Classic later: 82541 and 82547, the new EEPROM read layout.
  - Express: the 8257x/82583 PCI Express parts (QEMU's e1000e is an
    82574L). Bit 22 of the transmit descriptor control must be set.
  - Hub: the I217, I218 and I219 built into the platform controller hub.
    Their NVM is the platform's flash, which the hardware loads into the
    receive address registers at reset (the driver reads it from there,
    and does not reset the PHY, which the firmware set up), and the
    software flag guards the reset.

  Only copper parts: the fibre and SerDes ones need another link set up.
  The 82543/82544 (no EEPROM read register), the 80003ES2LAN, the
  ICH8-ICH10 and 82577-82579 parts are not taken.
}
unit Drivers.E1000.Models;

{$mode objfpc}

interface

type
  TE1000Family = (FamilyClassic, FamilyClassicLater, FamilyExpress, FamilyHub);

  PE1000Model = ^TE1000Model;
  TE1000Model = record
    DeviceId: Word;
    Family: TE1000Family;
    Name: PChar;
  end;

const
  IntelVendorId = $8086;

{ The model with DeviceId (Intel's vendor ID assumed), or nil. }
function FindE1000Model(DeviceId: Word): PE1000Model;

implementation

const
  ModelCount = 84;
  Models: array[0..ModelCount - 1] of TE1000Model = (
    (DeviceId: $100E; Family: FamilyClassic; Name: 'Intel 82540EM'),
    (DeviceId: $1015; Family: FamilyClassic; Name: 'Intel 82540EM'),
    (DeviceId: $1016; Family: FamilyClassic; Name: 'Intel 82540EP'),
    (DeviceId: $1017; Family: FamilyClassic; Name: 'Intel 82540EP'),
    (DeviceId: $101E; Family: FamilyClassic; Name: 'Intel 82540EP'),
    (DeviceId: $100F; Family: FamilyClassic; Name: 'Intel 82545EM'),
    (DeviceId: $1026; Family: FamilyClassic; Name: 'Intel 82545GM'),
    (DeviceId: $1010; Family: FamilyClassic; Name: 'Intel 82546EB'),
    (DeviceId: $101D; Family: FamilyClassic; Name: 'Intel 82546EB'),
    (DeviceId: $1079; Family: FamilyClassic; Name: 'Intel 82546GB'),
    (DeviceId: $1099; Family: FamilyClassic; Name: 'Intel 82546GB'),
    (DeviceId: $10B5; Family: FamilyClassic; Name: 'Intel 82546GB'),

    (DeviceId: $1013; Family: FamilyClassicLater; Name: 'Intel 82541EI'),
    (DeviceId: $1018; Family: FamilyClassicLater; Name: 'Intel 82541EI'),
    (DeviceId: $1014; Family: FamilyClassicLater; Name: 'Intel 82541ER'),
    (DeviceId: $1078; Family: FamilyClassicLater; Name: 'Intel 82541ER'),
    (DeviceId: $1076; Family: FamilyClassicLater; Name: 'Intel 82541GI'),
    (DeviceId: $1077; Family: FamilyClassicLater; Name: 'Intel 82541GI'),
    (DeviceId: $107C; Family: FamilyClassicLater; Name: 'Intel 82541PI'),
    (DeviceId: $1019; Family: FamilyClassicLater; Name: 'Intel 82547EI'),
    (DeviceId: $101A; Family: FamilyClassicLater; Name: 'Intel 82547EI'),
    (DeviceId: $1075; Family: FamilyClassicLater; Name: 'Intel 82547GI'),

    (DeviceId: $105E; Family: FamilyExpress; Name: 'Intel 82571EB'),
    (DeviceId: $10A4; Family: FamilyExpress; Name: 'Intel 82571EB'),
    (DeviceId: $10BC; Family: FamilyExpress; Name: 'Intel 82571EB'),
    (DeviceId: $107D; Family: FamilyExpress; Name: 'Intel 82572EI'),
    (DeviceId: $10B9; Family: FamilyExpress; Name: 'Intel 82572EI'),
    (DeviceId: $108B; Family: FamilyExpress; Name: 'Intel 82573V'),
    (DeviceId: $108C; Family: FamilyExpress; Name: 'Intel 82573E'),
    (DeviceId: $109A; Family: FamilyExpress; Name: 'Intel 82573L'),
    (DeviceId: $10D3; Family: FamilyExpress; Name: 'Intel 82574L'),
    (DeviceId: $10F6; Family: FamilyExpress; Name: 'Intel 82574L'),
    (DeviceId: $150C; Family: FamilyExpress; Name: 'Intel 82583V'),

    (DeviceId: $153A; Family: FamilyHub; Name: 'Intel I217-LM'),
    (DeviceId: $153B; Family: FamilyHub; Name: 'Intel I217-V'),
    (DeviceId: $155A; Family: FamilyHub; Name: 'Intel I218-LM'),
    (DeviceId: $1559; Family: FamilyHub; Name: 'Intel I218-V'),
    (DeviceId: $15A0; Family: FamilyHub; Name: 'Intel I218-LM'),
    (DeviceId: $15A1; Family: FamilyHub; Name: 'Intel I218-V'),
    (DeviceId: $15A2; Family: FamilyHub; Name: 'Intel I218-LM'),
    (DeviceId: $15A3; Family: FamilyHub; Name: 'Intel I218-V'),
    (DeviceId: $156F; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $1570; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15B7; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15B8; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15B9; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15BB; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15BC; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15BD; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15BE; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15D6; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15D7; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15D8; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15E3; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15DF; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15E0; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15E1; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15E2; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $0D4C; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $0D4D; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $0D4E; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $0D4F; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $0D53; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $0D55; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15F4; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15F5; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15F9; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15FA; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $15FB; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $15FC; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $1A1C; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $1A1D; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $1A1E; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $1A1F; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $550A; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $550B; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $550C; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $550D; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $550E; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $550F; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $5510; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $5511; Family: FamilyHub; Name: 'Intel I219-V'),
    (DeviceId: $57A0; Family: FamilyHub; Name: 'Intel I219-LM'),
    (DeviceId: $57A1; Family: FamilyHub; Name: 'Intel I219-V')
  );

function FindE1000Model(DeviceId: Word): PE1000Model;
var
  Index: Integer;
begin
  for Index := 0 to ModelCount - 1 do
    if Models[Index].DeviceId = DeviceId then
      Exit(@Models[Index]);
  Result := nil;
end;

end.
