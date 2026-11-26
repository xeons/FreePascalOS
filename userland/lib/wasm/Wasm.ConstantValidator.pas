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
  Constant expressions (spec 3.0, section 3.3.10): globals' and tables'
  initializers, segment offsets and element expressions.

  The constant instructions are the constants, ref.null, ref.func,
  global.get of an immutable global, and in 3.0 the extended constants
  (i32 and i64 add, sub and mul) and the allocating GC instructions
  (ref.i31, struct.new, array.new and its forms, any.convert_extern and
  extern.convert_any). A global's initializer may read the globals
  before it (only imported ones in 2.0); other expressions any global.
  The expression must leave exactly one value of the expected type.
}
unit Wasm.ConstantValidator;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types,
  Wasm.Module,
  Wasm.ModuleTypes;

type
  TWasmConstantValidator = class
  private
    FModule: TWasmModule;
    FContext: TWasmModuleTypeContext;
    FStack: array of TWasmValueType;
    FCount: Integer;
    procedure Fail(const Message: AnsiString);
    procedure Push(const ValueType: TWasmValueType);
    function Pop: TWasmValueType;
    procedure PopExpected(const Expected: TWasmValueType);
    procedure CheckTypeIndex(Index: Cardinal; Kind: Integer);
  public
    constructor Create(AModule: TWasmModule; AContext: TWasmModuleTypeContext);
    { VisibleGlobals: the globals global.get may name (those before a
      global being initialized, or all). }
    procedure Check(const Expression: TWasmConstantExpression; const Expected: TWasmValueType;
      VisibleGlobals: Cardinal);
  end;

implementation

uses
  SysUtils,
  Wasm.Errors,
  Wasm.Features,
  Wasm.Opcodes,
  Wasm.Instructions,
  Wasm.TypeDefinitions,
  Wasm.Subtyping;

constructor TWasmConstantValidator.Create(AModule: TWasmModule; AContext: TWasmModuleTypeContext);
begin
  inherited Create;
  FModule := AModule;
  FContext := AContext;
end;

procedure TWasmConstantValidator.Fail(const Message: AnsiString);
begin
  raise EWasmInvalid.CreateAt(0, Message);
end;

procedure TWasmConstantValidator.Push(const ValueType: TWasmValueType);
begin
  if FCount >= Length(FStack) then
    SetLength(FStack, FCount * 2 + 4);
  FStack[FCount] := ValueType;
  Inc(FCount);
end;

function TWasmConstantValidator.Pop: TWasmValueType;
begin
  if FCount = 0 then
    Fail('type mismatch');
  Dec(FCount);
  Result := FStack[FCount];
end;

procedure TWasmConstantValidator.PopExpected(const Expected: TWasmValueType);
begin
  if not ValueTypeMatches(FContext, Pop, Expected) then
    Fail('type mismatch');
end;

{ Kind: the composite kind the type must be, or -1 for any. }
procedure TWasmConstantValidator.CheckTypeIndex(Index: Cardinal; Kind: Integer);
begin
  if Index >= Cardinal(Length(FModule.TypeDefinitions)) then
    Fail('unknown type ' + IntToStr(Index));
  if (Kind >= 0) and (Ord(FModule.TypeDefinitions[Index].Kind) <> Kind) then
    Fail('type mismatch');
end;

procedure TWasmConstantValidator.Check(const Expression: TWasmConstantExpression; const Expected: TWasmValueType;
  VisibleGlobals: Cardinal);
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Features: TWasmFeatures;
  Definition: TWasmTypeDefinition;
  Operand: TWasmValueType;
  Index: Integer;
  TypeIndex: Int32;
  Item: Cardinal;
