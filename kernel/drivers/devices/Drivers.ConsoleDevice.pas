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
  The console as a device: /dev/console, and /dev/tty for the same thing.

  Reads and writes go to the console (Io.Console), and a handle to it
  can be waited on until a read would not wait (its ReadyEvent). Control requests (the
  Abi Control* values) get and set its modes, report its size, set and
  get the foreground process group and take a pending Ctrl-C.

  Programs outside the console's foreground group are stopped when they
  read it; that check needs the process layer and is made before the
  request reaches this driver (Processes.FileCalls).
}
unit Drivers.ConsoleDevice;

{$mode objfpc}

interface

procedure InitializeConsoleDevice;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Io.Manager,
  Io.Console,
  Kernel.Panic;

function ReadConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Count: Int64;
begin
  Count := ReadFromConsole(PByte(Request.Buffer), Request.Length);
  { Negative: the wait was cut short; the call may be started again. }
  if Count < 0 then
    Exit(ErrorInterrupted);
  Request.Information := Count;
  Result := ErrorNone;
end;

function WriteConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  WriteToConsole(PByte(Request.Buffer), Request.Length);
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

function ControlConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ErrorNone;
  case Request.ControlCode of
    ControlGetConsoleMode:
      Request.Information := GetConsoleMode;
    ControlSetConsoleMode:
      SetConsoleMode(LongWord(Request.ControlArgument));
    ControlGetConsoleSize:
      Request.Information := (Int64(ConsoleRows) shl 16) or ConsoleColumns;
    ControlSetForegroundGroup:
      SetConsoleForegroundGroup(Request.ControlArgument);
    ControlGetForegroundGroup:
      Request.Information := Int64(ConsoleForegroundGroup);
    ControlTakePendingInterrupt:
      if TakePendingInterrupt then
        Request.Information := 1;
  else
    Result := ErrorInvalidArgument;
  end;
end;

procedure AddConsoleDevice(Driver: PDriverObject; Name: PChar);
const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
var
  Device: PDeviceObject;
begin
  Device := CreateDevice(Driver, Name, DeviceKindCharacter, EveryoneReadWrite, 0);
  if Device = nil then
    KernelPanic('could not create the console device');
  Device^.ReportedHandleKind := HandleKindConsole;
  { Waiting on a console handle waits until a read would not wait. }
  Device^.ReadyEvent := ConsoleReadableEvent;
end;

procedure InitializeConsoleDevice;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadConsoleDevice;
  Dispatch[IoFunctionWrite] := @WriteConsoleDevice;
  Dispatch[IoFunctionControl] := @ControlConsoleDevice;
  Driver := CreateDriver('console', Dispatch);
  AddConsoleDevice(Driver, 'console');
  AddConsoleDevice(Driver, 'tty');
end;

end.
