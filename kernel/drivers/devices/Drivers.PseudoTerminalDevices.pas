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
  The devices of the pseudo-terminals (Io.PseudoTerminals).

  The terminal side of pair N is the device ptsN (/dev/ptsN, rw-rw-rw-),
  which programs are told is a console (HandleKindConsole): reads and
  control requests go through its line discipline like the console's
  (Io.TerminalRequests), writes into the pair's output. Its ReadyEvent
  says a read would not wait; its WritableEvent that the output has
  room.

  The master side is a device without a name, of the driver
  `ptmaster`, only opened by CreatePseudoTerminal: once for reading the
  output and once for typing into the terminal, so each handle can be
  waited on for what it is for (ReadyEvent: output to read;
  WritableEvent: room to type). Its control requests are the
  terminal's, so the window's size can be set from either side.

  Both devices of a pair are made the first time the pair is used, and
  kept for its later uses.
}
unit Drivers.PseudoTerminalDevices;

{$mode objfpc}

interface

uses
  Io.Manager;

procedure InitializePseudoTerminalDevices;

{ A new pseudo-terminal of Rows by Columns: the master side opened for
  reading (OutputFile) and for writing (InputFile), and the terminal side
  opened for both (TerminalFile); each device file has one reference for
  the caller. Returns ErrorNone, ErrorBusy (all taken) or another Abi
  error. }
function CreatePseudoTerminal(Rows, Columns: LongWord; out OutputFile, InputFile, TerminalFile: PDeviceFile;
  out Number: LongInt): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Objects.Manager,
  Io.DeviceFiles,
  Io.LineDiscipline,
  Io.TerminalRequests,
  Io.PseudoTerminals;

const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
  OwnerReadWrite = $180; { rw------- }

var
  MasterDriver: PDriverObject;
  TerminalDriver: PDriverObject;

function PairOf(Device: PDeviceObject): PPseudoTerminal;
begin
  Result := PPseudoTerminal(Device^.Extension);
end;

{ --- The master side ------------------------------------------------------ }

