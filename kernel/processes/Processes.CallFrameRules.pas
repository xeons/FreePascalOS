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
  Unwinding one frame: the rules of a call frame information entry
  (Processes.CallFrameEntries) at an address, and the caller's registers
  they give.

  The CIE's initial instructions and then the FDE's run until the next
  advance would pass the address; what they leave is where the frame's
  canonical frame address (CFA: the stack pointer before the call) is
  computed from and where each register the routine saved lies. The
  caller's stack pointer is the CFA and its program counter the return
  address column's value. Registers no rule names keep their value.
  Rules given as DWARF expressions are not evaluated: such a register
  becomes unknown, and a CFA given by one ends the unwind.

  Without call frame information a frame is stepped by its frame
  pointer (UnwindWithFramePointer): the saved frame pointer and the
  return address lie at the frame pointer, as every routine Free Pascal
  compiles here leaves them (x86-64: PUSH RBP; MOV RBP, RSP, AArch64:
  STP X29, X30, [SP, #-n]!; MOV X29, SP).

  Pure code like the entries unit: the host test runs it too.
}
unit Processes.CallFrameRules;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.CallFrameEntries;

const
  { How deep DW_CFA_remember_state may nest. }
  CfiStateDepth = 8;

type
  TRuleKind = (
    { No rule: the register keeps its value (as same value). }
    RuleUnspecified,
    RuleUndefined,
    RuleSameValue,
    { Saved at CFA + Operand. }
    RuleOffset,
    { Its value is CFA + Operand. }
    RuleValueOffset,
    { Its value is register Operand's. }
    RuleRegister,
    { A DWARF expression: not known here. }
    RuleUnknown);

  TRegisterRule = record
    Kind: TRuleKind;
    Operand: Int64;
  end;

  TFrameRules = record
    CfaRegister: LongWord;
    CfaOffset: Int64;
    CfaIsExpression: Boolean;
    Registers: array[0..CfiRegisterCapacity - 1] of TRegisterRule;
    ReturnAddressColumn: LongWord;
  end;

{ The rules in force at Pc of the routine Entry describes. }
function ComputeFrameRules(constref Entry: TFrameEntry; Pc: QWord; out Rules: TFrameRules): Boolean;
{ Replaces Registers by the caller's, by Rules; False if the CFA or the
  return address cannot be had. }
function ApplyFrameRules(constref Rules: TFrameRules; constref Architecture: TCfiArchitecture;
  constref Memory: TCfiMemory; var Registers: TUnwindRegisters): Boolean;
{ Replaces Registers by the caller's through the frame pointer; False if
  it is not known, misaligned, or the words cannot be read. }
function UnwindWithFramePointer(constref Architecture: TCfiArchitecture; constref Memory: TCfiMemory;
  var Registers: TUnwindRegisters): Boolean;

function RegisterIsKnown(constref Registers: TUnwindRegisters; Index: LongWord): Boolean;
procedure SetRegister(var Registers: TUnwindRegisters; Index: LongWord; Value: QWord);
procedure ForgetRegister(var Registers: TUnwindRegisters; Index: LongWord);

implementation

uses
  Runtime.Memory;

const
  OpcodeAdvanceLocation = $40;
  OpcodeOffset = $80;
  OpcodeRestore = $C0;
  OpcodeNop = $00;
  OpcodeSetLocation = $01;
  OpcodeAdvanceLocation1 = $02;
  OpcodeAdvanceLocation2 = $03;
  OpcodeAdvanceLocation4 = $04;
  OpcodeOffsetExtended = $05;
  OpcodeRestoreExtended = $06;
  OpcodeUndefined = $07;
  OpcodeSameValue = $08;
  OpcodeRegister = $09;
  OpcodeRememberState = $0A;
  OpcodeRestoreState = $0B;
  OpcodeDefineCfa = $0C;
  OpcodeDefineCfaRegister = $0D;
  OpcodeDefineCfaOffset = $0E;
  OpcodeDefineCfaExpression = $0F;
  OpcodeExpression = $10;
  OpcodeOffsetExtendedSigned = $11;
  OpcodeDefineCfaSigned = $12;
  OpcodeDefineCfaOffsetSigned = $13;
  OpcodeValueOffset = $14;
  OpcodeValueOffsetSigned = $15;
  OpcodeValueExpression = $16;
  OpcodeNegateReturnAddressState = $2D;
  OpcodeArgumentsSize = $2E;
  OpcodeNegativeOffsetExtended = $2F;

type
  { Where a CFA program runs. }
  TProgramRun = record
    Bytes: PByte;
    Size: LongWord;
    Position: LongWord;
    BytesAddress: QWord;
    Location: QWord;
    Target: QWord;
    { The CIE's own instructions do not advance. }
    MayAdvance: Boolean;
    CodeAlignment: QWord;
    DataAlignment: Int64;
    PointerEncoding: Byte;
    AddressBias: QWord;
    IsEhFrame: Boolean;
    StateDepth: Integer;
    States: array[0..CfiStateDepth - 1] of TFrameRules;
  end;

function RegisterIsKnown(constref Registers: TUnwindRegisters; Index: LongWord): Boolean;
begin
  Result := (Index < CfiRegisterCapacity) and ((Registers.Known and (QWord(1) shl Index)) <> 0);
end;

procedure SetRegister(var Registers: TUnwindRegisters; Index: LongWord; Value: QWord);
begin
  if Index >= CfiRegisterCapacity then
    Exit;
  Registers.Values[Index] := Value;
  Registers.Known := Registers.Known or (QWord(1) shl Index);
end;

procedure ForgetRegister(var Registers: TUnwindRegisters; Index: LongWord);
begin
  if Index >= CfiRegisterCapacity then
    Exit;
  Registers.Known := Registers.Known and not (QWord(1) shl Index);
end;

{$push}{$R-}{$Q-}
function ScaledOffset(Factor: QWord; Alignment: Int64): Int64;
begin
  Result := Int64(Factor) * Alignment;
end;

function ScaledSignedOffset(Factor: Int64; Alignment: Int64): Int64;
begin
  Result := Factor * Alignment;
end;
{$pop}

procedure SetRule(var Rules: TFrameRules; Register: QWord; Kind: TRuleKind; Operand: Int64);
begin
  { Columns past the general registers (vector registers) do not
    matter for finding the caller. }
  if Register >= CfiRegisterCapacity then
    Exit;
  Rules.Registers[Register].Kind := Kind;
  Rules.Registers[Register].Operand := Operand;
end;

{ Moves the location on by Delta code units; False once it passes the
  target (the program stops there). }
function Advance(var Run: TProgramRun; Delta: QWord): Boolean;
var
  Distance: QWord;
begin
  if not Run.MayAdvance then
    Exit(True);
  if (Run.Location > Run.Target) or (Delta > High(LongWord)) then
    Exit(False);
  Distance := Delta * Run.CodeAlignment;
  if Distance > Run.Target - Run.Location then
    Exit(False);
  Run.Location := Run.Location + Distance;
  Result := True;
end;

{ Skips a DWARF expression block (a length, then its bytes). }
function SkipBlock(var Run: TProgramRun): Boolean;
var
  Length: QWord;
begin
  Result := ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Length) and
    (Length <= Run.Size - Run.Position);
  if Result then
    Run.Position := Run.Position + LongWord(Length);
end;

type
  TStepResult = (StepContinue, StepReachedTarget, StepFailed);

{ The instructions with an operand in the opcode byte's low bits. }
function RunPackedInstruction(var Run: TProgramRun; Opcode: Byte; var Rules: TFrameRules;
  constref Initial: TFrameRules): TStepResult;
var
  Operand: Byte;
  Value: QWord;
begin
  Result := StepContinue;
  Operand := Opcode and $3F;
  case Opcode and $C0 of
    OpcodeAdvanceLocation:
      if not Advance(Run, Operand) then
        Result := StepReachedTarget;
    OpcodeOffset:
      if ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Value) then
        SetRule(Rules, Operand, RuleOffset, ScaledOffset(Value, Run.DataAlignment))
      else
        Result := StepFailed;
    OpcodeRestore:
      if Operand < CfiRegisterCapacity then
        Rules.Registers[Operand] := Initial.Registers[Operand];
  end;
end;

{ The advances and DW_CFA_set_loc. }
function RunLocationInstruction(var Run: TProgramRun; Opcode: Byte): TStepResult;
var
  Value: QWord;
  Width: LongWord;
begin
  Result := StepContinue;
  if Opcode = OpcodeSetLocation then
  begin
    if Run.IsEhFrame then
    begin
      if not ReadEncodedPointer(Run.Bytes, Run.Size, Run.Position, Run.PointerEncoding, Run.BytesAddress, 0,
         Value) then
        Exit(StepFailed);
      if (Run.PointerEncoding and $70) = 0 then
        Value := AddressPlusOffset(Value, Int64(Run.AddressBias));
    end
    else
    begin
      if not ReadFixed(Run.Bytes, Run.Size, Run.Position, 8, Value) then
        Exit(StepFailed);
      Value := AddressPlusOffset(Value, Int64(Run.AddressBias));
    end;
    if Run.MayAdvance then
    begin
      if Value > Run.Target then
        Exit(StepReachedTarget);
      Run.Location := Value;
    end;
    Exit;
  end;
  case Opcode of
    OpcodeAdvanceLocation1: Width := 1;
    OpcodeAdvanceLocation2: Width := 2;
  else
    Width := 4;
  end;
  if not ReadFixed(Run.Bytes, Run.Size, Run.Position, Width, Value) then
    Exit(StepFailed);
  if not Advance(Run, Value) then
    Result := StepReachedTarget;
end;

{ The CFA definitions. }
function RunCfaInstruction(var Run: TProgramRun; Opcode: Byte; var Rules: TFrameRules): Boolean;
var
  Register: QWord;
  Value: QWord;
  Signed: Int64;
begin
  Result := False;
  case Opcode of
    OpcodeDefineCfa:
      begin
        if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Register) or
           not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Value) then
          Exit;
        Rules.CfaRegister := LongWord(Register and $FFFFFFFF);
        Rules.CfaOffset := Int64(Value);
        Rules.CfaIsExpression := False;
      end;
    OpcodeDefineCfaSigned:
      begin
        if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Register) or
           not ReadSignedLeb128(Run.Bytes, Run.Size, Run.Position, Signed) then
          Exit;
        Rules.CfaRegister := LongWord(Register and $FFFFFFFF);
        Rules.CfaOffset := ScaledSignedOffset(Signed, Run.DataAlignment);
        Rules.CfaIsExpression := False;
      end;
    OpcodeDefineCfaRegister:
      begin
        if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Register) then
          Exit;
        Rules.CfaRegister := LongWord(Register and $FFFFFFFF);
        Rules.CfaIsExpression := False;
      end;
    OpcodeDefineCfaOffset:
      begin
        if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Value) then
          Exit;
        Rules.CfaOffset := Int64(Value);
      end;
    OpcodeDefineCfaOffsetSigned:
      begin
        if not ReadSignedLeb128(Run.Bytes, Run.Size, Run.Position, Signed) then
          Exit;
        Rules.CfaOffset := ScaledSignedOffset(Signed, Run.DataAlignment);
      end;
    OpcodeDefineCfaExpression:
      begin
        if not SkipBlock(Run) then
          Exit;
        Rules.CfaIsExpression := True;
      end;
  end;
  Result := True;
