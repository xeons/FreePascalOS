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
  The broadcast timer: waking processors whose own clock interrupt stops
  in their idle state.

  In the deepest idle states a processor's local timer stops (x86-64
  C-states without ARAT; on AArch64 states marked local-timer-stop, and
  every power-down state). Such a processor would sleep through its next
  timer. So before it enters one it hands its next due time (the time
  its clock interrupt was set for) to the boot processor, which never
  enters those states and keeps time anyway: EnterBroadcastIdle records
  it in a table, one slot per processor, and if it is earlier than the
  boot processor's own next clock interrupt, asks the boot processor
  (a flag and its dispatch interrupt, ServeBroadcastRequest) to bring
  that interrupt forward. The boot processor's clock interrupt
  (ServeBroadcast) sends each processor whose time has come its dispatch
  interrupt, which ends the idle state, and its next interrupt is set
  for the earliest time still in the table (NextBroadcastDue, part of
  its next clock deadline, Kernel.Clock).

  Where the platform has a timer of its own that runs in every idle
  state (the HPET's comparator on x86-64, Hal.HpetEventTimer), that
  timer does the boot processor's part instead (StartBroadcastDevice,
  once device interrupts can be routed): EnterBroadcastIdle asks it for
  an interrupt by the processor's due time if that is earlier than the
  one it is set for (DeviceDue, under DeviceLock), and its interrupt
  (ServeBroadcastDevice, on the boot processor) wakes the processors
  due and sets it for the next due time in the table. The boot
  processor then may enter those states too (its own due time goes in
  the table like any other), and its clock no longer wakes for the
  others. One comparator serves every processor. Kernel option
  broadcasttimer=boot keeps the boot processor's clock instead.

  The device cannot lose a wake-up either: a processor writes its slot
  before it looks at DeviceDue (under the lock), and the interrupt sets
  DeviceDue to never (under the lock) before it reads the table, so
  either the interrupt sees the slot or the processor sees never and
  sets the device itself.

  Recording and checking cannot lose a wake-up: the slot is written
  before the boot processor's next interrupt time is read (a full
  barrier), and a dispatch interrupt sent before the processor waits
  stays pending and ends the wait at once. One sent after the processor
  woke for another reason is merely an extra dispatch interrupt.

  The processor's own timer is then stale: EnterBroadcastIdle marks its
  clock interrupt time as never, so whatever comes next sets it again
  (Kernel.Clock.RearmClockInterrupt from the idle loop, or the switch
  away from the idle thread).

  Power-down tested on QEMU (kernel option idle=powerdown-test,
  AArch64): there the processor turns itself off (PSCI CPU_OFF) instead
  of suspending, since QEMU's CPU_SUSPEND never powers down, and
  whatever would wake it (its due time here, a thread made ready for it,
  Kernel.InterProcessor) starts it again with CPU_ON through the same
  entry point a real power-down state returns to (WakePoweredDownProcessor).
}
unit Kernel.BroadcastTimer;

{$mode objfpc}

interface

uses
  Kernel.Processors;

{ True if Processor may enter a state whose timer stops: it is not the
  boot processor, which keeps the time, and that one runs. }
function BroadcastIsAvailable(Processor: PProcessor): Boolean;
{ Interrupts disabled, about to wait in such a state. }
procedure EnterBroadcastIdle(Processor: PProcessor);
{ Back from it (interrupts may be enabled). }
procedure LeaveBroadcastIdle(Processor: PProcessor);
{ The boot processor's clock interrupt: wakes the processors due by
  Now. }
procedure ServeBroadcast(Now: QWord);
{ The earliest due time in the table after Now (NeverDue if none). }
function NextBroadcastDue(Now: QWord): QWord;
{ The boot processor's dispatch interrupt: brings its clock interrupt
  forward if a processor asked. }
