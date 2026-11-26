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

{ The interpreter's cases (Wasm.Interpreter.Execute): moving values,
  branches, calls and returns, select, globals, references, tables and
  the bulk memory and table operations. }

CodeCopy:
  S[P^.A] := S[P^.B];
CodeCopy128:
  begin
    U64A := S[P^.B];
    Element := S[P^.B + 1];
    S[P^.A] := U64A;
    S[P^.A + 1] := Element;
  end;
CodeCopyRange:
  Move(S[P^.B], S[P^.A], SizeInt(P^.C) * SizeOf(QWord));
CodeConst32:
  PDWord(@S[P^.A])^ := DWord(P^.B);
CodeConst64:
  S[P^.A] := QWord(DWord(P^.B)) or (QWord(DWord(P^.C)) shl 32);
CodeConst128:
  begin
    S[P^.A] := Code.Constants[P^.B];
    S[P^.A + 1] := Code.Constants[P^.B + 1];
  end;
CodeNop: ;
CodeBranch:
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
CodeBranchIf:
  if PDWord(@S[P^.B])^ <> 0 then
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
CodeBranchUnless:
  if PDWord(@S[P^.B])^ = 0 then
  begin
    P := @CodeStart[P^.A];
    Continue;
  end;
CodeBranchTable:
  begin
    U32A := PDWord(@S[P^.A])^;
    if U32A > DWord(P^.C) then
      U32A := DWord(P^.C);
    P := @CodeStart[Code.BranchTargets[P^.B + Int32(U32A)]];
    Continue;
  end;
CodeReturn:
  begin
    if (P^.A <> 0) and (P^.B > 0) then
      Move(S[P^.A], S[0], SizeInt(P^.B) * SizeOf(QWord));
    if Store.FrameCount = EntryFrameCount then
      goto Finished;
    Dec(Store.FrameCount);
    Func := Store.Frames[Store.FrameCount].Func;
    Base := Store.Frames[Store.FrameCount].Base;
    Index := Store.Frames[Store.FrameCount].ResumeIndex;
    Code := Func.Code;
    CodeStart := @Code.Instructions[0];
    P := @CodeStart[Index];
    S := @Store.Stack[Base];
    Instance := Func.Instance;
    if Instance.DefaultMemory <> nil then
    begin
      MemoryBase := Instance.DefaultMemory.Data;
      MemoryLength := Instance.DefaultMemory.ByteLength;
    end
    else
    begin
      MemoryBase := nil;
      MemoryLength := 0;
    end;
    Continue;
  end;
CodeCall:
  begin
    Callee := Instance.Functions[P^.A];
    ArgumentBase := P^.B;
    goto DoCall;
  end;
CodeCallIndirect:
  begin
    Table := Instance.Tables[P^.C];
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
    if Callee.TypeId <> Instance.TypeIds[P^.A] then
    begin
      TrapKind := tkIndirectCallTypeMismatch;
      goto Trapped;
    end;
    ArgumentBase := P^.B;
    goto DoCall;
  end;
OpUnreachable:
  begin
    TrapKind := tkUnreachable;
    goto Trapped;
  end;
CodeSelect:
  if PDWord(@S[P^.Extra])^ <> 0 then
    S[P^.A] := S[P^.B]
  else
    S[P^.A] := S[P^.C];
CodeSelectAtHome:
  if PDWord(@S[P^.A + 2])^ = 0 then
    S[P^.A] := S[P^.A + 1];
CodeSelect128:
  begin
    if PDWord(@S[P^.Extra])^ <> 0 then
      Slot := P^.B
    else
      Slot := P^.C;
    U64A := S[Slot];
    Element := S[Slot + 1];
    S[P^.A] := U64A;
    S[P^.A + 1] := Element;
  end;
CodeSelect128AtHome:
  if PDWord(@S[P^.A + 4])^ = 0 then
  begin
    S[P^.A] := S[P^.A + 2];
    S[P^.A + 1] := S[P^.A + 3];
  end;
CodeGlobalGet:
  S[P^.A] := Instance.Globals[P^.B].Value.QWords[0];
CodeGlobalGet128:
  begin
    S[P^.A] := Instance.Globals[P^.B].Value.QWords[0];
    S[P^.A + 1] := Instance.Globals[P^.B].Value.QWords[1];
  end;
CodeGlobalSet:
  Instance.Globals[P^.B].Value.QWords[0] := S[P^.A];
CodeGlobalSet128:
  begin
    Instance.Globals[P^.B].Value.QWords[0] := S[P^.A];
    Instance.Globals[P^.B].Value.QWords[1] := S[P^.A + 1];
  end;
OpRefIsNull:
  PDWord(@S[P^.A])^ := Ord(S[P^.B] = 0);
OpRefFunc:
  S[P^.A] := QWord(PtrUInt(Instance.Functions[P^.B]));
OpTableGet:
  begin
    Table := Instance.Tables[P^.C];
    Element := PDWord(@S[P^.B])^;
    if Element >= QWord(Length(Table.Elements)) then
    begin
      TrapKind := tkTableOutOfBounds;
      goto Trapped;
    end;
    S[P^.A] := QWord(PtrUInt(Table.Elements[Element]));
  end;
