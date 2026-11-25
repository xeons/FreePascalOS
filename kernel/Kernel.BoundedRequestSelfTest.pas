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
  Self tests of bounded requests (Io.BoundedRequests) with a driver
  that loses requests: its device ("lossy", without a name) keeps every
  read, open and close it gets and never completes them by itself (nor
  can a cancel reach them: they wait in no request queue).

    * A thread waiting alertably for a read is alerted: it cancels the
      request, which stays lost, and gives it up after the grace
      (shortened for the test) with ErrorInterrupted.
    * A thread that must end (the test's own query says so) waiting
      for an open, which is not alertable, gives it up too, with
      ErrorTimedOut.
    * A thread that need not end waits on, until the driver completes
      its request late; then it gets the result as usual.
    * The driver completing the given up requests afterwards writes
      into the requests' own memory: the senders' buffers keep what
      they held, and the requests are freed.
}
unit Kernel.BoundedRequestSelfTest;

{$mode objfpc}

interface

procedure RunBoundedRequestSelfTests;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Clock,
  Objects.Manager,
  Processes.Thread,
  Io.Manager,
  Io.BoundedRequests,
  Kernel.SelfTest;

const
  TestGraceMilliseconds = 200;
  WaitLimitMilliseconds = 5000;
  BufferBytes = 16;
  SenderPattern = $5A;
  LateDataPattern = $A5;
  LateByteCount = 9;

var
  LossyDevice: PDeviceObject;
  { The requests the driver holds (it never completes them itself). }
  Kept: array[0..3] of PIoRequest;
  KeptCount: PtrUInt;

  SenderThread: PThreadControlBlock;
  SenderMustEnd: PtrUInt;
  SenderStatus: LongInt;
  SenderInformation: Int64;
  SenderBuffer: array[0..BufferBytes - 1] of Byte;
  SenderFinished: TEvent;

