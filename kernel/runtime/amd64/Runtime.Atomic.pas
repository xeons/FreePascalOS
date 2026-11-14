{
  Atomic memory operations for x86-64.

  Every operation is a full memory barrier (x86 locked instructions are),
  which is what the synchronization code built on top of them expects.

  System V calling convention: first argument in RDI, second in RSI,
  third in RDX, result in RAX. A "var" parameter arrives as its address.
}
unit Runtime.Atomic;

{$mode objfpc}
{$asmmode intel}

interface

{ Adds one and returns the new value. }
function AtomicIncrement(var Value: Int64): Int64;

{ Subtracts one and returns the new value. }
function AtomicDecrement(var Value: Int64): Int64;

{ Adds Amount and returns the value from before the addition. }
function AtomicFetchAndAdd(var Value: Int64; Amount: Int64): Int64;

{ Stores NewValue and returns the previous value. }
function AtomicExchange(var Target: PtrUInt; NewValue: PtrUInt): PtrUInt;

{ Stores NewValue only if Target equals ExpectedValue. Returns the value
  Target held before the operation, so the exchange happened exactly when
  the result equals ExpectedValue. }
function AtomicCompareExchange(var Target: PtrUInt; NewValue: PtrUInt;
  ExpectedValue: PtrUInt): PtrUInt;

{ Reads Target with acquire semantics. }
function AtomicLoad(var Target: PtrUInt): PtrUInt;

{ Writes Target with release semantics. }
procedure AtomicStore(var Target: PtrUInt; Value: PtrUInt);

procedure FullMemoryBarrier;

implementation

function AtomicIncrement(var Value: Int64): Int64; assembler; nostackframe;
asm
  mov rax, 1
  lock xadd [rdi], rax
  add rax, 1
end;

function AtomicDecrement(var Value: Int64): Int64; assembler; nostackframe;
asm
  mov rax, -1
  lock xadd [rdi], rax
  sub rax, 1
end;

function AtomicFetchAndAdd(var Value: Int64; Amount: Int64): Int64; assembler; nostackframe;
asm
  mov rax, rsi
  lock xadd [rdi], rax
end;

function AtomicExchange(var Target: PtrUInt; NewValue: PtrUInt): PtrUInt; assembler; nostackframe;
asm
  { xchg with a memory operand is always locked. }
  mov rax, rsi
  xchg [rdi], rax
end;

function AtomicCompareExchange(var Target: PtrUInt; NewValue: PtrUInt;
  ExpectedValue: PtrUInt): PtrUInt; assembler; nostackframe;
asm
  mov rax, rdx
  lock cmpxchg [rdi], rsi
end;

function AtomicLoad(var Target: PtrUInt): PtrUInt; assembler; nostackframe;
asm
  { Aligned loads are atomic on x86-64 and already have acquire ordering. }
  mov rax, [rdi]
end;

procedure AtomicStore(var Target: PtrUInt; Value: PtrUInt); assembler; nostackframe;
asm
  { Aligned stores are atomic on x86-64 and already have release ordering. }
  mov [rdi], rsi
end;

procedure FullMemoryBarrier; assembler; nostackframe;
asm
  mfence
end;

end.
