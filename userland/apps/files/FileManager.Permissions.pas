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
  Permission bits: as the Permissions column shows them ("rwxr-x---",
  with s and t for the set-id and sticky bits as ls shows them), and
  the nine read, write and execute bits of the owner, the group and
  everyone else by row and column, as the properties dialog's check
  boxes are laid out.

  Plain logic: the host checks it (make files-test).
}
unit FileManager.Permissions;

{$mode objfpc}
{$H+}

interface

type
  TPermissionClass = (PermissionOwner, PermissionGroup, PermissionOthers);
  TPermissionRight = (PermissionRead, PermissionWrite, PermissionExecute);

const
  SetUserIdBit = $800;
  SetGroupIdBit = $400;
  StickyBit = $200;

{ The bit of Right for Who: owner read is $100, others execute $1. }
function PermissionBit(Who: TPermissionClass; Right: TPermissionRight): LongWord;
{ "rwxr-xr-x" for $1ED. }
function PermissionText(Mode: LongWord): string;
{ The mode as four octal digits ("0755"). }
function OctalModeText(Mode: LongWord): string;

implementation

function PermissionBit(Who: TPermissionClass; Right: TPermissionRight): LongWord;
const
  RightBits: array[TPermissionRight] of LongWord = (4, 2, 1);
  ClassShifts: array[TPermissionClass] of LongWord = (6, 3, 0);
begin
  Result := RightBits[Right] shl ClassShifts[Who];
end;

function PermissionText(Mode: LongWord): string;
const
  Letters: array[TPermissionRight] of Char = ('r', 'w', 'x');
  SpecialBits: array[TPermissionClass] of LongWord = (SetUserIdBit, SetGroupIdBit, StickyBit);
  SpecialWithExecute: array[TPermissionClass] of Char = ('s', 's', 't');
  SpecialWithoutExecute: array[TPermissionClass] of Char = ('S', 'S', 'T');
var
  Who: TPermissionClass;
  Right: TPermissionRight;
  Letter: Char;
begin
  Result := '';
  for Who := Low(TPermissionClass) to High(TPermissionClass) do
    for Right := Low(TPermissionRight) to High(TPermissionRight) do
    begin
      if (Mode and PermissionBit(Who, Right)) <> 0 then
        Letter := Letters[Right]
      else
        Letter := '-';
      if (Right = PermissionExecute) and ((Mode and SpecialBits[Who]) <> 0) then
      begin
        if Letter = 'x' then
          Letter := SpecialWithExecute[Who]
        else
          Letter := SpecialWithoutExecute[Who];
      end;
      Result := Result + Letter;
    end;
end;

function OctalModeText(Mode: LongWord): string;
var
  Shift: LongInt;
begin
  Result := '';
  Shift := 9;
  while Shift >= 0 do
  begin
    Result := Result + Chr(Ord('0') + ((Mode shr Shift) and 7));
    Shift := Shift - 3;
  end;
end;

end.