procedure ServeBroadcastRequest;
{ How many times a processor was woken by the broadcast. }
function BroadcastWakeCount: QWord;
{ On the boot processor, once device interrupts can be routed: the
  platform's timer takes the broadcast over where there is one. }
procedure StartBroadcastDevice;
{ The broadcast is the platform timer's, not the boot processor's. }
function BroadcastUsesDevice: Boolean;
{ "boot processor", or the platform timer ("HPET comparator 2 (...)"). }
procedure DescribeBroadcastTimer(Text: PChar; Capacity: LongWord);

{ The QEMU power-down test (see above): the processor is off now, or
  on its way there. }
procedure NotePoweredDown(Processor: PProcessor);
procedure NotePoweredUp(Processor: PProcessor);
{ Starts Processor again if it is powered down; True if it was (and
  nothing else needs to be sent to it). Notes the request either way. }
function WakePoweredDownProcessor(Processor: PProcessor): Boolean;
{ The idle loop, before it decides to wait: requests from before are
  for work it is about to look at. }
procedure ClearWakeRequest(Processor: PProcessor);
{ After NotePoweredDown, just before turning off: False if a wake was
  asked for meanwhile (or Pending says an interrupt waits), and the
  processor is back on and must not turn off. }
function PowerDownMayProceed(Processor: PProcessor; Pending: Boolean): Boolean;
{ Set by the architecture: starts a powered-down processor again;
  False if the firmware refused (still on its way off). }
type
  TPowerUpRoutine = function(Processor: PProcessor): Boolean;
procedure SetPowerUpRoutine(Routine: TPowerUpRoutine);

implementation

uses
  Runtime.Atomic,
  Runtime.Text,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.Options,
  Kernel.Clock,
  Debug.Output;

const
  PowerStateOn = 0;
  PowerStateOff = 1;
  PowerStateWaking = 2;
  LongestPowerUpNanoseconds = 50 * 1000000;
  PowerUpRetryNanoseconds = 1000000;
  { The power-down test: a processor that is off takes no device
    interrupt, so it is started again at least this often. }
  LongestTestOffNanoseconds = 20 * 1000000;

var
  DueTimes: array[0..MaximumProcessors - 1] of PtrUInt;
  PowerStates: array[0..MaximumProcessors - 1] of PtrUInt;
  WakeRequests: array[0..MaximumProcessors - 1] of PtrUInt;
  ReprogramRequested: PtrUInt = 0;
  WakeCount: Int64 = 0;
  Initialized: Boolean = False;
  PowerUp: TPowerUpRoutine = nil;
  UsesDevice: Boolean = False;
  DeviceLock: TSpinLock;
  { The time the device is set to interrupt by. }
  DeviceDue: QWord = NeverDue;

procedure InitializeTable;
var
  Index: Integer;
begin
  for Index := 0 to MaximumProcessors - 1 do
    DueTimes[Index] := PtrUInt(NeverDue);
  Initialized := True;
end;

function BroadcastIsAvailable(Processor: PProcessor): Boolean;
var
  Owner: PProcessor;
begin
  if Processor^.Index >= MaximumProcessors then
    Exit(False);
  if UsesDevice then
    Exit(True);
  if Processor^.Index = 0 then
    Exit(False);
  Owner := ProcessorByIndex(0);
  Result := (Owner <> nil) and Owner^.IsOnline;
end;

{ The device interrupts by Due at the latest. }
procedure RequestDeviceBy(Due: QWord);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(DeviceLock);
  if Due < DeviceDue then
  begin
    DeviceDue := Due;
    HalSetBroadcastTimerAt(Due);
  end;
  ReleaseSpinLockAtCurrentLevel(DeviceLock);
  RestoreInterrupts(WereEnabled);
end;

procedure EnterBroadcastIdle(Processor: PProcessor);
var
  Owner: PProcessor;
  Due: QWord;
begin
  if not Initialized then
    InitializeTable;
  Due := Processor^.ClockInterruptTime;
  if (PowerUp <> nil) and (Due > ClockNanoseconds + LongestTestOffNanoseconds) then
    Due := ClockNanoseconds + LongestTestOffNanoseconds;
  AtomicStore(DueTimes[Processor^.Index], PtrUInt(Due));
  { Its own timer is stale from here: the next one to set it sets it
    again in full. }
  Processor^.ClockInterruptTime := NeverDue;
  FullMemoryBarrier;
  if UsesDevice then
  begin
    RequestDeviceBy(Due);
    Exit;
  end;
  Owner := ProcessorByIndex(0);
  if Due < Owner^.ClockInterruptTime then
  begin
    AtomicExchange(ReprogramRequested, 1);
    HalRequestDispatchOn(Owner^.ApicId);
  end;
end;

procedure LeaveBroadcastIdle(Processor: PProcessor);
begin
  AtomicStore(DueTimes[Processor^.Index], PtrUInt(NeverDue));
end;

procedure WakeProcessor(Processor: PProcessor);
begin
  if not WakePoweredDownProcessor(Processor) then
    HalRequestDispatchOn(Processor^.ApicId);
  AtomicIncrement(WakeCount);
end;

procedure ServeBroadcast(Now: QWord);
var
  Index: LongWord;
  Due: PtrUInt;
  Processor: PProcessor;
begin
  if not Initialized then
    Exit;
  { From 0: the boot processor has a slot too when the device wakes. }
  Index := 0;
  while (Index < ProcessorTotal) and (Index < MaximumProcessors) do
  begin
    Due := AtomicLoad(DueTimes[Index]);
    if (QWord(Due) <= Now) and
       (AtomicCompareExchange(DueTimes[Index], PtrUInt(NeverDue), Due) = Due) then
    begin
      Processor := ProcessorByIndex(Index);
      if Processor <> nil then
        WakeProcessor(Processor);
    end;
    Inc(Index);
  end;
end;

function NextBroadcastDue(Now: QWord): QWord;
var
  Index: LongWord;
  Due: QWord;
begin
  Result := NeverDue;
  if not Initialized then
    Exit;
  Index := 0;
  while (Index < ProcessorTotal) and (Index < MaximumProcessors) do
  begin
    Due := QWord(AtomicLoad(DueTimes[Index]));
    if (Due < Result) then
      Result := Due;
    Inc(Index);
  end;
  if Result <= Now then
    Result := Now + 1;
end;

procedure ServeBroadcastRequest;
begin
  if (CurrentProcessor^.Index <> 0) or (AtomicLoad(ReprogramRequested) = 0) then
    Exit;
  AtomicExchange(ReprogramRequested, 0);
  RequestClockInterruptBy(NextBroadcastDue(ClockNanoseconds));
end;

function BroadcastWakeCount: QWord;
begin
  Result := QWord(AtomicFetchAndAdd(WakeCount, 0));
end;

{ The device's interrupt (on the boot processor, at the clock's level). }
procedure ServeBroadcastDevice(Now: QWord);
var
  WereEnabled: Boolean;
  Next: QWord;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(DeviceLock);
  DeviceDue := NeverDue;
  ReleaseSpinLockAtCurrentLevel(DeviceLock);
  RestoreInterrupts(WereEnabled);
  ServeBroadcast(Now);
  Next := NextBroadcastDue(Now);
  if Next <> NeverDue then
    RequestDeviceBy(Next);
