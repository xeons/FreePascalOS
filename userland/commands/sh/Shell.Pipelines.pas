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
  Pipelines (a single command is a pipeline of one).

  A pipeline is started in two passes so that no stage waits for one
  that has not started yet: first every external program, then the
  stages that run inside the shell, from left to right. Then the shell
  waits for the external programs. The status of a pipeline is the
  status of its last stage.

  An interactive shell runs every pipeline in a process group of its own;
  a foreground pipeline's group becomes the console's foreground group
  while the shell waits, so Ctrl-C ends exactly that pipeline, and Ctrl-Z
  stops it: it then becomes a stopped job (Shell.Jobs) for fg and bg. A
  pipeline ending in '&' becomes a running job. When a foreground
  program ends by Ctrl-C (status 130), the rest of the command line is
  abandoned.
}
unit Shell.Pipelines;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Nodes;

{ Runs Commands connected by pipes. Wait False: the pipeline becomes a
  background job. }
function ExecutePipeline(const Commands: array of TShellNode; Negate, Wait: Boolean): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Files,
  Sys.Processes,
  Sys.Streams,
  Shell.Output,
  Shell.Variables,
  Shell.Commands,
  Shell.Redirections,
  Shell.Jobs,
  Shell.Execution;

const
  StatusInterrupted = 130;

type
  TPreparedArray = array of TPreparedCommand;
  TStatusArray = array of LongInt;

{ The command line of a pipeline as jobs shows it, rebuilt from the
  expanded words. }
function DescribePipeline(const Prepared: TPreparedArray): string;
var
  Stage: Integer;
  Index: Integer;
begin
  Result := '';
  for Stage := 0 to High(Prepared) do
  begin
    if Stage > 0 then
      Result := Result + ' | ';
    { Compound commands have no words of their own. }
    if Prepared[Stage].Node = nil then
      Result := Result + '(...)';
    for Index := 0 to Prepared[Stage].Fields.Count - 1 do
    begin
      if Index > 0 then
        Result := Result + ' ';
      Result := Result + Prepared[Stage].Fields[Index];
    end;
  end;
end;

procedure AddHandle(var Handles: THandleArray; Handle: Int64);
var
  Count: Integer;
begin
  Count := Length(Handles);
  SetLength(Handles, Count + 1);
  Handles[Count] := Handle;
end;

{ A background pipeline becomes a job; its programs run on. }
procedure StartBackgroundJob(const Prepared: TPreparedArray; const Processes: THandleArray; GroupId: Int64);
var
  Handles: THandleArray;
  Index: Integer;
  Job: TJob;
begin
  Handles := nil;
  for Index := 0 to High(Processes) do
    if Processes[Index] >= 0 then
      AddHandle(Handles, Processes[Index]);
  if Length(Handles) = 0 then
    Exit;
  LastBackgroundProcessId := ProcessIdOf(Handles[High(Handles)]);
  if GroupId < 0 then
    GroupId := 0;
  Job := AddJob(Handles, GroupId, DescribePipeline(Prepared), JobRunning);
  if ShellIsInteractive and (Job <> nil) then
  begin
    WriteStringLine(StandardError, Format('[%d] %d', [Job.Number, LastBackgroundProcessId]));
    FlushStream(StandardError);
  end;
end;

{ Waits for one program of an interactive shell's pipeline; True if it
  stopped instead of ending. }
function WaitForInteractiveProgram(Process: Int64; out Status: LongInt): Boolean;
var
  Stopped: Boolean;
  ExitCode: LongInt;
begin
  if WaitForProgramChange(Process, InfiniteWait, Stopped, ExitCode) <> ErrorNone then
  begin
    Stopped := False;
    ExitCode := 1;
  end;
  Result := Stopped;
  if Stopped then
    Status := StatusStopped
  else
  begin
    CloseFile(Process);
    Status := ExitCode;
  end;
end;

{ Waits for the external programs of a foreground pipeline. In an
  interactive shell a stopped program (Ctrl-Z) turns the rest of the
  pipeline into a stopped job and abandons the rest of the command line;
  then the result is True. }
function WaitForPipeline(const Prepared: TPreparedArray; const Processes: THandleArray;
  var Statuses: TStatusArray; GroupId: Int64): Boolean;
var
  StoppedHandles: THandleArray;
  Index: Integer;
  Job: TJob;
begin
  StoppedHandles := nil;
  for Index := 0 to High(Processes) do
  begin
    if Processes[Index] < 0 then
      Continue;
    if Length(StoppedHandles) > 0 then
    begin
      { A later stage of a stopped pipeline belongs to the job too. }
      AddHandle(StoppedHandles, Processes[Index]);
      Statuses[Index] := StatusStopped;
      Continue;
    end;
    if ShellIsInteractive then
    begin
      if WaitForInteractiveProgram(Processes[Index], Statuses[Index]) then
      begin
        AddHandle(StoppedHandles, Processes[Index]);
        Continue;
      end;
    end
    else
      Statuses[Index] := WaitForProgram(Processes[Index]);
    if ShellIsInteractive and (Statuses[Index] = StatusInterrupted) then
      InterruptRequested := True;
    if Prepared[Index].ExitAfterwards then
    begin
      ExitRequested := True;
      RequestedExitCode := Statuses[Index];
    end;
  end;

  Result := Length(StoppedHandles) > 0;
  if not Result then
    Exit;
  if GroupId < 0 then
    GroupId := 0;
  Job := AddJob(StoppedHandles, GroupId, DescribePipeline(Prepared), JobStopped);
  if Job <> nil then
  begin
    PrintJob(StandardError, Job, False);
    FlushStream(StandardError);
  end;
  { Like Ctrl-C, Ctrl-Z abandons the rest of the command line (a loop
    would otherwise start the next program at once). }
  InterruptRequested := True;
