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
  Requests a thread may give up on.

  CallDriverAndWait keeps the request, and the buffer it names, on the
  waiting thread's stack, so the thread has to wait until the driver
  completes it - forever, if the driver lost it. The waits a user
  thread reaches that way (opening and closing a device, block I/O,
  the wait for a cancelled request) would keep its process from ending.

  A bounded request is a copy on the heap that the driver owns as long
  as it holds it: its own buffer (copied in before, and out after for
  reads and control requests), a reference to the device file it names
  (a close carries a copy of the device file instead, its object being
  deleted), and a completion routine. Two references: the waiter's and
  the completion's. The waiter waits as usual - alertably for device
  reads and writes, cancelling the request when alerted - but once the
  request was cancelled, or the thread must end (its process is being
  ended or is exiting, or the thread was asked to exit: the query
  Processes sets), it waits at most RequestGraceMilliseconds more. Then
  it gives the request up (ErrorTimedOut, or ErrorInterrupted for a
  cancelled one) and the driver completes it whenever it does, into
  memory nobody else uses; the last reference frees it (the device
  file's reference at passive level: a completion at dispatch level
  leaves the record on a list the next bounded request clears).

  Without memory for the copy, the request is sent the old way.
}
unit Io.BoundedRequests;

{$mode objfpc}

interface

uses
  Io.Manager;

const
  { How much longer a thread that must end, or that cancelled its
    request, waits for the driver before it gives the request up. }
  RequestGraceMilliseconds = 5000;
  { How often a waiting thread looks whether it must end. }
  EndCheckMilliseconds = 250;

type
  { True if the calling thread must end (set by Processes). }
  TThreadMustEndQuery = function: Boolean;
  PBoundedRequest = Pointer;

procedure InitializeBoundedRequests;
procedure SetThreadMustEndQuery(Query: TThreadMustEndQuery);
{ The query set (for a self test that puts its own in for a while). }
function ThreadMustEndQueryInUse: TThreadMustEndQuery;

{ Sends Request (as CallDriverAndWait does) and waits for it, giving it
  up as described above. Returns its status. PassiveLevel. }
function CallDriverAndWaitBounded(Device: PDeviceObject; var Request: TIoRequest;
  Alertable: Boolean): LongInt;

{ For several requests in flight at once: sends a copy of Request and
  returns it, or nil if there was no memory for it (then nothing was
  sent). }
function StartBoundedRequest(Device: PDeviceObject; const Request: TIoRequest): PBoundedRequest;
{ Waits for a request StartBoundedRequest sent and fills in Request's
  results (status, Information, the data read). GiveUpAt is the clock
  time after which it is given up (NeverDue at first); shared between
  the requests of one batch, so that they are given up together. }
function FinishBoundedRequest(Bounded: PBoundedRequest; var Request: TIoRequest; Alertable: Boolean;
  var GiveUpAt: QWord): LongInt;

{ How many requests were given up so far. }
function AbandonedRequestCount: QWord;
{ For the self tests only: another grace (0 puts the usual one back). }
procedure SetRequestGraceForTest(Milliseconds: QWord);

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Objects.Manager,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.PriorityBoosts,
  Debug.Output;

