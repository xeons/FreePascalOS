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
  System calls for what wakes the machine (CallSetWakeAlarm,
  CallListWakeSources, CallSetWakeSource: Io.AcpiWake), its cooling
  devices (CallListCoolingDevices: Power.Cooling) and the processors'
  performance states (CallListPerformanceStates: Power.PerformanceStates).
  Reading is for anyone; changing what wakes the machine is root's.
  Nothing here runs AML.
}
unit Processes.PowerDeviceCalls;

{$mode objfpc}

interface

function PerformSetWakeAlarm(Seconds: QWord): Int64;
function PerformListWakeSources(BufferAddress, Capacity: QWord): Int64;
function PerformSetWakeSource(Index, Enabled: QWord): Int64;
function PerformListCoolingDevices(BufferAddress, Capacity: QWord): Int64;
function PerformListPerformanceStates(BufferAddress, Capacity: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Io.AcpiWake,
  Power.Cooling,
  Power.PerformanceStates,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerIsRoot: Boolean;
begin
  Result := CurrentProcess^.Credentials.EffectiveUserId = RootUserId;
end;

function PerformSetWakeAlarm(Seconds: QWord): Int64;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  Result := Failure(SetWakeAlarm(Seconds));
end;

function PerformListWakeSources(BufferAddress, Capacity: QWord): Int64;
var
  Index: Integer;
  Source: TAbiWakeSource;
  Error: LongInt;
begin
  Index := 0;
  while GetWakeSource(Index, Source) do
  begin
    if QWord(Index) < Capacity then
    begin
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(Source), @Source, SizeOf(Source));
      if Error <> 0 then
        Exit(Failure(Error));
    end;
    Inc(Index);
  end;
  Result := Index;
end;

function PerformSetWakeSource(Index, Enabled: QWord): Int64;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  if (Index > High(LongInt)) or not SetWakeSourceEnabled(Integer(Index), Enabled <> 0) then
    Exit(Failure(ErrorInvalidArgument));
  Result := 0;
end;

function PerformListCoolingDevices(BufferAddress, Capacity: QWord): Int64;
var
  Index: Integer;
  Device: TAbiCoolingDevice;
  Error: LongInt;
begin
  Index := 0;
  while GetCoolingDevice(Index, Device) do
  begin
    if QWord(Index) < Capacity then
    begin
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(Device), @Device, SizeOf(Device));
      if Error <> 0 then
        Exit(Failure(Error));
    end;
    Inc(Index);
  end;
  Result := Index;
end;

function PerformListPerformanceStates(BufferAddress, Capacity: QWord): Int64;
var
  Index: Integer;
  State: TAbiPerformanceState;
  Error: LongInt;
begin
  Index := 0;
  while GetPerformanceStateRecord(Index, State) do
  begin
    if QWord(Index) < Capacity then
    begin
      Error := CopyToUser(BufferAddress + QWord(Index) * SizeOf(State), @State, SizeOf(State));
      if Error <> 0 then
        Exit(Failure(Error));
    end;
    Inc(Index);
  end;
  Result := Index;
end;

end.
