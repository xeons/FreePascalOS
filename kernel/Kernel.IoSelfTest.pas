{
  Self tests of the I/O manager's asynchronous requests.

  A test driver ("selftest", one device without a name) holds every read
  in a request queue until the test completes it from a deferred call,
  the way an interrupt driven driver does. The tests check that

    * a waiting sender gets the status and byte count of a request
      completed later, from DispatchLevel;
    * a completion routine runs exactly once, with the request's status;
    * alerting a thread that waits for a queued request cancels it, and
      the sender gets ErrorInterrupted.
}
unit Kernel.IoSelfTest;

{$mode objfpc}

interface

procedure RunIoSelfTests;

implementation

uses
  Runtime.Atomic,
  Runtime.LinkedList,
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.DeferredCalls,
  Processes.Thread,
  Io.Manager,
  Kernel.SelfTest;

const
  CompletedByteCount = 7;
  MaximumWaitRounds = 1000;

var
  TestDevice: PDeviceObject;
  HeldReads: TRequestQueue;
  CompleteHeldRead: TDeferredCall;

  { Set by the sender thread. }
  SenderThread: PThreadControlBlock;
  SenderStatus: LongInt;
  SenderInformation: Int64;
  SenderFinished: TEvent;

  CompletionRoutineCalls: Int64;
  CompletionRoutineStatus: LongInt;

function HoldRead(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  if not QueueRequest(HeldReads, Request) then
    Exit(ErrorInterrupted);
  Result := StatusPending;
end;

{ Deferred call: completes the oldest held read, as an interrupt driven
  driver would. }
procedure CompleteOldestHeldRead(Context: Pointer);
var
  Request: PIoRequest;
begin
  Request := TakeQueuedRequest(HeldReads);
  if Request = nil then
    Exit;
  Request^.Information := CompletedByteCount;
  CompleteRequest(Request^, ErrorNone);
end;

procedure CreateTestDevice;
var
  Dispatch: TDispatchTable;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @HoldRead;
  TestDevice := CreateDevice(CreateDriver('selftest', Dispatch), nil, DeviceKindCharacter, 0, 0);
  Check(TestDevice <> nil, 'could not create the I/O test device');
  InitializeRequestQueue(HeldReads);
  InitializeDeferredCall(CompleteHeldRead, @CompleteOldestHeldRead, nil);
end;

function HeldReadIsWaiting: Boolean;
begin
  Result := not ListIsEmpty(HeldReads.Requests);
end;

procedure WaitUntilReadIsHeld;
var
  Round: Integer;
begin
  for Round := 1 to MaximumWaitRounds do
  begin
    if HeldReadIsWaiting then
      Exit;
    SleepMilliseconds(1);
  end;
  Check(False, 'the test read was never queued');
end;

{ Sends one read and waits (alertably) for it. }
procedure SenderThreadMain(Context: Pointer);
var
  Request: TIoRequest;
  Buffer: array[0..15] of Byte;
begin
  SenderThread := CurrentThread;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionRead;
  Request.Buffer := @Buffer[0];
  Request.Length := SizeOf(Buffer);
  SenderStatus := CallDriverAndWait(TestDevice, Request, True);
  SenderInformation := Request.Information;
  SignalEvent(SenderFinished);
end;

procedure StartSender;
begin
  InitializeEvent(SenderFinished, EventKindNotification, False);
  SenderStatus := StatusPending;
  SenderInformation := -1;
  Check(CreateSystemThread(@SenderThreadMain, nil, DefaultThreadPriority, 'IoTest', False) <> nil,
    'could not create the I/O test thread');
  WaitUntilReadIsHeld;
end;

procedure TestLaterCompletion;
begin
  StartSender;
  QueueDeferredCall(CompleteHeldRead);
  WaitForEvent(SenderFinished);
  Check(SenderStatus = ErrorNone, 'a request completed later did not report success');
  Check(SenderInformation = CompletedByteCount, 'a request completed later lost its byte count');
  ReportPassed('requests completed from a deferred call');
end;

procedure CountCompletion(Request: PIoRequest);
begin
  CompletionRoutineStatus := Request^.Status;
  AtomicIncrement(CompletionRoutineCalls);
end;

procedure TestCompletionRoutine;
var
  Request: TIoRequest;
  Round: Integer;
begin
  CompletionRoutineCalls := 0;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionRead;
  Request.CompletionRoutine := @CountCompletion;
  Check(CallDriver(TestDevice, Request) = StatusPending, 'the test read did not stay pending');
  Check(CompletionRoutineCalls = 0, 'a completion routine ran before completion');
  QueueDeferredCall(CompleteHeldRead);
  Round := 0;
  while (CompletionRoutineCalls = 0) and (Round < MaximumWaitRounds) do
  begin
    SleepMilliseconds(1);
    Inc(Round);
  end;
  Check(CompletionRoutineCalls = 1, 'a completion routine did not run exactly once');
  Check(CompletionRoutineStatus = ErrorNone, 'a completion routine saw the wrong status');
  Check(Request.Information = CompletedByteCount, 'a completed request lost its byte count');

  { A routine that does not stay pending completes inside CallDriver. }
  Request.Operation := IoFunctionWrite;
  Check(CallDriver(TestDevice, Request) = ErrorUnsupported, 'a missing routine was not refused');
  Check(CompletionRoutineCalls = 2, 'a request refused at once did not complete');
  Check(CompletionRoutineStatus = ErrorUnsupported, 'a refused request completed with the wrong status');
  ReportPassed('completion routines');
end;

procedure TestCancellation;
begin
  StartSender;
  AlertThread(SenderThread);
  WaitForEvent(SenderFinished);
  Check(SenderStatus = ErrorInterrupted, 'an alerted wait did not cancel its request');
  Check(not HeldReadIsWaiting, 'a cancelled request stayed in its queue');
  ReportPassed('cancelling a waiting request');
end;

procedure RunIoSelfTests;
begin
  CreateTestDevice;
  TestLaterCompletion;
  TestCompletionRoutine;
  TestCancellation;
end;

end.
