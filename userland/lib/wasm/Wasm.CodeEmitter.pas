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
  The compiler's bookkeeping (Wasm.Compiler translates instructions with
  it): the code being emitted, the operand stack with each operand's
  slot, and the control stack with the branches waiting for a block's
  end.

  Every operand has a home, the slot its stack position stands for. Its
  value may be elsewhere for a while: a local.get leaves it in the local's
  slot and a small constant is not written anywhere yet. Materialize puts
  a value in its home; it is done for every operand before a block
  boundary or a branch, where code that joins from elsewhere expects
  values at home, and for the operands reading a local before the local
  changes.

  LastResult is the instruction just emitted when its only effect is to
  write the top operand's home (operand A): local.set can then make it
  write the local instead, and br_if can fuse with a comparison.
}
unit Wasm.CodeEmitter;

{$mode objfpc}
{$H+}

interface

uses
  Wasm.Types,
  Wasm.Module,
  Wasm.Code;

type
  TCompileOperand = record
    ValueType: TWasmValueType;
    Home: Int32;
    Source: Int32;
    IsConstant: Boolean;     { a constant not written yet: Constant }
    Constant: Int64;
  end;

  TCompileFrameKind = (cfBlock, cfLoop, cfIf, cfElse, cfFunction);

  TCompileFrame = record
    Kind: TCompileFrameKind;
    ParamTypes: TWasmValueTypeArray;
    ResultTypes: TWasmValueTypeArray;
    OperandHeight: Integer;   { operands below the block's parameters }
    SlotHeight: Int32;        { the home of the first parameter }
    LoopStart: Int32;
    Fixups: array of Int32;   { branches to the end: instruction index * 2, or branch table entry * 2 + 1 }
    FixupCount: Integer;
    IfBranch: Int32;          { the if's branch to its else, -1 once bound }
    Unreachable: Boolean;
  end;

  TCodeEmitter = class
  protected
    FModule: TWasmModule;
    FCode: TCompiledFunction;
    FInstructions: array of TCodeInstruction;
    FByteOffsets: array of Int32;
    FCount: Integer;
    FConstants: array of QWord;
    FConstantCount: Integer;
    FBranchTargets: array of Int32;
    FBranchTargetCount: Integer;
    FSafepointInstructions: array of Int32;
    FSafepointStarts: array of Int32;
    FSafepointSlots: array of Int32;
    FSafepointCount: Integer;
    FSafepointSlotCount: Integer;
    FLocalTypes: TWasmValueTypeArray;
    FLocalSlots: array of Int32;
    FLocalSlotCount: Integer;
    FHasExternLocals: Boolean;
    FOperands: array of TCompileOperand;
    FOperandCount: Integer;
    FNextHome: Int32;
    FMaximumSlots: Int32;
    FFrames: array of TCompileFrame;
    FFrameCount: Integer;
    FByteOffset: SizeInt;
    FLastResult: Integer;
    function Emit(Operation: Integer; A: Int32 = 0; B: Int32 = 0; C: Int32 = 0; Extra: Integer = 0): Integer;
    { Emits an operation whose only effect is to write its operand A, the
      home of the operand just pushed. }
    procedure EmitResult(Operation: Integer; A: Int32; B: Int32 = 0; C: Int32 = 0; Extra: Integer = 0);
    procedure RemoveLastInstruction;
    function AddConstants(Low, High: QWord): Int32;
    function AddBranchTarget(Target: Int32): Int32;
    procedure RecordSafepoint(InstructionIndex: Integer; OperandLimit: Integer);
    function PushOperand(const ValueType: TWasmValueType): Int32;
    procedure PushLocal(LocalIndex: Cardinal);
    procedure PushConstant(const ValueType: TWasmValueType; Value: Int64);
    function PopOperand: TCompileOperand;
    function TopOperand: TCompileOperand; inline;
    procedure Materialize(Index: Integer);
    procedure MaterializeAll;
    procedure MaterializeLocalReaders(Slot: Int32);
    { The slot a popped operand's value can be read from, writing a lazy
      constant to its home first. }
    function SourceOf(var Operand: TCompileOperand): Int32;
    procedure ResetOperands(Height: Integer; const Types: TWasmValueTypeArray);
    procedure PushFrame(Kind: TCompileFrameKind; const ParamTypes, ResultTypes: TWasmValueTypeArray);
    procedure AddFixup(var Frame: TCompileFrame; Entry: Int32);
    procedure BindFixups(var Frame: TCompileFrame; Target: Int32);
    procedure MarkUnreachable;
    function CurrentFrame: Integer; inline;
    procedure Finish;
  public
    constructor Create(AModule: TWasmModule);
  end;

implementation

uses
  Wasm.Opcodes;

constructor TCodeEmitter.Create(AModule: TWasmModule);
begin
  inherited Create;
  FModule := AModule;
end;

function TCodeEmitter.Emit(Operation: Integer; A: Int32; B: Int32; C: Int32; Extra: Integer): Integer;
begin
  if FCount >= Length(FInstructions) then
  begin
    SetLength(FInstructions, FCount * 2 + 64);
    SetLength(FByteOffsets, Length(FInstructions));
  end;
  FInstructions[FCount].Operation := Operation;
  FInstructions[FCount].Extra := Extra;
  FInstructions[FCount].A := A;
  FInstructions[FCount].B := B;
  FInstructions[FCount].C := C;
  FByteOffsets[FCount] := FByteOffset;
  Result := FCount;
  Inc(FCount);
  FLastResult := -1;
end;

procedure TCodeEmitter.EmitResult(Operation: Integer; A: Int32; B: Int32; C: Int32; Extra: Integer);
begin
  FLastResult := Emit(Operation, A, B, C, Extra);
end;

procedure TCodeEmitter.RemoveLastInstruction;
begin
  Dec(FCount);
  FLastResult := -1;
end;

function TCodeEmitter.AddConstants(Low, High: QWord): Int32;
begin
  if FConstantCount + 2 > Length(FConstants) then
    SetLength(FConstants, FConstantCount * 2 + 8);
  FConstants[FConstantCount] := Low;
  FConstants[FConstantCount + 1] := High;
  Result := FConstantCount;
  Inc(FConstantCount, 2);
end;

function TCodeEmitter.AddBranchTarget(Target: Int32): Int32;
begin
  if FBranchTargetCount >= Length(FBranchTargets) then
    SetLength(FBranchTargets, FBranchTargetCount * 2 + 16);
  FBranchTargets[FBranchTargetCount] := Target;
  Result := FBranchTargetCount;
  Inc(FBranchTargetCount);
end;

procedure TCodeEmitter.RecordSafepoint(InstructionIndex: Integer; OperandLimit: Integer);
var
  Index, Start: Integer;

  procedure AddSlot(Slot: Int32);
  begin
    if FSafepointSlotCount >= Length(FSafepointSlots) then
      SetLength(FSafepointSlots, FSafepointSlotCount * 2 + 16);
    FSafepointSlots[FSafepointSlotCount] := Slot;
    Inc(FSafepointSlotCount);
  end;

  function IsExtern(const ValueType: TWasmValueType): Boolean;
  begin
    Result := (ValueType.Kind = vkReference) and (ValueType.HeapType = HeapTypeExtern);
  end;

begin
  Start := FSafepointSlotCount;
  if FHasExternLocals then
    for Index := 0 to High(FLocalTypes) do
      if IsExtern(FLocalTypes[Index]) then
        AddSlot(FLocalSlots[Index]);
  for Index := 0 to OperandLimit - 1 do
    if IsExtern(FOperands[Index].ValueType) then
      AddSlot(FOperands[Index].Home);
  if FSafepointSlotCount = Start then
    Exit;
  if FSafepointCount + 1 >= Length(FSafepointInstructions) then
  begin
    SetLength(FSafepointInstructions, FSafepointCount * 2 + 8);
    SetLength(FSafepointStarts, Length(FSafepointInstructions) + 1);
  end;
  FSafepointInstructions[FSafepointCount] := InstructionIndex;
  FSafepointStarts[FSafepointCount] := Start;
  Inc(FSafepointCount);
end;

function TCodeEmitter.PushOperand(const ValueType: TWasmValueType): Int32;
begin
  if FOperandCount >= Length(FOperands) then
    SetLength(FOperands, FOperandCount * 2 + 16);
  Result := FNextHome;
  with FOperands[FOperandCount] do
  begin
    Home := FNextHome;
    Source := FNextHome;
    IsConstant := False;
    Constant := 0;
  end;
  FOperands[FOperandCount].ValueType := ValueType;
  Inc(FOperandCount);
  Inc(FNextHome, SlotCount(ValueType));
  if FNextHome > FMaximumSlots then
    FMaximumSlots := FNextHome;
end;

procedure TCodeEmitter.PushLocal(LocalIndex: Cardinal);
begin
  PushOperand(FLocalTypes[LocalIndex]);
  FOperands[FOperandCount - 1].Source := FLocalSlots[LocalIndex];
end;

procedure TCodeEmitter.PushConstant(const ValueType: TWasmValueType; Value: Int64);
begin
  PushOperand(ValueType);
  FOperands[FOperandCount - 1].IsConstant := True;
  FOperands[FOperandCount - 1].Constant := Value;
end;

function TCodeEmitter.PopOperand: TCompileOperand;
begin
  Dec(FOperandCount);
  Result := FOperands[FOperandCount];
  FNextHome := Result.Home;
end;

function TCodeEmitter.TopOperand: TCompileOperand;
begin
  Result := FOperands[FOperandCount - 1];
end;

procedure TCodeEmitter.Materialize(Index: Integer);
var
  LastResult: Integer;
begin
  with FOperands[Index] do
  begin
    if IsConstant then
    begin
      LastResult := FLastResult;
      if ValueType.Kind in [vkI32, vkF32] then
        Emit(CodeConst32, Home, Int32(Constant))
      else
        Emit(CodeConst64, Home, Int32(Constant and $FFFFFFFF), Int32(Constant shr 32));
      IsConstant := False;
      Source := Home;
      FLastResult := LastResult;
    end
    else if Source <> Home then
    begin
      if ValueType.Kind = vkV128 then
        Emit(CodeCopy128, Home, Source)
      else
        Emit(CodeCopy, Home, Source);
      Source := Home;
    end;
  end;
end;

procedure TCodeEmitter.MaterializeAll;
var
  Index: Integer;
begin
  for Index := 0 to FOperandCount - 1 do
    if FOperands[Index].IsConstant or (FOperands[Index].Source <> FOperands[Index].Home) then
      Materialize(Index);
end;

procedure TCodeEmitter.MaterializeLocalReaders(Slot: Int32);
var
  Index: Integer;
begin
  for Index := 0 to FOperandCount - 1 do
    if (not FOperands[Index].IsConstant) and (FOperands[Index].Source = Slot) and
      (FOperands[Index].Home <> Slot) then
      Materialize(Index);
end;

function TCodeEmitter.SourceOf(var Operand: TCompileOperand): Int32;
begin
  if Operand.IsConstant then
  begin
    if Operand.ValueType.Kind in [vkI32, vkF32] then
      Emit(CodeConst32, Operand.Home, Int32(Operand.Constant))
    else
      Emit(CodeConst64, Operand.Home, Int32(Operand.Constant and $FFFFFFFF), Int32(Operand.Constant shr 32));
    Operand.IsConstant := False;
    Operand.Source := Operand.Home;
  end;
  Result := Operand.Source;
end;

procedure TCodeEmitter.ResetOperands(Height: Integer; const Types: TWasmValueTypeArray);
var
  Index: Integer;
begin
  FOperandCount := Height;
  if Height = 0 then
    FNextHome := FLocalSlotCount
  else
    FNextHome := FOperands[Height - 1].Home + SlotCount(FOperands[Height - 1].ValueType);
  for Index := 0 to High(Types) do
    PushOperand(Types[Index]);
end;

procedure TCodeEmitter.PushFrame(Kind: TCompileFrameKind; const ParamTypes, ResultTypes: TWasmValueTypeArray);
begin
  if FFrameCount >= Length(FFrames) then
    SetLength(FFrames, FFrameCount * 2 + 8);
  with FFrames[FFrameCount] do
  begin
    FixupCount := 0;
    IfBranch := -1;
    LoopStart := FCount;
    Unreachable := False;
  end;
  FFrames[FFrameCount].Kind := Kind;
  FFrames[FFrameCount].ParamTypes := ParamTypes;
  FFrames[FFrameCount].ResultTypes := ResultTypes;
  FFrames[FFrameCount].OperandHeight := FOperandCount - Length(ParamTypes);
  if FFrames[FFrameCount].OperandHeight = FOperandCount then
    FFrames[FFrameCount].SlotHeight := FNextHome
  else
    FFrames[FFrameCount].SlotHeight := FOperands[FFrames[FFrameCount].OperandHeight].Home;
  Inc(FFrameCount);
end;

procedure TCodeEmitter.AddFixup(var Frame: TCompileFrame; Entry: Int32);
begin
  if Frame.FixupCount >= Length(Frame.Fixups) then
    SetLength(Frame.Fixups, Frame.FixupCount * 2 + 4);
  Frame.Fixups[Frame.FixupCount] := Entry;
  Inc(Frame.FixupCount);
end;

procedure TCodeEmitter.BindFixups(var Frame: TCompileFrame; Target: Int32);
var
  Index: Integer;
begin
  for Index := 0 to Frame.FixupCount - 1 do
    if Frame.Fixups[Index] and 1 = 0 then
      FInstructions[Frame.Fixups[Index] shr 1].A := Target
    else
      FBranchTargets[Frame.Fixups[Index] shr 1] := Target;
  Frame.FixupCount := 0;
end;

procedure TCodeEmitter.MarkUnreachable;
begin
  FFrames[FFrameCount - 1].Unreachable := True;
end;

function TCodeEmitter.CurrentFrame: Integer;
begin
  Result := FFrameCount - 1;
end;

procedure TCodeEmitter.Finish;
begin
  FCode.Instructions := Copy(FInstructions, 0, FCount);
  FCode.ByteOffsets := Copy(FByteOffsets, 0, FCount);
  FCode.Constants := Copy(FConstants, 0, FConstantCount);
  FCode.BranchTargets := Copy(FBranchTargets, 0, FBranchTargetCount);
  FCode.LocalSlots := FLocalSlotCount;
  FCode.FrameSlots := FMaximumSlots;
  if FSafepointCount > 0 then
  begin
    FCode.SafepointInstructions := Copy(FSafepointInstructions, 0, FSafepointCount);
    FCode.SafepointStarts := Copy(FSafepointStarts, 0, FSafepointCount + 1);
    FCode.SafepointStarts[FSafepointCount] := FSafepointSlotCount;
    FCode.SafepointSlots := Copy(FSafepointSlots, 0, FSafepointSlotCount);
  end;
end;

end.
