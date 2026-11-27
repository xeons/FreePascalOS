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
  How far a file operation has got, shared between the thread doing it
  and the window showing it.

  The worker thread sets the totals once it has counted what there is
  to do, then adds what it has done and names the file it is on; the
  window takes a snapshot whenever it looks (a few times a second). A
  lock guards the lot, held only for a moment. Cancel is a flag the
  window sets and the worker looks at between pieces of work.
}
unit FileManager.OperationProgress;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Locks;

type
  TProgressPhase = (PhaseCounting, PhaseWorking);

  TProgressSnapshot = record
    Phase: TProgressPhase;
    TotalFiles: QWord;
    TotalBytes: QWord;
    DoneFiles: QWord;
    DoneBytes: QWord;
    CurrentName: string;
  end;

  TOperationProgress = class
  private
    FLock: TLock;
    FState: TProgressSnapshot;
    FCancelled: LongInt;
    FPaused: LongInt;
  public
    procedure SetTotals(Files, Bytes: QWord);
    procedure AddDone(Files, Bytes: QWord);
    procedure SetCurrentName(const Name: string);
    function Snapshot: TProgressSnapshot;
    procedure Cancel;
    function IsCancelled: Boolean;
    { Paused: the worker waits at its next piece until resumed. }
    procedure SetPaused(Value: Boolean);
    function IsPaused: Boolean;
  end;

implementation

procedure TOperationProgress.SetTotals(Files, Bytes: QWord);
begin
  AcquireLock(FLock);
  FState.TotalFiles := Files;
  FState.TotalBytes := Bytes;
  FState.Phase := PhaseWorking;
  ReleaseLock(FLock);
end;

procedure TOperationProgress.AddDone(Files, Bytes: QWord);
begin
  AcquireLock(FLock);
  FState.DoneFiles := FState.DoneFiles + Files;
  FState.DoneBytes := FState.DoneBytes + Bytes;
  ReleaseLock(FLock);
end;

procedure TOperationProgress.SetCurrentName(const Name: string);
begin
  AcquireLock(FLock);
  FState.CurrentName := Name;
  ReleaseLock(FLock);
end;

function TOperationProgress.Snapshot: TProgressSnapshot;
begin
  AcquireLock(FLock);
  Result := FState;
  { A copy of its own: the worker may replace the name the moment the
    lock is let go. }
  UniqueString(Result.CurrentName);
  ReleaseLock(FLock);
end;

procedure TOperationProgress.Cancel;
begin
  AtomicExchange32(FCancelled, 1);
end;

function TOperationProgress.IsCancelled: Boolean;
begin
  Result := AtomicCompareExchange32(FCancelled, 0, 0) <> 0;
end;

procedure TOperationProgress.SetPaused(Value: Boolean);
begin
  if Value then
    AtomicExchange32(FPaused, 1)
  else
    AtomicExchange32(FPaused, 0);
end;

function TOperationProgress.IsPaused: Boolean;
begin
  Result := AtomicCompareExchange32(FPaused, 0, 0) <> 0;
end;

end.