begin
  FCount := 0;
  Features := FModule.Features;
  if Features * [wfGarbageCollection, wfExtendedConstants] = [] then
    if VisibleGlobals > FModule.ImportedGlobalCount then
      VisibleGlobals := FModule.ImportedGlobalCount;
  Instructions.Initialize(PByte(FModule.Bytes), Expression.Start, Expression.Limit, Features);
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpI32Const: Push(WasmI32Type);
      OpI64Const: Push(WasmI64Type);
      OpF32Const: Push(WasmF32Type);
      OpF64Const: Push(WasmF64Type);
      OpV128Const: Push(WasmV128Type);
      OpRefNull:
        begin
          if Instruction.ReferenceType.HeapType >= 0 then
          begin
            CheckTypeIndex(Instruction.ReferenceType.HeapType, -1);
            Instruction.ReferenceType.HeapType := FModule.CanonicalType(Instruction.ReferenceType.HeapType);
          end;
          Push(Instruction.ReferenceType);
        end;
      OpRefFunc:
        begin
          if Instruction.Index >= FModule.FunctionCount then
            Fail('unknown function ' + IntToStr(Instruction.Index));
          Push(MakeReferenceType(FModule.CanonicalType(FModule.FunctionTypes[Instruction.Index]), False));
        end;
      OpGlobalGet:
        begin
          if Instruction.Index >= VisibleGlobals then
            Fail('unknown global ' + IntToStr(Instruction.Index));
          if FModule.Globals[Instruction.Index].Mutable then
            Fail('constant expression required');
          Push(FModule.Globals[Instruction.Index].ValueType);
        end;
      OpI32Add, OpI32Sub, OpI32Mul, OpI64Add, OpI64Sub, OpI64Mul:
        begin
          if not (wfExtendedConstants in Features) then
            Fail('constant expression required');
          if Instruction.Opcode <= OpI32Mul then
            Operand := WasmI32Type
          else
            Operand := WasmI64Type;
          PopExpected(Operand);
          PopExpected(Operand);
          Push(Operand);
        end;
      OpRefI31:
        begin
          PopExpected(WasmI32Type);
          Push(MakeReferenceType(HeapTypeI31, False));
        end;
      OpStructNew, OpStructNewDefault:
        begin
          CheckTypeIndex(Instruction.Index, Ord(ckStruct));
          Definition := FModule.TypeDefinitions[Instruction.Index];
          if Instruction.Opcode = OpStructNew then
          begin
            for Index := High(Definition.Fields) downto 0 do
              PopExpected(FieldValueType(Definition.Fields[Index]));
          end
          else
            for Index := 0 to High(Definition.Fields) do
              if not IsDefaultable(Definition.Fields[Index].ValueType) then
                Fail('type mismatch: field is not defaultable');
          TypeIndex := FModule.CanonicalType(Instruction.Index);
          Push(MakeReferenceType(TypeIndex, False));
        end;
      OpArrayNew, OpArrayNewDefault, OpArrayNewFixed:
        begin
          CheckTypeIndex(Instruction.Index, Ord(ckArray));
          Definition := FModule.TypeDefinitions[Instruction.Index];
          case Instruction.Opcode of
            OpArrayNew:
              begin
                PopExpected(WasmI32Type);
                PopExpected(FieldValueType(Definition.Fields[0]));
              end;
            OpArrayNewDefault:
              begin
                if not IsDefaultable(Definition.Fields[0].ValueType) then
                  Fail('type mismatch: array element is not defaultable');
                PopExpected(WasmI32Type);
              end;
          else
            Item := 0;
            while Item < Instruction.SecondIndex do
            begin
              PopExpected(FieldValueType(Definition.Fields[0]));
              Inc(Item);
            end;
          end;
          Push(MakeReferenceType(FModule.CanonicalType(Instruction.Index), False));
        end;
      OpAnyConvertExtern:
        begin
          Operand := Pop;
          if not ValueTypeMatches(FContext, Operand, WasmExternRefType) then
            Fail('type mismatch');
          Push(MakeReferenceType(HeapTypeAny, Operand.Nullable));
        end;
      OpExternConvertAny:
        begin
          Operand := Pop;
          if not ValueTypeMatches(FContext, Operand, MakeReferenceType(HeapTypeAny)) then
            Fail('type mismatch');
          Push(MakeReferenceType(HeapTypeExtern, Operand.Nullable));
        end;
      OpEnd: ;
    else
      Fail('constant expression required');
    end;
  until Instruction.Opcode = OpEnd;
  if (FCount <> 1) or not ValueTypeMatches(FContext, FStack[0], Expected) then
    Fail('type mismatch');
end;

end.
