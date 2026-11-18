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
  Information about the system: name, version, memory and volumes.
}
unit Sys.Information;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

type
  TSystemInformation = TAbiSystemInformation;
  TVolumeInformation = TAbiVolumeInformation;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
{ Returns False when Index is past the last volume. }
function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;
{ The machine's node name (its host name) into Buffer. }
function GetNodeName(Buffer: PChar; Capacity: PtrUInt): LongInt;
{ The same as a string ('' on an error); 0 or an error code. }
function ReadNodeName(out Name: string): LongInt;
{ A new node name (root only): letters, digits, hyphens and dots,
  starting with a letter or digit, 63 at most. }
function SetNodeName(Name: PChar): LongInt;
{ What machine this is, as its maker names it ("Raspberry Pi 5 Model B
  Rev 1.0"); '' when the kernel does not know (PCs, for now). }
function MachineModel: string;

implementation

uses
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSystemInformation(Information));
end;

function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;
begin
  Result := KernelListVolumes(QWord(Index), Information) > 0;
end;

function GetNodeName(Buffer: PChar; Capacity: PtrUInt): LongInt;
var
  Information: TSystemInformation;
begin
  Result := GetSystemInformation(Information);
  if Result = ErrorNone then
    CopyText(Buffer, @Information.NodeName[0], Capacity)
  else if Capacity > 0 then
    Buffer[0] := #0;
end;

function SetNodeName(Name: PChar): LongInt;
begin
  Result := ErrorCodeOf(KernelSetNodeName(Name));
end;

function ReadNodeName(out Name: string): LongInt;
var
  Buffer: array[0..AbiTextCapacity - 1] of Char;
begin
  Name := '';
  Result := GetNodeName(@Buffer[0], SizeOf(Buffer));
  if Result = ErrorNone then
    Name := PChar(@Buffer[0]);
end;

function MachineModel: string;
const
  Capacity = 128;
var
  Buffer: array[0..Capacity - 1] of Char;
begin
  if SystemCall(CallGetMachineModel, QWord(@Buffer[0]), Capacity, 0, 0, 0, 0) <= 0 then
    Exit('');
  Result := string(PChar(@Buffer[0]));
end;

end.
