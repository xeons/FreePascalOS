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
  The memory devices: null, zero, full, random and urandom.

    null     reads nothing (end of file); swallows writes
    zero     reads zero bytes without end; swallows writes
    full     reads like zero; every write fails with "no space left"
    random   reads random bytes; swallows writes
    urandom  the same as random

  Random bytes come from the kernel's generator (Kernel.Random).
}
unit Drivers.MemoryDevices;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeMemoryDevices;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Random,
  Io.Manager,
  Kernel.Panic;

type
  TMemoryDeviceRole = (RoleNull, RoleZero, RoleFull, RoleRandom);
  PMemoryDeviceRole = ^TMemoryDeviceRole;

function RoleOf(Device: PDeviceObject): TMemoryDeviceRole;
begin
  Result := PMemoryDeviceRole(Device^.Extension)^;
end;

function ReadMemoryDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  case RoleOf(Device) of
    RoleNull:
      Request.Information := 0;
    RoleZero, RoleFull:
      begin
        ZeroMemory(Request.Buffer, Request.Length);
        Request.Information := Int64(Request.Length);
      end;
    RoleRandom:
      begin
        FillRandom(PByte(Request.Buffer), Request.Length);
        Request.Information := Int64(Request.Length);
      end;
  end;
  Result := ErrorNone;
end;

function WriteMemoryDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  if RoleOf(Device) = RoleFull then
    Exit(ErrorNoSpace);
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

procedure AddDevice(Driver: PDriverObject; Name: PChar; Role: TMemoryDeviceRole);
const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
var
  Device: PDeviceObject;
begin
  Device := CreateDevice(Driver, Name, DeviceKindCharacter, EveryoneReadWrite,
    SizeOf(TMemoryDeviceRole));
  if Device = nil then
    KernelPanic('could not create a memory device');
  PMemoryDeviceRole(Device^.Extension)^ := Role;
  if Role = RoleNull then
    Device^.ReportedHandleKind := HandleKindNullDevice;
end;

procedure InitializeMemoryDevices;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadMemoryDevice;
  Dispatch[IoFunctionWrite] := @WriteMemoryDevice;
  Driver := CreateDriver('memory', Dispatch);
  AddDevice(Driver, 'null', RoleNull);
  AddDevice(Driver, 'zero', RoleZero);
  AddDevice(Driver, 'full', RoleFull);
  AddDevice(Driver, 'random', RoleRandom);
  AddDevice(Driver, 'urandom', RoleRandom);
end;

end.
