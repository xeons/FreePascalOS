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
  The machine's node name (its host name): what CallGetSystemInformation
  reports (uname -n, hostname) and what a DHCP client sends its server.
  "freepascalos" until root sets another (CallSetNodeName: hostname
  NAME, or the network service from /etc/settings/Network.settings).

  A name is 1 to MaximumNodeNameLength letters, digits, hyphens and dots
  (a host name, RFC 1123), starting with a letter or digit. Under its
  own spin lock.
}
unit Processes.NodeName;

{$mode objfpc}

interface

const
  DefaultNodeName = 'freepascalos';
  MaximumNodeNameLength = 63;

{ Copies the node name (with its #0) into Buffer. }
procedure GetNodeName(Buffer: PChar; Capacity: PtrUInt);
{ The system call: (NameAddress). Root only. }
function PerformSetNodeName(NameAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess;

var
  { A zeroed spin lock is free. }
  NameLock: TSpinLock;
  CurrentName: array[0..MaximumNodeNameLength] of Char = DefaultNodeName;

procedure GetNodeName(Buffer: PChar; Capacity: PtrUInt);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(NameLock);
  CopyText(Buffer, @CurrentName[0], Capacity);
  ReleaseSpinLock(NameLock, PreviousLevel);
end;

function IsNameCharacter(Character: Char): Boolean;
begin
  Result := ((Character >= 'a') and (Character <= 'z')) or ((Character >= 'A') and (Character <= 'Z')) or
    ((Character >= '0') and (Character <= '9')) or (Character = '-') or (Character = '.');
end;

function IsValidNodeName(Name: PChar): Boolean;
var
  Position: Integer;
begin
  if (Name[0] = #0) or (Name[0] = '-') or (Name[0] = '.') then
    Exit(False);
  Position := 0;
  while Name[Position] <> #0 do
  begin
    if not IsNameCharacter(Name[Position]) then
      Exit(False);
    Inc(Position);
  end;
  Result := True;
end;

function PerformSetNodeName(NameAddress: QWord): Int64;
var
  Name: array[0..MaximumNodeNameLength] of Char;
  PreviousLevel: TPriorityLevel;
  Error: LongInt;
begin
  if CurrentProcess^.Credentials.EffectiveUserId <> RootUserId then
    Exit(-Int64(ErrorNotPermitted));
  Error := CopyStringFromUser(NameAddress, @Name[0], SizeOf(Name));
  if Error = ErrorNameTooLong then
    Exit(-Int64(ErrorInvalidArgument));
  if Error <> ErrorNone then
    Exit(-Int64(Error));
  if not IsValidNodeName(@Name[0]) then
    Exit(-Int64(ErrorInvalidArgument));
  PreviousLevel := AcquireSpinLock(NameLock);
  CopyText(@CurrentName[0], @Name[0], SizeOf(CurrentName));
  ReleaseSpinLock(NameLock, PreviousLevel);
  Result := 0;
end;

end.
