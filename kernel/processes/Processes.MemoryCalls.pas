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
  System calls of the virtual memory group (160-167): reserving,
  committing, decommitting, protecting and describing the caller's
  memory, and its policy on executable memory. The work is
  Processes.VirtualMemory's; the address space has a lock of its own, so
  these do not take the process's.
}
unit Processes.MemoryCalls;

{$mode objfpc}

interface

function PerformReserveMemory(Length, Flags: QWord): Int64;
function PerformCommitMemory(Address, Length, Protection: QWord): Int64;
function PerformDecommitMemory(Address, Length: QWord): Int64;
function PerformProtectMemory(Address, Length, Protection: QWord): Int64;
function PerformQueryMemory(Address, InformationAddress: QWord): Int64;
function PerformSetMemoryPolicy(Flags: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Processes.Process,
  Processes.Thread,
  Processes.AddressSpace,
  Processes.VirtualMemory,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerSpace: PAddressSpace;
begin
  Result := CurrentProcess^.AddressSpace;
end;

function PerformReserveMemory(Length, Flags: QWord): Int64;
var
  Start: QWord;
  Error: LongInt;
begin
  if Flags <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Error := ReserveAddressRange(CallerSpace, Length, Start);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Start);
end;

function PerformCommitMemory(Address, Length, Protection: QWord): Int64;
begin
  if Protection > High(LongWord) then
    Exit(Failure(ErrorInvalidArgument));
  Result := Failure(CommitAddressRange(CallerSpace, Address, Length, LongWord(Protection)));
end;

function PerformDecommitMemory(Address, Length: QWord): Int64;
begin
  Result := Failure(DecommitAddressRange(CallerSpace, Address, Length));
end;

function PerformProtectMemory(Address, Length, Protection: QWord): Int64;
var
  Previous: LongWord;
  Error: LongInt;
begin
  if Protection > High(LongWord) then
    Exit(Failure(ErrorInvalidArgument));
  Error := ProtectAddressRange(CallerSpace, Address, Length, LongWord(Protection), Previous);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Previous);
end;

function PerformQueryMemory(Address, InformationAddress: QWord): Int64;
var
  Information: TAbiMemoryInformation;
begin
  QueryAddress(CallerSpace, Address, Information);
  Result := Failure(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

function PerformSetMemoryPolicy(Flags: QWord): Int64;
var
  Space: PAddressSpace;
begin
  if (Flags and not QWord(MemoryPolicyAllowDynamicCode)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Space := CallerSpace;
  Result := 0;
  if Space^.AllowsDynamicCode then
    Result := MemoryPolicyAllowDynamicCode;
  Space^.AllowsDynamicCode := (Flags and MemoryPolicyAllowDynamicCode) <> 0;
end;

end.
