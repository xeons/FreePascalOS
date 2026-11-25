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
  CallFrameInfoTest

  The kernel's unwinder for user back traces (Processes.CallFrameEntries,
  Processes.CallFrameRules) on the host, over the fixtures
  make-cfi-fixtures.py writes:

  - x86-64 .eh_frame found through .eh_frame_hdr's search table: a
    routine stopped after PUSH RBX; SUB RSP, 32 unwinds to its caller
    with RBX restored, and that caller (a frame pointer routine) to its
    own; remember/restore state around an epilogue; addresses no FDE
    covers are not found;
  - Free Pascal's .debug_frame (8-byte CIE pointers) at the first
    instruction, after PUSH RBP and after MOV RBP, RSP, with a load
    bias; a standard version 3 .debug_frame;
  - AArch64 .eh_frame (code alignment 4, return address in x30);
  - frame pointer steps on both, a misaligned frame pointer refused,
    and an unreadable stack stopping the unwind;
  - Free Pascal's decorated names made readable as symbolize.py does
    (Processes.SymbolNames).

  Prints every failed check and exits with 1 if there was one.
}
program CallFrameInfoTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Processes.CallFrameEntries,
  Processes.CallFrameRules,
  Processes.SymbolNames;

type
  TMemoryRecord = record
    Address: QWord;
    Data: TBytes;
  end;

var
  Failures: Integer = 0;
  MemoryRecords: array of TMemoryRecord;
  Memory: TCfiMemory;
  Entry: TFrameEntry;
  X86: TCfiArchitecture;
  Arm: TCfiArchitecture;

procedure Check(Condition: Boolean; const Description: string);
begin
  if not Condition then
  begin
    WriteLn('FAILED: ', Description);
    Inc(Failures);
  end;
end;

procedure CheckValue(constref Registers: TUnwindRegisters; Index: LongWord; Expected: QWord;
  const Description: string);
begin
  if not RegisterIsKnown(Registers, Index) then
    Check(False, Description + ': register ' + IntToStr(Index) + ' not known')
  else
    Check(Registers.Values[Index] = Expected, Format('%s: register %d is %x, expected %x',
      [Description, Index, Registers.Values[Index], Expected]));
end;

