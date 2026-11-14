{
  Spin locks.

  A spin lock is held at a raised priority level, which keeps the holder
  from being preempted or interrupted (on its own processor) by code that
  could try to take the same lock. The usual level is DispatchLevel; locks
  that interrupt handlers also take must be acquired at the handler's level
  or above.

  Typical use:

    PreviousLevel := AcquireSpinLock(SomeLock);
    ... touch the protected data ...
    ReleaseSpinLock(SomeLock, PreviousLevel);
}
unit Kernel.SpinLock;

{$mode objfpc}

interface

uses
  Kernel.PriorityLevel;

type
  TSpinLock = record
    State: PtrUInt;
  end;

procedure InitializeSpinLock(out Lock: TSpinLock);

{ Raises to DispatchLevel, acquires the lock and returns the previous level. }
function AcquireSpinLock(var Lock: TSpinLock): TPriorityLevel;
procedure ReleaseSpinLock(var Lock: TSpinLock; PreviousLevel: TPriorityLevel);

{ Raises to Level (which must not be below the current level), acquires the
  lock and returns the previous level. }
function AcquireSpinLockAtLevel(var Lock: TSpinLock; Level: TPriorityLevel): TPriorityLevel;

{ For callers that are already running at a suitable level. }
procedure AcquireSpinLockAtCurrentLevel(var Lock: TSpinLock);
procedure ReleaseSpinLockAtCurrentLevel(var Lock: TSpinLock);

function TryAcquireSpinLockAtCurrentLevel(var Lock: TSpinLock): Boolean;
function SpinLockIsHeld(var Lock: TSpinLock): Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu;

const
  LockIsFree = 0;
  LockIsHeld = 1;

procedure InitializeSpinLock(out Lock: TSpinLock);
begin
  Lock.State := LockIsFree;
end;

function TryAcquireSpinLockAtCurrentLevel(var Lock: TSpinLock): Boolean;
begin
  Result := AtomicExchange(Lock.State, LockIsHeld) = LockIsFree;
end;

procedure AcquireSpinLockAtCurrentLevel(var Lock: TSpinLock);
begin
  while not TryAcquireSpinLockAtCurrentLevel(Lock) do
  begin
    { Wait with plain reads so the cache line is not bounced between
      processors while another one holds the lock. }
    while AtomicLoad(Lock.State) <> LockIsFree do
      CpuRelax;
  end;
end;

procedure ReleaseSpinLockAtCurrentLevel(var Lock: TSpinLock);
begin
  AtomicStore(Lock.State, LockIsFree);
end;

function AcquireSpinLockAtLevel(var Lock: TSpinLock; Level: TPriorityLevel): TPriorityLevel;
begin
  Result := RaisePriorityLevel(Level);
  AcquireSpinLockAtCurrentLevel(Lock);
end;

function AcquireSpinLock(var Lock: TSpinLock): TPriorityLevel;
begin
  Result := AcquireSpinLockAtLevel(Lock, DispatchLevel);
end;

procedure ReleaseSpinLock(var Lock: TSpinLock; PreviousLevel: TPriorityLevel);
begin
  ReleaseSpinLockAtCurrentLevel(Lock);
  LowerPriorityLevel(PreviousLevel);
end;

function SpinLockIsHeld(var Lock: TSpinLock): Boolean;
begin
  Result := AtomicLoad(Lock.State) <> LockIsFree;
end;

end.
