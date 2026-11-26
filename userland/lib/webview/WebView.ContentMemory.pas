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
  How much memory pages may take: each content process has a commit
  limit of its own (--memory-limit, set by the process on itself: a
  quarter of the machine's RAM, between 256 MiB and 2 GiB), and all of
  them together are in one job (Sys.Jobs) limited to three fifths of
  it. A page that keeps allocating has its allocations fail - its
  process ends and the tab shows that it ran out of memory - and many
  heavy tabs together cannot take what the desktop, the browser's own
  window and the user's other programs need.
}
unit WebView.ContentMemory;

{$mode objfpc}
{$H+}

interface

const
  MinimumPageMemoryMegabytes = 256;
  MaximumPageMemoryMegabytes = 2048;

{ A content process's own limit for a machine with RamMegabytes. }
function PageMemoryLimitFor(RamMegabytes: QWord): LongWord;
{ All content processes' limit together, in bytes (at least one page's). }
function ContentJobLimitFor(RamMegabytes: QWord; PageLimitMegabytes: LongWord): QWord;
{ The machine's RAM (0 if it cannot be read). }
function MachineRamMegabytes: QWord;

{ Puts a newly started content process (a process handle) in the
  browser's content job, made at the first call; False if it could not
  be (the process then has only its own limit). }
function PutInContentJob(ProcessHandle: Int64; PageLimitMegabytes: LongWord): Boolean;
{ The job's committed memory and limit in bytes (0, 0 before there is
  one). }
procedure GetContentJobMemory(out CommittedBytes, LimitBytes: QWord);
{ True if process ProcessId ended with ExitCode because its memory ran
  out: its heap was refused (run time error 203: its own, the job's or
  the system's commit limit), or the kernel ended it for memory (137,
  and the kernel's last process ended for memory is this one). }
function EndedForMemory(ProcessId: QWord; ExitCode: LongInt): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.MemoryStatus,
  Sys.Jobs;

const
  Mebibyte = QWord(1024) * 1024;
  PageBytes = 4096;
  ExitStatusEndedForMemory = 137;
  ExitStatusHeapOverflow = 203;

var
  ContentJob: Int64 = -1;

function PageMemoryLimitFor(RamMegabytes: QWord): LongWord;
var
  Quarter: QWord;
begin
  Quarter := RamMegabytes div 4;
  if Quarter < MinimumPageMemoryMegabytes then
    Quarter := MinimumPageMemoryMegabytes;
  if Quarter > MaximumPageMemoryMegabytes then
    Quarter := MaximumPageMemoryMegabytes;
  Result := LongWord(Quarter);
end;

function ContentJobLimitFor(RamMegabytes: QWord; PageLimitMegabytes: LongWord): QWord;
var
  Megabytes: QWord;
begin
  Megabytes := RamMegabytes * 3 div 5;
  if Megabytes < PageLimitMegabytes then
    Megabytes := PageLimitMegabytes;
  Result := Megabytes * Mebibyte;
end;

function MachineRamMegabytes: QWord;
var
  Pressure: TMemoryPressure;
begin
  if GetMemoryPressure(Pressure) <> ErrorNone then
    Exit(0);
  Result := Pressure.TotalPages * PageBytes div Mebibyte;
end;

function EnsureContentJob(PageLimitMegabytes: LongWord): Boolean;
var
  Ram: QWord;
begin
  if ContentJob >= 0 then
    Exit(True);
  Ram := MachineRamMegabytes;
  if Ram = 0 then
    Exit(False);
  ContentJob := CreateJob;
  if ContentJob < 0 then
    Exit(False);
  SetJobCommitLimit(ContentJob, ContentJobLimitFor(Ram, PageLimitMegabytes));
  Result := True;
end;

function PutInContentJob(ProcessHandle: Int64; PageLimitMegabytes: LongWord): Boolean;
begin
  Result := EnsureContentJob(PageLimitMegabytes) and
    (AssignProcessToJob(ContentJob, ProcessHandle) = ErrorNone);
end;

procedure GetContentJobMemory(out CommittedBytes, LimitBytes: QWord);
var
  Information: TJobInformation;
begin
  CommittedBytes := 0;
  LimitBytes := 0;
  if (ContentJob < 0) or (GetJobInformation(ContentJob, Information) <> ErrorNone) then
    Exit;
  CommittedBytes := Information.CommitChargePages * PageBytes;
  LimitBytes := Information.CommitLimitPages * PageBytes;
end;

function EndedForMemory(ProcessId: QWord; ExitCode: LongInt): Boolean;
var
  Pressure: TMemoryPressure;
begin
  if ExitCode = ExitStatusHeapOverflow then
    Exit(True);
  Result := (ExitCode = ExitStatusEndedForMemory) and (GetMemoryPressure(Pressure) = ErrorNone) and
    (Pressure.LastEndedProcessId = ProcessId);
end;

end.
