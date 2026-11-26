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
  The decoder's threads: a pool of workers that run the indices of a job
  (the tiles of a tile group, the rows of a post filter) between them,
  the calling thread included, and return when all are done. Each call
  of the job knows which worker runs it, so per-worker state (a tile
  context, filter scratch) needs no locking.
}
unit Av1.WorkerPool;

{$mode objfpc}
{$H+}

interface

uses
  Classes, SysUtils, Av1.Common;

type
  { Runs index Index of a job on worker Worker (0 = the calling thread). }
  TParallelJob = procedure(Index, Worker: Integer) of object;

  TWorkerPool = class;

  TPoolThread = class(TThread)
  private
    FPool: TWorkerPool;
    FWorker: Integer;
    FStart: PRTLEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(Pool: TWorkerPool; Worker: Integer);
    destructor Destroy; override;
  end;

  TWorkerPool = class
  private
    FThreads: array of TPoolThread;
    FJob: TParallelJob;
    FCount: LongInt;
    FNext: LongInt;
    FPending: LongInt;
    FDone: PRTLEvent;
    FLock: TRTLCriticalSection;
    FFailure: string;
    FStopping: Boolean;
    procedure WorkLoop(Worker: Integer);
  public
    { A pool of Workers workers: the caller and Workers - 1 threads. }
    constructor Create(Workers: Integer);
    destructor Destroy; override;
    { Job( 0 .. Count - 1 ) on the workers; raises EAv1Error with the first
      failure's message if any index failed. }
    procedure Run(Count: Integer; Job: TParallelJob);
    function WorkerCount: Integer;
  end;

implementation

constructor TPoolThread.Create(Pool: TWorkerPool; Worker: Integer);
begin
  FPool := Pool;
  FWorker := Worker;
  FStart := RTLEventCreate;
  inherited Create(False);
end;

destructor TPoolThread.Destroy;
begin
  RTLEventDestroy(FStart);
  inherited Destroy;
end;

procedure TPoolThread.Execute;
begin
  while True do
  begin
    RTLEventWaitFor(FStart);
    if FPool.FStopping then
      Break;
    FPool.WorkLoop(FWorker);
    if InterLockedDecrement(FPool.FPending) = 0 then
      RTLEventSetEvent(FPool.FDone);
  end;
end;

constructor TWorkerPool.Create(Workers: Integer);
var
  Index: Integer;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FDone := RTLEventCreate;
  SetLength(FThreads, Max(0, Workers - 1));
  for Index := 0 to High(FThreads) do
    FThreads[Index] := TPoolThread.Create(Self, Index + 1);
end;

destructor TWorkerPool.Destroy;
var
  Index: Integer;
begin
  FStopping := True;
  for Index := 0 to High(FThreads) do
    RTLEventSetEvent(FThreads[Index].FStart);
  for Index := 0 to High(FThreads) do
  begin
    FThreads[Index].WaitFor;
    FThreads[Index].Free;
  end;
  RTLEventDestroy(FDone);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TWorkerPool.WorkerCount: Integer;
begin
  Result := Length(FThreads) + 1;
end;

procedure TWorkerPool.WorkLoop(Worker: Integer);
var
  Index: LongInt;
begin
  while True do
  begin
    Index := InterLockedIncrement(FNext) - 1;
    if Index >= FCount then
      Break;
    try
      FJob(Index, Worker);
    except
      on Error: Exception do
      begin
        EnterCriticalSection(FLock);
        if FFailure = '' then
          FFailure := Error.Message;
        LeaveCriticalSection(FLock);
      end;
    end;
  end;
end;

procedure TWorkerPool.Run(Count: Integer; Job: TParallelJob);
var
  Index, Helpers: Integer;
  Failure: string;
begin
  if Count <= 0 then
    Exit;
  FJob := Job;
  FCount := Count;
  FNext := 0;
  FFailure := '';
  Helpers := Min(Length(FThreads), Count - 1);
  FPending := Helpers;
  for Index := 0 to Helpers - 1 do
    RTLEventSetEvent(FThreads[Index].FStart);
  WorkLoop(0);
  if Helpers > 0 then
    RTLEventWaitFor(FDone);
  Failure := FFailure;
  if Failure <> '' then
    raise EAv1Error.Create(Failure);
end;

end.