end;

{ The register rules with operands in the bytes that follow. }
function RunRegisterInstruction(var Run: TProgramRun; Opcode: Byte; var Rules: TFrameRules;
  constref Initial: TFrameRules): Boolean;
var
  Register: QWord;
  Value: QWord;
  Signed: Int64;
begin
  Result := False;
  if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Register) then
    Exit;
  case Opcode of
    OpcodeOffsetExtended, OpcodeValueOffset, OpcodeNegativeOffsetExtended, OpcodeRegister:
      if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Value) then
        Exit;
    OpcodeOffsetExtendedSigned, OpcodeValueOffsetSigned:
      if not ReadSignedLeb128(Run.Bytes, Run.Size, Run.Position, Signed) then
        Exit;
    OpcodeExpression, OpcodeValueExpression:
      if not SkipBlock(Run) then
        Exit;
  end;
  case Opcode of
    OpcodeOffsetExtended:
      SetRule(Rules, Register, RuleOffset, ScaledOffset(Value, Run.DataAlignment));
    OpcodeNegativeOffsetExtended:
      SetRule(Rules, Register, RuleOffset, -ScaledOffset(Value, Run.DataAlignment));
    OpcodeOffsetExtendedSigned:
      SetRule(Rules, Register, RuleOffset, ScaledSignedOffset(Signed, Run.DataAlignment));
    OpcodeValueOffset:
      SetRule(Rules, Register, RuleValueOffset, ScaledOffset(Value, Run.DataAlignment));
    OpcodeValueOffsetSigned:
      SetRule(Rules, Register, RuleValueOffset, ScaledSignedOffset(Signed, Run.DataAlignment));
    OpcodeRegister:
      SetRule(Rules, Register, RuleRegister, Int64(Value and $FFFFFFFF));
    OpcodeRestoreExtended:
      if Register < CfiRegisterCapacity then
        Rules.Registers[Register] := Initial.Registers[Register];
    OpcodeUndefined:
      SetRule(Rules, Register, RuleUndefined, 0);
    OpcodeSameValue:
      SetRule(Rules, Register, RuleSameValue, 0);
    OpcodeExpression, OpcodeValueExpression:
      SetRule(Rules, Register, RuleUnknown, 0);
  end;
  Result := True;
