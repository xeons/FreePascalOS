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
  Address space identifiers (ASIDs) on AArch64.

  User mappings are tagged in the TLB with the ASID TTBR0_EL1 held when
  they were cached, so switching address spaces only loads TTBR0_EL1
  with the next space's root and ASID: nothing is invalidated. The 8-bit
  ASIDs every AArch64 processor has (TCR_EL1.AS = 0) are handed out with
  generations, the scheme Linux uses:

  - An address space's context is its ASID plus the generation it was
    given in: the generation's number above bit 9, the ASID in bits 1-8,
    and bit 0 always clear, so the context can be kept in a translation
    table entry that is never valid (Memory.Arch.PageTables). A context of the
    current generation is valid as it is; switching to it takes no lock
    (the common case).
  - Otherwise it gets an ASID of the current generation - its old number
    if that is still free - under the lock.
  - When none is left, a new generation starts: every ASID becomes free
    again except those the processors are running with, which stay
    reserved for their address spaces, and every processor invalidates
    its whole TLB before it next loads a context, since stale entries of
    the old generation could now carry a reused number.

  ASID 0 is never handed out: the kernel's empty user half
  (Memory.Arch.PageTables) runs with it and has no user mappings to tag.
  An ASID is never given back when its address space ends, only at the
  next generation, so no stale entry of an ended space can match a live
  one. Removing a mapping invalidates it for every ASID (TLBI VAAE1IS).
}
unit Memory.Arch.AddressSpaceIds;

{$mode objfpc}

interface

const
  AsidBits = 8;
  AsidCount = 1 shl AsidBits;
  AsidMask = AsidCount - 1;
  { The ASID of the kernel's empty user half. }
  KernelAsid = 0;

{ The ASID the address space whose context word is Context runs with on
  this processor, giving it one if its context is from an older
  generation (Context is updated). MustFlushTlb is set when this
  processor has to invalidate its whole TLB before loading it. Called
  with interrupts disabled. }
function AddressSpaceIdFor(var Context: PtrUInt; out MustFlushTlb: Boolean): LongWord;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Processors;

const
  AsidShift = 1;
  GenerationStep = PtrUInt(AsidCount) shl AsidShift;
  GenerationMask = not (GenerationStep - 1);
  UsedWordCount = AsidCount div 64;

var
  AsidLock: TSpinLock;
  { The current generation; the first is GenerationStep, so a context of
    zero (a new address space) is never current. }
  Generation: PtrUInt = GenerationStep;
  UsedAsids: array[0..UsedWordCount - 1] of QWord = (1, 0, 0, 0);
  NextAsid: LongWord = 1;
  { The context each processor runs with, 0 once a new generation began
    and it has not loaded a context since. }
  ActiveContexts: array[0..MaximumProcessors - 1] of PtrUInt;
  { The context each processor ran with when the last generation began. }
  ReservedContexts: array[0..MaximumProcessors - 1] of PtrUInt;
  FlushPending: array[0..MaximumProcessors - 1] of Boolean;

function IsCurrent(Context: PtrUInt): Boolean;
begin
  Result := (Context and GenerationMask) = AtomicLoad(Generation);
end;

function ContextAsid(Context: PtrUInt): LongWord;
begin
  Result := LongWord((Context shr AsidShift) and AsidMask);
end;

function MakeContext(Asid: LongWord): PtrUInt;
begin
  Result := Generation or (PtrUInt(Asid) shl AsidShift);
end;

function AsidIsUsed(Asid: LongWord): Boolean;
begin
  Result := (UsedAsids[Asid shr 6] and (QWord(1) shl (Asid and 63))) <> 0;
end;

procedure MarkAsidUsed(Asid: LongWord);
begin
  UsedAsids[Asid shr 6] := UsedAsids[Asid shr 6] or (QWord(1) shl (Asid and 63));
end;

{ A free ASID from From upwards, 0 if there is none. }
function FindFreeAsid(From: LongWord): LongWord;
var
  Asid: LongWord;
begin
  Asid := From;
  while Asid < AsidCount do
  begin
    if not AsidIsUsed(Asid) then
      Exit(Asid);
    Inc(Asid);
  end;
  Result := 0;
end;

{ Begins a new generation (the lock is held). }
procedure BeginGeneration;
var
  Index: LongWord;
  Context: PtrUInt;
begin
  AtomicStore(Generation, Generation + GenerationStep);
  ZeroMemory(@UsedAsids, SizeOf(UsedAsids));
  MarkAsidUsed(KernelAsid);
  for Index := 0 to MaximumProcessors - 1 do
  begin
    Context := AtomicExchange(ActiveContexts[Index], 0);
    { A processor that has not loaded a context since the generation
      before still runs with the one it had then. }
    if Context = 0 then
      Context := ReservedContexts[Index];
    if Context <> 0 then
      MarkAsidUsed(ContextAsid(Context));
    ReservedContexts[Index] := Context;
    FlushPending[Index] := True;
  end;
  NextAsid := 1;
end;

{ If Old is reserved (its address space was running when the generation
  began), the reservation moves to the current generation. }
function TakeReservedContext(Old: PtrUInt; out NewContext: PtrUInt): Boolean;
var
  Index: LongWord;
begin
  Result := False;
  NewContext := MakeContext(ContextAsid(Old));
  for Index := 0 to MaximumProcessors - 1 do
    if ReservedContexts[Index] = Old then
    begin
      ReservedContexts[Index] := NewContext;
      Result := True;
    end;
end;

{ A context of the current generation for an address space whose
  context was Old (the lock is held). }
function GiveContext(Old: PtrUInt): PtrUInt;
var
  Asid: LongWord;
begin
  if Old <> 0 then
  begin
    if TakeReservedContext(Old, Result) then
      Exit;
    Asid := ContextAsid(Old);
    if not AsidIsUsed(Asid) then
    begin
      MarkAsidUsed(Asid);
      Exit(MakeContext(Asid));
    end;
  end;
  Asid := FindFreeAsid(NextAsid);
  if Asid = 0 then
  begin
    BeginGeneration;
    Asid := FindFreeAsid(1);
  end;
  MarkAsidUsed(Asid);
  NextAsid := Asid + 1;
  Result := MakeContext(Asid);
end;

function AddressSpaceIdFor(var Context: PtrUInt; out MustFlushTlb: Boolean): LongWord;
var
  Processor: LongWord;
  Current: PtrUInt;
  Previous: PtrUInt;
  PreviousLevel: TPriorityLevel;
begin
  MustFlushTlb := False;
  Processor := CurrentProcessorIndex;
  Current := AtomicLoad(Context);
  Previous := AtomicLoad(ActiveContexts[Processor]);
  { Without the lock: a new generation beginning meanwhile clears this
    processor's active context first, which makes the exchange fail. }
  if (Previous <> 0) and IsCurrent(Current) and
     (AtomicCompareExchange(ActiveContexts[Processor], Current, Previous) = Previous) then
    Exit(ContextAsid(Current));

  PreviousLevel := AcquireSpinLock(AsidLock);
  Current := Context;
  if not IsCurrent(Current) then
  begin
    Current := GiveContext(Current);
    AtomicStore(Context, Current);
  end;
  if FlushPending[Processor] then
  begin
    MustFlushTlb := True;
    FlushPending[Processor] := False;
  end;
  AtomicStore(ActiveContexts[Processor], Current);
  ReleaseSpinLock(AsidLock, PreviousLevel);
  Result := ContextAsid(Current);
end;

end.
