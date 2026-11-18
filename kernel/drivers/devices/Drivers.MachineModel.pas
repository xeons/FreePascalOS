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
  What machine this is, as its maker names it (CallGetMachineModel,
  sysinfo's "Host"): the device tree's root "model" when the system
  started with one ("Raspberry Pi 5 Model B Rev 1.0"), else the
  Raspberry Pi firmware's board revision through the VideoCore mailbox
  (a Raspberry Pi 4 started with ACPI: "Raspberry Pi 4 Model B"), else
  nothing (a PC: no SMBIOS reading yet).

  Found once, on the first call, and kept.
}
unit Drivers.MachineModel;

{$mode objfpc}

interface

const
  MaximumMachineModelLength = 127;

{ The model, or an empty text if it is not known. }
function MachineModel: PChar;

implementation

uses
  Runtime.Text,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Firmware.DeviceTree,
  Drivers.RaspberryPiBoard;

var
  Model: array[0..MaximumMachineModelLength] of Char;
  IsFound: Boolean;
  { A zeroed spin lock is free. }
  ModelLock: TSpinLock;

{ The model from the firmware (outside the lock: the mailbox waits). }
procedure FindModel(Buffer: PChar; Capacity: PtrUInt);
var
  Board: TBoardInformation;
  TreeModel: PChar;
begin
  Buffer[0] := #0;
  TreeModel := DeviceTreeModel;
  if TreeModel <> nil then
    CopyText(Buffer, TreeModel, Capacity)
  else if GetBoardInformation(Board) then
    CopyText(Buffer, BoardModelName(Board.BoardRevision), Capacity);
end;

function MachineModel: PChar;
var
  Found: array[0..MaximumMachineModelLength] of Char;
  PreviousLevel: TPriorityLevel;
begin
  if not IsFound then
  begin
    FindModel(@Found[0], SizeOf(Found));
    PreviousLevel := AcquireSpinLock(ModelLock);
    if not IsFound then
    begin
      CopyText(@Model[0], @Found[0], SizeOf(Model));
      IsFound := True;
    end;
    ReleaseSpinLock(ModelLock, PreviousLevel);
  end;
  Result := @Model[0];
end;

end.
