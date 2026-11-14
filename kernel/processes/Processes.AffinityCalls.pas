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
