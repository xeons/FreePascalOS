{
  The I/O manager: drivers, devices and requests.

  A driver is an object with a name and a dispatch table: one routine per
  kind of request (open, close, read, write, control). A driver creates
  device objects, each with a name, an owner and permission bits like a
  file, a kind (character or block) and an extension: memory the driver
  uses for that device's own state. Programs see every named device
  under /dev (Processes.FileCalls); a device created without a name is
  only reachable from inside the kernel, like the disk controller ports
  below the disk devices.

  Every operation is described by a request (TIoRequest) handed to the
  device's driver through CallDriver. Buffers in requests are always
  kernel memory. A dispatch routine either

    * finishes the request and returns its status (ErrorNone or an Abi
      error code), having filled in Information (bytes moved, or the
      result of a control request), or
    * returns StatusPending, keeps the request, and finishes it later -
      usually from a deferred call after its device interrupted - by
      calling CompleteRequest.

  Either way the request completes exactly once: CallDriver completes a
  request whose dispatch routine returned anything but StatusPending.
  Completing runs the request's completion routine, if it has one, or
  signals its completion event. CallDriverAndWait does the usual thing:
  it sends a request and waits until it completes.

  A driver that holds requests until something happens (input arriving)
  keeps them in a request queue (TRequestQueue). Requests waiting there
  can be cancelled: CancelRequest takes a queued request out of its queue
  and completes it with ErrorInterrupted. That is how a program blocked
  reading a device is ended or stopped.

  Dispatch routines are called at PassiveLevel, except that read
  routines of input devices (Io.InputDevice) may also be called at
  DispatchLevel, from completion routines. Completion routines run at
  whatever level the request completed at, up to DispatchLevel, so they
  may only take spin locks and queue deferred calls.

  Devices are never removed.
}
unit Io.Manager;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Objects.Manager,
  Kernel.Events;

const
  DeviceNameLength = 32;
  MaximumDevices = 128;

  { Returned by a dispatch routine that will complete the request later.
    Never seen outside the kernel; Abi error codes are all positive. }
  StatusPending = -1;

