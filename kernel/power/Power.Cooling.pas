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
  The cooling devices the kernel drives: the fans (and power resources)
  of ACPI thermal zones' active trip points (Io.AcpiPower, run by the
  thermal policy, Power.ThermalZones) and the board's fan (the Raspberry
  Pi 5's, Drivers.Rp1Fan through Power.BoardClocks). Each says how to run
  it at a speed (in percent; ACPI's only on or off) and reports what it
  does, for CallListCoolingDevices and the log.
}
unit Power.Cooling;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  MaximumCoolingDevices = 16;
  NoCoolingZone = High(LongWord);

type
  { Runs the device at Percent (0 stops it); False if that failed.
    Passive level, on a large stack (ACPI's run AML). }
  TCoolingSpeedRoutine = function(Context: Pointer; Percent: LongWord): Boolean;

{ Adds a device; returns its number, or -1 if there are too many. }
function RegisterCoolingDevice(Name: PChar; Kind: LongWord; Routine: TCoolingSpeedRoutine;
  Context: Pointer): Integer;
{ Runs device Number at Percent for zone Zone's active level Level; only
  when that changes something. Returns whether it runs now. }
function SetCoolingDeviceSpeed(Number: Integer; Percent: LongWord; Zone, Level: LongWord): Boolean;
{ A device reports its speed itself (the board's fan, driven elsewhere). }
procedure NoteCoolingDeviceSpeed(Number: Integer; Percent: LongWord);
{ The device whose routine's context is Context, or -1. }
function FindCoolingDevice(Context: Pointer): Integer;
{ Device Number's routine context (nil past the last). }
function CoolingDeviceContext(Number: Integer): Pointer;
function CoolingDeviceCount: Integer;
function GetCoolingDevice(Index: Integer; out Device: TAbiCoolingDevice): Boolean;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Debug.Output;

type
  TCoolingDevice = record
    Record_: TAbiCoolingDevice;
    Routine: TCoolingSpeedRoutine;
    Context: Pointer;
    Driven: Boolean;
  end;

var
  Lock: TSpinLock;
  Devices: array[0..MaximumCoolingDevices - 1] of TCoolingDevice;
  DeviceTotal: Integer = 0;

function RegisterCoolingDevice(Name: PChar; Kind: LongWord; Routine: TCoolingSpeedRoutine;
  Context: Pointer): Integer;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := -1;
  if DeviceTotal < MaximumCoolingDevices then
  begin
    Result := DeviceTotal;
    ZeroMemory(@Devices[Result], SizeOf(TCoolingDevice));
    CopyText(@Devices[Result].Record_.Name[0], Name, AbiCoolingNameCapacity);
    Devices[Result].Record_.Kind := Kind;
    Devices[Result].Record_.ThermalZone := NoCoolingZone;
    Devices[Result].Record_.ActiveLevel := NoCoolingZone;
    Devices[Result].Routine := Routine;
    Devices[Result].Context := Context;
    Inc(DeviceTotal);
  end;
  ReleaseSpinLock(Lock, PreviousLevel);
end;

procedure WriteChange(Number: Integer; Percent: LongWord; Worked: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('fan');
  DebugWrite(@Devices[Number].Record_.Name[0]);
  if not Worked then
    DebugWrite(' could not be set to ')
  else if Percent = 0 then
    DebugWrite(' off')
  else
    DebugWrite(' running at ');
  if (Percent > 0) or not Worked then
  begin
    DebugWriteDecimal(Percent);
    DebugWrite(' %');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function SetCoolingDeviceSpeed(Number: Integer; Percent: LongWord; Zone, Level: LongWord): Boolean;
var
  Device: ^TCoolingDevice;
  Worked: Boolean;
begin
  Result := False;
  if (Number < 0) or (Number >= DeviceTotal) then
    Exit;
  Device := @Devices[Number];
  if Percent > 100 then
    Percent := 100;
  Device^.Record_.ThermalZone := Zone;
  Device^.Record_.ActiveLevel := Level;
  if Device^.Driven and (Device^.Record_.SpeedPercent = Percent) then
    Exit(Percent > 0);
  Worked := Device^.Routine(Device^.Context, Percent);
  Device^.Driven := True;
  if Worked then
  begin
    Device^.Record_.SpeedPercent := Percent;
    Device^.Record_.Running := Ord(Percent > 0);
  end;
  WriteChange(Number, Percent, Worked);
  Result := Device^.Record_.Running <> 0;
end;

procedure NoteCoolingDeviceSpeed(Number: Integer; Percent: LongWord);
begin
  if (Number < 0) or (Number >= DeviceTotal) then
    Exit;
  Devices[Number].Record_.SpeedPercent := Percent;
  Devices[Number].Record_.Running := Ord(Percent > 0);
end;

function FindCoolingDevice(Context: Pointer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to DeviceTotal - 1 do
    if Devices[Index].Context = Context then
      Exit(Index);
  Result := -1;
end;

function CoolingDeviceContext(Number: Integer): Pointer;
begin
  if (Number < 0) or (Number >= DeviceTotal) then
    Exit(nil);
  Result := Devices[Number].Context;
end;

function CoolingDeviceCount: Integer;
begin
  Result := DeviceTotal;
end;

function GetCoolingDevice(Index: Integer; out Device: TAbiCoolingDevice): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := (Index >= 0) and (Index < DeviceTotal);
  if Result then
    Device := Devices[Index].Record_
  else
    ZeroMemory(@Device, SizeOf(Device));
  ReleaseSpinLock(Lock, PreviousLevel);
end;

end.
