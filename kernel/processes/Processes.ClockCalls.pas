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
  System calls for the clock and the time zone (CallSetWallClock,
  CallGetTimeZone, CallSetTimeZone).

  The wall clock is the kernel's (Kernel.Clock); setting it writes the
  battery backed clock too, so the time survives a restart. The time
  zone is only a name here: the kernel never shows local times, and the
  zones' rules (offsets, daylight saving) are libsystem's
  (Sys.TimeZones), which every program reads the name for. Keeping it
  in the kernel, as other systems keep their time zone with the clock,
  lets every program find it with one call and no file to parse, and a
  change reaches every program at once. Both changes are root's: the
  system settings service makes them for users who may.
}
unit Processes.ClockCalls;

{$mode objfpc}

interface

function PerformSetWallClock(Time: Int64): Int64;
function PerformGetTimeZone(BufferAddress, Capacity: QWord): Int64;
function PerformSetTimeZone(NameAddress: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Clock,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess;

const
  { 2000-01-01 and 2099-12-31: what the battery backed clock can hold. }
  EarliestSettableTime = 946684800;
  LatestSettableTime = 4102444799;

var
  { A zeroed spin lock is free. }
  ZoneLock: TSpinLock;
  ZoneName: array[0..TimeZoneNameCapacity - 1] of Char = 'UTC';

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerIsRoot: Boolean;
begin
  Result := CurrentProcess^.Credentials.EffectiveUserId = RootUserId;
end;

function PerformSetWallClock(Time: Int64): Int64;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  if (Time < EarliestSettableTime) or (Time > LatestSettableTime) then
    Exit(Failure(ErrorInvalidArgument));
  SetWallClockTime(Time);
  Result := 0;
end;

function PerformGetTimeZone(BufferAddress, Capacity: QWord): Int64;
var
  Copy: array[0..TimeZoneNameCapacity - 1] of Char;
  PreviousLevel: TPriorityLevel;
  Length: QWord;
begin
  PreviousLevel := AcquireSpinLock(ZoneLock);
  CopyText(@Copy[0], @ZoneName[0], TimeZoneNameCapacity);
  ReleaseSpinLock(ZoneLock, PreviousLevel);
  Length := TextLength(@Copy[0]);
  if Capacity < Length + 1 then
    Exit(Failure(ErrorNameTooLong));
  Result := -Int64(CopyToUser(BufferAddress, @Copy[0], Length + 1));
  if Result = 0 then
    Result := Int64(Length);
end;

function PerformSetTimeZone(NameAddress: QWord): Int64;
var
  Name: array[0..TimeZoneNameCapacity - 1] of Char;
  PreviousLevel: TPriorityLevel;
  Error: LongInt;
begin
  if not CallerIsRoot then
    Exit(Failure(ErrorNotPermitted));
  Error := CopyStringFromUser(NameAddress, @Name[0], TimeZoneNameCapacity);
  if Error = ErrorNameTooLong then
    Exit(Failure(ErrorInvalidArgument));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if Name[0] = #0 then
    Exit(Failure(ErrorInvalidArgument));
  PreviousLevel := AcquireSpinLock(ZoneLock);
  CopyText(@ZoneName[0], @Name[0], TimeZoneNameCapacity);
  ReleaseSpinLock(ZoneLock, PreviousLevel);
  Result := 0;
end;

end.
