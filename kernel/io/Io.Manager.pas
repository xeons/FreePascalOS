{
  The I/O manager: drivers, devices and requests.

  A driver is an object with a name and a dispatch table: one routine per
  kind of request (open, close, read, write, control). A driver creates
  device objects, each with a name, an owner and permission bits like a
  file, a kind (character or block) and an extension: memory the driver
  uses for that device's own state. Programs see every device under
  /dev, by name (Processes.FileCalls).

  Opening a device gives a device file object, which holds the device and
  what belongs to that one open: the position (for block devices) and a
  context pointer of the driver's. Every operation is described by a
  request (TIoRequest) handed to the device's driver through CallDriver;
  the driver fills in the result (Information: bytes moved, or the
  control result) and returns an Abi error code. Buffers in requests are
  always kernel memory.

  Requests complete synchronously: the dispatch routine returns when the
  work is done, and may wait (alertably, so a program can be ended or
  stopped while it waits). Devices are never removed.
}
unit Io.Manager;

{$mode objfpc}
{$pointermath on}

interface

uses
  Objects.Manager;

const
  DeviceNameLength = 32;
  MaximumDevices = 128;

type
  TIoFunction = (IoFunctionOpen, IoFunctionClose, IoFunctionRead, IoFunctionWrite,
    IoFunctionControl);

  TDeviceKind = (DeviceKindCharacter, DeviceKindBlock);

  PDriverObject = ^TDriverObject;
  PDeviceObject = ^TDeviceObject;
  PDeviceFile = ^TDeviceFile;

  PIoRequest = ^TIoRequest;
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
  end;

  { Returns ErrorNone or an Abi error code. }
  TDispatchRoutine = function(Device: PDeviceObject; var Request: TIoRequest): LongInt;
  TDispatchTable = array[TIoFunction] of TDispatchRoutine;

  TDriverObject = record
    Name: array[0..DeviceNameLength - 1] of Char;
    { A missing open or close routine means "nothing to do"; any other
      missing routine makes that request unsupported. }
    Dispatch: TDispatchTable;
  end;

  TDeviceObject = record
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

var
  DeviceFileObjectType: TObjectType;

procedure InitializeIoManager;

function CreateDriver(Name: PChar; const Dispatch: TDispatchTable): PDriverObject;
{ Creates a device of Driver with ExtensionSize zeroed bytes of extension,
  owned by root. Returns nil if the name is taken or memory is short. }
function CreateDevice(Driver: PDriverObject; Name: PChar; Kind: TDeviceKind; Mode: LongWord;
  ExtensionSize: QWord): PDeviceObject;

function FindDevice(Name: PChar): PDeviceObject;
function DeviceCount: Integer;
{ nil past the end. }
function DeviceAt(Index: Integer): PDeviceObject;

