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
  Atomic memory operations for AArch64 (kernel/core/arm64/Atomics.s).

  Every read-modify-write operation is a full memory barrier, as on
  x86-64, which is what the synchronization code built on top of them
  expects.
}
unit Runtime.Atomic;

{$mode objfpc}

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

{ Sets Bits in Target, atomically. }
procedure AtomicOr(var Target: PtrUInt; Bits: PtrUInt);

{ Reads Target with acquire semantics. }
function AtomicLoad(var Target: PtrUInt): PtrUInt;

{ Writes Target with release semantics. }
procedure AtomicStore(var Target: PtrUInt; Value: PtrUInt);

procedure FullMemoryBarrier;

implementation

function ArchAtomicAdd(var Value: Int64; Amount: Int64): Int64; external name 'ArchAtomicAdd';
function ArchAtomicFetchAndAdd(var Value: Int64; Amount: Int64): Int64; external name 'ArchAtomicFetchAndAdd';
function ArchAtomicExchange(var Target: PtrUInt; NewValue: PtrUInt): PtrUInt; external name 'ArchAtomicExchange';
function ArchAtomicCompareExchange(var Target: PtrUInt; NewValue: PtrUInt; ExpectedValue: PtrUInt): PtrUInt;
  external name 'ArchAtomicCompareExchange';
procedure ArchAtomicOr(var Target: PtrUInt; Bits: PtrUInt); external name 'ArchAtomicOr';
function ArchAtomicLoad(var Target: PtrUInt): PtrUInt; external name 'ArchAtomicLoad';
procedure ArchAtomicStore(var Target: PtrUInt; Value: PtrUInt); external name 'ArchAtomicStore';
procedure ArchFullMemoryBarrier; external name 'ArchFullMemoryBarrier';

function AtomicIncrement(var Value: Int64): Int64;
begin
  Result := ArchAtomicAdd(Value, 1);
end;

function AtomicDecrement(var Value: Int64): Int64;
begin
  Result := ArchAtomicAdd(Value, -1);
end;

function AtomicFetchAndAdd(var Value: Int64; Amount: Int64): Int64;
begin
  Result := ArchAtomicFetchAndAdd(Value, Amount);
end;

function AtomicExchange(var Target: PtrUInt; NewValue: PtrUInt): PtrUInt;
begin
  Result := ArchAtomicExchange(Target, NewValue);
end;

function AtomicCompareExchange(var Target: PtrUInt; NewValue: PtrUInt;
  ExpectedValue: PtrUInt): PtrUInt;
begin
  Result := ArchAtomicCompareExchange(Target, NewValue, ExpectedValue);
end;

procedure AtomicOr(var Target: PtrUInt; Bits: PtrUInt);
begin
  ArchAtomicOr(Target, Bits);
end;

function AtomicLoad(var Target: PtrUInt): PtrUInt;
begin
  Result := ArchAtomicLoad(Target);
end;

procedure AtomicStore(var Target: PtrUInt; Value: PtrUInt);
begin
  ArchAtomicStore(Target, Value);
end;

procedure FullMemoryBarrier;
begin
  ArchFullMemoryBarrier;
end;

end.