function ReadFixture(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure LoadMemory(const Path: string);
var
  Bytes: TBytes;
  Position: Integer;
  Address, Length: QWord;
begin
  Bytes := ReadFixture(Path);
  Position := 0;
  while Position + 16 <= System.Length(Bytes) do
  begin
    Move(Bytes[Position], Address, 8);
    Move(Bytes[Position + 8], Length, 8);
    Position := Position + 16;
    SetLength(MemoryRecords, System.Length(MemoryRecords) + 1);
    MemoryRecords[High(MemoryRecords)].Address := Address;
    MemoryRecords[High(MemoryRecords)].Data := Copy(Bytes, Position, Length);
    Position := Position + Integer(Length);
  end;
end;

function ReadTestMemory(Context: Pointer; Address: QWord; Buffer: Pointer; Count: LongWord): Boolean;
var
  Index: Integer;
  Start: QWord;
  Size: QWord;
begin
  for Index := 0 to High(MemoryRecords) do
  begin
    Start := MemoryRecords[Index].Address;
    Size := QWord(System.Length(MemoryRecords[Index].Data));
    if (Address >= Start) and (Address + Count <= Start + Size) then
    begin
      Move(MemoryRecords[Index].Data[Address - Start], Buffer^, Count);
      Exit(True);
    end;
  end;
  Result := False;
end;

{ Looks up Pc through Header, computes the rules there and unwinds. }
function UnwindThroughHeader(Header: QWord; constref Architecture: TCfiArchitecture; Pc: QWord;
  var Registers: TUnwindRegisters): Boolean;
var
  Rules: TFrameRules;
begin
  Result := FindInEhFrameHeader(Memory, Header, Pc, Entry) and ComputeFrameRules(Entry, Pc, Rules) and
    ApplyFrameRules(Rules, Architecture, Memory, Registers);
end;

procedure SetUpArchitectures;
begin
  X86.RegisterCount := 17;
  X86.ReturnAddressColumn := 16;
  X86.StackPointerIndex := 7;
  X86.FramePointerIndex := 6;
  X86.ProgramCounterIndex := 16;
  X86.FramePointerAlignment := 8;
  Arm.RegisterCount := 32;
  Arm.ReturnAddressColumn := 30;
  Arm.StackPointerIndex := 31;
  Arm.FramePointerIndex := 29;
  Arm.ProgramCounterIndex := 32;
  Arm.FramePointerAlignment := 16;
end;

procedure TestX86EhFrame;
const
  Header = $400700;
var
  Registers: TUnwindRegisters;
  Rules: TFrameRules;
begin
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 16, $401020);
  SetRegister(Registers, 7, $70000000);
  SetRegister(Registers, 6, $70000100);
  SetRegister(Registers, 3, $9999);
  Check(UnwindThroughHeader(Header, X86, $401020, Registers), 'x86-64 .eh_frame: F unwinds');
  CheckValue(Registers, 16, $402345, 'F: return address');
  CheckValue(Registers, 7, $70000030, 'F: stack pointer');
  CheckValue(Registers, 3, $1111, 'F: RBX restored');
  CheckValue(Registers, 6, $70000100, 'F: RBP kept');
  { The caller is looked up by the call instruction (return - 1). }
  Check(UnwindThroughHeader(Header, X86, Registers.Values[16] - 1, Registers), 'x86-64 .eh_frame: G unwinds');
  CheckValue(Registers, 16, $403000, 'G: return address');
  CheckValue(Registers, 7, $70000110, 'G: stack pointer');
  CheckValue(Registers, 6, $70000200, 'G: RBP restored');

  { Inside the remembered state the epilogue's CFA (RSP + 8) holds;
    after the restore, RBP's again. }
  Check(FindInEhFrameHeader(Memory, Header, $402364, Entry) and ComputeFrameRules(Entry, $402364, Rules),
    'G epilogue: rules');
  Check((Rules.CfaRegister = 7) and (Rules.CfaOffset = 8), 'G epilogue: CFA is RSP + 8');
  Check(FindInEhFrameHeader(Memory, Header, $402365, Entry) and ComputeFrameRules(Entry, $402365, Rules),
    'G after the epilogue: rules');
  Check((Rules.CfaRegister = 6) and (Rules.CfaOffset = 16), 'G after restore_state: CFA is RBP + 16');
  Check(FindInEhFrameHeader(Memory, Header, $401000, Entry), 'F''s first byte is covered');
  Check(not FindInEhFrameHeader(Memory, Header, $401040, Entry), 'past F is not covered');
  Check(not FindInEhFrameHeader(Memory, Header, $400FFF, Entry), 'before F is not covered');
  Check(not FindInEhFrameHeader(Memory, Header, $402400, Entry), 'past G is not covered');
end;

procedure TestFreePascalDebugFrame;
const
  Bias = $10000000;
var
  Section: TBytes;
  Registers: TUnwindRegisters;
  Rules: TFrameRules;

  function Unwind(Pc: QWord): Boolean;
  begin
    Result := FindInFrameSection(@Section[0], Length(Section), False, 0, Bias, $8000, $9000, Pc, Entry) and
      ComputeFrameRules(Entry, Pc, Rules) and ApplyFrameRules(Rules, X86, Memory, Registers);
  end;

begin
  Section := ReadFixture(ParamStr(1) + '/fpc-debug-frame.bin');
  { At the first instruction: the return address is at RSP. }
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 16, Bias + $8330);
  SetRegister(Registers, 7, $71000000);
  Check(Unwind(Bias + $8330), 'Free Pascal .debug_frame: first instruction');
  Check(Entry.CiePointerSize = 8, 'Free Pascal''s 8-byte CIE pointer recognized');
  CheckValue(Registers, 16, $10008999, 'first instruction: return address');
  CheckValue(Registers, 7, $71000008, 'first instruction: stack pointer');
  { After PUSH RBP. }
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 16, Bias + $8331);
  SetRegister(Registers, 7, $70FFFFF8);
  SetRegister(Registers, 6, $12345678);
  Check(Unwind(Bias + $8331), 'after PUSH RBP');
  CheckValue(Registers, 16, $10008999, 'after PUSH RBP: return address');
  CheckValue(Registers, 7, $71000008, 'after PUSH RBP: stack pointer');
  CheckValue(Registers, 6, $71000100, 'after PUSH RBP: RBP restored');
  { In the body, from RBP (RSP anywhere below). }
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 16, Bias + $8340);
  SetRegister(Registers, 7, $70FFFF00);
  SetRegister(Registers, 6, $70FFFFF8);
  Check(Unwind(Bias + $8340), 'in the body');
  CheckValue(Registers, 16, $10008999, 'body: return address');
  CheckValue(Registers, 7, $71000008, 'body: stack pointer');
  CheckValue(Registers, 6, $71000100, 'body: RBP restored');
  Check(not FindInFrameSection(@Section[0], Length(Section), False, 0, Bias, $8000, $9000, Bias + $842A, Entry),
    'past the routine is not covered');
  Check(not FindInFrameSection(@Section[0], Length(Section), False, 0, Bias, $8000, $9000, $8340, Entry),
    'an address below the bias is not covered');
