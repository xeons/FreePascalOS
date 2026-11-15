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
  Terminals and processes: creating a pseudo-terminal
  (CallCreatePseudoTerminal), and knowing a terminal behind a handle.

  A process has a controlling terminal (TProcess.ControllingTerminal, a
  terminal device), inherited from its parent; the first program's is
  the console. A process started with GroupNewInForeground whose
  standard input is a terminal gets that terminal instead, and its new
  group becomes the terminal's foreground group: that is how a terminal
  window starts its shell. The controlling terminal is what /dev/tty
  opens, whose foreground group decides whether reading it stops a
  process (Processes.FileCalls), and whose hang-up ends the process
  (Processes.TerminalSignals).
}
unit Processes.TerminalCalls;

{$mode objfpc}

interface

uses
  Processes.Handles;

function PerformCreatePseudoTerminal(TerminalAddress: QWord; Size: QWord): Int64;

{ The terminal device (a PDeviceObject) behind a handle's object, or nil
  if it is not a terminal. }
function TerminalDeviceOf(Kind: THandleKind; ObjectBody: Pointer): Pointer;

implementation

uses
  Abi.SystemCalls,
  Kernel.Mutex,
  Objects.Manager,
  Io.Manager,
  Io.LineDiscipline,
  Drivers.PseudoTerminalDevices,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess;

const
  LargestTerminalSide = $FFFF;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function TerminalDeviceOf(Kind: THandleKind; ObjectBody: Pointer): Pointer;
var
  OpenFile: PDeviceFile;
begin
  Result := nil;
  if (Kind <> Processes.Handles.HandleKindDevice) or (ObjectBody = nil) then
    Exit;
  OpenFile := PDeviceFile(ObjectBody);
  if OpenFile^.IsDirectory or (OpenFile^.Device = nil) then
    Exit;
  if (OpenFile^.Device^.Terminal <> nil) and (OpenFile^.Device^.ReportedHandleKind = HandleKindConsole) then
    Result := OpenFile^.Device;
end;

{ Rows and columns from the call's Size argument (0: the default). }
function DecodeSize(Size: QWord; out Rows, Columns: LongWord): Boolean;
begin
  Rows := DefaultTerminalRows;
  Columns := DefaultTerminalColumns;
  if Size = 0 then
    Exit(True);
  if ((Size shr 16) = 0) or ((Size shr 16) > LargestTerminalSide) or ((Size and LargestTerminalSide) = 0) then
    Exit(False);
  Rows := LongWord(Size shr 16);
  Columns := LongWord(Size and LargestTerminalSide);
  Result := True;
end;

{ Gives the caller handles to the three device files; False if its table
  is full (then none is left in it). }
function InsertTerminalHandles(OutputFile, InputFile, TerminalFile: PDeviceFile;
  out Description: TAbiPseudoTerminal): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Description.OutputHandle := InsertHandle(Process^.Handles, Processes.Handles.HandleKindDevice, OutputFile, 0);
  Description.InputHandle := InsertHandle(Process^.Handles, Processes.Handles.HandleKindDevice, InputFile, 0);
  Description.TerminalHandle := InsertHandle(Process^.Handles, Processes.Handles.HandleKindDevice, TerminalFile, 0);
  Result := (Description.OutputHandle >= 0) and (Description.InputHandle >= 0) and
    (Description.TerminalHandle >= 0);
  if not Result then
  begin
    CloseHandle(Process^.Handles, Description.OutputHandle);
    CloseHandle(Process^.Handles, Description.InputHandle);
    CloseHandle(Process^.Handles, Description.TerminalHandle);
  end;
  ReleaseMutex(Process^.Lock);
end;

procedure CloseTerminalHandles(const Description: TAbiPseudoTerminal);
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  CloseHandle(Process^.Handles, Description.OutputHandle);
  CloseHandle(Process^.Handles, Description.InputHandle);
  CloseHandle(Process^.Handles, Description.TerminalHandle);
  ReleaseMutex(Process^.Lock);
end;

function PerformCreatePseudoTerminal(TerminalAddress: QWord; Size: QWord): Int64;
var
  Rows: LongWord;
  Columns: LongWord;
  OutputFile: PDeviceFile;
  InputFile: PDeviceFile;
  TerminalFile: PDeviceFile;
  Number: LongInt;
  Error: LongInt;
  Description: TAbiPseudoTerminal;
  Inserted: Boolean;
begin
  if not UserRangeIsValid(TerminalAddress, SizeOf(TAbiPseudoTerminal), True) then
    Exit(Failure(ErrorBadAddress));
  if not DecodeSize(Size, Rows, Columns) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CreatePseudoTerminal(Rows, Columns, OutputFile, InputFile, TerminalFile, Number);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Inserted := InsertTerminalHandles(OutputFile, InputFile, TerminalFile, Description);
  { The handles hold their own references; without them, this closes
    the pair again. }
  DereferenceObject(OutputFile);
  DereferenceObject(InputFile);
  DereferenceObject(TerminalFile);
  if not Inserted then
    Exit(Failure(ErrorTooManyHandles));
  Description.Number := Number;
  Error := CopyToUser(TerminalAddress, @Description, SizeOf(Description));
  if Error <> ErrorNone then
  begin
    CloseTerminalHandles(Description);
    Exit(Failure(Error));
  end;
  Result := 0;
end;

end.
