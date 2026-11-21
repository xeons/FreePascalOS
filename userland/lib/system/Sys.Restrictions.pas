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
  A sandbox a program puts itself in (CallSetProcessLimit with
  ProcessLimitRestrictions): Restrict* flags, only ever added, inherited
  by what it starts (see Processes.Restrictions in the kernel). And the
  most memory it may commit (ProcessLimitCommit), which it may lower but
  never raise again.
}
unit Sys.Restrictions;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

{ Adds Flags (Restrict*) to this process's restrictions; 0 or an error. }
function RestrictThisProcess(Flags: LongWord): LongInt;
{ The restrictions this process has now (or -1 on an error). }
function ThisProcessRestrictions: Int64;
{ Lowers the memory this process may commit to Bytes; 0 or an error. }
function LimitCommittedMemory(Bytes: QWord): LongInt;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function RestrictThisProcess(Flags: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelSetProcessLimit(ProcessLimitRestrictions, Flags));
end;

function ThisProcessRestrictions: Int64;
begin
  { Adding nothing returns the flags as they are. }
  Result := KernelSetProcessLimit(ProcessLimitRestrictions, 0);
  if Result < 0 then
    Result := -1;
end;

function LimitCommittedMemory(Bytes: QWord): LongInt;
var
  Pages: QWord;
begin
  Pages := (Bytes + 4095) div 4096;
  if Pages = 0 then
    Pages := 1;
  Result := ErrorCodeOf(KernelSetProcessLimit(ProcessLimitCommit, Pages));
end;

end.