end;

procedure TestStandardDebugFrame;
var
  Section: TBytes;
  Rules: TFrameRules;
begin
  Section := ReadFixture(ParamStr(1) + '/standard-debug-frame.bin');
  Check(FindInFrameSection(@Section[0], Length(Section), False, 0, 0, $8000, $9000, $8501, Entry),
    'version 3 .debug_frame: found');
  Check(Entry.CiePointerSize = 4, 'standard layout recognized');
  Check(ComputeFrameRules(Entry, $8501, Rules) and (Rules.CfaRegister = 7) and (Rules.CfaOffset = 16),
    'version 3: CFA is RSP + 16 after the push');
  Check(ComputeFrameRules(Entry, $8500, Rules) and (Rules.CfaOffset = 8), 'version 3: CFA is RSP + 8 at entry');
  Check((Rules.Registers[16].Kind = RuleOffset) and (Rules.Registers[16].Operand = -8),
    'version 3: the return address at CFA - 8');
end;

procedure TestAarch64EhFrame;
var
  Registers: TUnwindRegisters;
begin
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 32, $501008);
  SetRegister(Registers, 31, $72000000);
  SetRegister(Registers, 29, $72000000);
  SetRegister(Registers, 30, $501100);
  Check(UnwindThroughHeader($500700, Arm, $501008, Registers), 'AArch64 .eh_frame: K unwinds');
  CheckValue(Registers, 32, $501234, 'K: program counter');
  CheckValue(Registers, 30, $501234, 'K: x30 restored');
  CheckValue(Registers, 31, $72000020, 'K: stack pointer');
  CheckValue(Registers, 29, $72000100, 'K: x29 restored');
  { At its first instruction nothing was saved yet: x30 is the return. }
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 32, $501000);
  SetRegister(Registers, 31, $72000020);
  SetRegister(Registers, 30, $501100);
  Check(UnwindThroughHeader($500700, Arm, $501000, Registers), 'AArch64: first instruction');
  CheckValue(Registers, 32, $501100, 'first instruction: program counter from x30');
  CheckValue(Registers, 31, $72000020, 'first instruction: stack pointer kept');
end;

procedure TestFramePointers;
var
  Registers: TUnwindRegisters;