function OpenMaster(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  NoteMasterOpened(PairOf(Device));
  Result := ErrorNone;
end;

function CloseMaster(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  NoteMasterClosed(PairOf(Device));
  Result := ErrorNone;
end;

function ReadMaster(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Count: Int64;
begin
  Count := ReadPseudoTerminalOutput(PairOf(Device), PByte(Request.Buffer), Request.Length);
  if Count = PseudoTerminalInterrupted then
    Exit(ErrorInterrupted);
  Request.Information := Count;
  Result := ErrorNone;
end;

function WriteMaster(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Count: Int64;
begin
  Count := WriteTerminalInput(PairOf(Device)^.Terminal, PByte(Request.Buffer), Request.Length);
  if Count = TerminalTransferInterrupted then
    Exit(ErrorInterrupted);
  Request.Information := Count;
  Result := ErrorNone;
end;

function ControlMaster(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ControlTerminalRequest(PairOf(Device)^.Terminal, Request);
end;

{ --- The terminal side --------------------------------------------------- }

function OpenTerminalSide(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := NoteTerminalOpened(PairOf(Device));
end;

function CloseTerminalSide(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  NoteTerminalClosed(PairOf(Device));
  Result := ErrorNone;
end;

function ReadTerminalSide(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ReadTerminalRequest(PairOf(Device)^.Terminal, Request);
end;

function WriteTerminalSide(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Count: Int64;
begin
  Count := WritePseudoTerminalOutput(PairOf(Device), PByte(Request.Buffer), Request.Length, True);
  if Count = PseudoTerminalInterrupted then
    Exit(ErrorInterrupted);
  if Count = PseudoTerminalHungUp then
    Exit(ErrorIo);
  Request.Information := Count;
  Result := ErrorNone;
end;

function ControlTerminalSide(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Result := ControlTerminalRequest(PairOf(Device)^.Terminal, Request);
end;

{ --- Making them ------------------------------------------------------------ }

procedure InitializePseudoTerminalDevices;
var
  Dispatch: TDispatchTable;
begin
  InitializePseudoTerminals;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionOpen] := @OpenMaster;
  Dispatch[IoFunctionClose] := @CloseMaster;
  Dispatch[IoFunctionRead] := @ReadMaster;
  Dispatch[IoFunctionWrite] := @WriteMaster;
  Dispatch[IoFunctionControl] := @ControlMaster;
  MasterDriver := CreateDriver('ptmaster', Dispatch);
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionOpen] := @OpenTerminalSide;
  Dispatch[IoFunctionClose] := @CloseTerminalSide;
  Dispatch[IoFunctionRead] := @ReadTerminalSide;
  Dispatch[IoFunctionWrite] := @WriteTerminalSide;
  Dispatch[IoFunctionControl] := @ControlTerminalSide;
  TerminalDriver := CreateDriver('pts', Dispatch);
end;

{ Makes the two devices of a pair used for the first time. }
function MakeDevices(Pair: PPseudoTerminal): Boolean;
var
  Name: array[0..DeviceNameLength - 1] of Char;
  NumberText: TNumberText;
  Master: PDeviceObject;
  TerminalSide: PDeviceObject;
begin
  CopyText(@Name[0], 'pts', DeviceNameLength);
  CopyText(@Name[3], FormatDecimal(QWord(Pair^.Number), NumberText), DeviceNameLength - 3);
  Master := CreateDevice(MasterDriver, nil, DeviceKindCharacter, OwnerReadWrite, 0);
  if Master = nil then
    Exit(False);
  TerminalSide := CreateDevice(TerminalDriver, @Name[0], DeviceKindCharacter, EveryoneReadWrite, 0);
  if TerminalSide = nil then
    Exit(False);
  Master^.Extension := Pair;
  Master^.ReadyEvent := @Pair^.OutputReadable;
  Master^.WritableEvent := @Pair^.Terminal.InputRoom;
  TerminalSide^.Extension := Pair;
  TerminalSide^.ReportedHandleKind := HandleKindConsole;
  TerminalSide^.Terminal := @Pair^.Terminal;
  TerminalSide^.ReadyEvent := @Pair^.Terminal.Readable;
  TerminalSide^.WritableEvent := @Pair^.OutputRoom;
  Pair^.MasterDevice := Master;
  Pair^.TerminalDevice := TerminalSide;
  Result := True;
end;

function CreatePseudoTerminal(Rows, Columns: LongWord; out OutputFile, InputFile, TerminalFile: PDeviceFile;
  out Number: LongInt): LongInt;
var
  Pair: PPseudoTerminal;
begin
  OutputFile := nil;
  InputFile := nil;
  TerminalFile := nil;
  Number := -1;
  Pair := ReservePseudoTerminal;
  if Pair = nil then
    Exit(ErrorBusy);
  if (Pair^.MasterDevice = nil) and not MakeDevices(Pair) then
  begin
    ReleasePseudoTerminal(Pair);
    Exit(ErrorOutOfMemory);
  end;
  SetTerminalSize(Pair^.Terminal, Rows, Columns);
  { If any open fails, dropping the ones that worked closes them, which
    hangs the terminal up and frees the pair. }
  Result := OpenDevice(PDeviceObject(Pair^.MasterDevice), OpenRead, OutputFile);
  if Result = ErrorNone then
    Result := OpenDevice(PDeviceObject(Pair^.MasterDevice), OpenWrite, InputFile);
  if Result = ErrorNone then
    Result := OpenDevice(PDeviceObject(Pair^.TerminalDevice), OpenRead or OpenWrite, TerminalFile);
  if Result <> ErrorNone then
  begin
    if OutputFile = nil then
      ReleasePseudoTerminal(Pair);
    if OutputFile <> nil then
      DereferenceObject(OutputFile);
    if InputFile <> nil then
      DereferenceObject(InputFile);
    OutputFile := nil;
    InputFile := nil;
    Exit;
  end;
  Number := Pair^.Number;
end;

end.
