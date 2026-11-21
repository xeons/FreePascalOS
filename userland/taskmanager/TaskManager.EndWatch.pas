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
  The processes the task manager asked to end, or ended, watched until
  they are gone: each look at the processes (NoticeEndedProcesses) says
  "ended PID" for those no longer there.

  A process that was only asked may never end: it took the request and
  then did nothing (it has stopped responding, or it refuses). Once its
  wait (EndAskWaitMilliseconds) is over and it still runs,
  TakeOverdueRequests hands it back - once - so the task manager can
  offer to end it outright. A process ended outright meanwhile is not
  handed back.
}
unit TaskManager.EndWatch;

{$mode objfpc}
{$H+}

interface

uses
  TaskManager.Sampler,
  TaskManager.Targets;

const
  { How long a process asked to end has before the task manager offers
    to end it outright. }
  EndAskWaitMilliseconds = 10000;

{ Watches Target, which was asked to end. }
procedure WatchAskedToEnd(const Target: TProcessTarget);
{ Watches ProcessId, which was ended outright. }
procedure WatchEndedOutright(ProcessId: QWord);
{ After a look: says "ended PID" for every watched process gone, and
  stops watching it. }
procedure NoticeEndedProcesses(Sampler: TUsageSampler);
{ The processes asked to end whose wait is over and that still run
  (not even being ended), each handed back only once. }
function TakeOverdueRequests: TProcessTargets;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.ProcessList,
  Sys.Time,
  TaskManager.Output;

type
  TWatchedProcess = record
    Target: TProcessTarget;
    { When it was asked (0: ended outright, nothing to offer). }
    AskedAt: QWord;
  end;

var
  Watched: array of TWatchedProcess;

function WatchedIndexOf(ProcessId: QWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Watched) do
    if Watched[Index].Target.ProcessId = ProcessId then
      Exit(Index);
  Result := -1;
end;

function WatchedEntry(ProcessId: QWord): LongInt;
begin
  Result := WatchedIndexOf(ProcessId);
  if Result >= 0 then
    Exit;
  Result := Length(Watched);
  SetLength(Watched, Result + 1);
  Watched[Result].Target := MakeTarget(ProcessId, '');
  Watched[Result].AskedAt := 0;
end;

procedure WatchAskedToEnd(const Target: TProcessTarget);
var
  Index: LongInt;
begin
  Index := WatchedEntry(Target.ProcessId);
  Watched[Index].Target := Target;
  Watched[Index].AskedAt := UptimeMilliseconds;
end;

procedure WatchEndedOutright(ProcessId: QWord);
var
  Index: LongInt;
begin
  Index := WatchedEntry(ProcessId);
  Watched[Index].AskedAt := 0;
end;

function IsInLook(Sampler: TUsageSampler; ProcessId: QWord): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to Sampler.ProcessCount - 1 do
    if Sampler.Processes[Index]^.ProcessId = ProcessId then
      Exit(True);
  Result := False;
end;

procedure NoticeEndedProcesses(Sampler: TUsageSampler);
var
  Index: LongInt;
begin
  Index := High(Watched);
  while Index >= 0 do
  begin
    if not IsInLook(Sampler, Watched[Index].Target.ProcessId) then
    begin
      Say('ended ' + IntToStr(Watched[Index].Target.ProcessId));
      Delete(Watched, Index, 1);
    end;
    Dec(Index);
  end;
end;

{ Still there and not being ended by the kernel already. }
function StillRuns(ProcessId: QWord): Boolean;
var
  Details: TProcessDetails;
begin
  Result := GetProcessDetails(ProcessId, Details) and (Details.State <> ProcessStateExiting);
end;

function TakeOverdueRequests: TProcessTargets;
var
  Index: LongInt;
  Now: QWord;
begin
  Result := nil;
  Now := UptimeMilliseconds;
  for Index := 0 to High(Watched) do
  begin
    if (Watched[Index].AskedAt = 0) or (Now - Watched[Index].AskedAt < EndAskWaitMilliseconds) then
      Continue;
    Watched[Index].AskedAt := 0;
    if StillRuns(Watched[Index].Target.ProcessId) then
      AddTarget(Result, Watched[Index].Target);
  end;
end;

end.
