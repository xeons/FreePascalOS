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
  Read and control requests on a terminal device, the same for the
  console (Drivers.ConsoleDevice) and the pseudo-terminals
  (Drivers.PseudoTerminalDevices): reads go through the terminal's line
  discipline, and the control requests (the Abi Control* values for
  consoles) get and set its modes and size, set and get the foreground
  process group, take a pending Ctrl-C and tell a pseudo-terminal's
  number.

  Every terminal device points at its line discipline (TDeviceObject's
  Terminal), which is also how the process layer knows a terminal when
  it sees one (Processes.FileCalls, Processes.TerminalCalls).
}
unit Io.TerminalRequests;

{$mode objfpc}

interface

uses
  Io.Manager,
  Io.LineDiscipline;

function ReadTerminalRequest(var Terminal: TLineDiscipline; var Request: TIoRequest): LongInt;
function ControlTerminalRequest(var Terminal: TLineDiscipline; var Request: TIoRequest): LongInt;

implementation

uses
  Abi.SystemCalls;

const
  LargestTerminalSide = $FFFF;

function ReadTerminalRequest(var Terminal: TLineDiscipline; var Request: TIoRequest): LongInt;
var
  Count: Int64;
begin
  Count := ReadFromTerminal(Terminal, PByte(Request.Buffer), Request.Length);
  { The wait was cut short; the call may be started again. }
  if Count = TerminalTransferInterrupted then
    Exit(ErrorInterrupted);
  Request.Information := Count;
  Result := ErrorNone;
end;

function SetSizeRequest(var Terminal: TLineDiscipline; Argument: QWord): LongInt;
var
  Rows: QWord;
  Columns: QWord;
begin
  Rows := Argument shr 16;
  Columns := Argument and LargestTerminalSide;
  if (Rows = 0) or (Rows > LargestTerminalSide) or (Columns = 0) then
    Exit(ErrorInvalidArgument);
  SetTerminalSize(Terminal, LongWord(Rows), LongWord(Columns));
  Result := ErrorNone;
end;

function ControlTerminalRequest(var Terminal: TLineDiscipline; var Request: TIoRequest): LongInt;
begin
  Result := ErrorNone;
  case Request.ControlCode of
    ControlGetConsoleMode:
      Request.Information := GetTerminalMode(Terminal);
    ControlSetConsoleMode:
      SetTerminalMode(Terminal, LongWord(Request.ControlArgument));
    ControlGetConsoleSize:
      Request.Information := (Int64(Terminal.Rows) shl 16) or Terminal.Columns;
    ControlSetConsoleSize:
      Result := SetSizeRequest(Terminal, Request.ControlArgument);
    ControlSetForegroundGroup:
      SetTerminalForegroundGroup(Terminal, Request.ControlArgument);
    ControlGetForegroundGroup:
      Request.Information := Int64(Terminal.ForegroundGroup);
    ControlTakePendingInterrupt:
      if TakePendingTerminalInterrupt(Terminal) then
        Request.Information := 1;
    ControlGetTerminalNumber:
      if Terminal.Number < 0 then
        Result := ErrorUnsupported
      else
        Request.Information := Terminal.Number;
  else
    Result := ErrorInvalidArgument;
  end;
end;

end.