end;

{ Runs the instructions in Run until the location would pass the
  target; False if they are malformed. }
function RunProgram(var Run: TProgramRun; var Rules: TFrameRules; constref Initial: TFrameRules): Boolean;
var
  Opcode: Byte;
  Step: TStepResult;
  Value: QWord;
begin
  Result := False;
  while Run.Position < Run.Size do
  begin
    Opcode := Run.Bytes[Run.Position];
    Inc(Run.Position);
    Step := StepContinue;
    if (Opcode and $C0) <> 0 then
      Step := RunPackedInstruction(Run, Opcode, Rules, Initial)
    else
      case Opcode of
        OpcodeNop, OpcodeNegateReturnAddressState:
          ;
        OpcodeSetLocation, OpcodeAdvanceLocation1, OpcodeAdvanceLocation2, OpcodeAdvanceLocation4:
          Step := RunLocationInstruction(Run, Opcode);
        OpcodeDefineCfa, OpcodeDefineCfaSigned, OpcodeDefineCfaRegister, OpcodeDefineCfaOffset,
        OpcodeDefineCfaOffsetSigned, OpcodeDefineCfaExpression:
          if not RunCfaInstruction(Run, Opcode, Rules) then
            Step := StepFailed;
        OpcodeOffsetExtended, OpcodeRestoreExtended, OpcodeUndefined, OpcodeSameValue, OpcodeRegister,
        OpcodeExpression, OpcodeOffsetExtendedSigned, OpcodeValueOffset, OpcodeValueOffsetSigned,
        OpcodeValueExpression, OpcodeNegativeOffsetExtended:
          if not RunRegisterInstruction(Run, Opcode, Rules, Initial) then
            Step := StepFailed;
        OpcodeRememberState:
          begin
            if Run.StateDepth >= CfiStateDepth then
              Exit;
            Run.States[Run.StateDepth] := Rules;
            Inc(Run.StateDepth);
          end;
        OpcodeRestoreState:
          begin
            if Run.StateDepth = 0 then
              Exit;
            Dec(Run.StateDepth);
            Rules := Run.States[Run.StateDepth];
          end;
        OpcodeArgumentsSize:
          if not ReadUnsignedLeb128(Run.Bytes, Run.Size, Run.Position, Value) then
            Step := StepFailed;
      else
        Exit;
      end;
    case Step of
      StepReachedTarget:
        Break;
      StepFailed:
        Exit;
    end;
  end;
  Result := True;
