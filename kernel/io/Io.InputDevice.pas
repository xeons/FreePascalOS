{
  Input devices: bytes that arrive by interrupt, and reads that wait for
  them.

  The keyboard and the serial port both work like this. Their interrupt
  handlers turn whatever the hardware sends into bytes and add them here
  (AddInputByte); the bytes wait in a small ring. A read request takes
  what is waiting; if nothing is, it is queued and completes - from a
  deferred call - as soon as input arrives. A queued read can be
  cancelled (Io.Manager).

  A driver gives each such device a TInputDevice as its extension and
  uses ReadInputDevice as its read routine:

    Device := CreateDevice(Driver, 'keyboard', DeviceKindCharacter, Mode,
      SizeOf(TInputDevice));
    InitializeInputDevice(PInputDevice(Device^.Extension)^);
    Dispatch[IoFunctionRead] := @ReadInputDevice;

  ReadInputDevice may be called at DispatchLevel, so the console can
  keep a read going from a completion routine (Io.ConsoleInput).
}
unit Io.InputDevice;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Io.Manager;

const
  InputRingCapacity = 256;

type
  PInputDevice = ^TInputDevice;
  TInputDevice = record
    { Taken with interrupts disabled: interrupt handlers fill the ring. }
    Lock: TSpinLock;
    Ring: array[0..InputRingCapacity - 1] of Byte;
    RingStart: LongWord;
    RingCount: LongWord;
    { Bytes lost because nobody read them in time. }
    DroppedCount: QWord;
    WaitingReads: TRequestQueue;
    CompleteReads: TDeferredCall;
  end;

procedure InitializeInputDevice(var Input: TInputDevice);
{ May be called at any level, from interrupt handlers too. }
procedure AddInputByte(var Input: TInputDevice; Value: Byte);
{ The read routine of an input device. }
function ReadInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;

implementation

uses
  Abi.SystemCalls,
  Kernel.Arch.Cpu;

{ Moves waiting bytes into Request; the caller holds Input.Lock. }
function TakeBytesLocked(var Input: TInputDevice; var Request: TIoRequest): QWord;
var
  Destination: PByte;
begin
  Destination := PByte(Request.Buffer);
  Result := 0;
  while (Result < Request.Length) and (Input.RingCount > 0) do
  begin
    Destination[Result] := Input.Ring[Input.RingStart];
    Input.RingStart := (Input.RingStart + 1) mod InputRingCapacity;
    Dec(Input.RingCount);
    Inc(Result);
  end;
end;

{ Deferred call: hands waiting bytes to waiting reads, oldest first. }
procedure CompleteWaitingReads(Context: Pointer);
var
  Input: PInputDevice;
  Request: PIoRequest;
  WereEnabled: Boolean;
begin
  Input := PInputDevice(Context);
  repeat
    Request := nil;
    WereEnabled := SaveAndDisableInterrupts;
    AcquireSpinLockAtCurrentLevel(Input^.Lock);
    if Input^.RingCount > 0 then
    begin
      Request := TakeQueuedRequest(Input^.WaitingReads);
      if Request <> nil then
        Request^.Information := Int64(TakeBytesLocked(Input^, Request^));
    end;
    ReleaseSpinLockAtCurrentLevel(Input^.Lock);
    RestoreInterrupts(WereEnabled);
    if Request = nil then
      Break;
    CompleteRequest(Request^, ErrorNone);
  until False;
end;

procedure InitializeInputDevice(var Input: TInputDevice);
begin
  InitializeSpinLock(Input.Lock);
  Input.RingStart := 0;
  Input.RingCount := 0;
  Input.DroppedCount := 0;
  InitializeRequestQueue(Input.WaitingReads);
  InitializeDeferredCall(Input.CompleteReads, @CompleteWaitingReads, @Input);
end;

procedure AddInputByte(var Input: TInputDevice; Value: Byte);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Input.Lock);
  { When the ring is full, newer input is dropped. }
  if Input.RingCount < InputRingCapacity then
  begin
    Input.Ring[(Input.RingStart + Input.RingCount) mod InputRingCapacity] := Value;
    Inc(Input.RingCount);
  end
  else
    Inc(Input.DroppedCount);
  ReleaseSpinLockAtCurrentLevel(Input.Lock);
  RestoreInterrupts(WereEnabled);
  QueueDeferredCall(Input.CompleteReads);
end;

function ReadInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Input: PInputDevice;
  WereEnabled: Boolean;
begin
  Input := PInputDevice(Device^.Extension);
  if Request.Length = 0 then
    Exit(ErrorNone);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Input^.Lock);
  Request.Information := Int64(TakeBytesLocked(Input^, Request));
  ReleaseSpinLockAtCurrentLevel(Input^.Lock);
  RestoreInterrupts(WereEnabled);
  if Request.Information > 0 then
    Exit(ErrorNone);

  if not QueueRequest(Input^.WaitingReads, Request) then
    Exit(ErrorInterrupted);
  { Input that arrived since the ring was looked at would otherwise wait
    for the next byte. }
  QueueDeferredCall(Input^.CompleteReads);
  Result := StatusPending;
end;

end.
