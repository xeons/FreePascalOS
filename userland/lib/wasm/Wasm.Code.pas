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
  The compiled form of a function, which the interpreter runs.

  A frame is an array of 64-bit slots: the parameters, then the declared
  locals, then the operand stack (a v128 takes two slots). Since the
  validator knows the height of the operand stack at every instruction,
  every operand has a fixed slot, and the compiled code names slots
  directly, like registers: i32.add becomes "slot A := slot B + slot C".
  Every operation reads all its operands before it writes its result,
  so a result may go to a slot that is also an operand.
  A local.get does not copy: its operand reads the local's slot until
  something would change the local or a block boundary comes, and a
  result that goes straight into a local (local.set after an operation)
  is written there. Branches are code indices, with the values a branch
  carries moved to the target's slots first.

  An instruction is 16 bytes: the operation, a 16-bit extra immediate
  (a lane, a memory index, the parameter slots of call_indirect, the
  condition slot of select) and three 32-bit operands A, B and C, whose
  meaning each operation defines below. Operations that exist in
  WebAssembly keep its code (Wasm.Opcodes); the ones of the compiled
  form alone are numbered from CodeFirst on.

  Memory instructions: A the value (loaded into or stored from), B the
  address, C the offset (unsigned), Extra the memory index.

  A function's frame begins where its caller's operand stack had the
  arguments, so a call copies nothing: the callee's parameters are the
  caller's argument slots, and its results land where the arguments
  were.
}
unit Wasm.Code;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Opcodes;

const
  CodeFirst = LastWasmOpcode + 1;
  CodeCopy = CodeFirst + 0;            { A := B }
  CodeCopy128 = CodeFirst + 1;         { A, A+1 := B, B+1 }
  CodeCopyRange = CodeFirst + 2;       { C slots from B to A }
  CodeConst32 = CodeFirst + 3;         { A := B (32 bits) }
  CodeConst64 = CodeFirst + 4;         { A := B or C shl 32 }
  CodeConst128 = CodeFirst + 5;        { A, A+1 := Constants[B], Constants[B+1] }
  { Branches go to A; Extra is 1 on a back edge (to a loop), which counts
    down to the next interrupt check. }
  CodeBranch = CodeFirst + 6;          { go to A }
  CodeNop = CodeFirst + 7;             { nothing (a removed instruction) }
  CodeBranchIf = CodeFirst + 8;        { if B (i32) <> 0 go to A }
  CodeUnused = CodeFirst + 9;
  CodeBranchUnless = CodeFirst + 10;   { if B (i32) = 0 go to A }
  CodeBranchTable = CodeFirst + 11;    { go to BranchTargets[B + min(slot A, C)] }
  CodeReturn = CodeFirst + 12;         { results: B slots from A to the frame's slot 0 }
  CodeCall = CodeFirst + 13;           { function A, its frame at slot B }
  CodeCallIndirect = CodeFirst + 14;   { type A, frame at B, table C; Extra parameter slots (index after them) }
  CodeSelect = CodeFirst + 15;         { A := if slot Extra then B else C }
  CodeSelectAtHome = CodeFirst + 16;   { A := if A+2 then A else A+1 }
  CodeSelect128 = CodeFirst + 17;      { as CodeSelect for v128 }
  CodeSelect128AtHome = CodeFirst + 18; { A := if A+4 then A else A+2 }
  CodeGlobalGet = CodeFirst + 19;      { A := global B }
  CodeGlobalGet128 = CodeFirst + 20;
  CodeGlobalSet = CodeFirst + 21;      { global B := A }
  CodeGlobalSet128 = CodeFirst + 22;
  { Comparisons fused with the branch that tests them: go to A if B op C. }
  CodeBranchIfI32Eqz = CodeFirst + 23;  { if B = 0 }
  CodeBranchIfI32Eq = CodeFirst + 24;
  CodeBranchIfI32Ne = CodeFirst + 25;
  CodeBranchIfI32LtS = CodeFirst + 26;
  CodeBranchIfI32LtU = CodeFirst + 27;
  CodeBranchIfI32GtS = CodeFirst + 28;
  CodeBranchIfI32GtU = CodeFirst + 29;
  CodeBranchIfI32LeS = CodeFirst + 30;
  CodeBranchIfI32LeU = CodeFirst + 31;
  CodeBranchIfI32GeS = CodeFirst + 32;
  CodeBranchIfI32GeU = CodeFirst + 33;
  { An i32 operation with a constant: A := B op C. }
  CodeI32AddImmediate = CodeFirst + 34;
  CodeI32AndImmediate = CodeFirst + 35;
  CodeI32OrImmediate = CodeFirst + 36;
  CodeI32XorImmediate = CodeFirst + 37;
  CodeI32ShlImmediate = CodeFirst + 38;
  CodeI32ShrSImmediate = CodeFirst + 39;
  CodeI32ShrUImmediate = CodeFirst + 40;
  CodeI32MulImmediate = CodeFirst + 41;
  CodeI32EqImmediate = CodeFirst + 42;
  CodeI32NeImmediate = CodeFirst + 43;
  CodeI32LtSImmediate = CodeFirst + 44;
  CodeI32LtUImmediate = CodeFirst + 45;
  CodeI32GtSImmediate = CodeFirst + 46;
  CodeI32GtUImmediate = CodeFirst + 47;
  CodeI32LeSImmediate = CodeFirst + 48;
  CodeI32LeUImmediate = CodeFirst + 49;
  CodeI32GeSImmediate = CodeFirst + 50;
  CodeI32GeUImmediate = CodeFirst + 51;
  CodeI64AddImmediate = CodeFirst + 52;  { C sign extended }
  CodeI64AndImmediate = CodeFirst + 53;
  CodeI64ShlImmediate = CodeFirst + 54;
  CodeI64ShrUImmediate = CodeFirst + 55;
  CodeI64ShrSImmediate = CodeFirst + 56;
  CodeLast = CodeI64ShrSImmediate;

type
  TCodeInstruction = packed record
    Operation: Word;
    Extra: Word;
    A: Int32;
    B: Int32;
    C: Int32;
  end;
  PCodeInstruction = ^TCodeInstruction;

  TCompiledFunction = class
  public
    Instructions: array of TCodeInstruction;
    { The module offset of the WebAssembly instruction each one came from. }
    ByteOffsets: array of Int32;
    Constants: array of QWord;
    BranchTargets: array of Int32;
    FunctionIndex: Cardinal;
    ParamSlots: Integer;
    LocalSlots: Integer;    { parameters and declared locals }
    FrameSlots: Integer;    { locals and the deepest operand stack }
    { Where externrefs are live when the function is suspended at a call
      or a back edge (for an embedder's garbage collector): the slots of
      the safepoint at instruction SafepointInstructions[i] are
      SafepointSlots[SafepointStarts[i] .. SafepointStarts[i + 1]). }
    SafepointInstructions: array of Int32;
    SafepointStarts: array of Int32;
    SafepointSlots: array of Int32;
    { The slots live at instruction Index; False if it is no safepoint. }
    function FindSafepoint(Index: Integer; out First, Limit: Integer): Boolean;
  end;

implementation

function TCompiledFunction.FindSafepoint(Index: Integer; out First, Limit: Integer): Boolean;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := Length(SafepointInstructions) - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if SafepointInstructions[Middle] = Index then
    begin
      First := SafepointStarts[Middle];
      Limit := SafepointStarts[Middle + 1];
      Exit(True);
    end;
    if SafepointInstructions[Middle] < Index then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  First := 0;
  Limit := 0;
  Result := False;
end;

end.
