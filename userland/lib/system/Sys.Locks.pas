{
  Locks for threads of one process.

  A lock is one 32-bit word: 0 when free, 1 when held, 2 when held and
  other threads may be sleeping on it. Taking a free lock and releasing
  an uncontended one are a single atomic instruction in user mode; the
  kernel is involved only when threads actually have to wait, through
  CallWaitOnAddress ("sleep while the word is still 2") and
  CallWakeAddress.

  Locks are not recursive: a thread that takes a lock it already holds
  waits forever.
}
unit Sys.Locks;

{$mode objfpc}
{$asmmode intel}

interface

type
  TLock = record
    State: LongInt;
  end;
  PLock = ^TLock;

{ A lock that is all zero is a valid free lock, so global locks need no
  initialization. }
procedure InitializeLock(out Lock: TLock);
procedure AcquireLock(var Lock: TLock);
{ Takes the lock only if it is free; True if it did. }
function TryAcquireLock(var Lock: TLock): Boolean;
procedure ReleaseLock(var Lock: TLock);

{ Atomic operations on 32-bit words. }
{ Stores NewValue if Target equals Comparand; returns the old value. }
function AtomicCompareExchange32(var Target: LongInt; NewValue, Comparand: LongInt): LongInt;
{ Stores NewValue and returns the old value. }
function AtomicExchange32(var Target: LongInt; NewValue: LongInt): LongInt;
{ Adds Amount and returns the new value. }
function AtomicAdd32(var Target: LongInt; Amount: LongInt): LongInt;

implementation

uses
  Abi.SystemCalls;

const
  LockFree = 0;
  LockHeld = 1;
  LockHeldWithWaiters = 2;

function AtomicCompareExchange32(var Target: LongInt; NewValue, Comparand: LongInt): LongInt;
  assembler; nostackframe;
asm
  { Target in RDI, NewValue in ESI, Comparand in EDX. }
  mov eax, edx
  lock cmpxchg dword ptr [rdi], esi
end;

function AtomicExchange32(var Target: LongInt; NewValue: LongInt): LongInt;
  assembler; nostackframe;
asm
  mov eax, esi
  xchg dword ptr [rdi], eax
end;

function AtomicAdd32(var Target: LongInt; Amount: LongInt): LongInt; assembler; nostackframe;
asm
  mov eax, esi
  lock xadd dword ptr [rdi], eax
  add eax, esi
end;

procedure InitializeLock(out Lock: TLock);
begin
  Lock.State := LockFree;
end;

function TryAcquireLock(var Lock: TLock): Boolean;
begin
  Result := AtomicCompareExchange32(Lock.State, LockHeld, LockFree) = LockFree;
end;

procedure AcquireLock(var Lock: TLock);
var
  Previous: LongInt;
begin
  Previous := AtomicCompareExchange32(Lock.State, LockHeld, LockFree);
  if Previous = LockFree then
    Exit;
  { Contended: mark that someone waits, then sleep until the lock is
    handed back as free. Whoever takes it from here leaves the waiters
    mark set, so its release wakes the next sleeper. }
  if Previous <> LockHeldWithWaiters then
    Previous := AtomicExchange32(Lock.State, LockHeldWithWaiters);
  while Previous <> LockFree do
  begin
    SystemCall(CallWaitOnAddress, QWord(@Lock.State), LockHeldWithWaiters, QWord(InfiniteWait), 0, 0, 0);
    Previous := AtomicExchange32(Lock.State, LockHeldWithWaiters);
  end;
end;

procedure ReleaseLock(var Lock: TLock);
begin
  if AtomicExchange32(Lock.State, LockFree) = LockHeldWithWaiters then
    SystemCall(CallWakeAddress, QWord(@Lock.State), 1, 0, 0, 0, 0);
end;

end.
