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
  Values match expected types by subtyping (Wasm.Subtyping); a reference
  popped where any reference will do but none is known has the bottom
  heap type, which matches every heap type.

  Locals of a non-defaultable type (non-nullable references) must be set
  before they are read: the locals set so far are a stack, and a block
  forgets the ones set inside it when it ends.

  Instructions with a fixed type come with a signature in the opcode
  table (Wasm.Opcodes); the rest are typed here one by one, the
  references, tables and memories here and exception handling, calls
  and the garbage collection instructions in their own include files.
  Errors are EWasmInvalid with the offset of the instruction.
}
unit Wasm.CodeValidator;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Module,
  Wasm.ModuleTypes,
  Wasm.Instructions;

const
  { The heap type of a reference known only to be a reference (in
    unreachable code). Never leaves the validator. }
  HeapTypeBottom = -1000;

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
    InitHeight: Integer;
    Unreachable: Boolean;
  end;

  TWasmCodeValidator = class
  private
    FModule: TWasmModule;
    FContext: TWasmModuleTypeContext;
    FDeclaredReferences: array of Boolean;
    FLocals: TWasmValueTypeArray;
    FLocalSet: array of Boolean;
    FInits: array of Cardinal;
    FInitCount: Integer;
    FResults: TWasmValueTypeArray;
    FOperands: array of TOperandType;
    FOperandCount: Integer;
    FControls: array of TControlFrame;
    FControlCount: Integer;
    FOffset: SizeInt;
    procedure Fail(const Message: AnsiString);
    function Matches(const Sub, Super: TWasmValueType): Boolean;
    function HeapType(TypeIndex: Cardinal): Int32;
    procedure PushOperand(const ValueType: TWasmValueType);
    procedure PushUnknown;
    function PopOperand: TOperandType;
    function PopExpected(const Expected: TWasmValueType): TOperandType;
    { Pops a reference of any type (the bottom reference if unknown). }
    function PopReference: TWasmValueType;
    procedure PushTypes(const Types: TWasmValueTypeArray);
    procedure PopTypes(const Types: TWasmValueTypeArray);
    procedure PushControl(Opcode: Integer; const StartTypes, EndTypes: TWasmValueTypeArray);
    function PopControl: TControlFrame;
    function LabelTypes(const Frame: TControlFrame): TWasmValueTypeArray;
    procedure MarkUnreachable;
    function Label_(Depth: Cardinal): Integer;
    procedure BlockSignature(const BlockType: TWasmBlockType; out StartTypes, EndTypes: TWasmValueTypeArray);
    procedure ApplySignature(const Signature: ShortString);
    procedure CheckTypeIndex(Index: Cardinal);
    procedure CheckValueType(var ValueType: TWasmValueType);
    function FunctionTypeAt(TypeIndex: Cardinal): TWasmFunctionType;
    function StructAt(TypeIndex: Cardinal): TWasmTypeDefinition;
    function ArrayAt(TypeIndex: Cardinal): TWasmTypeDefinition;
    function MemoryAddressType(Index: Cardinal): TWasmValueType;
    function TableAddressType(Index: Cardinal): TWasmValueType;
    procedure CheckMemarg(const Instruction: TWasmInstruction);
    procedure CheckLane(const Instruction: TWasmInstruction);
    procedure CheckTable(Index: Cardinal);
    procedure CheckFunction(Index: Cardinal);
    procedure CheckElement(Index: Cardinal);
    procedure CheckData(Index: Cardinal);
    procedure CheckTag(Index: Cardinal);
    procedure SetLocal(Index: Cardinal);
    procedure ValidateLocal(const Instruction: TWasmInstruction);
    procedure ValidateMemory(const Instruction: TWasmInstruction);
    procedure ValidateTable(const Instruction: TWasmInstruction);
    procedure ValidateCall(const Instruction: TWasmInstruction);
    procedure ValidateReference(const Instruction: TWasmInstruction);
    procedure ValidateException(const Instruction: TWasmInstruction; const Catches: array of TWasmCatchClause);
    procedure ValidateAggregate(const Instruction: TWasmInstruction);
    procedure ValidateCast(const Instruction: TWasmInstruction);
    procedure ValidateInstruction(const Instruction: TWasmInstruction; const Labels: array of Cardinal;
      const Catches: array of TWasmCatchClause);
  public
    constructor Create(AModule: TWasmModule; AContext: TWasmModuleTypeContext;
      const DeclaredReferences: array of Boolean);
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
  Wasm.Limits,
  Wasm.Features,
  Wasm.Subtyping,
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

constructor TWasmCodeValidator.Create(AModule: TWasmModule; AContext: TWasmModuleTypeContext;
  const DeclaredReferences: array of Boolean);
var
  Index: Integer;
begin
  inherited Create;
  FModule := AModule;
  FContext := AContext;
  SetLength(FDeclaredReferences, Length(DeclaredReferences));
  for Index := 0 to High(DeclaredReferences) do
    FDeclaredReferences[Index] := DeclaredReferences[Index];
end;

procedure TWasmCodeValidator.Fail(const Message: AnsiString);
begin
  raise EWasmInvalid.CreateAt(FOffset, Message);
end;

function TWasmCodeValidator.Matches(const Sub, Super: TWasmValueType): Boolean;
begin
  if (Sub.Kind = vkReference) and (Sub.HeapType = HeapTypeBottom) then
    Exit((Super.Kind = vkReference) and (Super.Nullable or not Sub.Nullable));
  Result := ValueTypeMatches(FContext, Sub, Super);
