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

{ The body validator (Wasm.CodeValidator): calls, tail calls (whose
  callee's results must match the caller's) and exception handling, the
  standard form (throw, throw_ref, try_table, whose catch clauses name
  labels outside it) and the legacy one (try, catch, catch_all,
  delegate, rethrow). }

procedure TWasmCodeValidator.ValidateCall(const Instruction: TWasmInstruction);
var
  FunctionType: TWasmFunctionType;
  Index: Integer;
  IsTail: Boolean;
begin
  case Instruction.Opcode of
    OpCall, OpReturnCall:
      begin
        CheckFunction(Instruction.Index);
        FunctionType := FModule.FunctionType(Instruction.Index);
        PopTypes(FunctionType.Params);
      end;
    OpCallIndirect, OpReturnCallIndirect:
      begin
        CheckTable(Instruction.SecondIndex);
        if not Matches(FModule.Tables[Instruction.SecondIndex].ElementType, WasmFuncRefType) then
          Fail('type mismatch');
        FunctionType := FunctionTypeAt(Instruction.Index);
        PopExpected(TableAddressType(Instruction.SecondIndex));
        PopTypes(FunctionType.Params);
      end;
  else
    begin
      FunctionType := FunctionTypeAt(Instruction.Index);
      PopExpected(MakeReferenceType(HeapType(Instruction.Index), True));
      PopTypes(FunctionType.Params);
    end;
  end;
  IsTail := Instruction.Opcode in [OpReturnCall, OpReturnCallIndirect, OpReturnCallRef];
  if IsTail then
  begin
    if Length(FunctionType.Results) <> Length(FResults) then
      Fail('type mismatch: tail call results');
    for Index := 0 to High(FResults) do
      if not Matches(FunctionType.Results[Index], FResults[Index]) then
        Fail('type mismatch: tail call results');
    MarkUnreachable;
  end
  else
    PushTypes(FunctionType.Results);
end;

procedure TWasmCodeValidator.ValidateException(const Instruction: TWasmInstruction;
  const Catches: array of TWasmCatchClause);
var
  StartTypes, EndTypes, Provided, Expected: TWasmValueTypeArray;
  Frame: TControlFrame;
  Clause, Index: Integer;
begin
  case Instruction.Opcode of
    OpTry:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        PopTypes(StartTypes);
        PushControl(OpTry, StartTypes, EndTypes);
      end;
    OpCatch, OpCatchAll:
      begin
        Frame := PopControl;
        if (Frame.Opcode <> OpTry) and (Frame.Opcode <> OpCatch) then
          Fail('catch without try');
        if Instruction.Opcode = OpCatch then
        begin
          CheckTag(Instruction.Index);
          PushControl(OpCatch, FModule.TagType(Instruction.Index).Params, Frame.EndTypes);
        end
        else
          PushControl(OpCatchAll, nil, Frame.EndTypes);
      end;
    OpDelegate:
      begin
        Frame := PopControl;
        if Frame.Opcode <> OpTry then
          Fail('delegate without try');
        Label_(Instruction.Index);
        PushTypes(Frame.EndTypes);
      end;
    OpThrow:
      begin
        CheckTag(Instruction.Index);
        PopTypes(FModule.TagType(Instruction.Index).Params);
        MarkUnreachable;
      end;
    OpRethrow:
      begin
        Frame := FControls[Label_(Instruction.Index)];
        if (Frame.Opcode <> OpCatch) and (Frame.Opcode <> OpCatchAll) then
          Fail('invalid rethrow label');
        MarkUnreachable;
      end;
    OpThrowRef:
      begin
        PopExpected(MakeReferenceType(HeapTypeExn, True));
        MarkUnreachable;
      end;
    OpTryTable:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        for Clause := 0 to Integer(Instruction.CatchCount) - 1 do
        begin
          Provided := nil;
          if Catches[Clause].Kind in [ckCatch, ckCatchRef] then
          begin
            CheckTag(Catches[Clause].Tag);
            Provided := Copy(FModule.TagType(Catches[Clause].Tag).Params);
          end;
          if Catches[Clause].Kind in [ckCatchRef, ckCatchAllRef] then
          begin
            SetLength(Provided, Length(Provided) + 1);
            Provided[High(Provided)] := MakeReferenceType(HeapTypeExn, False);
          end;
          Expected := LabelTypes(FControls[Label_(Catches[Clause].LabelIndex)]);
          if Length(Expected) <> Length(Provided) then
            Fail('type mismatch: catch label');
          for Index := 0 to High(Expected) do
            if not Matches(Provided[Index], Expected[Index]) then
              Fail('type mismatch: catch label');
        end;
        PopTypes(StartTypes);
        PushControl(OpTryTable, StartTypes, EndTypes);
      end;
  end;
end;
