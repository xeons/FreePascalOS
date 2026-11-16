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
  Heap checking for the kernel heap: the setting, the fill patterns and
  the reports.

  Freed memory that still holds its old contents hides bugs: code that
  uses an object after freeing it keeps working until the memory is
  reused, far from the cause. With the kernel option "heapchecks" the
  kernel heap (Memory.KernelHeap) makes such bugs show at once:

    * new blocks are filled with HeapAllocationFill, so code reading
      memory it never set sees junk instead of a lucky zero;
    * freed blocks are filled with HeapFreeFill: a pointer read from a
      freed object is $DFDFDFDFDFDFDFDF, which is not a canonical
      address, so following it faults at once;
    * the bytes between the end of the request and the end of the block
      hold HeapGuardFill, checked when the block is freed (writes past
      the end);
    * freed blocks wait in a quarantine (Memory.HeapQuarantine) before
      they can be reused, and their fill is checked when they leave it
      (writes after free); freeing a block twice is caught by its
      header.

  The value says how much: "heapchecks=fill" only fills and checks the
  headers and guards, "heapchecks" or "heapchecks=all" adds the
  quarantine, "heapchecks=off" (or no option) checks nothing. User mode
  reads the same option as the default for HEAP_CHECKS (rtl/fpc).

  The patterns are the same in user mode (rtl/fpc/sysheapcheck.inc), so
  a value in a crash dump means the same thing everywhere. All three
  repeated over eight bytes are non-canonical addresses.
}
unit Memory.HeapChecks;

{$mode objfpc}

interface

type
  THeapCheckLevel = (
    HeapChecksOff,
    { Fill patterns, header and guard checks. }
    HeapChecksFill,
    { Everything, with freed blocks quarantined before reuse. }
    HeapChecksQuarantine);

const
  OptionHeapChecks = 'heapchecks';

  HeapAllocationFill = Byte($A5);
  HeapFreeFill = Byte($DF);
  HeapGuardFill = Byte($FD);

var
  { Set once, before the first allocation, and never changed: every
    block is then handled the same way from allocation to free. }
  KernelHeapCheckLevel: THeapCheckLevel = HeapChecksOff;

procedure InitializeHeapChecks;

function HeapCheckLevelName(Level: THeapCheckLevel): PChar;

{ The level a heapchecks value names: off, fill, or everything else
  (all, quarantine, 1, or the bare option) for the quarantine. }
function HeapCheckLevelFromText(Text: PChar): THeapCheckLevel;

{ Stops the system for a damaged block. Offset is where the first
  changed byte is (from the start of the block's usable memory), Found
  the byte there and Expected the pattern it should hold; FreedBy is the
  code address that freed the block (0 if unknown). }
procedure ReportDamagedBlock(Problem: PChar; Block: Pointer; UsableBytes, Offset: QWord;
  Found, Expected: Byte; FreedBy: QWord); noreturn;

{ Stops the system for a bad free: Problem says what was wrong with the
  block, Caller is the code that freed it, FreedBy the code that freed
  it before (for a double free; 0 if unknown). }
procedure ReportBadFree(Problem: PChar; Block: Pointer; HeaderMagic: QWord;
  Caller, FreedBy: QWord); noreturn;

implementation

uses
  Runtime.Text,
  Kernel.Options,
  Kernel.Panic,
  Debug.Output;

function HeapCheckLevelFromText(Text: PChar): THeapCheckLevel;
begin
  if TextIsEqual(Text, 'off') or TextIsEqual(Text, '0') or TextIsEqual(Text, 'none') then
    Result := HeapChecksOff
  else if TextIsEqual(Text, 'fill') then
    Result := HeapChecksFill
  else
    Result := HeapChecksQuarantine;
end;

function HeapCheckLevelName(Level: THeapCheckLevel): PChar;
begin
  case Level of
    HeapChecksOff: Result := 'off';
    HeapChecksFill: Result := 'fill';
  else
    Result := 'all (fill and quarantine)';
  end;
end;

procedure InitializeHeapChecks;
const
  ValueCapacity = 32;
var
  Value: array[0..ValueCapacity - 1] of Char;
begin
  if GetKernelOptionValue(OptionHeapChecks, @Value[0], ValueCapacity) then
    KernelHeapCheckLevel := HeapCheckLevelFromText(@Value[0])
  else if KernelOptionIsSet(OptionHeapChecks) then
    KernelHeapCheckLevel := HeapChecksQuarantine
  else
    KernelHeapCheckLevel := HeapChecksOff;
end;

procedure WriteCodeAddress(Caption: PChar; Address: QWord);
begin
  DebugWrite(Caption);
  if Address = 0 then
    DebugWriteLine('unknown')
  else
  begin
    DebugWriteAddress(Address);
    DebugWriteLine(' (addr2line -f -e build/amd64/kernel.elf)');
  end;
end;

procedure ReportDamagedBlock(Problem: PChar; Block: Pointer; UsableBytes, Offset: QWord;
  Found, Expected: Byte; FreedBy: QWord);
begin
  BeginKernelPanic(PanicHeapCorruption, Problem);
  DebugWrite('  Block:      ');
  DebugWriteAddress(QWord(Block));
  DebugWrite(', ');
  DebugWriteDecimal(UsableBytes);
  DebugWriteLine(' usable bytes');
  DebugWrite('  Offset:     ');
  DebugWriteDecimal(Offset);
  DebugWrite(' holds 0x');
  DebugWriteHex(Found, 2);
  DebugWrite(' instead of 0x');
  DebugWriteHex(Expected, 2);
  DebugWriteLine('');
  WriteCodeAddress('  Freed by:   ', FreedBy);
  FinishKernelPanic;
end;

procedure ReportBadFree(Problem: PChar; Block: Pointer; HeaderMagic: QWord;
  Caller, FreedBy: QWord);
begin
  BeginKernelPanic(PanicHeapCorruption, Problem);
  DebugWrite('  Block:      ');
  DebugWriteAddress(QWord(Block));
  DebugWriteLine('');
  DebugWrite('  Header:     0x');
  DebugWriteHex(HeaderMagic, 8);
  DebugWriteLine('');
  WriteCodeAddress('  Freed by:   ', Caller);
  if FreedBy <> 0 then
    WriteCodeAddress('  Freed before by: ', FreedBy);
  FinishKernelPanic;
end;

end.