type
  PBoundedRecord = ^TBoundedRecord;
  TBoundedRecord = record
    { What the driver sees. }
    Request: TIoRequest;
    Completed: TEvent;
    References: Int64;
    { The driver's buffer (nil for none). }
    Bounce: Pointer;
    { The device file object referenced while the request lives. }
    HeldFile: PDeviceFile;
    { A close: the device file as it was, for the driver. }
    ClosingCopy: TDeviceFile;
    Cancelled: Boolean;
    { On the list of records to free at passive level. }
    NextToFree: PBoundedRecord;
  end;

var
  GraceMilliseconds: QWord = RequestGraceMilliseconds;
  ThreadMustEnd: TThreadMustEndQuery = nil;
  FreeListLock: TSpinLock;
  FreeList: PBoundedRecord = nil;
  AbandonedCount: Int64 = 0;

procedure InitializeBoundedRequests;
begin
  InitializeSpinLock(FreeListLock);
end;

procedure SetThreadMustEndQuery(Query: TThreadMustEndQuery);
begin
  ThreadMustEnd := Query;
end;

procedure SetRequestGraceForTest(Milliseconds: QWord);
begin
  if Milliseconds = 0 then
    Milliseconds := RequestGraceMilliseconds;
  GraceMilliseconds := Milliseconds;
end;

function ThreadMustEndQueryInUse: TThreadMustEndQuery;
begin
  Result := ThreadMustEnd;
end;

function AbandonedRequestCount: QWord;
begin
  Result := QWord(AbandonedCount);
end;

procedure DestroyRecord(Bounded: PBoundedRecord);
begin
  if Bounded^.Bounce <> nil then
    FreeKernelMemory(Bounded^.Bounce);
  if Bounded^.HeldFile <> nil then
    DereferenceObject(Bounded^.HeldFile);
  FreeKernelMemory(Bounded);
end;

{ Frees the records whose last reference went at dispatch level. }
procedure DrainFreeList;
var
  PreviousLevel: TPriorityLevel;
  Taken: PBoundedRecord;
  Next: PBoundedRecord;
begin
  if FreeList = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(FreeListLock);
  Taken := FreeList;
  FreeList := nil;
  ReleaseSpinLock(FreeListLock, PreviousLevel);
  while Taken <> nil do
  begin
    Next := Taken^.NextToFree;
    DestroyRecord(Taken);
    Taken := Next;
  end;
end;

procedure ReleaseRecord(Bounded: PBoundedRecord);
var
  PreviousLevel: TPriorityLevel;
begin
  if AtomicDecrement(Bounded^.References) <> 0 then
    Exit;
  if (Bounded^.HeldFile = nil) or (CurrentPriorityLevel = PassiveLevel) then
  begin
    DestroyRecord(Bounded);
    Exit;
  end;
  { Dereferencing the device file may delete it, which waits. }
  PreviousLevel := AcquireSpinLock(FreeListLock);
  Bounded^.NextToFree := FreeList;
  FreeList := Bounded;
  ReleaseSpinLock(FreeListLock, PreviousLevel);
end;

procedure CompleteBoundedRequest(Request: PIoRequest);
var
  Bounded: PBoundedRecord;
begin
  Bounded := PBoundedRecord(Request^.CompletionContext);
  SignalEventWithBoost(Bounded^.Completed, BoostIoCompletion);
  ReleaseRecord(Bounded);
end;

function StartBoundedRequest(Device: PDeviceObject; const Request: TIoRequest): PBoundedRequest;
var
  Bounded: PBoundedRecord;
begin
  DrainFreeList;
  Result := nil;
  Bounded := PBoundedRecord(AllocateZeroedKernelMemory(SizeOf(TBoundedRecord)));
  if Bounded = nil then
    Exit;
  Bounded^.Request := Request;
  if (Request.Buffer <> nil) and (Request.Length > 0) then
  begin
    Bounded^.Bounce := AllocateKernelMemory(Request.Length);
    if Bounded^.Bounce = nil then
    begin
      FreeKernelMemory(Bounded);
      Exit;
    end;
    if Request.Operation <> IoFunctionRead then
      CopyMemory(Bounded^.Bounce, Request.Buffer, Request.Length);
    Bounded^.Request.Buffer := Bounded^.Bounce;
  end;
  if Request.OpenFile <> nil then
  begin
    if Request.Operation = IoFunctionClose then
    begin
      Bounded^.ClosingCopy := Request.OpenFile^;
      Bounded^.Request.OpenFile := @Bounded^.ClosingCopy;
    end
    else
    begin
      ReferenceObject(Request.OpenFile);
      Bounded^.HeldFile := Request.OpenFile;
    end;
  end;
  InitializeEvent(Bounded^.Completed, EventKindNotification, False);
  Bounded^.References := 2;
  Bounded^.Request.CompletionRoutine := @CompleteBoundedRequest;
  Bounded^.Request.CompletionContext := Bounded;
  Bounded^.Request.CompletionEvent := nil;
  CallDriver(Device, Bounded^.Request);
  Result := Bounded;
end;

function CurrentThreadMustEnd: Boolean;
begin
  Result := Assigned(ThreadMustEnd) and ThreadMustEnd();
end;

{ The clock time RequestGraceMilliseconds from now, unless GiveUpAt is
  earlier already. }
procedure StartGrace(var GiveUpAt: QWord);
var
  Deadline: QWord;
begin
  Deadline := DeadlineAfterMilliseconds(GraceMilliseconds);
  if Deadline < GiveUpAt then
    GiveUpAt := Deadline;
end;

procedure CopyResults(Bounded: PBoundedRecord; var Request: TIoRequest);
var
  Bytes: QWord;
begin
  Request.Status := Bounded^.Request.Status;
  Request.Information := Bounded^.Request.Information;
  Request.MapPhysical := Bounded^.Request.MapPhysical;
  Request.MapWriteCombining := Bounded^.Request.MapWriteCombining;
  if Bounded^.Bounce = nil then
    Exit;
  if Request.Operation = IoFunctionRead then
  begin
    Bytes := 0;
    if Bounded^.Request.Information > 0 then
      Bytes := QWord(Bounded^.Request.Information);
    if Bytes > Request.Length then
      Bytes := Request.Length;
    if Bytes > 0 then
      CopyMemory(Request.Buffer, Bounded^.Bounce, Bytes);
  end
  else if Request.Operation = IoFunctionControl then
    CopyMemory(Request.Buffer, Bounded^.Bounce, Request.Length);
end;

function OperationName(Operation: TIoFunction): PChar;
begin
  case Operation of
    IoFunctionOpen: Result := 'an open';
    IoFunctionClose: Result := 'a close';
    IoFunctionRead: Result := 'a read';
    IoFunctionWrite: Result := 'a write';
    IoFunctionControl: Result := 'a control request';
    IoFunctionFlush: Result := 'a flush';
    IoFunctionMap: Result := 'a mapping request';
  else
    Result := 'a discard';
  end;
end;

procedure WriteAbandonedLine(Bounded: PBoundedRecord);
begin
  DebugBeginMessage;
  DebugWriteTag('io');
  DebugWrite('gave up on ');
  DebugWrite(OperationName(Bounded^.Request.Operation));
  DebugWrite(' sent to ');
  if (Bounded^.Request.Device <> nil) and (Bounded^.Request.Device^.Name[0] <> #0) then
    DebugWrite(@Bounded^.Request.Device^.Name[0])
  else
    DebugWrite('an unnamed device');
  DebugWriteLine(' that its driver did not complete');
  DebugEndMessage;
end;

function FinishBoundedRequest(Bounded: PBoundedRequest; var Request: TIoRequest; Alertable: Boolean;
  var GiveUpAt: QWord): LongInt;
var
  Record_: PBoundedRecord;
  WaitFor: QWord;
  Now: QWord;
begin
  Record_ := PBoundedRecord(Bounded);
  repeat
    if Alertable and not Record_^.Cancelled and (GiveUpAt = NeverDue) then
    begin
      if WaitForEventWithOptions(Record_^.Completed, InfiniteTimeout, True) = WaitAlerted then
      begin
        CancelRequest(Record_^.Request);
        Record_^.Cancelled := True;
        StartGrace(GiveUpAt);
      end;
      Continue;
    end;
    { Not alertable (or alerted already): in short waits, looking in
      between whether the thread must end. }
    Now := ClockNanoseconds;
    if (GiveUpAt = NeverDue) and CurrentThreadMustEnd then
      StartGrace(GiveUpAt);
    if Now >= GiveUpAt then
      Break;
    WaitFor := EndCheckMilliseconds;
    if (GiveUpAt <> NeverDue) and ((GiveUpAt - Now) div NanosecondsPerMillisecond + 1 < WaitFor) then
      WaitFor := (GiveUpAt - Now) div NanosecondsPerMillisecond + 1;
    WaitForEventWithOptions(Record_^.Completed, WaitFor, False);
  until EventIsSignaled(Record_^.Completed);

  if EventIsSignaled(Record_^.Completed) then
  begin
    CopyResults(Record_, Request);
    Result := Request.Status;
  end
  else
  begin
    AtomicIncrement(AbandonedCount);
    WriteAbandonedLine(Record_);
    if Record_^.Cancelled then
      Result := ErrorInterrupted
    else
      Result := ErrorTimedOut;
    Request.Status := Result;
    Request.Information := 0;
  end;
  ReleaseRecord(Record_);
end;

function CallDriverAndWaitBounded(Device: PDeviceObject; var Request: TIoRequest;
  Alertable: Boolean): LongInt;
var
  Bounded: PBoundedRequest;
  GiveUpAt: QWord;
begin
  Bounded := StartBoundedRequest(Device, Request);
  if Bounded = nil then
    Exit(CallDriverAndWait(Device, Request, Alertable));
  GiveUpAt := NeverDue;
  Result := FinishBoundedRequest(Bounded, Request, Alertable, GiveUpAt);
end;

end.
