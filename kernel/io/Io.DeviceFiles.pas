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
  Device files: what opening a device gives.

  A device file object holds the device and what belongs to that one
  open: the position (for block devices), the open flags and a context
  pointer of the driver's. Reads, writes and control requests on it are
  sent to the device's driver as requests (Io.Manager) and waited for;
  those waits are alertable, so a program blocked on a device can be
  ended or stopped (its request is cancelled). Every request goes
  through Io.BoundedRequests, so a driver that never completes one -
  an open, a close, a cancelled read - keeps a thread that must end
  waiting only RequestGraceMilliseconds.

  Opening the /dev directory gives a device file too, with no device,
  for listing the devices.
}
unit Io.DeviceFiles;

{$mode objfpc}

interface

uses
  Objects.Manager,
  Io.Manager;

var
  DeviceFileObjectType: TObjectType;

procedure InitializeDeviceFiles;

{ Opens Device; the device file has one reference for the caller. An
  exclusive device that is already open gives ErrorBusy. }
function OpenDevice(Device: PDeviceObject; Flags: LongWord; out OpenFile: PDeviceFile): LongInt;
{ Opens the /dev directory for listing. }
function OpenDeviceDirectory(out OpenFile: PDeviceFile): LongInt;

{ Return the bytes moved or the control result, or minus an Abi error. }
function ReadDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
function WriteDevice(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord): Int64;
function ControlDevice(OpenFile: PDeviceFile; Code: QWord; Argument: QWord): Int64;
{ pread and pwrite of a block device: at Offset, its position left
  alone. ErrorIllegalSeek for other devices. }
function ReadDeviceAt(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord; Offset: QWord): Int64;
function WriteDeviceAt(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord; Offset: QWord): Int64;
{ Asks the driver for the device memory a program may map: Length bytes
  at Offset (page aligned). Returns ErrorNone or an Abi error code. }
function QueryDeviceMapping(OpenFile: PDeviceFile; Offset, Length: QWord; out Physical: QWord;
  out WriteCombining: Boolean): LongInt;
{ Block devices only; Origin is an Abi Seek* value. Returns the new
  position or minus an Abi error. }
function SeekDevice(OpenFile: PDeviceFile; Offset: Int64; Origin: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Io.BoundedRequests,
  Kernel.PriorityLevel,
  Kernel.SpinLock;

var
  OpenCountLock: TSpinLock;

{ Counts an open of Device; False if it is exclusive and already open. }
function TryCountOpen(Device: PDeviceObject): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(OpenCountLock);
  Result := not (Device^.IsExclusive and (Device^.OpenCount > 0));
  if Result then
    Inc(Device^.OpenCount);
  ReleaseSpinLock(OpenCountLock, PreviousLevel);
end;

procedure UncountOpen(Device: PDeviceObject);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(OpenCountLock);
  Dec(Device^.OpenCount);
  ReleaseSpinLock(OpenCountLock, PreviousLevel);
end;

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
  CallDriverAndWaitBounded(OpenFile^.Device, Request, False);
  UncountOpen(OpenFile^.Device);
end;

procedure InitializeDeviceFiles;
begin
  InitializeSpinLock(OpenCountLock);
  RegisterObjectType(DeviceFileObjectType, 'DeviceFile', SizeOf(TDeviceFile), @DeleteDeviceFile);
end;

function OpenDevice(Device: PDeviceObject; Flags: LongWord; out OpenFile: PDeviceFile): LongInt;
var
  Request: TIoRequest;
  Instead: Pointer;
begin
  OpenFile := nil;
  if Assigned(Device^.OpenInstead) then
  begin
    Result := Device^.OpenInstead(Device, Flags, Instead);
    OpenFile := PDeviceFile(Instead);
    Exit;
  end;
  if not TryCountOpen(Device) then
    Exit(ErrorBusy);
  OpenFile := PDeviceFile(CreateObject(DeviceFileObjectType, nil));
  if OpenFile = nil then
  begin
    UncountOpen(Device);
    Exit(ErrorOutOfMemory);
  end;
  OpenFile^.OpenFlags := Flags;
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionOpen;
  Request.OpenFile := OpenFile;
  Request.OpenFlags := Flags;
  Result := CallDriverAndWaitBounded(Device, Request, False);
  if Result <> ErrorNone then
  begin
    { Not opened, so the driver must not see a close. }
    DereferenceObject(OpenFile);
    OpenFile := nil;
    UncountOpen(Device);
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

{ One request at Offset; returns the bytes moved or minus an Abi error. }
function TransferAt(OpenFile: PDeviceFile; Operation: TIoFunction; Buffer: Pointer; Length: QWord;
  Offset: QWord): Int64;
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
  Request.Offset := Offset;
  Error := CallDriverAndWaitBounded(OpenFile^.Device, Request, True);
  if Error <> ErrorNone then
    Exit(-Int64(Error));
  Result := Request.Information;
end;

function Transfer(OpenFile: PDeviceFile; Operation: TIoFunction; Buffer: Pointer; Length: QWord): Int64;
begin
  Result := TransferAt(OpenFile, Operation, Buffer, Length, OpenFile^.Position);
  if (Result > 0) and (OpenFile^.Device^.Kind = DeviceKindBlock) then
    OpenFile^.Position := OpenFile^.Position + QWord(Result);
end;

function ReadDeviceAt(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord; Offset: QWord): Int64;
begin
  if OpenFile^.IsDirectory or (OpenFile^.Device^.Kind <> DeviceKindBlock) then
    Exit(-Int64(ErrorIllegalSeek));
  Result := TransferAt(OpenFile, IoFunctionRead, Buffer, Length, Offset);
end;

function WriteDeviceAt(OpenFile: PDeviceFile; Buffer: Pointer; Length: QWord; Offset: QWord): Int64;
begin
  if OpenFile^.IsDirectory or (OpenFile^.Device^.Kind <> DeviceKindBlock) then
    Exit(-Int64(ErrorIllegalSeek));
  Result := TransferAt(OpenFile, IoFunctionWrite, Buffer, Length, Offset);
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
  Error := CallDriverAndWaitBounded(OpenFile^.Device, Request, True);
  if Error <> ErrorNone then
    Exit(-Int64(Error));
  Result := Request.Information;
end;

function QueryDeviceMapping(OpenFile: PDeviceFile; Offset, Length: QWord; out Physical: QWord;
  out WriteCombining: Boolean): LongInt;
var
  Request: TIoRequest;
begin
  Physical := 0;
  WriteCombining := False;
  if OpenFile^.IsDirectory then
    Exit(ErrorUnsupported);
  if OpenFile^.Device^.Driver^.Dispatch[IoFunctionMap] = nil then
    Exit(ErrorUnsupported);
  FillMemory(@Request, SizeOf(Request), 0);
  Request.Operation := IoFunctionMap;
  Request.OpenFile := OpenFile;
  Request.Offset := Offset;
  Request.Length := Length;
  Result := CallDriverAndWaitBounded(OpenFile^.Device, Request, True);
  if Result <> ErrorNone then
    Exit;
  Physical := Request.MapPhysical;
  WriteCombining := Request.MapWriteCombining;
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
