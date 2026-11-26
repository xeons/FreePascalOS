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
  Jobs (CallCreateJob and friends): processes whose memory is charged
  together against one limit - what a browser puts its content
  processes in, so all its pages together cannot take the machine.
}
unit Sys.Jobs;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

type
  TJobInformation = TAbiJobInformation;

{ A new job's handle, or a negative error. }
function CreateJob: Int64;
{ Puts the process behind ProcessHandle (CurrentProcessHandle: this one)
  in the job; 0 or an error. }
function AssignProcessToJob(Job, ProcessHandle: Int64): LongInt;
{ Limits what the job's processes may commit together to Bytes (0: no
  limit); 0 or an error. }
function SetJobCommitLimit(Job: Int64; Bytes: QWord): LongInt;
function GetJobInformation(Job: Int64; out Information: TJobInformation): LongInt;

implementation

uses
  Sys.Errors;

const
  PageBytes = 4096;

function CreateJob: Int64;
begin
  Result := SystemCall(CallCreateJob, 0, 0, 0, 0, 0, 0);
end;

function AssignProcessToJob(Job, ProcessHandle: Int64): LongInt;
begin
  Result := ErrorCodeOf(SystemCall(CallAssignProcessToJob, QWord(Job), QWord(ProcessHandle), 0, 0, 0, 0));
end;

function SetJobCommitLimit(Job: Int64; Bytes: QWord): LongInt;
var
  Pages: QWord;
  CallResult: Int64;
begin
  Pages := (Bytes + PageBytes - 1) div PageBytes;
  CallResult := SystemCall(CallSetJobLimit, QWord(Job), JobLimitCommit, Pages, 0, 0, 0);
  if CallResult < 0 then
    Result := ErrorCodeOf(CallResult)
  else
    Result := ErrorNone;
end;

function GetJobInformation(Job: Int64; out Information: TJobInformation): LongInt;
begin
  FillChar(Information, SizeOf(Information), 0);
  Result := ErrorCodeOf(SystemCall(CallGetJobInformation, QWord(Job), QWord(@Information), 0, 0, 0, 0));
end;

end.
