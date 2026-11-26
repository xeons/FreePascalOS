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

{ The interpreter's cases (Wasm.Interpreter.Execute) of WebAssembly 3.0:
  tail calls and call_ref, typed references, exceptions, memories other
  than an i32 memory 0, and the garbage collection instructions (whose
  work is done in Wasm.GcOperations; the allocating ones go through
  Allocate, which collects first when the heap asks). }

CodeReturnCall:
  begin
    Callee := Instance.Functions[P^.A];
    ArgumentBase := P^.B;
    goto DoTailCall;
  end;
CodeReturnCallIndirect, CodeReturnCallIndirect64:
  begin
    Table := Instance.Tables[P^.C];
    if P^.Operation = CodeReturnCallIndirect64 then
      Element := S[P^.B + P^.Extra]
    else
      Element := PDWord(@S[P^.B + P^.Extra])^;
    if Element >= QWord(Length(Table.Elements)) then
    begin
      TrapKind := tkUndefinedElement;
      goto Trapped;
    end;
    Callee := TWasmFunction(Table.Elements[Element]);
    if Callee = nil then
    begin
      TrapKind := tkUninitializedElement;
      goto Trapped;
    end;
    if not CallTypeMatches(Store, Callee.TypeId, Instance.TypeIds[P^.A]) then
    begin
      TrapKind := tkIndirectCallTypeMismatch;
      goto Trapped;
    end;
    ArgumentBase := P^.B;
    goto DoTailCall;
  end;
CodeCallRef, CodeReturnCallRef:
  begin
    Callee := TWasmFunction(PtrUInt(S[P^.B + P^.Extra]));
    if Callee = nil then
    begin
      TrapKind := tkNullFunctionReference;
      goto Trapped;
    end;
    ArgumentBase := P^.B;
    if P^.Operation = CodeCallRef then
      goto DoCall;
    goto DoTailCall;
  end;
CodeBranchIfNull:
  if S[P^.B] = 0 then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeBranchIfNonNull:
  if S[P^.B] <> 0 then
  begin
    Target := P^.A;
    if P^.Extra <> 0 then
    begin
      Dec(Store.InterruptCountdown);
      if Store.InterruptCountdown <= 0 then
        goto InterruptCheck;
    end;
    P := @CodeStart[Target];
    Continue;
  end;
CodeRefAsNonNull:
  begin
    if S[P^.B] = 0 then
    begin
      TrapKind := tkNullReference;
      goto Trapped;
    end;
    S[P^.A] := S[P^.B];
  end;
CodeRefEq:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] = S[P^.C]);
CodeThrow:
  begin
    Value := ThrowAt(Store, Func, Instance.Tags[P^.B], Base, P^.A,
      (PtrUInt(P) - PtrUInt(CodeStart)) div SizeOf(TCodeInstruction));
    if Value = nil then
    begin
      TrapKind := tkOutOfMemory;
      goto Trapped;
    end;
    goto ThrowException;
  end;
CodeThrowRef, CodeRethrow:
  begin
    Value := PWasmGcObject(PtrUInt(S[P^.A]));
    if Value = nil then
    begin
      TrapKind := tkNullExceptionReference;
      goto Trapped;
    end;
    goto ThrowException;
  end;
CodeMemoryAccessAt, CodeMemorySizeAt, CodeMemoryGrowAt, CodeMemoryFillAt, CodeMemoryCopyAt, CodeMemoryInitAt:
  begin
    Index := ExecuteMemoryAt(Instance, P^, S, PQWord(Code.Constants));
    if Instance.DefaultMemory <> nil then
    begin
      MemoryBase := Instance.DefaultMemory.Data;
      MemoryLength := Instance.DefaultMemory.ByteLength;
    end;
    if Index <> NoTrap then
    begin
      TrapKind := TWasmTrapKind(Index);
      goto Trapped;
    end;
  end;
CodeStructNew, CodeStructNewDefault, CodeArrayNew, CodeArrayNewDefault, CodeArrayNewFixed, CodeArrayNewData,
CodeArrayNewElem, CodeAnyConvertExtern:
  goto Allocate;
CodeRefTest, CodeRefCast, CodeStructGet, CodeStructSet, CodeArrayGet, CodeArraySet, CodeArrayLen, CodeArrayFill,
CodeArrayCopy, CodeArrayInitData, CodeArrayInitElem, CodeExternConvertAny, CodeRefI31, CodeI31Get:
  begin
    Index := ExecuteGcOperation(Store, Instance, P^, S);
    if Index <> NoTrap then
    begin
      TrapKind := TWasmTrapKind(Index);
      goto Trapped;
    end;
  end;