end;

{ The process group the pipeline's programs are started in. }
function PipelineGroupFor(Wait: Boolean): Int64;
begin
  Result := GroupInherit;
  if ShellIsInteractive and Wait and IsConsole(StandardInputHandle) then
    Result := GroupNewInForeground
  else if ShellIsInteractive then
    Result := GroupNew;
end;

function ExecutePipeline(const Commands: array of TShellNode; Negate, Wait: Boolean): LongInt;
var
  Count: Integer;
  Prepared: TPreparedArray;
  Processes: THandleArray;
  Statuses: TStatusArray;
  Inputs: THandleArray;
  Outputs: THandleArray;
  IsInShell: array of Boolean;
  Index: Integer;
  ReadHandle: Int64;
  WriteHandle: Int64;
  Handles: TStandardHandles;
  Saved: TStandardHandles;
  PipelineGroup: Int64;
  OwnsConsole: Boolean;
  PipelineStopped: Boolean;
begin
  Count := Length(Commands);
  Prepared := nil;
  Processes := nil;
  Statuses := nil;
  Inputs := nil;
  Outputs := nil;
  IsInShell := nil;
  SetLength(Prepared, Count);
  SetLength(Processes, Count);
  SetLength(Statuses, Count);
  SetLength(Inputs, Count);
  SetLength(Outputs, Count);
  SetLength(IsInShell, Count);
  try
    { Connect the stages. }
    Inputs[0] := StandardInputHandle;
    Outputs[Count - 1] := StandardOutputHandle;
    for Index := 0 to Count - 2 do
    begin
      if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
      begin
        ShellError('cannot create a pipe');
        ReadHandle := StandardInputHandle;
        WriteHandle := StandardOutputHandle;
      end;
      Outputs[Index] := WriteHandle;
      Inputs[Index + 1] := ReadHandle;
    end;

    { Expand every simple command; anything else runs in the shell. }
    for Index := 0 to Count - 1 do
    begin
      Processes[Index] := -1;
      if Commands[Index].Kind = NodeSimple then
      begin
        Prepared[Index] := PrepareCommand(TSimpleCommandNode(Commands[Index]));
        IsInShell[Index] := Prepared[Index].RunsInShell;
      end
      else
      begin
        Prepared[Index] := TPreparedCommand.Create(nil);
        IsInShell[Index] := True;
      end;
    end;

    { Pass 1: external programs. In an interactive shell they form a new
      process group, led by the first; a foreground pipeline's group is
      the terminal's foreground group from the start, so its programs
      can read the terminal at once. }
    PipelineGroup := PipelineGroupFor(Wait);
    for Index := 0 to Count - 1 do
    begin
      if IsInShell[Index] then
        Continue;
      Handles[0] := Inputs[Index];
      Handles[1] := Outputs[Index];
      Handles[2] := StandardErrorHandle;
      Processes[Index] := StartExternal(Prepared[Index], Handles, PipelineGroup, Statuses[Index]);
      if (PipelineGroup < 0) and (Processes[Index] >= 0) then
        PipelineGroup := ProcessIdOf(Processes[Index]);
    end;
    { Ctrl-C now belongs to the pipeline. }
    OwnsConsole := Wait and ShellIsInteractive and (PipelineGroup > 0) and IsConsole(StandardInputHandle);
    if OwnsConsole then
      SetForegroundGroup(StandardInputHandle, PipelineGroup);
    { The shell keeps only the pipe ends that in-shell stages still need,
      so readers see the end of their input when the writers finish. }
    for Index := 0 to Count - 1 do
    begin
      if IsInShell[Index] then
        Continue;
      if Inputs[Index] <> StandardInputHandle then
        CloseFile(Inputs[Index]);
      if Outputs[Index] <> StandardOutputHandle then
        CloseFile(Outputs[Index]);
    end;

    { Pass 2: stages inside the shell, left to right. }
    for Index := 0 to Count - 1 do
    begin
      if not IsInShell[Index] then
        Continue;
      Handles[0] := Inputs[Index];
      Handles[1] := Outputs[Index];
      Handles[2] := StandardErrorHandle;
      if Commands[Index].Kind = NodeSimple then
        Statuses[Index] := RunInShell(Prepared[Index], Handles)
      else
      begin
        SwitchStandardHandles(Handles, Saved);
        Statuses[Index] := ExecuteNode(Commands[Index]);
        RestoreStandardHandles(Saved);
      end;
      if Inputs[Index] <> StandardInputHandle then
        CloseFile(Inputs[Index]);
      if Outputs[Index] <> StandardOutputHandle then
        CloseFile(Outputs[Index]);
    end;

    PipelineStopped := False;
    if Wait then
      PipelineStopped := WaitForPipeline(Prepared, Processes, Statuses, PipelineGroup)
    else
      StartBackgroundJob(Prepared, Processes, PipelineGroup);
    if OwnsConsole then
      SetForegroundGroup(StandardInputHandle, CurrentProcessGroup);

    Result := Statuses[Count - 1];
    if PipelineStopped then
      Result := StatusStopped;
    if Negate then
      Result := Ord(Result = 0);
    if Wait then
      RemoveTemporaryFiles;
  finally
    for Index := 0 to Count - 1 do
      Prepared[Index].Free;
  end;
end;

end.
