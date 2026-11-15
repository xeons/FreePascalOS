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
  The console as a device: /dev/console, and /dev/tty, which opens a
  program's controlling terminal (Processes.FileCalls) - the console,
  unless the program runs on a pseudo-terminal.

  Reads and control requests go through the console's line discipline
  (Io.TerminalRequests), writes to the console's output (Io.Console). A
  handle to it can be waited on until a read would not wait (its
  ReadyEvent), or, opened only for writing, until a write would not wait
  (always).

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
  Io.TerminalRequests,
  Kernel.Panic;

function ReadConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ReadTerminalRequest(ConsoleTerminal^, Request);
end;

function WriteConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  WriteToConsole(PByte(Request.Buffer), Request.Length);
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

function ControlConsoleDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ControlTerminalRequest(ConsoleTerminal^, Request);
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
  Device^.Terminal := ConsoleTerminal;
  Device^.ReadyEvent := ConsoleReadableEvent;
  Device^.WritableEvent := ConsoleWritableEvent;
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
