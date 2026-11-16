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
  The shell a terminal window runs: a pseudo-terminal (Sys.PseudoTerminals)
  with the shell started on it.

  The message loop watches the master side (Windowing.HandleWatches):
  what programs wrote goes to OnOutput as soon as it is there. What is
  typed waits in a buffer of the session's own and goes to the terminal
  whenever it has room, so a shell busy with something else never holds
  up the window. When the shell ends (its process handle is ready), the
  output left is read and OnEnded follows. Closing the session closes
  the master side, which hangs the terminal up: the shell and what it
  runs end.
}
unit Terminal.Session;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls;

type
  TOutputEvent = procedure(Data: PByte; Count: LongInt) of object;
  TSessionEndedEvent = procedure(ExitCode: LongInt) of object;

  TTerminalSession = class
  private
    FTerminal: TAbiPseudoTerminal;
    FShell: Int64;
    FPendingInput: string;
    FWatchingInput: Boolean;
    FRunning: Boolean;
    FOnOutput: TOutputEvent;
    FOnEnded: TSessionEndedEvent;
    procedure OutputReady(Handle: Int64);
    procedure InputReady(Handle: Int64);
    procedure ShellEnded(Handle: Int64);
    function ReadOutput: Boolean;
    procedure WritePendingInput;
    procedure StopWatching;
  public
    constructor Create;
    destructor Destroy; override;
    { Makes the pseudo-terminal and starts ShellPath on it. Returns 0 or
      an error code. }
    function Start(const ShellPath: string; Rows, Columns: LongInt): LongInt;
    procedure Send(const Bytes: string);
    { Tells the terminal its window's new size. }
    procedure Resize(Rows, Columns: LongInt);
    { Hangs up: the master side is closed. Returns the shell's exit code
      if it ended within TimeoutMilliseconds, else -1. }
    function Close(TimeoutMilliseconds: QWord): LongInt;
    { The terminal's number (/dev/ptsN). }
    property Number: Int64 read FTerminal.Number;
    property Running: Boolean read FRunning;
    property OnOutput: TOutputEvent read FOnOutput write FOnOutput;
    property OnEnded: TSessionEndedEvent read FOnEnded write FOnEnded;
  end;

implementation

uses
  Sys.Kernel,
  Sys.Console,
  Sys.Objects,
  Sys.Processes,
  Sys.PseudoTerminals,
  Windowing.HandleWatches;

const
  ReadChunkBytes = 16 * 1024;

constructor TTerminalSession.Create;
begin
  inherited Create;
  FTerminal.OutputHandle := NoHandle;
  FTerminal.InputHandle := NoHandle;
  FTerminal.TerminalHandle := NoHandle;
  FTerminal.Number := -1;
  FShell := NoHandle;
end;

destructor TTerminalSession.Destroy;
begin
  Close(0);
  inherited Destroy;
end;

function TTerminalSession.Start(const ShellPath: string; Rows, Columns: LongInt): LongInt;
var
  Arguments: array[0..1] of PChar;
begin
  Result := CreatePseudoTerminal(Rows, Columns, FTerminal);
  if Result <> ErrorNone then
    Exit;
  Arguments[0] := PChar(ShellPath);
  Arguments[1] := nil;
  FShell := StartOnTerminal(PChar(ShellPath), @Arguments[0], FTerminal.TerminalHandle);
  { Only the shell (and what it starts) holds the terminal now. }
  KernelClose(FTerminal.TerminalHandle);
  FTerminal.TerminalHandle := NoHandle;
  if FShell < 0 then
  begin
    Result := LongInt(-FShell);
    FShell := NoHandle;
    Close(0);
    Exit;
  end;
  FRunning := True;
  WatchHandle(FTerminal.OutputHandle, @OutputReady);
  WatchHandle(FShell, @ShellEnded);
  Result := ErrorNone;
end;

{ Reads once (the handle is ready, so it does not wait); False at the
  end of the output. }
function TTerminalSession.ReadOutput: Boolean;
var
  Buffer: array[0..ReadChunkBytes - 1] of Byte;
  Count: Int64;
begin
  Count := KernelRead(FTerminal.OutputHandle, @Buffer[0], SizeOf(Buffer));
  Result := Count > 0;
  if Result and Assigned(FOnOutput) then
    FOnOutput(@Buffer[0], LongInt(Count));
end;

procedure TTerminalSession.OutputReady(Handle: Int64);
begin
  { End of the output: every program on the terminal is gone; the
    shell's handle says so too. }
  if not ReadOutput then
    StopWatchingHandle(FTerminal.OutputHandle);
end;

procedure TTerminalSession.ShellEnded(Handle: Int64);
var
  ExitCode: LongInt;
begin
  StopWatching;
  { What the shell wrote last is shown before the window goes. }
  while (WaitForHandles([FTerminal.OutputHandle], 0) = 0) and ReadOutput do
    ;
  ExitCode := -1;
  WaitForProgramWithTimeout(FShell, 0, ExitCode);
  FRunning := False;
  if Assigned(FOnEnded) then
    FOnEnded(ExitCode);
end;

procedure TTerminalSession.WritePendingInput;
var
  Written: Int64;
begin
  if FPendingInput = '' then
    Exit;
  Written := KernelWrite(FTerminal.InputHandle, PChar(FPendingInput), Length(FPendingInput));
  if Written > 0 then
    Delete(FPendingInput, 1, Written)
  else
    { Nobody will read it: the terminal is gone. }
    FPendingInput := '';
end;

procedure TTerminalSession.InputReady(Handle: Int64);
begin
  WritePendingInput;
  if FPendingInput = '' then
  begin
    StopWatchingHandle(FTerminal.InputHandle);
    FWatchingInput := False;
  end;
end;

procedure TTerminalSession.Send(const Bytes: string);
begin
  if not FRunning or (Bytes = '') then
    Exit;
  FPendingInput := FPendingInput + Bytes;
  { Written when the terminal has room (now, usually: the loop finds the
    handle ready before it waits). }
  if not FWatchingInput then
    FWatchingInput := WatchHandle(FTerminal.InputHandle, @InputReady);
end;

procedure TTerminalSession.Resize(Rows, Columns: LongInt);
begin
  if FTerminal.InputHandle >= 0 then
    SetConsoleSize(FTerminal.InputHandle, Rows, Columns);
end;

procedure TTerminalSession.StopWatching;
begin
  StopWatchingHandle(FTerminal.OutputHandle);
  StopWatchingHandle(FTerminal.InputHandle);
  StopWatchingHandle(FShell);
  FWatchingInput := False;
end;

function TTerminalSession.Close(TimeoutMilliseconds: QWord): LongInt;
var
  ExitCode: LongInt;
begin
  StopWatching;
  if FTerminal.OutputHandle >= 0 then
    KernelClose(FTerminal.OutputHandle);
  if FTerminal.InputHandle >= 0 then
    KernelClose(FTerminal.InputHandle);
  FTerminal.OutputHandle := NoHandle;
  FTerminal.InputHandle := NoHandle;
  Result := -1;
  if FShell >= 0 then
  begin
    if WaitForProgramWithTimeout(FShell, TimeoutMilliseconds, ExitCode) = ErrorNone then
      Result := ExitCode;
    CloseHandle(FShell);
    FShell := NoHandle;
  end;
  FRunning := False;
end;

end.