OpTableSet:
  begin
    Table := Instance.Tables[P^.C];
    Element := PDWord(@S[P^.A])^;
    if Element >= QWord(Length(Table.Elements)) then
    begin
      TrapKind := tkTableOutOfBounds;
      goto Trapped;
    end;
    Table.Elements[Element] := Pointer(PtrUInt(S[P^.B]));
  end;
OpTableSize:
  PDWord(@S[P^.A])^ := DWord(Length(Instance.Tables[P^.C].Elements));
OpTableGrow:
  begin
    Grown := Instance.Tables[P^.C].Grow(PDWord(@S[P^.A + 1])^, Pointer(PtrUInt(S[P^.A])));
    PInt32(@S[P^.A])^ := Int32(Grown);
  end;
OpTableFill:
  begin
    Table := Instance.Tables[P^.C];
    Destination := PDWord(@S[P^.A])^;
    Value := Pointer(PtrUInt(S[P^.A + 1]));
    Count := PDWord(@S[P^.A + 2])^;
    if Destination + Count > QWord(Length(Table.Elements)) then
    begin
      TrapKind := tkTableOutOfBounds;
      goto Trapped;
    end;
    while Count > 0 do
    begin
      Table.Elements[Destination] := Value;
      Inc(Destination);
      Dec(Count);
    end;
  end;
OpTableCopy:
  begin
    Table := Instance.Tables[P^.B];
    SourceTable := Instance.Tables[P^.C];
    Destination := PDWord(@S[P^.A])^;
    Source := PDWord(@S[P^.A + 1])^;
    Count := PDWord(@S[P^.A + 2])^;
    if (Source + Count > QWord(Length(SourceTable.Elements))) or
      (Destination + Count > QWord(Length(Table.Elements))) then
    begin
      TrapKind := tkTableOutOfBounds;
      goto Trapped;
    end;
    if Count > 0 then
      Move(SourceTable.Elements[Source], Table.Elements[Destination], Count * SizeOf(Pointer));
  end;
OpTableInit:
  begin
    Table := Instance.Tables[P^.C];
    Destination := PDWord(@S[P^.A])^;
    Source := PDWord(@S[P^.A + 1])^;
    Count := PDWord(@S[P^.A + 2])^;
    if (Source + Count > QWord(Length(Instance.ElementSegments[P^.B]))) or
      (Destination + Count > QWord(Length(Table.Elements))) then
    begin
      TrapKind := tkTableOutOfBounds;
      goto Trapped;
    end;
    if Count > 0 then
      Move(Instance.ElementSegments[P^.B][Source], Table.Elements[Destination], Count * SizeOf(Pointer));
  end;
OpElemDrop:
  Instance.ElementSegments[P^.A] := nil;
OpMemoryInit:
  begin
    Destination := PDWord(@S[P^.A])^;
    Source := PDWord(@S[P^.A + 1])^;
    Count := PDWord(@S[P^.A + 2])^;
    if Instance.DataDropped[P^.B] then
      Element := 0
    else
      Element := Instance.Module.Data[P^.B].DataLength;
    if (Source + Count > Element) or (Destination + Count > MemoryLength) then
    begin
      TrapKind := tkMemoryOutOfBounds;
      goto Trapped;
    end;
    if Count > 0 then
      Move(Instance.Module.Bytes[Instance.Module.Data[P^.B].DataStart + SizeInt(Source)], MemoryBase[Destination], Count);
  end;
OpDataDrop:
  Instance.DataDropped[P^.A] := True;
OpMemoryCopy:
  begin
    Destination := PDWord(@S[P^.A])^;
    Source := PDWord(@S[P^.A + 1])^;
    Count := PDWord(@S[P^.A + 2])^;
    if (Source + Count > MemoryLength) or (Destination + Count > MemoryLength) then
    begin
      TrapKind := tkMemoryOutOfBounds;
      goto Trapped;
    end;
    if Count > 0 then
      Move(MemoryBase[Source], MemoryBase[Destination], Count);
  end;
OpMemoryFill:
  begin
    Destination := PDWord(@S[P^.A])^;
    U32A := PDWord(@S[P^.A + 1])^;
    Count := PDWord(@S[P^.A + 2])^;
    if Destination + Count > MemoryLength then
    begin
      TrapKind := tkMemoryOutOfBounds;
      goto Trapped;
    end;
    if Count > 0 then
      FillChar(MemoryBase[Destination], Count, Byte(U32A));
  end;
OpMemorySize:
  PDWord(@S[P^.A])^ := DWord(MemoryLength div WasmPageSize);
OpMemoryGrow:
  begin
    Memory := Instance.DefaultMemory;
    Grown := Memory.Grow(PDWord(@S[P^.B])^);
    MemoryBase := Memory.Data;
    MemoryLength := Memory.ByteLength;
    PInt32(@S[P^.A])^ := Int32(Grown);
  end;