function KeepRequest(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Slot: PtrUInt;
begin
  Slot := AtomicIncrement(Int64(KeptCount)) - 1;
  if Slot > High(Kept) then
    Exit(ErrorBusy);
  Kept[Slot] := @Request;
  Result := StatusPending;
end;

procedure CreateLossyDevice;
var
  Dispatch: TDispatchTable;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @KeepRequest;
  Dispatch[IoFunctionOpen] := @KeepRequest;
  LossyDevice := CreateDevice(CreateDriver('lossy', Dispatch), nil, DeviceKindCharacter, 0, 0);
  Check(LossyDevice <> nil, 'could not create the lossy test device');
end;

{ The test's own "must end" query: only the sender, and only when told. }
function SenderMustEndQuery: Boolean;
begin
  Result := (CurrentThread = SenderThread) and (AtomicLoad(SenderMustEnd) <> 0);
end;

procedure SenderMain(Context: Pointer);
var
  Request: TIoRequest;
  Operation: TIoFunction;
begin
  Operation := TIoFunction(PtrUInt(Context));
  SenderThread := CurrentThread;
  FillMemory(@SenderBuffer[0], BufferBytes, SenderPattern);
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := Operation;
  if Operation = IoFunctionRead then
  begin
    Request.Buffer := @SenderBuffer[0];
    Request.Length := BufferBytes;
  end;
  SenderStatus := CallDriverAndWaitBounded(LossyDevice, Request, Operation = IoFunctionRead);
  SenderInformation := Request.Information;
  SignalEvent(SenderFinished);
end;

function StartSender(Operation: TIoFunction): PThread;
var
  Deadline: QWord;
  Before: PtrUInt;
begin
  Before := AtomicLoad(KeptCount);
  SenderThread := nil;
  InitializeEvent(SenderFinished, EventKindNotification, False);
  Result := CreateSystemThread(@SenderMain, Pointer(PtrUInt(Ord(Operation))), DefaultThreadPriority,
    'LossySender', True);
  Check(Result <> nil, 'could not create the bounded request sender');
  Deadline := DeadlineAfterMilliseconds(WaitLimitMilliseconds);
  while AtomicLoad(KeptCount) = Before do
  begin
    Check(ClockNanoseconds < Deadline, 'the lossy driver never got the request');
    SleepMilliseconds(1);
  end;
end;

procedure FinishSender(Thread: PThread; const What: PChar);
begin
  Check(WaitForEventWithOptions(SenderFinished, WaitLimitMilliseconds, False) = WaitSignaled, What);
  DereferenceObject(Thread);
end;

{ The driver completes a request late, writing data as a read would. }
procedure CompleteLate(Request: PIoRequest);
begin
  if Request^.Buffer <> nil then
    FillMemory(Request^.Buffer, Request^.Length, LateDataPattern);
  Request^.Information := LateByteCount;
  CompleteRequest(Request^, ErrorNone);
end;

function BufferIsUntouched: Boolean;
var
  Index: Integer;
begin
  Result := True;
  for Index := 0 to BufferBytes - 1 do
    if SenderBuffer[Index] <> SenderPattern then
      Result := False;
end;

procedure TestCancelledReadIsGivenUp;
var
  Thread: PThread;
  Abandoned: QWord;
begin
  Abandoned := AbandonedRequestCount;
  Thread := StartSender(IoFunctionRead);
  AlertThread(SenderThread);
  FinishSender(Thread, 'a thread whose cancelled request was lost kept waiting');
  Check(SenderStatus = ErrorInterrupted, 'a cancelled request given up did not end with ErrorInterrupted');
  Check(AbandonedRequestCount = Abandoned + 1, 'the given up request was not counted');
  CompleteLate(Kept[AtomicLoad(KeptCount) - 1]);
  Check(BufferIsUntouched, 'a driver completing a given up read wrote into the sender''s buffer');
end;

procedure TestEndingThreadGivesUpOpen;
var
  Thread: PThread;
begin
  AtomicStore(SenderMustEnd, 1);
  Thread := StartSender(IoFunctionOpen);
  FinishSender(Thread, 'a thread that must end kept waiting for an open its driver lost');
  Check(SenderStatus = ErrorTimedOut, 'an open given up did not end with ErrorTimedOut');
  AtomicStore(SenderMustEnd, 0);
  CompleteLate(Kept[AtomicLoad(KeptCount) - 1]);
end;

procedure TestLateCompletionStillArrives;
var
  Thread: PThread;
begin
  Thread := StartSender(IoFunctionRead);
  { Longer than the grace: a thread that need not end waits on. }
  SleepMilliseconds(TestGraceMilliseconds * 2);
  Check(not EventIsSignaled(SenderFinished), 'a thread that need not end gave up its request');
  CompleteLate(Kept[AtomicLoad(KeptCount) - 1]);
  FinishSender(Thread, 'a late completion did not reach its sender');
  Check((SenderStatus = ErrorNone) and (SenderInformation = LateByteCount),
    'a late completion did not give the sender its result');
  Check((SenderBuffer[0] = LateDataPattern) and (SenderBuffer[LateByteCount - 1] = LateDataPattern) and
    (SenderBuffer[LateByteCount] = SenderPattern), 'a late read did not bring exactly its bytes');
end;

procedure RunBoundedRequestSelfTests;
var
  PreviousQuery: TThreadMustEndQuery;
begin
  KeptCount := 0;
  SenderMustEnd := 0;
  CreateLossyDevice;
  PreviousQuery := ThreadMustEndQueryInUse;
  SetThreadMustEndQuery(@SenderMustEndQuery);
  SetRequestGraceForTest(TestGraceMilliseconds);
  TestCancelledReadIsGivenUp;
  TestEndingThreadGivesUpOpen;
  TestLateCompletionStillArrives;
  SetRequestGraceForTest(0);
  SetThreadMustEndQuery(PreviousQuery);
  ReportPassed('requests a driver loses are given up by threads that must end');
end;

end.