end;

function DeviceIsRefused: Boolean;
var
  Value: array[0..15] of Char;
begin
  Result := GetKernelOptionValue('broadcasttimer', @Value[0], SizeOf(Value)) and TextIsEqual(@Value[0], 'boot');
end;

procedure StartBroadcastDevice;
var
  Name: array[0..63] of Char;
begin
  if not Initialized then
    InitializeTable;
  if not HalBroadcastTimerIsAvailable or DeviceIsRefused then
    Exit;
  InitializeSpinLock(DeviceLock);
  DeviceDue := NeverDue;
  HalSetBroadcastHandler(@ServeBroadcastDevice);
  FullMemoryBarrier;
  UsesDevice := True;
  HalDescribeBroadcastTimer(@Name[0], SizeOf(Name));
  DebugBeginMessage;
  DebugWriteTag('idle');
  DebugWrite('Broadcast timer: ');
  DebugWriteLine(@Name[0]);
  DebugEndMessage;
end;

function BroadcastUsesDevice: Boolean;
begin
  Result := UsesDevice;
end;

procedure DescribeBroadcastTimer(Text: PChar; Capacity: LongWord);
begin
  if UsesDevice then
    HalDescribeBroadcastTimer(Text, Capacity)
  else
    CopyText(Text, 'boot processor', Capacity);