begin
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 6, $73000000);
  Check(UnwindWithFramePointer(X86, Memory, Registers), 'x86-64 frame pointer step');
  CheckValue(Registers, 16, $404040, 'frame pointer: return address');
  CheckValue(Registers, 7, $73000010, 'frame pointer: stack pointer');
  CheckValue(Registers, 6, $73000040, 'frame pointer: next frame');
  Check(not UnwindWithFramePointer(X86, Memory, Registers), 'an unreadable frame stops the walk');

  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 29, $73000000);
  Check(UnwindWithFramePointer(Arm, Memory, Registers), 'AArch64 frame pointer step');
  CheckValue(Registers, 32, $404040, 'AArch64 frame pointer: program counter');
  CheckValue(Registers, 30, $404040, 'AArch64 frame pointer: x30');
  CheckValue(Registers, 31, $73000010, 'AArch64 frame pointer: stack pointer');
  FillChar(Registers, SizeOf(Registers), 0);
  SetRegister(Registers, 29, $73000008);
  Check(not UnwindWithFramePointer(Arm, Memory, Registers), 'a misaligned AArch64 frame pointer is refused');
  FillChar(Registers, SizeOf(Registers), 0);
  Check(not UnwindWithFramePointer(X86, Memory, Registers), 'an unknown frame pointer is refused');
end;

procedure TestLeb128;
const
  Bytes: array[0..5] of Byte = ($E5, $8E, $26, $7F, $80, $7F);
var
  Position: LongWord;
  Unsigned: QWord;
  Signed: Int64;
begin
  Position := 0;
  Check(ReadUnsignedLeb128(@Bytes[0], 6, Position, Unsigned) and (Unsigned = 624485) and (Position = 3),
    'ULEB128 624485');
  Check(ReadSignedLeb128(@Bytes[0], 6, Position, Signed) and (Signed = -1), 'SLEB128 -1');
  Check(ReadSignedLeb128(@Bytes[0], 6, Position, Signed) and (Signed = -128), 'SLEB128 -128');
  Position := 1;
  Check(not ReadUnsignedLeb128(@Bytes[0], 2, Position, Unsigned), 'a truncated ULEB128 fails');
end;

procedure CheckName(const Symbol, Expected: string);
var
  Readable: array[0..95] of Char;
begin
  ReadableSymbolName(PChar(Symbol), @Readable[0], SizeOf(Readable));
  Check(StrPas(@Readable[0]) = Expected, Format('%s reads as "%s", expected "%s"',
    [Symbol, StrPas(@Readable[0]), Expected]));
end;

procedure TestSymbolNames;
var
  Short: array[0..7] of Char;
begin
  CheckName('P$CORETEST_$$_CRASHONPURPOSE', 'CORETEST.CRASHONPURPOSE');
  CheckName('SYSTEM_$$_SYSENTRY$TENTRYINFORMATION', 'SYSTEM.SYSENTRY');
  CheckName('SYSUTILS_$$_FORMAT$ANSISTRING$array_of_const$$ANSISTRING', 'SYSUTILS.FORMAT');
  CheckName('UNIT_$$_OUTER$LONGINT$$BOOLEAN_$$_INNER', 'UNIT.OUTER.INNER');
  CheckName('CLASSES$_$TLIST_$__$$_ADD$POINTER$$LONGINT', 'CLASSES.TLIST.ADD');
  CheckName('INIT$_$SYSUTILS', 'SYSUTILS.initialization');
  CheckName('FINALIZE$_$CLASSES', 'CLASSES.finalization');
  CheckName('main', 'main');
  CheckName('__libc_start_main', '__libc_start_main');
  ReadableSymbolName('P$CORETEST_$$_CRASHONPURPOSE', @Short[0], SizeOf(Short));
  Check(StrPas(@Short[0]) = 'CORETES', 'a long name is cut to the capacity');
end;

begin
  if ParamCount <> 1 then
  begin
    WriteLn('usage: CallFrameInfoTest FIXTURE_DIRECTORY');
    Halt(2);
  end;
  LoadMemory(ParamStr(1) + '/memory.bin');
  Memory.Read := @ReadTestMemory;
  Memory.Context := nil;
  SetUpArchitectures;
  TestLeb128;
  TestX86EhFrame;
  TestFreePascalDebugFrame;
  TestStandardDebugFrame;
  TestAarch64EhFrame;
  TestFramePointers;
  TestSymbolNames;
  if Failures > 0 then
  begin
    WriteLn('call frame information test: ', Failures, ' failed');
    Halt(1);
  end;
  WriteLn('call frame information test: passed');
end.
