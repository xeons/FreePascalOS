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
  How an idle processor waits.

  The idle thread (Kernel.Startup) calls IdleProcessor over and over.
  It picks the deepest of the processor's idle states (Kernel.Arch.-
  IdleStates: HLT or WFI, then MWAIT C-states or PSCI standby states)
  whose target residency fits in the time to the processor's next clock
  interrupt - with the tick stopped while it idles (Kernel.Clock), that
  is its next due timer or wake-up, so a quiet processor goes deep and
  one about to be woken stays shallow. A device or another processor
  may wake it earlier; the deeper states are chosen only where that
  costs little (their exit latency is a fraction of the expected stay).

  Deciding to wait and waiting are one step: interrupts are disabled
  first, then the processor checks that nothing calls for it to look at
  the ready queues again (a steal refused since it last looked,
  Kernel.ReadyQueues), and the architecture enters the state with
  interrupts enabled only by the instruction that waits (STI; HLT or
  STI; MWAIT on x86-64, where STI takes effect after the next
  instruction; WFI with interrupts masked on AArch64, which wakes for a
  pending one). An interrupt in between stays pending and ends the wait
  at once, so a wake-up cannot slip in between the check and the wait.

  Every processor shares one table of states, found at start
  (InitializeIdleStates) and possibly replaced once the firmware's own
  list is read (SetFirmwareIdleStates, from ACPI's _CST). The idle
  threads read it without a lock: a sequence number, odd while the
  table changes, makes a reader take a copy of the state it chose again
  if the table changed meanwhile, so it never enters a state half
  written. How often each processor entered each state is counted in
  its block (IdleStateEntries) for the power information call.

  States whose clock interrupt stops (IdleStateStopsTimer: deep C-states
  without ARAT, PSCI states that stop the timer or power down) are
  entered only by a processor the boot processor can wake on time
  (Kernel.BroadcastTimer), never by the boot processor itself. Its timer
  is stale afterwards (its clock interrupt time reads NeverDue): the
  next round of the idle loop, or the switch to a thread, sets it again
  (RearmClockInterrupt). The kernel option idlebroadcast=force treats
  every state of the other processors as one whose timer stops, and
  really leaves the timer at its longest (4 s) while they wait, so the
  broadcast is all that wakes them on time: the test of it on machines
  without such states (QEMU); idlebroadcast=off keeps to states whose
  timer runs.
}
unit Kernel.IdleStates;

{$mode objfpc}

interface

uses
  Kernel.IdleStateDefinitions;

{ On the boot processor, once the HAL is ready. }
procedure InitializeIdleStates;
{ One wait of the executing processor (the idle thread's), until an
  interrupt. Interrupts are enabled before and after. }
procedure IdleProcessor;

function IdleStateCount: Integer;
{ State Index of the table (False past its end). }
function GetIdleState(Index: Integer; out State: TIdleState): Boolean;
{ Replaces states 1 and up with the firmware's (state 0, the plain
  halt, stays). }
procedure SetFirmwareIdleStates(constref States: array of TIdleState; Count: Integer);
procedure WriteIdleStates;
{ Entries into states whose timer stops, on every processor. }
function BroadcastIdleEntryCount: QWord;
{ For the self test: as idlebroadcast=force while On. }
procedure SetForcedBroadcast(On: Boolean);
function ForcedBroadcastIsOn: Boolean;