type
  TIoFunction = (IoFunctionOpen, IoFunctionClose, IoFunctionRead, IoFunctionWrite,
    IoFunctionControl);

  TDeviceKind = (DeviceKindCharacter, DeviceKindBlock);

  PDriverObject = ^TDriverObject;
  PDeviceObject = ^TDeviceObject;
  PDeviceFile = ^TDeviceFile;
  PIoRequest = ^TIoRequest;

  { Runs once when Request completes; see the unit comment for where. }
  TCompletionRoutine = procedure(Request: PIoRequest);

  TIoRequest = record
    Operation: TIoFunction;
    Device: PDeviceObject;
    OpenFile: PDeviceFile;
    { Read and write: kernel memory, Length bytes, starting at Offset in
      the device (block devices). }
    Buffer: Pointer;
    Length: QWord;
    Offset: QWord;
    { Open: the Abi open flags. }
    OpenFlags: LongWord;
    ControlCode: QWord;
    ControlArgument: QWord;
    { Set by the driver: bytes moved, or the result of a control request. }
    Information: Int64;

    { Set when the request completes: ErrorNone or an Abi error code. }
    Status: LongInt;
    { Whoever sends the request sets one of these (or neither). }
    CompletionRoutine: TCompletionRoutine;
    CompletionContext: Pointer;
    CompletionEvent: PEvent;

    { Owned by the request queue the request waits in. }
    QueueLink: TListEntry;
    IsQueued: Boolean;
    CancelRequested: Boolean;
  end;

  { Requests a driver holds until it can finish them. }
  TRequestQueue = record
    Requests: TListEntry;
  end;

  { Returns ErrorNone, an Abi error code or StatusPending. }
  TDispatchRoutine = function(Device: PDeviceObject; var Request: TIoRequest): LongInt;
  TDispatchTable = array[TIoFunction] of TDispatchRoutine;

  TDriverObject = record
    Name: array[0..DeviceNameLength - 1] of Char;
    { A missing open or close routine means "nothing to do"; any other
      missing routine makes that request unsupported. }
    Dispatch: TDispatchTable;
  end;

  TDeviceObject = record
    { Empty for a device that is not listed under /dev. }
    Name: array[0..DeviceNameLength - 1] of Char;
    Driver: PDriverObject;
    Kind: TDeviceKind;
    { What a program is told a handle to this device is (Abi
      HandleKind*): the console and the null device keep their own kinds,
      everything else is HandleKindDevice. }
    ReportedHandleKind: LongInt;
    OwnerId: LongWord;
    GroupId: LongWord;
    { Permission bits, as for a file. }
    Mode: LongWord;
    { Block devices: their size. }
    SizeInBytes: QWord;
    { Only one open at a time (the input devices, which the console
      holds open). }
    IsExclusive: Boolean;
    OpenCount: LongWord;
    { The driver's state for this device. }
    Extension: Pointer;
  end;

  TDeviceFile = record
    Device: PDeviceObject;
    { Where the next read or write of a block device starts. }
    Position: QWord;
    OpenFlags: LongWord;
    { The driver's state for this open. }
    Context: Pointer;
    { The /dev directory itself: Device is nil and ReadDirectoryIndex is
      the next device to list. }
    IsDirectory: Boolean;
    ReadDirectoryIndex: LongWord;
  end;

procedure InitializeIoManager;

function CreateDriver(Name: PChar; const Dispatch: TDispatchTable): PDriverObject;
{ Creates a device of Driver with ExtensionSize zeroed bytes of extension,
  owned by root. A nil Name makes a device that is not listed under /dev.
  Returns nil if the name is taken or memory is short. }
function CreateDevice(Driver: PDriverObject; Name: PChar; Kind: TDeviceKind; Mode: LongWord;
  ExtensionSize: QWord): PDeviceObject;

{ Named devices only. }
function FindDevice(Name: PChar): PDeviceObject;
function DeviceCount: Integer;
{ nil past the end. }
function DeviceAt(Index: Integer): PDeviceObject;

{ Sends Request to Device's driver. Returns the request's status, or
  StatusPending if it completes later. The completion routine or event
  must be set beforehand. }
function CallDriver(Device: PDeviceObject; var Request: TIoRequest): LongInt;
{ Sends Request and waits until it completes; returns its status. An
  alertable wait that is alerted cancels the request (if it is still
  queued) and then waits for it to complete. }
function CallDriverAndWait(Device: PDeviceObject; var Request: TIoRequest;
  Alertable: Boolean): LongInt;
{ For drivers: finishes a request they returned StatusPending for. }
procedure CompleteRequest(var Request: TIoRequest; Status: LongInt);

procedure InitializeRequestQueue(out Queue: TRequestQueue);
{ Adds Request at the end of Queue. Returns False, and leaves it out, if
  the request was already cancelled; the driver then fails it with
  ErrorInterrupted. }
function QueueRequest(var Queue: TRequestQueue; var Request: TIoRequest): Boolean;
{ Takes the oldest request out of Queue; nil if it is empty. }
function TakeQueuedRequest(var Queue: TRequestQueue): PIoRequest;
{ Completes Request with ErrorInterrupted if it is waiting in a queue;
  otherwise marks it, so that queueing it later fails. }
procedure CancelRequest(var Request: TIoRequest);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Panic;

var
  DriverObjectType: TObjectType;
  DeviceObjectType: TObjectType;
  RegistryLock: TSpinLock;
  Devices: array[0..MaximumDevices - 1] of PDeviceObject;
  DeviceTotal: Integer = 0;
  { Guards every request queue, so that cancelling needs no knowledge
    of which queue a request is in. }
  QueueLock: TSpinLock;

procedure InitializeIoManager;
begin
  InitializeSpinLock(RegistryLock);
  InitializeSpinLock(QueueLock);
  RegisterObjectType(DriverObjectType, 'Driver', SizeOf(TDriverObject), nil);
  RegisterObjectType(DeviceObjectType, 'Device', SizeOf(TDeviceObject), nil);
end;

{ --- Drivers and devices ------------------------------------------------ }

function CreateDriver(Name: PChar; const Dispatch: TDispatchTable): PDriverObject;
begin
  Result := PDriverObject(CreateObject(DriverObjectType, nil));
  if Result = nil then
    KernelPanic('could not create a driver object');
  CopyText(@Result^.Name[0], Name, DeviceNameLength);
  Result^.Dispatch := Dispatch;
end;

function FindDeviceLocked(Name: PChar): PDeviceObject;
var
  Index: Integer;
begin
  for Index := 0 to DeviceTotal - 1 do
    if TextIsEqual(@Devices[Index]^.Name[0], Name) then
      Exit(Devices[Index]);
  Result := nil;
end;

{ Adds a named device to the list. False if the name is taken or the
  list is full. }
function RegisterDevice(Device: PDeviceObject): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(RegistryLock);
  Result := (DeviceTotal < MaximumDevices) and (FindDeviceLocked(@Device^.Name[0]) = nil);
  if Result then
  begin
    Devices[DeviceTotal] := Device;
    Inc(DeviceTotal);
  end;
  ReleaseSpinLock(RegistryLock, PreviousLevel);
end;

function CreateDevice(Driver: PDriverObject; Name: PChar; Kind: TDeviceKind; Mode: LongWord;
  ExtensionSize: QWord): PDeviceObject;
begin
  Result := PDeviceObject(CreateObject(DeviceObjectType, nil));
  if Result = nil then
    Exit;
  if Name <> nil then
    CopyText(@Result^.Name[0], Name, DeviceNameLength);
  Result^.Driver := Driver;
  Result^.Kind := Kind;
  Result^.ReportedHandleKind := HandleKindDevice;
  Result^.Mode := Mode;
  if ExtensionSize > 0 then
  begin
    Result^.Extension := AllocateZeroedKernelMemory(ExtensionSize);
    if Result^.Extension = nil then
    begin
      DereferenceObject(Result);
      Exit(nil);
    end;
  end;

  if (Name <> nil) and not RegisterDevice(Result) then
  begin
    FreeKernelMemory(Result^.Extension);
    DereferenceObject(Result);
    Exit(nil);
  end;
end;

function FindDevice(Name: PChar): PDeviceObject;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(RegistryLock);
  Result := FindDeviceLocked(Name);
  ReleaseSpinLock(RegistryLock, PreviousLevel);
end;

function DeviceCount: Integer;
begin
  Result := DeviceTotal;
end;

function DeviceAt(Index: Integer): PDeviceObject;
begin
  if (Index < 0) or (Index >= DeviceTotal) then
    Exit(nil);
  Result := Devices[Index];
end;

{ --- Sending and completing requests ------------------------------------- }

procedure CompleteRequest(var Request: TIoRequest; Status: LongInt);
begin
  Request.Status := Status;
  { The sender may reuse or free the request as soon as it learns of the
    completion, so nothing touches it after that. }
  if Assigned(Request.CompletionRoutine) then
    Request.CompletionRoutine(@Request)
  else if Request.CompletionEvent <> nil then
    SignalEvent(Request.CompletionEvent^);
end;

function CallDriver(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Routine: TDispatchRoutine;
begin
  Request.Device := Device;
  Request.Information := 0;
  Request.Status := StatusPending;
  Request.IsQueued := False;
  Request.CancelRequested := False;
  Routine := Device^.Driver^.Dispatch[Request.Operation];
  if Assigned(Routine) then
    Result := Routine(Device, Request)
  else if Request.Operation in [IoFunctionOpen, IoFunctionClose] then
    Result := ErrorNone
  else
    Result := ErrorUnsupported;
  if Result <> StatusPending then
    CompleteRequest(Request, Result);
end;

function CallDriverAndWait(Device: PDeviceObject; var Request: TIoRequest;
  Alertable: Boolean): LongInt;
var
  Completed: TEvent;
begin
  InitializeEvent(Completed, EventKindNotification, False);
  Request.CompletionRoutine := nil;
  Request.CompletionEvent := @Completed;
  if CallDriver(Device, Request) = StatusPending then
    if WaitForEventWithOptions(Completed, InfiniteTimeout, Alertable) = WaitAlerted then
    begin
      CancelRequest(Request);
      { Cancelled or not, the request completes; it lives on this stack. }
      WaitForEvent(Completed);
    end;
  Result := Request.Status;
end;

{ --- Request queues ------------------------------------------------------- }

function RequestOfQueueLink(Entry: PListEntry): PIoRequest;
begin
  Result := PIoRequest(ContainingRecord(Entry, FieldOffset(PIoRequest(nil)^.QueueLink)));
end;

procedure InitializeRequestQueue(out Queue: TRequestQueue);
begin
  InitializeListHead(Queue.Requests);
end;

function QueueRequest(var Queue: TRequestQueue; var Request: TIoRequest): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(QueueLock);
  Result := not Request.CancelRequested;
  if Result then
  begin
    InsertAtTail(Queue.Requests, @Request.QueueLink);
    Request.IsQueued := True;
  end;
  ReleaseSpinLock(QueueLock, PreviousLevel);
end;

function TakeQueuedRequest(var Queue: TRequestQueue): PIoRequest;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
begin
  PreviousLevel := AcquireSpinLock(QueueLock);
  Entry := RemoveHeadEntry(Queue.Requests);
  Result := nil;
  if Entry <> nil then
  begin
    Result := RequestOfQueueLink(Entry);
    Result^.IsQueued := False;
  end;
  ReleaseSpinLock(QueueLock, PreviousLevel);
end;

procedure CancelRequest(var Request: TIoRequest);
var
  PreviousLevel: TPriorityLevel;
  WasQueued: Boolean;
begin
  PreviousLevel := AcquireSpinLock(QueueLock);
  Request.CancelRequested := True;
  WasQueued := Request.IsQueued;
  if WasQueued then
  begin
    RemoveListEntry(@Request.QueueLink);
    Request.IsQueued := False;
  end;
  ReleaseSpinLock(QueueLock, PreviousLevel);
  { Out of the queue, so the driver can no longer complete it. }
  if WasQueued then
    CompleteRequest(Request, ErrorInterrupted);
end;

end.
