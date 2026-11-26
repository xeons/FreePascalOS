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
  Validation of function bodies: the algorithm of the spec's appendix
  (section A.3), an operand stack of types and a control stack of
  frames. After an unconditional branch the rest of a block is
  unreachable and its operand stack polymorphic: popping below the
  frame's height then gives an unknown type, which matches anything.

  Instructions with a fixed type come with a signature in the opcode
  table (Wasm.Opcodes); the rest are typed here one by one. Errors are
  EWasmInvalid with the offset of the instruction.
}
unit Wasm.CodeValidator;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types,
  Wasm.Module,
  Wasm.Instructions;

type
  TOperandType = record
    Known: Boolean;
    ValueType: TWasmValueType;
  end;

  TControlFrame = record
    Opcode: Integer;
    StartTypes: TWasmValueTypeArray;
    EndTypes: TWasmValueTypeArray;
    Height: Integer;
    Unreachable: Boolean;
  end;

  TWasmCodeValidator = class
  private
    FModule: TWasmModule;
    FDeclaredReferences: array of Boolean;
    FLocals: TWasmValueTypeArray;
    FOperands: array of TOperandType;
    FOperandCount: Integer;
    FControls: array of TControlFrame;
    FControlCount: Integer;
    FOffset: SizeInt;
    procedure Fail(const Message: AnsiString);
    procedure PushOperand(const ValueType: TWasmValueType);
    procedure PushUnknown;
    function PopOperand: TOperandType;
    function PopExpected(const Expected: TWasmValueType): TOperandType;
    procedure PushTypes(const Types: TWasmValueTypeArray);
    procedure PopTypes(const Types: TWasmValueTypeArray);
    procedure PushControl(Opcode: Integer; const StartTypes, EndTypes: TWasmValueTypeArray);
    function PopControl: TControlFrame;
    function LabelTypes(const Frame: TControlFrame): TWasmValueTypeArray;
    procedure MarkUnreachable;
    function Label_(Depth: Cardinal): Integer;
    procedure BlockSignature(const BlockType: TWasmBlockType; out StartTypes, EndTypes: TWasmValueTypeArray);
    procedure ApplySignature(const Signature: ShortString);
    procedure CheckMemory(Index: Cardinal);
    procedure CheckMemarg(const Instruction: TWasmInstruction);
    procedure CheckLane(const Instruction: TWasmInstruction);
    procedure CheckTable(Index: Cardinal);
    procedure CheckFunction(Index: Cardinal);
    procedure CheckElement(Index: Cardinal);
    procedure CheckData(Index: Cardinal);
    procedure ValidateInstruction(const Instruction: TWasmInstruction; const Labels: array of Cardinal);
  public
    constructor Create(AModule: TWasmModule; const DeclaredReferences: array of Boolean);
    { Validates the body of the defined function DefinedIndex (its index
      among the module's own functions). }
    procedure ValidateFunction(DefinedIndex: Cardinal);
  end;

{ The type a signature letter of Wasm.Opcodes stands for. }
function SignatureLetterType(Letter: AnsiChar): TWasmValueType;

implementation

uses
  SysUtils,
  Wasm.Errors,
  Wasm.Opcodes;

function SignatureLetterType(Letter: AnsiChar): TWasmValueType;
begin
  case Letter of
    'i': Result := WasmI32Type;
    'l': Result := WasmI64Type;
    'f': Result := WasmF32Type;
    'd': Result := WasmF64Type;
    'v': Result := WasmV128Type;
  else
    Result := WasmFuncRefType;
  end;
end;

constructor TWasmCodeValidator.Create(AModule: TWasmModule; const DeclaredReferences: array of Boolean);
var
  Index: Integer;
begin
  inherited Create;
  FModule := AModule;
  SetLength(FDeclaredReferences, Length(DeclaredReferences));
  for Index := 0 to High(DeclaredReferences) do
    FDeclaredReferences[Index] := DeclaredReferences[Index];
end;

procedure TWasmCodeValidator.Fail(const Message: AnsiString);
begin
  raise EWasmInvalid.CreateAt(FOffset, Message);
end;

procedure TWasmCodeValidator.PushOperand(const ValueType: TWasmValueType);
begin
  if FOperandCount >= Length(FOperands) then
    SetLength(FOperands, FOperandCount * 2 + 16);
  FOperands[FOperandCount].Known := True;
  FOperands[FOperandCount].ValueType := ValueType;
  Inc(FOperandCount);
end;

procedure TWasmCodeValidator.PushUnknown;
begin
  if FOperandCount >= Length(FOperands) then
    SetLength(FOperands, FOperandCount * 2 + 16);
  FOperands[FOperandCount].Known := False;
  FOperands[FOperandCount].ValueType := WasmI32Type;
  Inc(FOperandCount);
end;

function TWasmCodeValidator.PopOperand: TOperandType;
begin
  with FControls[FControlCount - 1] do
    if FOperandCount = Height then
    begin
      if Unreachable then
      begin
        Result.Known := False;
        Result.ValueType := WasmI32Type;
        Exit;
      end;
      Fail('type mismatch');
    end;
  Dec(FOperandCount);
  Result := FOperands[FOperandCount];
end;

function TWasmCodeValidator.PopExpected(const Expected: TWasmValueType): TOperandType;
begin
  Result := PopOperand;
  if Result.Known and (Result.ValueType <> Expected) then
    Fail('type mismatch');
  if not Result.Known then
  begin
    Result.Known := True;
    Result.ValueType := Expected;
  end;
end;

procedure TWasmCodeValidator.PushTypes(const Types: TWasmValueTypeArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Types) do
    PushOperand(Types[Index]);
end;

procedure TWasmCodeValidator.PopTypes(const Types: TWasmValueTypeArray);
var
  Index: Integer;
begin
  for Index := High(Types) downto 0 do
    PopExpected(Types[Index]);
end;

procedure TWasmCodeValidator.PushControl(Opcode: Integer; const StartTypes, EndTypes: TWasmValueTypeArray);
begin
  if FControlCount >= Length(FControls) then
    SetLength(FControls, FControlCount * 2 + 8);
  FControls[FControlCount].Opcode := Opcode;
  FControls[FControlCount].StartTypes := StartTypes;
  FControls[FControlCount].EndTypes := EndTypes;
  FControls[FControlCount].Height := FOperandCount;
  FControls[FControlCount].Unreachable := False;
  Inc(FControlCount);
  PushTypes(StartTypes);
end;

function TWasmCodeValidator.PopControl: TControlFrame;
begin
  if FControlCount = 0 then
    Fail('type mismatch');
  Result := FControls[FControlCount - 1];
  PopTypes(Result.EndTypes);
  if FOperandCount <> Result.Height then
    Fail('type mismatch');
  Dec(FControlCount);
end;

function TWasmCodeValidator.LabelTypes(const Frame: TControlFrame): TWasmValueTypeArray;
begin
  if Frame.Opcode = OpLoop then
    Result := Frame.StartTypes
  else
    Result := Frame.EndTypes;
end;

procedure TWasmCodeValidator.MarkUnreachable;
begin
  FOperandCount := FControls[FControlCount - 1].Height;
  FControls[FControlCount - 1].Unreachable := True;
end;

function TWasmCodeValidator.Label_(Depth: Cardinal): Integer;
begin
  if Depth >= Cardinal(FControlCount) then
    Fail('unknown label');
  Result := FControlCount - 1 - Integer(Depth);
end;

procedure TWasmCodeValidator.BlockSignature(const BlockType: TWasmBlockType;
  out StartTypes, EndTypes: TWasmValueTypeArray);
begin
  StartTypes := nil;
  EndTypes := nil;
  case BlockType.Kind of
    btEmpty: ;
    btValue:
      begin
        SetLength(EndTypes, 1);
        EndTypes[0] := BlockType.ValueType;
      end;
    btTypeIndex:
      begin
        if BlockType.TypeIndex >= Cardinal(Length(FModule.Types)) then
          Fail('unknown type');
        StartTypes := FModule.Types[BlockType.TypeIndex].Params;
        EndTypes := FModule.Types[BlockType.TypeIndex].Results;
      end;
  end;
end;

procedure TWasmCodeValidator.ApplySignature(const Signature: ShortString);
var
  Separator, Index: Integer;
begin
  Separator := Pos('>', Signature);
  for Index := Separator - 1 downto 1 do
    PopExpected(SignatureLetterType(Signature[Index]));
  for Index := Separator + 1 to Length(Signature) do
    PushOperand(SignatureLetterType(Signature[Index]));
end;

procedure TWasmCodeValidator.CheckMemory(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.Memories)) then
    Fail('unknown memory ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.CheckMemarg(const Instruction: TWasmInstruction);
begin
  CheckMemory(Instruction.MemoryIndex);
  if Instruction.Alignment > Cardinal(WasmOpcodeTable[Instruction.Opcode].Alignment) then
    Fail('alignment must not be larger than natural');
end;

procedure TWasmCodeValidator.CheckLane(const Instruction: TWasmInstruction);
begin
  if Instruction.Lane >= WasmOpcodeTable[Instruction.Opcode].Lanes then
    Fail('invalid lane index');
end;

procedure TWasmCodeValidator.CheckTable(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.Tables)) then
    Fail('unknown table ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.CheckFunction(Index: Cardinal);
begin
  if Index >= FModule.FunctionCount then
    Fail('unknown function ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.CheckElement(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.Elements)) then
    Fail('unknown elem segment ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.CheckData(Index: Cardinal);
begin
  if not FModule.HasDataCount or (Index >= FModule.DataCount) then
    Fail('unknown data segment ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.ValidateInstruction(const Instruction: TWasmInstruction;
  const Labels: array of Cardinal);
var
  StartTypes, EndTypes, Types, DefaultTypes: TWasmValueTypeArray;
  Frame: TControlFrame;
  First, Second: TOperandType;
  FunctionType: TWasmFunctionType;
  Index, Arity, Item: Integer;
  Popped: array of TOperandType;
  Info: ^TWasmOpcodeInfo;
begin
  FOffset := Instruction.Offset;
  Info := @WasmOpcodeTable[Instruction.Opcode];
  case Instruction.Opcode of
    OpUnreachable:
      MarkUnreachable;
    OpNop: ;
    OpBlock, OpLoop:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        PopTypes(StartTypes);
        PushControl(Instruction.Opcode, StartTypes, EndTypes);
      end;
    OpIf:
      begin
        BlockSignature(Instruction.BlockType, StartTypes, EndTypes);
        PopExpected(WasmI32Type);
        PopTypes(StartTypes);
        PushControl(OpIf, StartTypes, EndTypes);
      end;
    OpElse:
      begin
        Frame := PopControl;
        if Frame.Opcode <> OpIf then
          Fail('else without if');
        PushControl(OpElse, Frame.StartTypes, Frame.EndTypes);
      end;
    OpEnd:
      begin
        Frame := PopControl;
        if Frame.Opcode = OpIf then
        begin
          { An if without else passes its parameters through. }
          if Length(Frame.StartTypes) <> Length(Frame.EndTypes) then
            Fail('type mismatch');
          for Index := 0 to High(Frame.StartTypes) do
            if Frame.StartTypes[Index] <> Frame.EndTypes[Index] then
              Fail('type mismatch');
        end;
        PushTypes(Frame.EndTypes);
      end;
    OpBr:
      begin
        PopTypes(LabelTypes(FControls[Label_(Instruction.Index)]));
        MarkUnreachable;
      end;
    OpBrIf:
      begin
        PopExpected(WasmI32Type);
        Types := LabelTypes(FControls[Label_(Instruction.Index)]);
        PopTypes(Types);
        PushTypes(Types);
      end;
    OpBrTable:
      begin
        PopExpected(WasmI32Type);
        DefaultTypes := LabelTypes(FControls[Label_(Instruction.Index)]);
        Arity := Length(DefaultTypes);
        if Instruction.LabelCount > 0 then
          for Index := 0 to Integer(Instruction.LabelCount) - 1 do
          begin
            Types := LabelTypes(FControls[Label_(Labels[Index])]);
            if Length(Types) <> Arity then
              Fail('type mismatch');
            { Pop and push back what was there: unknown stays unknown. }
            SetLength(Popped, Length(Types));
            for Item := High(Types) downto 0 do
            begin
              Popped[Item] := PopOperand;
              if Popped[Item].Known and (Popped[Item].ValueType <> Types[Item]) then
                Fail('type mismatch');
            end;
            for Item := 0 to High(Types) do
              if Popped[Item].Known then
                PushOperand(Popped[Item].ValueType)
              else
                PushUnknown;
          end;
        PopTypes(DefaultTypes);
        MarkUnreachable;
      end;
    OpReturn:
      begin
        PopTypes(FControls[0].EndTypes);
        MarkUnreachable;
      end;
    OpCall:
      begin
        CheckFunction(Instruction.Index);
        FunctionType := FModule.FunctionType(Instruction.Index);
        PopTypes(FunctionType.Params);
        PushTypes(FunctionType.Results);
      end;
    OpCallIndirect:
      begin
        CheckTable(Instruction.SecondIndex);
        if FModule.Tables[Instruction.SecondIndex].ElementType <> WasmFuncRefType then
          Fail('type mismatch');
        if Instruction.Index >= Cardinal(Length(FModule.Types)) then
          Fail('unknown type');
        PopExpected(WasmI32Type);
        PopTypes(FModule.Types[Instruction.Index].Params);
        PushTypes(FModule.Types[Instruction.Index].Results);
      end;
    OpDrop:
      PopOperand;
    OpSelect:
      begin
        PopExpected(WasmI32Type);
        First := PopOperand;
        Second := PopOperand;
        if (First.Known and IsReferenceType(First.ValueType)) or
          (Second.Known and IsReferenceType(Second.ValueType)) then
          Fail('type mismatch');
        if First.Known and Second.Known and (First.ValueType <> Second.ValueType) then
          Fail('type mismatch');
        if First.Known then
          PushOperand(First.ValueType)
        else if Second.Known then
          PushOperand(Second.ValueType)
        else
          PushUnknown;
      end;
    OpSelectTyped:
      begin
        if Instruction.SelectTypeCount <> 1 then
          Fail('invalid result arity');
        PopExpected(WasmI32Type);
        PopExpected(Instruction.SelectType);
        PopExpected(Instruction.SelectType);
        PushOperand(Instruction.SelectType);
      end;
    OpLocalGet, OpLocalSet, OpLocalTee:
      begin
        if Instruction.Index >= Cardinal(Length(FLocals)) then
          Fail('unknown local ' + IntToStr(Instruction.Index));
        case Instruction.Opcode of
          OpLocalGet: PushOperand(FLocals[Instruction.Index]);
          OpLocalSet: PopExpected(FLocals[Instruction.Index]);
        else
          PopExpected(FLocals[Instruction.Index]);
          PushOperand(FLocals[Instruction.Index]);
        end;
      end;
    OpGlobalGet, OpGlobalSet:
      begin
        if Instruction.Index >= Cardinal(Length(FModule.Globals)) then
          Fail('unknown global ' + IntToStr(Instruction.Index));
        if Instruction.Opcode = OpGlobalGet then
          PushOperand(FModule.Globals[Instruction.Index].ValueType)
        else
        begin
          if not FModule.Globals[Instruction.Index].Mutable then
            Fail('global is immutable');
          PopExpected(FModule.Globals[Instruction.Index].ValueType);
        end;
      end;
    OpTableGet:
      begin
        CheckTable(Instruction.Index);
        PopExpected(WasmI32Type);
        PushOperand(FModule.Tables[Instruction.Index].ElementType);
      end;
    OpTableSet:
      begin
        CheckTable(Instruction.Index);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PopExpected(WasmI32Type);
      end;
    OpTableSize:
      begin
        CheckTable(Instruction.Index);
        PushOperand(WasmI32Type);
      end;
    OpTableGrow:
      begin
        CheckTable(Instruction.Index);
        PopExpected(WasmI32Type);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PushOperand(WasmI32Type);
      end;
    OpTableFill:
      begin
        CheckTable(Instruction.Index);
        PopExpected(WasmI32Type);
        PopExpected(FModule.Tables[Instruction.Index].ElementType);
        PopExpected(WasmI32Type);
      end;
    OpTableCopy:
      begin
        CheckTable(Instruction.Index);
        CheckTable(Instruction.SecondIndex);
        if FModule.Tables[Instruction.Index].ElementType <> FModule.Tables[Instruction.SecondIndex].ElementType then
          Fail('type mismatch');
        ApplySignature('iii>');
      end;
    OpTableInit:
      begin
        CheckTable(Instruction.SecondIndex);
        CheckElement(Instruction.Index);
        if FModule.Elements[Instruction.Index].ElementType <> FModule.Tables[Instruction.SecondIndex].ElementType then
          Fail('type mismatch');
        ApplySignature('iii>');
      end;
    OpElemDrop:
      CheckElement(Instruction.Index);
    OpMemoryInit:
      begin
        CheckMemory(Instruction.MemoryIndex);
        CheckData(Instruction.Index);
        ApplySignature('iii>');
      end;
    OpDataDrop:
      CheckData(Instruction.Index);
    OpRefNull:
      PushOperand(Instruction.ReferenceType);
    OpRefIsNull:
      begin
        First := PopOperand;
        if First.Known and not IsReferenceType(First.ValueType) then
          Fail('type mismatch');
        PushOperand(WasmI32Type);
      end;
    OpRefFunc:
      begin
        CheckFunction(Instruction.Index);
        if (Instruction.Index >= Cardinal(Length(FDeclaredReferences))) or
          not FDeclaredReferences[Instruction.Index] then
          Fail('undeclared function reference');
        PushOperand(WasmFuncRefType);
      end;
  else
    case Info^.Immediate of
      ikMemarg, ikMemargLane:
        begin
          CheckMemarg(Instruction);
          if Info^.Immediate = ikMemargLane then
            CheckLane(Instruction);
        end;
      ikMemory, ikMemoryMemory:
        CheckMemory(Instruction.MemoryIndex);
      ikLane:
        CheckLane(Instruction);
      ikShuffle:
        for Index := 0 to 15 do
          if Instruction.Vector.Bytes[Index] >= 32 then
            Fail('invalid lane index');
    end;
    if Info^.Signature = '' then
      Fail('unsupported instruction ' + Info^.Name);
    ApplySignature(Info^.Signature);
  end;
end;

procedure TWasmCodeValidator.ValidateFunction(DefinedIndex: Cardinal);
var
  FunctionIndex: Cardinal;
  FunctionType: TWasmFunctionType;
  Body: TWasmFunctionBody;
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Index: Integer;
begin
  FunctionIndex := FModule.ImportedFunctionCount + DefinedIndex;
  FunctionType := FModule.FunctionType(FunctionIndex);
  Body := FModule.Bodies[DefinedIndex];
  SetLength(FLocals, Length(FunctionType.Params) + Length(Body.Locals));
  for Index := 0 to High(FunctionType.Params) do
    FLocals[Index] := FunctionType.Params[Index];
  for Index := 0 to High(Body.Locals) do
    FLocals[Length(FunctionType.Params) + Index] := Body.Locals[Index];
  FOperandCount := 0;
  FControlCount := 0;
  PushControl(OpBlock, nil, FunctionType.Results);
  Instructions.Initialize(PByte(FModule.Bytes), Body.BodyStart, Body.BodyLimit);
  while FControlCount > 0 do
  begin
    Instructions.Next(Instruction);
    ValidateInstruction(Instruction, Instructions.Labels);
  end;
end;

end.