type
  { Runs in the idle thread between the check for work and the wait,
    interrupts disabled, with the processor's index. }
  TIdleWindowHook = procedure(ProcessorIndex: LongWord);

{ For the self tests only: widens the window between deciding to wait
  and waiting, so that a wake-up can be sent into it on purpose (nil
  takes the hook away). }
procedure SetIdleWindowHookForTest(Hook: TIdleWindowHook);

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Processors,
  Kernel.ReadyQueues,
  Kernel.Clock,
  Kernel.Arch.IdleStates,
  Kernel.BroadcastTimer,
  Kernel.Options,
  Runtime.Text,
  Hal.Platform,
  Debug.Output;

var
  States: array[0..MaximumIdleStates - 1] of TIdleState;
  StateCount: PtrUInt = 1;
  { Odd while SetFirmwareIdleStates changes the table (one at a time,
    under ChangeLock). }
  TableSequence: PtrUInt = 0;
  ChangeLock: TSpinLock;
  ForceBroadcast: Boolean = False;
  BroadcastOff: Boolean = False;
  BroadcastEntries: Int64 = 0;
  IdleWindowHook: TIdleWindowHook = nil;

function BroadcastIdleEntryCount: QWord;
begin
  Result := QWord(AtomicFetchAndAdd(BroadcastEntries, 0));
end;

procedure SetForcedBroadcast(On: Boolean);
begin
  ForceBroadcast := On;
end;

function ForcedBroadcastIsOn: Boolean;
begin
  Result := ForceBroadcast;
end;

procedure ReadBroadcastOption;
var
  Value: array[0..15] of Char;
begin
  if not GetKernelOptionValue('idlebroadcast', @Value[0], SizeOf(Value)) then
    Exit;
  ForceBroadcast := TextIsEqual(@Value[0], 'force');
  BroadcastOff := TextIsEqual(@Value[0], 'off');
end;

procedure InitializeIdleStates;
begin
  ReadBroadcastOption;
  InitializeSpinLock(ChangeLock);
  StateCount := 1;
  StateCount := PtrUInt(ArchDiscoverIdleStates(States));
  if StateCount < 1 then
    StateCount := 1;
end;

{ The deepest state worth entering for a stay of Expected nanoseconds
  (only states whose timer runs, unless TimerMayStop). }
function ChooseState(Expected: QWord; TimerMayStop: Boolean): Integer;
var
  Count: Integer;
  Index: Integer;
begin
  Result := 0;
  Count := Integer(AtomicLoad(StateCount));
  Index := 1;
  while Index < Count do
  begin
    if (States[Index].TargetResidencyNanoseconds <= Expected) and
       (TimerMayStop or ((States[Index].Flags and IdleStateStopsTimer) = 0)) then
      Result := Index;
    Inc(Index);
  end;
end;

{ A consistent copy of the state worth entering for a stay of Expected
  nanoseconds, and its number. }
function TakeState(Expected: QWord; TimerMayStop: Boolean; out State: TIdleState): Integer;
var
  Sequence: PtrUInt;
begin
  repeat
    Sequence := AtomicLoad(TableSequence);
    if (Sequence and 1) <> 0 then
    begin
      CpuRelax;
      Continue;
    end;
    Result := ChooseState(Expected, TimerMayStop);
    State := States[Result];
    FullMemoryBarrier;
  until AtomicLoad(TableSequence) = Sequence;
end;

procedure IdleProcessor;
var
  Processor: PProcessor;
  Now: QWord;
  Due: QWord;
  Expected: QWord;
  Chosen: Integer;
  State: TIdleState;
  TimerMayStop: Boolean;
  StopsTimer: Boolean;
begin
  { The idle thread never leaves its processor. }
  Processor := CurrentProcessor;
  DisableInterrupts;
  { Work it may take was left in another queue: no waiting. }
  if StealWasRefused(Processor) then
  begin
    EnableInterrupts;
    Exit;
  end;
  { Wake requests from before this look are for work it will see. }
  ClearWakeRequest(Processor);
  { Its timer stopped in the last wait: set it again first. }
  if Processor^.ClockInterruptTime = NeverDue then
    RearmClockInterrupt;
  Now := ClockNanoseconds;
  Due := Processor^.ClockInterruptTime;
  if Due > Now then
    Expected := Due - Now
  else
    Expected := 0;
  TimerMayStop := not BroadcastOff and BroadcastIsAvailable(Processor);
  Chosen := TakeState(Expected, TimerMayStop, State);
  Inc(Processor^.IdleStateEntries[Chosen]);
  StopsTimer := TimerMayStop and (ForceBroadcast or ((State.Flags and IdleStateStopsTimer) <> 0));
  if StopsTimer then
  begin
    AtomicIncrement(BroadcastEntries);
    EnterBroadcastIdle(Processor);
    { The test: as if the timer had stopped. }
    if ForceBroadcast then
      HalSetClockInterruptIn(NeverDue);
  end;
  if Assigned(IdleWindowHook) then
    IdleWindowHook(Processor^.Index);
  { Enables interrupts as it waits. }
  ArchEnterIdleState(State, Processor^.Index);
  if StopsTimer then
    LeaveBroadcastIdle(Processor);
end;

procedure SetIdleWindowHookForTest(Hook: TIdleWindowHook);
begin
  IdleWindowHook := Hook;
  FullMemoryBarrier;
end;

function IdleStateCount: Integer;
begin
  Result := Integer(AtomicLoad(StateCount));
end;

function GetIdleState(Index: Integer; out State: TIdleState): Boolean;
var
  Sequence: PtrUInt;
begin
  repeat
    Sequence := AtomicLoad(TableSequence);
    if (Sequence and 1) <> 0 then
    begin
      CpuRelax;
      Continue;
    end;
    Result := (Index >= 0) and (Index < IdleStateCount);
    if Result then
      State := States[Index]
    else
      ZeroMemory(@State, SizeOf(State));
    FullMemoryBarrier;
  until AtomicLoad(TableSequence) = Sequence;
end;

procedure SetFirmwareIdleStates(constref States: array of TIdleState; Count: Integer);
var
  Index: Integer;
  PreviousLevel: TPriorityLevel;
  InterruptsWereEnabled: Boolean;
begin
  if Count > MaximumIdleStates - 1 then
    Count := MaximumIdleStates - 1;
  PreviousLevel := AcquireSpinLock(ChangeLock);
  { A reader interrupted on this processor would wait for the change. }
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  AtomicStore(TableSequence, TableSequence + 1);
  FullMemoryBarrier;
  for Index := 0 to Count - 1 do
    Kernel.IdleStates.States[Index + 1] := States[Index];
  AtomicStore(StateCount, PtrUInt(Count + 1));
  FullMemoryBarrier;
  AtomicStore(TableSequence, TableSequence + 1);
  RestoreInterrupts(InterruptsWereEnabled);
  ReleaseSpinLock(ChangeLock, PreviousLevel);
end;

procedure WriteIdleStates;
var
  Index: Integer;
  State: TIdleState;
begin
  DebugBeginMessage;
  DebugWriteTag('idle');
  if ClockIsTickless then
    DebugWrite('tickless idle; states: ')
  else
    DebugWrite('periodic tick (tickless=off); states: ');
  Index := 0;
  while GetIdleState(Index, State) do
  begin
    if Index > 0 then
      DebugWrite(', ');
    DebugWrite(@State.Name[0]);
    if Index > 0 then
    begin
      DebugWrite(' ');
      DebugWriteDecimal(State.ExitLatencyNanoseconds div 1000);
      DebugWrite(' us');
    end;
    Inc(Index);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
