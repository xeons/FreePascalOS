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
  Threads for the video decoders: a pool of worker threads that run
  jobs (a routine and its argument) and a way for the caller to wait
  until all of them are done, and progress counters by which a job waits
  for another to get far enough (rows of macroblocks that need the row
  above, frames that need their references).

  A job that raises an exception has its message reported by WaitAll
  (as EVideoWorkerError); progress counters can be aborted so that jobs
  waiting on a failed one stop too.
}
unit Video.WorkerPool;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TVideoJobRoutine = procedure(Argument: Pointer);

  EVideoWorkerError = class(Exception);

  TVideoWorkerPool = class;

  TVideoWorker = class(TThread)
  private
    FPool: TVideoWorkerPool;
  protected
    procedure Execute; override;
  public
    constructor Create(Pool: TVideoWorkerPool);
  end;

  TVideoJob = record
    Routine: TVideoJobRoutine;
    Argument: Pointer;
  end;

  TVideoWorkerPool = class
  private
    FLock: TRTLCriticalSection;
    FWorkAvailable: PRTLEvent;
    FAllDone: PRTLEvent;
    FJobs: array of TVideoJob;
    FFirstJob: LongInt;
    FJobCount: LongInt;
    FPending: LongInt;
    FStopping: Boolean;
    FFailure: string;
    FWorkers: array of TVideoWorker;
    function TakeJob(out Job: TVideoJob): Boolean;
    procedure JobFinished(const Failure: string);
  public
    constructor Create(ThreadCount: LongInt);
    destructor Destroy; override;
    { Queues a job; it may start at once. }
    procedure Add(Routine: TVideoJobRoutine; Argument: Pointer);
    { Waits until every job added so far has finished; raises
      EVideoWorkerError when one of them raised an exception. }
    procedure WaitAll;
    function ThreadCount: LongInt;
  end;

  EVideoProgressAborted = class(Exception);

  { Counters that only go up, one per item (a row, a frame): one job
    publishes how far it got, others wait for a value. }
  TVideoProgress = class
  private
    FValues: array of LongInt;
    FAborted: Boolean;
  public
    constructor Create(Count: LongInt);
    procedure Publish(Index, Value: LongInt);
    { Returns once item Index reached Value; raises
      EVideoProgressAborted when the progress was aborted. }
    procedure WaitFor(Index, Value: LongInt);
    procedure Abort;
    function Value(Index: LongInt): LongInt;
  end;

{ The threads a decoder uses by default: one per processor, at most 8. }
function DefaultVideoThreadCount: LongInt;

implementation

function DefaultVideoThreadCount: LongInt;
begin
  Result := TThread.ProcessorCount;
  if Result < 1 then
    Result := 1;
  if Result > 8 then
    Result := 8;
end;

constructor TVideoWorker.Create(Pool: TVideoWorkerPool);
begin
  FPool := Pool;
  inherited Create(False);
end;

procedure TVideoWorker.Execute;
var
  Job: TVideoJob;
  Failure: string;
begin
  while FPool.TakeJob(Job) do
  begin
    Failure := '';
    try
      Job.Routine(Job.Argument);
    except
      on E: Exception do
        Failure := E.ClassName + ': ' + E.Message;
    end;
    FPool.JobFinished(Failure);
  end;
end;

constructor TVideoWorkerPool.Create(ThreadCount: LongInt);
var
  Index: LongInt;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FWorkAvailable := RTLEventCreate;
  FAllDone := RTLEventCreate;
  if ThreadCount < 1 then
    ThreadCount := 1;
  SetLength(FWorkers, ThreadCount);
  for Index := 0 to ThreadCount - 1 do
    FWorkers[Index] := TVideoWorker.Create(Self);
end;

destructor TVideoWorkerPool.Destroy;
var
  Index: LongInt;
begin
  EnterCriticalSection(FLock);
  FStopping := True;
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWorkAvailable);
  for Index := 0 to High(FWorkers) do
  begin
    FWorkers[Index].WaitFor;
    FWorkers[Index].Free;
  end;
  RTLEventDestroy(FWorkAvailable);
  RTLEventDestroy(FAllDone);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TVideoWorkerPool.TakeJob(out Job: TVideoJob): Boolean;
begin
  while True do
  begin
    EnterCriticalSection(FLock);
    if FStopping then
    begin
      LeaveCriticalSection(FLock);
      { Wake the next worker so that it stops too. }
      RTLEventSetEvent(FWorkAvailable);
      Exit(False);
    end;
    if FJobCount > 0 then
    begin
      Job := FJobs[FFirstJob];
      Inc(FFirstJob);
      Dec(FJobCount);
      if FJobCount > 0 then
        RTLEventSetEvent(FWorkAvailable);
      LeaveCriticalSection(FLock);
      Exit(True);
    end;
    LeaveCriticalSection(FLock);
    RTLEventWaitFor(FWorkAvailable);
  end;
end;

procedure TVideoWorkerPool.JobFinished(const Failure: string);
begin
  EnterCriticalSection(FLock);
  if (Failure <> '') and (FFailure = '') then
    FFailure := Failure;
  Dec(FPending);
  if FPending = 0 then
    RTLEventSetEvent(FAllDone);
  LeaveCriticalSection(FLock);
end;

procedure TVideoWorkerPool.Add(Routine: TVideoJobRoutine; Argument: Pointer);
begin
  EnterCriticalSection(FLock);
  if FJobCount = 0 then
    FFirstJob := 0;
  if FFirstJob + FJobCount >= Length(FJobs) then
  begin
    if FFirstJob > 0 then
    begin
      Move(FJobs[FFirstJob], FJobs[0], FJobCount * SizeOf(TVideoJob));
      FFirstJob := 0;
    end;
    if FJobCount >= Length(FJobs) then
      SetLength(FJobs, 2 * FJobCount + 16);
  end;
  FJobs[FFirstJob + FJobCount].Routine := Routine;
  FJobs[FFirstJob + FJobCount].Argument := Argument;
  Inc(FJobCount);
  Inc(FPending);
  LeaveCriticalSection(FLock);
  RTLEventSetEvent(FWorkAvailable);
end;

procedure TVideoWorkerPool.WaitAll;
var
  Done: Boolean;
  Failure: string;
begin
  while True do
  begin
    EnterCriticalSection(FLock);
    Done := FPending = 0;
    Failure := FFailure;
    if Done then
      FFailure := '';
    LeaveCriticalSection(FLock);
    if Done then
      Break;
    RTLEventWaitFor(FAllDone);
  end;
  if Failure <> '' then
    raise EVideoWorkerError.Create(Failure);
end;

function TVideoWorkerPool.ThreadCount: LongInt;
begin
  Result := Length(FWorkers);
end;

constructor TVideoProgress.Create(Count: LongInt);
begin
  inherited Create;
  SetLength(FValues, Count);
end;

procedure TVideoProgress.Publish(Index, Value: LongInt);
begin
  WriteBarrier;
  FValues[Index] := Value;
end;

procedure TVideoProgress.WaitFor(Index, Value: LongInt);
var
  Spins: LongInt;
begin
  Spins := 0;
  while FValues[Index] < Value do
  begin
    if FAborted then
      raise EVideoProgressAborted.Create('aborted');
    Inc(Spins);
    if Spins > 64 then
      ThreadSwitch;
    ReadBarrier;
  end;
  ReadBarrier;
end;

procedure TVideoProgress.Abort;
begin
  FAborted := True;
  WriteBarrier;
end;

function TVideoProgress.Value(Index: LongInt): LongInt;
begin
  Result := FValues[Index];
  ReadBarrier;
end;

end.
