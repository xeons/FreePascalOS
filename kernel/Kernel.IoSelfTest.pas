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
  Self tests of the I/O manager's asynchronous requests.

  A test driver ("selftest", one device without a name) holds every read
  in a request queue until the test completes it from a deferred call,
  the way an interrupt driven driver does. The tests check that

    * a waiting sender gets the status and byte count of a request
      completed later, from DispatchLevel;
    * a completion routine runs exactly once, with the request's status;
    * alerting a thread that waits for a queued request cancels it, and
      the sender gets ErrorInterrupted;
    * a filter attached on top of the device sees the requests sent to
      the device, its completion routine runs (also for a request
      completed later) before the sender's completion, and requests it
      has no routine for pass through it.
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
  Io.InputDevice,
  Drivers.KeyboardLayouts,
  Drivers.KeyboardTranslation,
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

const
  FilterMarker = 1000;

var
  FilterCompletions: Int64;

{ The filter's completion routine: marks the byte count. }
procedure MarkFilteredRead(Request: PIoRequest; Context: Pointer);
begin
  AtomicIncrement(FilterCompletions);
  Request^.Information := Request^.Information + FilterMarker;
end;

function FilterRead(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ForwardRequest(Device^.LowerDevice, Request, @MarkFilteredRead, nil);
end;

procedure TestFilter;
var
  Dispatch: TDispatchTable;
  Filter: PDeviceObject;
  Request: TIoRequest;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @FilterRead;
  Filter := CreateDevice(CreateDriver('selftestfilter', Dispatch), nil, DeviceKindCharacter, 0, 0);
  Check(Filter <> nil, 'could not create the I/O test filter');
  Check(AttachDevice(Filter, TestDevice) = TestDevice, 'a filter was attached to the wrong device');
  Check(TopOfStack(TestDevice) = Filter, 'a filter is not on top of its device');
  FilterCompletions := 0;

  { Sent to the device, through the filter, completed later. }
  StartSender;
  QueueDeferredCall(CompleteHeldRead);
  WaitForEvent(SenderFinished);
  Check(SenderStatus = ErrorNone, 'a filtered request did not report success');
  Check(FilterCompletions = 1, 'a filter''s completion routine did not run once');
  Check(SenderInformation = CompletedByteCount + FilterMarker,
    'a filter''s completion routine did not run before the sender''s completion');

  { The filter has no write routine: the request passes through. }
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionWrite;
  Check(CallDriverAndWait(TestDevice, Request, False) = ErrorUnsupported,
    'a request passed through a filter was not refused by the device');
  Check(FilterCompletions = 1, 'a passed-through request ran the filter''s routine');
  ReportPassed('filter devices');
end;

{ --- Keyboard translation ---------------------------------------------- }

var
  TestInput: TInputDevice;
  TestKeys: TKeyboardState;

procedure PressKey(Code: Byte);
begin
  TranslateKey(TestKeys, Code, False, False);
  TranslateKey(TestKeys, Code, False, True);
end;

procedure PressShifted(Code: Byte);
begin
  TranslateKey(TestKeys, $2A, False, False);
  PressKey(Code);
  TranslateKey(TestKeys, $2A, False, True);
end;

{ True if the keys typed since the last check gave Expected (UTF-8). }
function TypedText(Expected: PChar): Boolean;
var
  Index: LongWord;
begin
  Result := True;
  Index := 0;
  while Expected[Index] <> #0 do
  begin
    if (Index >= TestInput.RingCount) or
       (TestInput.Ring[(TestInput.RingStart + Index) mod InputRingCapacity] <> Byte(Expected[Index])) then
      Result := False;
    Inc(Index);
  end;
  Result := Result and (Index = TestInput.RingCount);
  TestInput.RingStart := 0;
  TestInput.RingCount := 0;
end;

{ Dead keys of the de and fr layouts, fed straight to the translation. }
procedure TestDeadKeys;
const
  KeyAcute = $0D;       { de: ´, with Shift ` }
  KeyCircumflexDe = $29;
  KeyCircumflexFr = $1A; { fr: ^, with Shift ¨ }
  KeyE = $12;
  KeyU = $16;
  KeyX = $2D;
  KeySpace = $39;
var
  PreviousLayout: PChar;
begin
  PreviousLayout := CurrentKeyboardLayoutName;
  InitializeInputDevice(TestInput);
  InitializeKeyboardState(TestKeys, @TestInput);

  SelectKeyboardLayout('de');
  PressKey(KeyAcute);
  PressKey(KeyE);
  Check(TypedText(#$C3#$A9), 'de: dead acute then e gives e acute');
  PressShifted(KeyAcute);
  PressShifted(KeyE);
  Check(TypedText(#$C3#$88), 'de: dead grave then E gives E grave');
  PressKey(KeyCircumflexDe);
  PressKey(KeySpace);
  Check(TypedText('^'), 'de: dead circumflex then space gives the accent');
  PressKey(KeyCircumflexDe);
  PressKey(KeyCircumflexDe);
  Check(TypedText('^'), 'de: the dead key twice gives the accent once');
  PressKey(KeyAcute);
  PressKey(KeyX);
  Check(TypedText(#$C2#$B4'x'), 'de: dead acute then x gives both');

  SelectKeyboardLayout('fr');
  PressKey(KeyCircumflexFr);
  PressKey(KeyE);
  Check(TypedText(#$C3#$AA), 'fr: dead circumflex then e gives e circumflex');
  PressShifted(KeyCircumflexFr);
  PressKey(KeyU);
  Check(TypedText(#$C3#$BC), 'fr: dead diaeresis then u gives u diaeresis');

  SelectKeyboardLayout(PreviousLayout);
  ReportPassed('dead keys');
end;

procedure RunIoSelfTests;
begin
  CreateTestDevice;
  TestLaterCompletion;
  TestCompletionRoutine;
  TestCancellation;
  TestFilter;
  TestDeadKeys;
end;

end.
