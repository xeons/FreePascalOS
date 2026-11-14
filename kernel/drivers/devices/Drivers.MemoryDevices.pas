{
  The memory devices: null, zero, full, random and urandom.

    null     reads nothing (end of file); swallows writes
    zero     reads zero bytes without end; swallows writes
    full     reads like zero; every write fails with "no space left"
    random   reads random bytes; swallows writes
    urandom  the same as random

  Random bytes come from the processor's generator (RDRAND) where there
  is one; otherwise from a xorshift generator seeded from the time stamp
  counter, which is unpredictable enough for scrambling but not for keys.
}
unit Drivers.MemoryDevices;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeMemoryDevices;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Io.Manager,
  Kernel.Panic;

type
  TMemoryDeviceRole = (RoleNull, RoleZero, RoleFull, RoleRandom);
  PMemoryDeviceRole = ^TMemoryDeviceRole;

var
  FallbackState: QWord;
  FallbackLock: TSpinLock;

function NextFallbackRandom: QWord;
var
  PreviousLevel: TPriorityLevel;
  State: QWord;
begin
  PreviousLevel := AcquireSpinLock(FallbackLock);
  State := FallbackState xor ReadTimeStampCounter;
  State := State xor (State shl 13);
  State := State xor (State shr 7);
  State := State xor (State shl 17);
  FallbackState := State;
  ReleaseSpinLock(FallbackLock, PreviousLevel);
  Result := State * QWord($2545F4914F6CDD1D);
end;

procedure FillRandom(Buffer: PByte; Length: QWord);
var
  Value: QWord;
  Index: QWord;
  Part: Integer;
begin
  Index := 0;
  while Index < Length do
  begin
    if not ReadHardwareRandom(Value) then
      Value := NextFallbackRandom;
    for Part := 0 to 7 do
    begin
      if Index >= Length then
        Break;
      Buffer[Index] := Byte(Value shr (Part * 8));
      Inc(Index);
    end;
  end;
end;

function RoleOf(Device: PDeviceObject): TMemoryDeviceRole;
begin
  Result := PMemoryDeviceRole(Device^.Extension)^;
end;

function ReadMemoryDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  case RoleOf(Device) of
    RoleNull:
      Request.Information := 0;
    RoleZero, RoleFull:
      begin
        ZeroMemory(Request.Buffer, Request.Length);
        Request.Information := Int64(Request.Length);
      end;
    RoleRandom:
      begin
        FillRandom(PByte(Request.Buffer), Request.Length);
        Request.Information := Int64(Request.Length);
      end;
  end;
  Result := ErrorNone;
end;

function WriteMemoryDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  if RoleOf(Device) = RoleFull then
    Exit(ErrorNoSpace);
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

procedure AddDevice(Driver: PDriverObject; Name: PChar; Role: TMemoryDeviceRole);
const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
var
  Device: PDeviceObject;
begin
  Device := CreateDevice(Driver, Name, DeviceKindCharacter, EveryoneReadWrite,
    SizeOf(TMemoryDeviceRole));
  if Device = nil then
    KernelPanic('could not create a memory device');
  PMemoryDeviceRole(Device^.Extension)^ := Role;
  if Role = RoleNull then
    Device^.ReportedHandleKind := HandleKindNullDevice;
end;

procedure InitializeMemoryDevices;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
begin
  InitializeSpinLock(FallbackLock);
  FallbackState := ReadTimeStampCounter or 1;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadMemoryDevice;
  Dispatch[IoFunctionWrite] := @WriteMemoryDevice;
  Driver := CreateDriver('memory', Dispatch);
  AddDevice(Driver, 'null', RoleNull);
  AddDevice(Driver, 'zero', RoleZero);
  AddDevice(Driver, 'full', RoleFull);
  AddDevice(Driver, 'random', RoleRandom);
  AddDevice(Driver, 'urandom', RoleRandom);
end;

end.