end;

function ComputeFrameRules(constref Entry: TFrameEntry; Pc: QWord; out Rules: TFrameRules): Boolean;
var
  Cie: TCommonInformation;
  Fde: TFrameDescription;
  Run: TProgramRun;
  Initial: TFrameRules;
begin
  ZeroMemory(@Rules, SizeOf(Rules));
  if not DecodeCommonInformation(Entry, Cie) or not DecodeFrameDescription(Entry, Cie, Fde) then
    Exit(False);
  if (Pc < Fde.Start) or (Pc >= Fde.Finish) then
    Exit(False);
  Rules.ReturnAddressColumn := Cie.ReturnAddressColumn;
  ZeroMemory(@Run, SizeOf(Run));
  Run.CodeAlignment := Cie.CodeAlignment;
  Run.DataAlignment := Cie.DataAlignment;
  Run.PointerEncoding := Cie.PointerEncoding;
  Run.AddressBias := Entry.AddressBias;
  Run.IsEhFrame := Entry.IsEhFrame;
  Run.Location := Fde.Start;
  Run.Target := Pc;

  Run.Bytes := @Entry.Cie[0];
  Run.Size := Cie.InstructionsEnd;
  Run.Position := Cie.InstructionsStart;
  Run.BytesAddress := Entry.CieAddress;
  Run.MayAdvance := False;
  Initial := Rules;
  if not RunProgram(Run, Rules, Initial) then
    Exit(False);
  Initial := Rules;

  Run.Bytes := @Entry.Fde[0];
  Run.Size := Fde.InstructionsEnd;
  Run.Position := Fde.InstructionsStart;
  Run.BytesAddress := Entry.FdeAddress;
  Run.MayAdvance := True;
  Run.StateDepth := 0;
  Result := RunProgram(Run, Rules, Initial) and not Rules.CfaIsExpression;
