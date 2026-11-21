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
  with the next space's root and ASID: nothing is invalidated. Every
  AArch64 processor has 8-bit ASIDs; most (ID_AA64MMFR0_EL1.ASIDBits = 2:
  the Cortex-A72 and A76 among them) have 16-bit ones, which the boot
  processor turns on (TCR_EL1.AS; the other processors take its
  translation control over) before any address space has one. The
  kernel option asidbits=N uses only the first 2^N (N at least 2), so
  the tests can make generations roll over often. They are handed out
  with generations, the scheme Linux uses:

  - An address space's context is its ASID plus the generation it was
    given in: the generation's number above the ASID, the ASID from bit
    1 up, and bit 0 always clear, so the context can be kept in a translation
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
  { The ASID of the kernel's empty user half. }
  KernelAsid = 0;

{ Turns 16-bit ASIDs on where the processor has them (the boot
  processor, before any address space runs) and reads asidbits=. }
procedure InitializeAddressSpaceIds;
{ How many bits of ASID are used (8 or 16, fewer with asidbits=). }
function AddressSpaceIdBits: LongWord;
{ How many generations began after the first. }
function AddressSpaceIdRollovers: QWord;

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
  Kernel.Processors,
  Kernel.Options,
  Debug.Output;

const
  AsidShift = 1;
  MaximumAsidBits = 16;
  MaximumAsidCount = 1 shl MaximumAsidBits;
  MaximumUsedWords = MaximumAsidCount div 64;
  MinimumAsidBits = 2;
  { TCR_EL1.AS: 16-bit ASIDs. }
  TranslationControlWideAsids = QWord(1) shl 36;
  MemoryModelAsidBitsShift = 4;
  MemoryModelAsidBits16 = 2;

var
  AsidLock: TSpinLock;
  AsidBits: LongWord = 8;
  AsidCount: LongWord = 1 shl 8;
  AsidMask: LongWord = (1 shl 8) - 1;
  GenerationStep: PtrUInt = PtrUInt(1 shl 8) shl AsidShift;
  GenerationMask: PtrUInt = not ((PtrUInt(1 shl 8) shl AsidShift) - 1);
  { The current generation; the first is GenerationStep, so a context of
    zero (a new address space) is never current. }
  Generation: PtrUInt = PtrUInt(1 shl 8) shl AsidShift;
  Rollovers: QWord = 0;
  UsedAsids: array[0..MaximumUsedWords - 1] of QWord;
  NextAsid: LongWord = 1;
  { The context each processor runs with, 0 once a new generation began
    and it has not loaded a context since. }
  ActiveContexts: array[0..MaximumProcessors - 1] of PtrUInt;
  { The context each processor ran with when the last generation began. }
  ReservedContexts: array[0..MaximumProcessors - 1] of PtrUInt;
  FlushPending: array[0..MaximumProcessors - 1] of Boolean;

function ArchReadTranslationControl: QWord; external name 'ArchReadTranslationControl';
procedure ArchWriteTranslationControl(Value: QWord); external name 'ArchWriteTranslationControl';
function ArchReadMemoryModelFeatures0: QWord; external name 'ArchReadMemoryModelFeatures0';

procedure UseAsidBits(Bits: LongWord);
begin
  AsidBits := Bits;
  AsidCount := LongWord(1) shl Bits;
  AsidMask := AsidCount - 1;
  GenerationStep := PtrUInt(AsidCount) shl AsidShift;
  GenerationMask := not (GenerationStep - 1);
  Generation := GenerationStep;
end;

procedure InitializeAddressSpaceIds;
var
  Hardware: LongWord;
  Wanted: QWord;
begin
  InitializeSpinLock(AsidLock);
  ZeroMemory(@UsedAsids, SizeOf(UsedAsids));
  UsedAsids[0] := 1;
  Hardware := 8;
  if ((ArchReadMemoryModelFeatures0 shr MemoryModelAsidBitsShift) and $F) = MemoryModelAsidBits16 then
  begin
    ArchWriteTranslationControl(ArchReadTranslationControl or TranslationControlWideAsids);
    Hardware := 16;
  end;
  if GetKernelOptionNumber('asidbits', Wanted) and (Wanted >= MinimumAsidBits) and (Wanted < Hardware) then
    UseAsidBits(LongWord(Wanted))
  else
    UseAsidBits(Hardware);
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWriteDecimal(AsidBits);
  DebugWrite('-bit address space identifiers (the processor has ');
  DebugWriteDecimal(Hardware);
  DebugWriteLine(')');
  DebugEndMessage;
end;

function AddressSpaceIdBits: LongWord;
begin
  Result := AsidBits;
end;

function AddressSpaceIdRollovers: QWord;
begin
  Result := Rollovers;
end;

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

{ A free ASID from From upwards, 0 if there is none. Whole words of
  used ones are passed over at once. }
function FindFreeAsid(From: LongWord): LongWord;
var
  Asid: LongWord;
begin
  Asid := From;
  while Asid < AsidCount do
  begin
    if ((Asid and 63) = 0) and (Asid + 64 <= AsidCount) and (UsedAsids[Asid shr 6] = High(QWord)) then
    begin
      Inc(Asid, 64);
      Continue;
    end;
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
  Inc(Rollovers);
  if Rollovers = 1 then
  begin
    DebugBeginMessage;
    DebugWriteTag('memory');
    DebugWriteLine('address space identifiers used up: a new generation began');
    DebugEndMessage;
  end;
  ZeroMemory(@UsedAsids, ((AsidCount + 63) div 64) * SizeOf(QWord));
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
