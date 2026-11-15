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
  The system console: the terminal on the screen and the serial port.

  Output goes wherever the kernel log goes (serial port and framebuffer).
  Input comes from the keyboard and the serial port. Everything that
  makes it a terminal - line editing, echo, Ctrl-C and Ctrl-Z, the
  modes, the foreground group - is its line discipline
  (Io.LineDiscipline), shared with the pseudo-terminals; echo goes to
  the kernel log's outputs like everything written.

  Input devices hand characters over with DeliverConsoleInput, from their
  interrupt handlers. Until a serial interrupt handler is connected, the
  serial port is also polled every few milliseconds while a reader
  waits; input the serial port has while it is still polled is only seen
  by a read, not by a wait on the console's readiness.
}
unit Io.Console;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.LineDiscipline;

procedure InitializeConsole;

{ The console's line discipline. }
function ConsoleTerminal: PLineDiscipline;
{ The console's readiness for reading (a PEvent): a read would not wait. }
function ConsoleReadableEvent: Pointer;
{ Always signaled (a PEvent): writing to the console never waits. }
function ConsoleWritableEvent: Pointer;

procedure WriteToConsole(Source: PByte; ByteCount: QWord);
{ Returns the number of bytes read, 0 at end of file, or
  TerminalTransferInterrupted when the thread was alerted (its process
  is being ended or stopped) before anything was read. }
function ReadFromConsole(Destination: PByte; ByteCount: QWord): Int64;

{ Adds a typed character to the console's input. May be called at any
  priority level, typically from an interrupt handler. }
procedure DeliverConsoleInput(Character: Char);
{ Called once the serial port delivers its input by interrupt, so it no
  longer needs polling. }
procedure SetSerialInputInterruptDriven;

implementation

uses
  Hal.SerialPort,
  Kernel.Events,
  Kernel.Panic,
  Objects.Manager,
  Debug.Output;

const
  PollIntervalMilliseconds = 10;

type
  TConsole = record
    Terminal: TLineDiscipline;
    Writable: TEvent;
  end;
  PConsole = ^TConsole;

var
  ConsoleObjectType: TObjectType;
  TheConsole: PConsole;

procedure ShowOnConsole(Terminal: PLineDiscipline; Text: PChar; Count: LongWord);
begin
  WriteToConsole(PByte(Text), Count);
end;

function PollSerialPort(Terminal: PLineDiscipline; out Character: Char): Boolean;
begin
  Result := TryReadSerialCharacter(Character);
end;

procedure InitializeConsole;
begin
  RegisterObjectType(ConsoleObjectType, 'Console', SizeOf(TConsole), nil);
  TheConsole := PConsole(CreateObject(ConsoleObjectType, 'Console'));
  if TheConsole = nil then
    KernelPanic('could not create the console');
  InitializeLineDiscipline(TheConsole^.Terminal, -1, TheConsole, @ShowOnConsole);
  TheConsole^.Terminal.PollIntervalMilliseconds := PollIntervalMilliseconds;
  TheConsole^.Terminal.PollInput := @PollSerialPort;
  InitializeEvent(TheConsole^.Writable, EventKindNotification, True);
end;

function ConsoleTerminal: PLineDiscipline;
begin
  Result := @TheConsole^.Terminal;
end;

function ConsoleReadableEvent: Pointer;
begin
  Result := @TheConsole^.Terminal.Readable;
end;

function ConsoleWritableEvent: Pointer;
begin
  Result := @TheConsole^.Writable;
end;

procedure DeliverConsoleInput(Character: Char);
begin
  if TheConsole = nil then
    Exit;
  DeliverTerminalInput(TheConsole^.Terminal, Character);
end;

procedure SetSerialInputInterruptDriven;
begin
  TheConsole^.Terminal.PollInput := nil;
end;

procedure WriteToConsole(Source: PByte; ByteCount: QWord);
var
  Index: QWord;
begin
  DebugBeginMessage;
  Index := 0;
  while Index < ByteCount do
  begin
    DebugWriteCharacter(Char(Source[Index]));
    Inc(Index);
  end;
  DebugEndMessage;
end;

function ReadFromConsole(Destination: PByte; ByteCount: QWord): Int64;
begin
  Result := ReadFromTerminal(TheConsole^.Terminal, Destination, ByteCount);
end;

end.