{ Sends Request to Device's driver. }
function CallDriver(Device: PDeviceObject; var Request: TIoRequest): LongInt;

{ Opens Device; the device file has one reference for the caller. }
function OpenDevice(Device: PDeviceObject; Flags: LongWord; out OpenFile: PDeviceFile): LongInt;
{ Opens the /dev directory for listing. }
function OpenDeviceDirectory(out OpenFile: PDeviceFile): LongInt;

{ Return the bytes moved or the control result, or minus an Abi error. }
function ReadDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
function WriteDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
function ControlDevice(OpenFile: PDeviceFile; Code: QWord; Argument: QWord): Int64;
{ Block devices only; Origin is an Abi Seek* value. Returns the new
  position or minus an Abi error. }
function SeekDevice(OpenFile: PDeviceFile; Offset: Int64; Origin: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Panic;

var
  DriverObjectType: TObjectType;
  DeviceObjectType: TObjectType;
  RegistryLock: TSpinLock;
  Devices: array[0..MaximumDevices - 1] of PDeviceObject;
  DeviceTotal: Integer = 0;

{ Closing the last handle to an open device tells its driver. }
procedure DeleteDeviceFile(ObjectBody: Pointer);
var
  OpenFile: PDeviceFile;
  Request: TIoRequest;
begin
  OpenFile := PDeviceFile(ObjectBody);
  if OpenFile^.Device = nil then
    Exit;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionClose;
  Request.OpenFile := OpenFile;
  CallDriver(OpenFile^.Device, Request);
end;

procedure InitializeIoManager;
begin
  InitializeSpinLock(RegistryLock);
  RegisterObjectType(DriverObjectType, 'Driver', SizeOf(TDriverObject), nil);
  RegisterObjectType(DeviceObjectType, 'Device', SizeOf(TDeviceObject), nil);
  RegisterObjectType(DeviceFileObjectType, 'DeviceFile', SizeOf(TDeviceFile), @DeleteDeviceFile);
end;

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

function CreateDevice(Driver: PDriverObject; Name: PChar; Kind: TDeviceKind; Mode: LongWord;
  ExtensionSize: QWord): PDeviceObject;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := PDeviceObject(CreateObject(DeviceObjectType, nil));
  if Result = nil then
    Exit;
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

  PreviousLevel := AcquireSpinLock(RegistryLock);
  if (DeviceTotal = MaximumDevices) or (FindDeviceLocked(Name) <> nil) then
  begin
    ReleaseSpinLock(RegistryLock, PreviousLevel);
    FreeKernelMemory(Result^.Extension);
    DereferenceObject(Result);
    Exit(nil);
  end;
  Devices[DeviceTotal] := Result;
  Inc(DeviceTotal);
  ReleaseSpinLock(RegistryLock, PreviousLevel);
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

function CallDriver(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Routine: TDispatchRoutine;
begin
  Request.Device := Device;
  Request.Information := 0;
  Routine := Device^.Driver^.Dispatch[Request.Operation];
  if Assigned(Routine) then
    Result := Routine(Device, Request)
  else if Request.Operation in [IoFunctionOpen, IoFunctionClose] then
    Result := ErrorNone
  else
    Result := ErrorUnsupported;
end;

function OpenDevice(Device: PDeviceObject; Flags: LongWord; out OpenFile: PDeviceFile): LongInt;
var
  Request: TIoRequest;
begin
  OpenFile := PDeviceFile(CreateObject(DeviceFileObjectType, nil));
  if OpenFile = nil then
    Exit(ErrorOutOfMemory);
  OpenFile^.OpenFlags := Flags;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionOpen;
  Request.OpenFile := OpenFile;
  Request.OpenFlags := Flags;
  Result := CallDriver(Device, Request);
  if Result <> ErrorNone then
  begin
    { Not opened, so the driver must not see a close. }
    DereferenceObject(OpenFile);
    OpenFile := nil;
    Exit;
  end;
  OpenFile^.Device := Device;
end;

function OpenDeviceDirectory(out OpenFile: PDeviceFile): LongInt;
begin
  OpenFile := PDeviceFile(CreateObject(DeviceFileObjectType, nil));
  if OpenFile = nil then
    Exit(ErrorOutOfMemory);
  OpenFile^.IsDirectory := True;
  Result := ErrorNone;
end;

function Transfer(OpenFile: PDeviceFile; Operation: TIoFunction; Buffer: Pointer; Length: QWord): Int64;
var
  Request: TIoRequest;
  Error: LongInt;
begin
  if OpenFile^.IsDirectory then
    Exit(-Int64(ErrorIsDirectory));
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := Operation;
  Request.OpenFile := OpenFile;
  Request.Buffer := Buffer;
  Request.Length := Length;
  Request.Offset := OpenFile^.Position;
  Error := CallDriver(OpenFile^.Device, Request);
  if Error <> ErrorNone then
    Exit(-Int64(Error));
  if OpenFile^.Device^.Kind = DeviceKindBlock then
    OpenFile^.Position := OpenFile^.Position + QWord(Request.Information);
  Result := Request.Information;
end;

function ReadDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
begin
  Result := Transfer(OpenFile, IoFunctionRead, Buffer, Length);
end;

function WriteDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
begin
  Result := Transfer(OpenFile, IoFunctionWrite, Buffer, Length);
end;

function ControlDevice(OpenFile: PDeviceFile; Code: QWord; Argument: QWord): Int64;
var
  Request: TIoRequest;
  Error: LongInt;
begin
  if OpenFile^.IsDirectory then
    Exit(-Int64(ErrorUnsupported));
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionControl;
  Request.OpenFile := OpenFile;
  Request.ControlCode := Code;
  Request.ControlArgument := Argument;
  Error := CallDriver(OpenFile^.Device, Request);
  if Error <> ErrorNone then
    Exit(-Int64(Error));
  Result := Request.Information;
end;

function SeekDevice(OpenFile: PDeviceFile; Offset: Int64; Origin: QWord): Int64;
var
  Base: Int64;
begin
  if OpenFile^.IsDirectory or (OpenFile^.Device^.Kind <> DeviceKindBlock) then
    Exit(-Int64(ErrorUnsupported));
  case Origin of
    SeekFromStart: Base := 0;
    SeekFromCurrent: Base := Int64(OpenFile^.Position);
    SeekFromEnd: Base := Int64(OpenFile^.Device^.SizeInBytes);
  else
    Exit(-Int64(ErrorInvalidArgument));
  end;
  if Base + Offset < 0 then
    Exit(-Int64(ErrorInvalidArgument));
  OpenFile^.Position := QWord(Base + Offset);
  Result := Int64(OpenFile^.Position);
end;

end.
