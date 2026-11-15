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
  ptytest - checks pseudo-terminals without a display

  ptytest

  Opens a pseudo-terminal and checks what its two sides are (a console
  for programs, waitable for reading and for typing), the window size
  set on the master side and seen on the terminal, then starts an
  interactive shell on it and types through the master: a command's echo
  and output, tty and stty size inside, /dev/tty as the controlling
  terminal, cat in line editing mode ended by Ctrl-D, Ctrl-C ending a
  sleeping program, and the hang-up when the master is closed (the shell
  ends with status 129). Then a second pseudo-terminal (the first one,
  reused) whose program ends: reading the master gives end of file.

  Each check prints a line; the exit status is 1 if any failed.
}
program PtyTest;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Console,
  Sys.Format,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes,
  Sys.PseudoTerminals,
  Sys.Streams,
  Sys.Time;

const
  ReplyTimeout = 10000;
  ShellPath: PChar = '/bin/sh';
  Prompt = '$ ';

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  Terminal: TAbiPseudoTerminal;
  { Everything read from the master since the last ExpectOutput that
    matched, so each check only looks at what came after. }
  Received: string;

procedure Check(Name: PChar; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteFormatted(StandardOutput, 'ptytest: pass: %s'#10, [ArgumentText(Name)])
  else
  begin
    WriteFormatted(StandardOutput, 'ptytest: FAIL: %s'#10, [ArgumentText(Name)]);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

{ Two hexadecimal digits. }
function IntToHexText(Value: Integer): string;
const
  Digits: PChar = '0123456789ABCDEF';
begin
  Result := Digits[(Value shr 4) and 15] + Digits[Value and 15];
end;

{ What came since the last match, for a failure's explanation. }
procedure ShowReceived;
var
  Shown: string;
  Index: Integer;
begin
  Shown := '';
  for Index := 1 to Length(Received) do
    if Received[Index] < ' ' then
      Shown := Shown + '<' + IntToHexText(Ord(Received[Index])) + '>'
    else
      Shown := Shown + Received[Index];
  WriteFormatted(StandardOutput, 'ptytest: received: %s'#10, [ArgumentText(PChar(Shown))]);
end;

{ Reads from the master until Expected appears in what came, or
  TimeoutMilliseconds pass. What came up to the end of the match is
  dropped. }
function ExpectOutput(const Expected: string; TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
  Buffer: array[0..1023] of Char;
  Count: Int64;
  Found: Integer;
  Remaining: Int64;
begin
  Deadline := UptimeMilliseconds + TimeoutMilliseconds;
  repeat
    Found := Pos(Expected, Received);
    if Found > 0 then
    begin
      Delete(Received, 1, Found + Length(Expected) - 1);
      Exit(True);
    end;
    Remaining := Int64(Deadline) - Int64(UptimeMilliseconds);
    if Remaining <= 0 then
      Break;
    if WaitForHandles([Terminal.OutputHandle], Remaining) <> 0 then
      Break;
    Count := KernelRead(Terminal.OutputHandle, @Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    Received := Received + Copy(Buffer, 0, Count);
  until False;
  ShowReceived;
  Result := False;
end;

procedure TypeText(const Text: string);
begin
  KernelWrite(Terminal.InputHandle, PChar(Text), Length(Text));
end;

procedure TestSides;
var
  Rows: LongInt;
  Columns: LongInt;
  Path: array[0..15] of Char;
  Opened: Int64;
  Line: array[0..15] of Char;
begin
  Check('created', CreatePseudoTerminal(24, 80, Terminal) = 0);
  Check('three handles and a number', (Terminal.OutputHandle >= 0) and (Terminal.InputHandle >= 0) and
    (Terminal.TerminalHandle >= 0) and (Terminal.Number >= 0));
  Check('the terminal side is a console', KernelGetHandleKind(Terminal.TerminalHandle) = HandleKindConsole);
  Check('the master side is not', KernelGetHandleKind(Terminal.OutputHandle) <> HandleKindConsole);
  Check('both sides know the number', (TerminalNumber(Terminal.TerminalHandle) = Terminal.Number) and
    (TerminalNumber(Terminal.InputHandle) = Terminal.Number) and (TerminalNumber(StandardInputHandle) = -1));
  GetConsoleSize(Terminal.TerminalHandle, Rows, Columns);
  Check('the size it was made with', (Rows = 24) and (Columns = 80));
  Check('the size set on the master side', SetConsoleSize(Terminal.InputHandle, 30, 100) = 0);
  GetConsoleSize(Terminal.TerminalHandle, Rows, Columns);
  Check('is seen on the terminal side', (Rows = 30) and (Columns = 100));
  Check('a size of nothing is refused', SetConsoleSize(Terminal.TerminalHandle, 0, 10) <> 0);
  Check('nothing to read yet', WaitForHandles([Terminal.OutputHandle], 0) = -ErrorTimedOut);
  Check('room to type', WaitForHandles([Terminal.InputHandle], 0) = 0);
  Check('nothing typed yet', WaitForHandles([Terminal.TerminalHandle], 0) = -ErrorTimedOut);
  PseudoTerminalPath(Terminal.Number, @Path[0]);
  Opened := KernelOpen(@Path[0], OpenRead or OpenWrite);
  Check('the terminal opens by its path', Opened >= 0);
  Check('a program writing to the terminal', KernelWrite(Opened, PChar('out'#10), 4) = 4);
  Check('is read on the master side', ExpectOutput('out'#10, ReplyTimeout));
  TypeText('in'#127'n'#13);
  Check('typed: readable in line editing mode once Enter is pressed',
    WaitForHandles([Opened], ReplyTimeout) = 0);
  Check('the edited line is read', (KernelRead(Opened, @Line[0], SizeOf(Line)) = 3) and (Line[0] = 'i') and
    (Line[1] = 'n') and (Line[2] = #10));
  Check('and was echoed as it was edited', ExpectOutput('in'#8' '#8'n'#10, ReplyTimeout));
  KernelClose(Opened);
end;

function StartShell: Int64;
var
  Arguments: array[0..1] of PChar;
begin
  Arguments[0] := ShellPath;
  Arguments[1] := nil;
  Result := StartOnTerminal(ShellPath, @Arguments[0], Terminal.TerminalHandle);
end;

procedure TestShell;
var
  Shell: Int64;
  Path: array[0..15] of Char;
  Start: QWord;
  ExitCode: LongInt;
begin
  Shell := StartShell;
  Check('a shell started on the terminal', Shell >= 0);
  KernelClose(Terminal.TerminalHandle);
  Check('it prompts', ExpectOutput(Prompt, ReplyTimeout));
  Check('the shell is the foreground group', GetForegroundGroup(Terminal.InputHandle) = ProcessIdOf(Shell));

  TypeText('echo hi'#13);
  Check('a command typed is echoed', ExpectOutput('echo hi', ReplyTimeout));
  Check('and its output follows', ExpectOutput(#10'hi'#10, ReplyTimeout));
  Check('then the prompt again', ExpectOutput(Prompt, ReplyTimeout));

  PseudoTerminalPath(Terminal.Number, @Path[0]);
  TypeText('tty; stty size'#13);
  Check('tty names the pseudo-terminal', ExpectOutput(#10 + string(PChar(@Path[0])) + #10, ReplyTimeout));
  Check('stty size gives the size the master set', ExpectOutput('30 100'#10, ReplyTimeout));
  Check('prompt after tty', ExpectOutput(Prompt, ReplyTimeout));

  TypeText('echo through-tty > /dev/tty'#13);
  Check('/dev/tty is the controlling terminal', ExpectOutput(#10'through-tty'#10, ReplyTimeout));
  Check('prompt after /dev/tty', ExpectOutput(Prompt, ReplyTimeout));

  TypeText('cat'#13);
  Check('cat started', ExpectOutput('cat'#10, ReplyTimeout));
  TypeText('abc'#13);
  Check('a line to cat is echoed', ExpectOutput('abc'#10, ReplyTimeout));
  { cat writes what it read once its buffer is full or its input ends. }
  TypeText(#4);
  Check('Ctrl-D ends cat''s input: it writes the line back', ExpectOutput('abc'#10, ReplyTimeout));
  Check('and ends', ExpectOutput(Prompt, ReplyTimeout));

  TypeText('sleep 30'#13);
  Check('sleep started', ExpectOutput('sleep 30'#10, ReplyTimeout));
  { Once it runs, its group is the terminal's foreground group. }
  Start := UptimeMilliseconds;
  while (GetForegroundGroup(Terminal.InputHandle) = ProcessIdOf(Shell)) and
        (UptimeMilliseconds - Start < ReplyTimeout) do
    SleepMilliseconds(20);
  Check('and is the foreground group', GetForegroundGroup(Terminal.InputHandle) <> ProcessIdOf(Shell));
  Start := UptimeMilliseconds;
  TypeText(#3);
  Check('Ctrl-C through the master interrupts it', ExpectOutput('^C'#10, ReplyTimeout));
  TypeText('echo status $?'#13);
  Check('which ended with status 130', ExpectOutput('status 130'#10, ReplyTimeout));
  Check('well before its time', UptimeMilliseconds - Start < 15000);
  Check('prompt after Ctrl-C', ExpectOutput(Prompt, ReplyTimeout));

  { Hanging up: both master handles closed. }
  KernelClose(Terminal.OutputHandle);
  KernelClose(Terminal.InputHandle);
  Check('closing the master ends the shell',
    WaitForProgramWithTimeout(Shell, ReplyTimeout, ExitCode) = ErrorNone);
  Check('with status 129 (hang-up)', ExitCode = 129);
  CloseHandle(Shell);
end;

procedure TestEndOfOutput;
var
  FirstNumber: Int64;
  Child: Int64;
  Arguments: array[0..3] of PChar;
  ExitCode: LongInt;
  Buffer: array[0..63] of Char;
begin
  FirstNumber := Terminal.Number;
  Received := '';
  Check('a second pseudo-terminal', CreatePseudoTerminal(25, 80, Terminal) = 0);
  Check('the first one is reused', Terminal.Number = FirstNumber);
  Arguments[0] := ShellPath;
  Arguments[1] := '-c';
  Arguments[2] := 'echo bye';
  Arguments[3] := nil;
  Child := StartOnTerminal(ShellPath, @Arguments[0], Terminal.TerminalHandle);
  KernelClose(Terminal.TerminalHandle);
  Check('a program on it', Child >= 0);
  Check('writes', ExpectOutput('bye'#10, ReplyTimeout));
  Check('and ends', WaitForProgramWithTimeout(Child, ReplyTimeout, ExitCode) = ErrorNone);
  Check('then the master is ready to read', WaitForHandles([Terminal.OutputHandle], ReplyTimeout) = 0);
  Check('and reads end of file', KernelRead(Terminal.OutputHandle, @Buffer[0], SizeOf(Buffer)) = 0);
  CloseHandle(Child);
  KernelClose(Terminal.OutputHandle);
  KernelClose(Terminal.InputHandle);
end;

begin
  Received := '';
  TestSides;
  TestShell;
  TestEndOfOutput;
  WriteFormatted(StandardOutput, 'ptytest: %d of %d checks passed'#10, [ArgumentNumber(Checks - Failures),
    ArgumentNumber(Checks)]);
  if Failures > 0 then
    Halt(1);
end.
