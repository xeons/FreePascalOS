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
  System calls for processor affinity (CallGetAffinity, CallSetAffinity).

  A process's affinity mask (in its credentials, so children inherit it)
  says which processors its threads may run on; setting it moves every
  thread of the process (Kernel.Scheduler.SetThreadAffinity).
}
unit Processes.AffinityCalls;

{$mode objfpc}

interface

{ The mask of ProcessId (0: the caller), limited to the processors that
  run; never negative, since there are at most 32 processors. }
function PerformGetAffinity(ProcessId: QWord): Int64;
function PerformSetAffinity(ProcessId: QWord; Mask: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Mutex,
  Kernel.Processors,
  Processes.Process,
  Processes.Thread,
  Processes.Security,
  Processes.SecurityCalls,
  Objects.Manager;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function RunningProcessorMask: QWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Result or (QWord(1) shl Index);
end;

function PerformGetAffinity(ProcessId: QWord): Int64;
var
  Target: PProcess;
begin
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNoSuchProcess));
  Result := Int64(Target^.Credentials.AffinityMask and RunningProcessorMask);
  DereferenceObject(Target);
end;

function PerformSetAffinity(ProcessId: QWord; Mask: QWord): Int64;
var
  Target: PProcess;
begin
  if (Mask and RunningProcessorMask) = 0 then
    Exit(Failure(ErrorInvalidArgument));
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNoSuchProcess));
  if not MayControlProcess(CurrentProcess, Target) then
  begin
    DereferenceObject(Target);
    Exit(Failure(ErrorNotPermitted));
  end;
  AcquireMutex(Target^.Lock);
  Target^.Credentials.AffinityMask := Mask;
  ReleaseMutex(Target^.Lock);
  SetProcessThreadAffinity(Target, Mask);
  DereferenceObject(Target);
  Result := 0;
end;

end.
