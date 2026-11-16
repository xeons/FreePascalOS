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
  they are gone: each look at the processes (Notice) says "ended PID"
  for those no longer there, and the Programs tab asks whether a
  program it asked to end still runs after a while (IsStillRunning).
}
unit TaskManager.EndWatch;

{$mode objfpc}
{$H+}

interface

uses
  TaskManager.Sampler;

procedure WatchForEnd(ProcessId: QWord);
{ After a look: says "ended PID" for every watched process gone, and
  stops watching it. }
procedure NoticeEndedProcesses(Sampler: TUsageSampler);
{ Whether ProcessId is among the processes of the newest look. }
function IsStillRunning(Sampler: TUsageSampler; ProcessId: QWord): Boolean;

implementation

uses
  SysUtils,
  TaskManager.Output;

const
  MaximumWatched = 64;

var
  Watched: array[0..MaximumWatched - 1] of QWord;
  WatchedCount: LongInt;

procedure WatchForEnd(ProcessId: QWord);
var
  Index: LongInt;
begin
  for Index := 0 to WatchedCount - 1 do
    if Watched[Index] = ProcessId then
      Exit;
  if WatchedCount < MaximumWatched then
  begin
    Watched[WatchedCount] := ProcessId;
    Inc(WatchedCount);
  end;
end;

function IsStillRunning(Sampler: TUsageSampler; ProcessId: QWord): Boolean;
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
  Index := WatchedCount - 1;
  while Index >= 0 do
  begin
    if not IsStillRunning(Sampler, Watched[Index]) then
    begin
      Say('ended ' + IntToStr(Watched[Index]));
      Watched[Index] := Watched[WatchedCount - 1];
      Dec(WatchedCount);
    end;
    Dec(Index);
  end;
end;

end.