end;

function ReadWord(constref Memory: TCfiMemory; Address: QWord; out Value: QWord): Boolean;
begin
  Value := 0;
  Result := Memory.Read(Memory.Context, Address, @Value, SizeOf(Value));
end;

function ApplyFrameRules(constref Rules: TFrameRules; constref Architecture: TCfiArchitecture;
  constref Memory: TCfiMemory; var Registers: TUnwindRegisters): Boolean;
var
  Caller: TUnwindRegisters;
  Cfa: QWord;
  Index: LongWord;
  Rule: TRegisterRule;
  Value: QWord;
begin
  Result := False;
  if Rules.CfaIsExpression or not RegisterIsKnown(Registers, Rules.CfaRegister) then
    Exit;
  Cfa := AddressPlusOffset(Registers.Values[Rules.CfaRegister], Rules.CfaOffset);
  Caller := Registers;
  Index := 0;
  while Index < Architecture.RegisterCount do
  begin
    Rule := Rules.Registers[Index];
    case Rule.Kind of
      RuleOffset:
        if ReadWord(Memory, AddressPlusOffset(Cfa, Rule.Operand), Value) then
          SetRegister(Caller, Index, Value)
        else
          ForgetRegister(Caller, Index);
      RuleValueOffset:
        SetRegister(Caller, Index, AddressPlusOffset(Cfa, Rule.Operand));
      RuleRegister:
        if RegisterIsKnown(Registers, LongWord(Rule.Operand)) then
          SetRegister(Caller, Index, Registers.Values[Rule.Operand])
        else
          ForgetRegister(Caller, Index);
      RuleUndefined, RuleUnknown:
        ForgetRegister(Caller, Index);
    end;
    Inc(Index);
  end;
  if not RegisterIsKnown(Caller, Rules.ReturnAddressColumn) then
    Exit;
  Value := Caller.Values[Rules.ReturnAddressColumn];
  SetRegister(Caller, Architecture.ProgramCounterIndex, Value);
  SetRegister(Caller, Architecture.StackPointerIndex, Cfa);
  Registers := Caller;
  Result := True;
end;

function UnwindWithFramePointer(constref Architecture: TCfiArchitecture; constref Memory: TCfiMemory;
  var Registers: TUnwindRegisters): Boolean;
var
  FramePointer: QWord;
  SavedFramePointer: QWord;
  ReturnAddress: QWord;
begin
  Result := False;
  if not RegisterIsKnown(Registers, Architecture.FramePointerIndex) then
    Exit;
  FramePointer := Registers.Values[Architecture.FramePointerIndex];
  if (FramePointer = 0) or ((FramePointer mod Architecture.FramePointerAlignment) <> 0) then
    Exit;
  if not ReadWord(Memory, FramePointer, SavedFramePointer) or
     not ReadWord(Memory, FramePointer + 8, ReturnAddress) then
    Exit;
  SetRegister(Registers, Architecture.FramePointerIndex, SavedFramePointer);
  SetRegister(Registers, Architecture.StackPointerIndex, FramePointer + 16);
  SetRegister(Registers, Architecture.ReturnAddressColumn, ReturnAddress);
  SetRegister(Registers, Architecture.ProgramCounterIndex, ReturnAddress);
  Result := True;
end;

end.
