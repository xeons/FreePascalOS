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
  Self test of suspend to RAM on AArch64 (the kernel option
  suspendtest): the whole way down and back (Processes.Suspend) - the
  drivers' power handlers, every other processor frozen and turned off
  (PSCI CPU_OFF), PSCI SYSTEM_SUSPEND, then each processor started again
  through the start-up entry (CPU_ON), set up again (vectors,
  translation, PAN, its GIC interface, its clock) and resumed where it
  froze. QEMU's PSCI has no SYSTEM_SUSPEND: with psci-suspend=force the
  firmware refuses it, which takes the same way back for every
  processor but the boot one. Afterwards every processor must run a
  thread again.
}
unit Kernel.Arch.SuspendSelfTest;

{$mode objfpc}

interface

{ Runs the test if the option asks for it. }
procedure RunSuspendSelfTestIfAsked;

implementation

uses
  Abi.SystemCalls,
  Kernel.Options,
  Kernel.Processors,
  Kernel.Scheduler,
  Kernel.Threads,
  Kernel.Events,
  Kernel.SelfTest,
  Processes.Thread,
  Processes.Suspend,
  Debug.Output;

const
  WaitMilliseconds = 5000;
  TestThreadPriority = 20;

var
  Arrived: array[0..MaximumProcessors - 1] of TEvent;

{ Moves to the processor whose index is Context and says so. }
procedure VisitProcessor(Context: Pointer);
var
  Index: LongWord;
begin
  Index := LongWord(PtrUInt(Context));
  SetThreadAffinity(CurrentThread, QWord(1) shl Index);
  if CurrentProcessorIndex = Index then
    SignalEvent(Arrived[Index]);
end;

function EveryProcessorRuns: Boolean;
var
  Index: LongWord;
begin
  Result := True;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    if not ProcessorByIndex(Index)^.IsOnline then
      Continue;
    InitializeEvent(Arrived[Index], EventKindNotification, False);
    if CreateSystemThread(@VisitProcessor, Pointer(PtrUInt(Index)), TestThreadPriority, 'SuspendTest',
      False) = nil then
      Exit(False);
    if WaitForEventWithOptions(Arrived[Index], WaitMilliseconds, False) <> WaitSignaled then
      Exit(False);
  end;
end;

procedure RunSuspendSelfTestIfAsked;
var
  Status: LongInt;
  Index: LongWord;
  AllBack: Boolean;
begin
  if not KernelOptionIsSet('suspendtest') then
    Exit;
  Status := SuspendToRam;
  AllBack := True;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline and ProcessorByIndex(Index)^.Frozen then
      AllBack := False;
  Check(AllBack, 'every processor resumed after suspend to RAM');
  Check(EveryProcessorRuns, 'every processor runs threads after suspend to RAM');
  if Status = ErrorNone then
    ReportPassed('suspend to RAM (PSCI SYSTEM_SUSPEND): slept, woke, every processor back')
  else
    ReportPassed('suspend to RAM (PSCI SYSTEM_SUSPEND): the firmware refused, every processor back');
end;

end.