end;

function TWasmCodeValidator.HeapType(TypeIndex: Cardinal): Int32;
begin
  Result := FModule.CanonicalType(TypeIndex);
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
  if Result.Known and not Matches(Result.ValueType, Expected) then
    Fail('type mismatch');
  if not Result.Known then
  begin
    Result.Known := True;
    Result.ValueType := Expected;
  end;
end;

function TWasmCodeValidator.PopReference: TWasmValueType;
var
  Operand: TOperandType;
begin
  Operand := PopOperand;
  if not Operand.Known then
    Exit(MakeReferenceType(HeapTypeBottom, False));
  if Operand.ValueType.Kind <> vkReference then
    Fail('type mismatch');
  Result := Operand.ValueType;
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
  FControls[FControlCount].InitHeight := FInitCount;
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
  { Locals set inside the block are unset again. }
  while FInitCount > Result.InitHeight do
  begin
    Dec(FInitCount);
    FLocalSet[FInits[FInitCount]] := False;
  end;
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

procedure TWasmCodeValidator.CheckTypeIndex(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.TypeDefinitions)) then
    Fail('unknown type ' + IntToStr(Index));
end;

{ A value type written in an instruction: its type index checked and
  made canonical. }
procedure TWasmCodeValidator.CheckValueType(var ValueType: TWasmValueType);
begin
  if (ValueType.Kind = vkReference) and (ValueType.HeapType >= 0) then
  begin
    CheckTypeIndex(ValueType.HeapType);
    ValueType.HeapType := HeapType(ValueType.HeapType);
  end;
end;

function TWasmCodeValidator.FunctionTypeAt(TypeIndex: Cardinal): TWasmFunctionType;
begin
  CheckTypeIndex(TypeIndex);
  if FModule.TypeDefinitions[TypeIndex].Kind <> ckFunction then
    Fail('type mismatch: not a function type');
  Result := FModule.Types[TypeIndex];
end;

function TWasmCodeValidator.StructAt(TypeIndex: Cardinal): TWasmTypeDefinition;
begin
  CheckTypeIndex(TypeIndex);
  Result := FModule.TypeDefinitions[TypeIndex];
  if Result.Kind <> ckStruct then
    Fail('type mismatch: not a struct type');
end;

function TWasmCodeValidator.ArrayAt(TypeIndex: Cardinal): TWasmTypeDefinition;
begin
  CheckTypeIndex(TypeIndex);
  Result := FModule.TypeDefinitions[TypeIndex];
  if Result.Kind <> ckArray then
    Fail('type mismatch: not an array type');
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
        CheckValueType(EndTypes[0]);
      end;
    btTypeIndex:
      begin
        if BlockType.TypeIndex >= Cardinal(Length(FModule.Types)) then
          Fail('unknown type');
        StartTypes := FunctionTypeAt(BlockType.TypeIndex).Params;
        EndTypes := FunctionTypeAt(BlockType.TypeIndex).Results;
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

function TWasmCodeValidator.MemoryAddressType(Index: Cardinal): TWasmValueType;
begin
  if Index >= Cardinal(Length(FModule.Memories)) then
    Fail('unknown memory ' + IntToStr(Index));
  Result := MakeNumberType(FModule.Memories[Index].AddressType);
end;

function TWasmCodeValidator.TableAddressType(Index: Cardinal): TWasmValueType;
begin
  CheckTable(Index);
  Result := MakeNumberType(FModule.Tables[Index].AddressType);
end;

procedure TWasmCodeValidator.CheckMemarg(const Instruction: TWasmInstruction);
begin
  if MemoryAddressType(Instruction.MemoryIndex).Kind = vkI32 then
    if Instruction.MemoryOffset > $FFFFFFFF then
      Fail('offset out of range');
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

procedure TWasmCodeValidator.CheckTag(Index: Cardinal);
begin
  if Index >= Cardinal(Length(FModule.TagTypes)) then
    Fail('unknown tag ' + IntToStr(Index));
end;

procedure TWasmCodeValidator.SetLocal(Index: Cardinal);
begin
  if FLocalSet[Index] then
    Exit;
  FLocalSet[Index] := True;
  if FInitCount >= Length(FInits) then
    SetLength(FInits, FInitCount * 2 + 8);
  FInits[FInitCount] := Index;
  Inc(FInitCount);
end;

{$I Wasm.CodeValidator.Basic.inc}
{$I Wasm.CodeValidator.Calls.inc}
{$I Wasm.CodeValidator.Aggregates.inc}

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
  SetLength(FLocalSet, Length(FLocals));
  for Index := 0 to High(FunctionType.Params) do
  begin
    FLocals[Index] := FunctionType.Params[Index];
    FLocalSet[Index] := True;
  end;
  for Index := 0 to High(Body.Locals) do
  begin
    FLocals[Length(FunctionType.Params) + Index] := Body.Locals[Index];
    FLocalSet[Length(FunctionType.Params) + Index] := IsDefaultable(Body.Locals[Index]);
  end;
  FInitCount := 0;
  FResults := FunctionType.Results;
  FOperandCount := 0;
  FControlCount := 0;
  PushControl(OpBlock, nil, FunctionType.Results);
  Instructions.Initialize(PByte(FModule.Bytes), Body.BodyStart, Body.BodyLimit, FModule.Features);
  while FControlCount > 0 do
  begin
    Instructions.Next(Instruction);
    ValidateInstruction(Instruction, Instructions.Labels, Instructions.Catches);
  end;
end;

end.