end;

{ --- The power-down test ------------------------------------------------------ }

procedure SetPowerUpRoutine(Routine: TPowerUpRoutine);
begin
  PowerUp := Routine;
end;

procedure NotePoweredDown(Processor: PProcessor);
begin
  AtomicStore(PowerStates[Processor^.Index], PowerStateOff);
end;

procedure NotePoweredUp(Processor: PProcessor);
begin
  AtomicStore(PowerStates[Processor^.Index], PowerStateOn);
end;

procedure ClearWakeRequest(Processor: PProcessor);
begin
  if (PowerUp <> nil) and (Processor^.Index < MaximumProcessors) then
    AtomicExchange(WakeRequests[Processor^.Index], 0);
end;

function PowerDownMayProceed(Processor: PProcessor; Pending: Boolean): Boolean;
begin
  Result := True;
  FullMemoryBarrier;
  if not Pending and (AtomicLoad(WakeRequests[Processor^.Index]) = 0) then
    Exit;
  { Asked meanwhile: back on, unless a waker took it already (it starts
    it again once it is off). }
  Result := AtomicCompareExchange(PowerStates[Processor^.Index], PowerStateOn, PowerStateOff) <> PowerStateOff;
end;

procedure RetryPowerUpLater(Processor: PProcessor);
var
  Owner: PProcessor;
begin
  if not Initialized then
    InitializeTable;
  AtomicStore(DueTimes[Processor^.Index], PtrUInt(ClockNanoseconds + PowerUpRetryNanoseconds));
  AtomicExchange(ReprogramRequested, 1);
  Owner := ProcessorByIndex(0);
  if (Owner <> nil) and (CurrentProcessor <> Owner) then
    HalRequestDispatchOn(Owner^.ApicId);
end;

function WakePoweredDownProcessor(Processor: PProcessor): Boolean;
var
  Deadline: QWord;
begin
  Result := False;
  if (Processor^.Index >= MaximumProcessors) or (PowerUp = nil) then
    Exit;
  { Noted before the state is read: a processor about to turn off sees
    it (PowerDownMayProceed). }
  AtomicExchange(WakeRequests[Processor^.Index], 1);
  if AtomicLoad(PowerStates[Processor^.Index]) = PowerStateOn then
    Exit;
  Result := True;
  { One waker starts it; another finds it waking already. }
  if AtomicCompareExchange(PowerStates[Processor^.Index], PowerStateWaking, PowerStateOff) <> PowerStateOff then
    Exit;
  { Refused while it is still on its way off (the firmware finishes
    CPU_OFF on that processor, in its own time). }
  Deadline := ClockNanoseconds + LongestPowerUpNanoseconds;
  while not PowerUp(Processor) do
  begin
    if ClockNanoseconds >= Deadline then
    begin
      { Tried again soon by the boot processor's clock interrupt (or by
        the next waker). }
      AtomicStore(PowerStates[Processor^.Index], PowerStateOff);
      RetryPowerUpLater(Processor);
      Exit;
    end;
    CpuRelax;
  end;
end;

end.
