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
  hangtest - get stuck on purpose, for checking that a stuck program can
  always be ended

  hangtest [-i] MODE
  hangtest --check [--windows]

  Gets stuck in the way MODE names and never ends by itself; prints
  "hangtest: ready PID MODE" once it is (about to be) stuck. With -i it
  takes requests to end and never reads them, so only ending it
  outright (kill -9, the task manager's End now) stops it. With --check
  it runs every mode in a copy of itself and ends each in every way
  (HangTest.Checks); --windows adds the window modes.

  In the processor:  spin, spin-threads (four threads)
  Kernel waits:      sleep, event, wait-handles (an event, a timer and
                     the notifications), lock (a lock another thread
                     keeps), deadlock (two threads, two locks), thread-join,
                     child-wait, pipe-read, pipe-write, fifo-open,
                     file-lock (a child keeps it), channel, suspended (a
                     thread suspended itself), allocate (memory taken and
                     given back over and over)
  Sockets:           tcp-receive, tcp-receive-thread, tcp-accept,
                     tcp-connect (nobody answers), udp-receive
  Windows:           window-idle (served: ends when asked), window-hung,
                     window-spin, window-lock (not served any more)
}
program hangtest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Notifications,
  Util.CommandLine,
  Util.Messages,
  Sys.Processes,
  HangTest.Report,
  HangTest.Checks,
  HangTest.Waits,
  HangTest.Network,
  HangTest.Windows;

const
  Usage = 'Usage: hangtest [-i] MODE | hangtest --check [--windows]'#10 +
    'Get stuck as MODE says (spin, spin-threads, sleep, event, wait-handles, lock,'#10 +
    'deadlock, thread-join, child-wait, pipe-read, pipe-write, fifo-open, file-lock,'#10 +
    'channel, suspended, allocate, tcp-receive, tcp-receive-thread, tcp-accept,'#10 +
    'tcp-connect, udp-receive, window-idle, window-hung, window-spin, window-lock).'#10 +
    '  -i         take requests to end and ignore them'#10 +
    '  --check    end every mode in every way, and say whether each ended'#10 +
    '  --windows  with --check: the window modes too (needs the display server)'#10;
  OptionIgnore = 1;
  OptionCheck = 2;
  OptionWindows = 3;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Mode: string;
begin
  CommandLine := TCommandLine.Create([CommandOption('i', 'ignore-end', False, OptionIgnore),
    CommandOption(#0, 'check', False, OptionCheck), CommandOption(#0, 'windows', False, OptionWindows)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionIgnore then
      TakeNotifications(NotifyEndRequests);
  if CommandLine.OptionGiven(OptionCheck) then
    ExitProgram(RunChecks(CommandLine.OptionGiven(OptionWindows)));
  if CommandLine.OperandCount <> 1 then
    FailWithUsageHint('one mode is needed');
  Mode := CommandLine.Operands[0];
  if not RunWaitMode(Mode) and not RunNetworkMode(Mode) and not RunWindowMode(Mode) then
    FailWithUsageHint('unknown mode ''' + Mode + '''');
end.
