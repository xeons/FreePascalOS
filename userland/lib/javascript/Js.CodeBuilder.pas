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
  The base of the compiler: building one function's code.

  Emitting instructions and patching jumps; constants (atoms, numbers,
  strings, BigInts, deduplicated) and inline caches; the exception
  handler and line tables; registers (the locals first, then
  temporaries given out and taken back like a stack: a routine notes
  NextRegister, uses temporaries, and puts NextRegister back); the
  layout of the function's scopes (each variable to a register or, when
  captured, to a slot of its scope's environment); loading and storing
  variables (through the environment chain: hops counted over the
  scopes that have an environment); and the control contexts that
  break, continue and return pass through: loops, switches, labelled
  statements, finally blocks (whose code is copied in front of each
  jump out of them) and for-of loops (whose iterator is closed).

  The layers above add expressions (Js.ExpressionCompiler), statements
  (Js.StatementCompiler) and functions and classes (Js.Compiler).
}
unit Js.CodeBuilder;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.BigIntegers,
  Js.Lexer,
  Js.Ast,
  Js.Bytecode;

type
  TJsControlKind = (ctLoop, ctSwitch, ctLabel, ctFinally, ctIterator);

  TJsGap = record
    Start: Integer;
    Finish: Integer;
  end;

  TJsControl = class
  public
    Kind: TJsControlKind;
    Labels: array of UnicodeString;
    BreakPatches: array of Integer;
    ContinuePatches: array of Integer;
    EnvironmentDepth: Integer;
    { ctFinally: the block copied in front of jumps out. }
    FinallyBlock: TJsNode;
    { ctIterator: the iterator's two registers. }
    IteratorRegister: Integer;
    IsAsync: Boolean;
    Gaps: array of TJsGap;
    function HasLabel(const Name: UnicodeString): Boolean;
    procedure AddGap(Start, Finish: Integer);
  end;

  { Shared by the compilers of one program. }
  TJsCompileContext = class
  public
    Realm: TJsRealm;
    Source: TJsSource;
    FileName: string;
  end;

  TJsCodeBuilder = class
  private
    FAtomIndex: array of Integer;
    FAtomMask: Integer;
    procedure GrowAtomIndex;
  protected
    FContext: TJsCompileContext;
    FInfo: TJsFunctionInfo;
    FCode: TJsCode;
    FInstructions: array of LongInt;
    FCount: Integer;
    FConstants: TJsValueList;
    FConstantCount: Integer;
    FFunctions: array of TJsCode;
    FFunctionCount: Integer;
    FCacheCount: Integer;
    FHandlers: array of TJsHandler;
    FHandlerCount: Integer;
    FLines: array of TJsLineEntry;
    FLineCount: Integer;
    FLastLine: Integer;
    FLastColumn: Integer;
    FNextRegister: Integer;
    FMaxRegister: Integer;
    FLocalCount: Integer;
    FScope: TJsScope;
    FEnvironmentDepth: Integer;
    FControls: array of TJsControl;
    FControlCount: Integer;
    FStrict: Boolean;
    FTemplateSites: Integer;
    function Heap: TJsHeap; inline;
    function Runtime: TJsRuntime; inline;
  public
    constructor Create(Context: TJsCompileContext; Info: TJsFunctionInfo);
    destructor Destroy; override;

    { Emission }
    procedure Emit(Opcode: TJsOpcode); overload;
    procedure Emit(Opcode: TJsOpcode; A: LongInt); overload;
    procedure Emit(Opcode: TJsOpcode; A, B: LongInt); overload;
    procedure Emit(Opcode: TJsOpcode; A, B, C: LongInt); overload;
    procedure Emit(Opcode: TJsOpcode; A, B, C, D: LongInt); overload;
    procedure Emit(Opcode: TJsOpcode; A, B, C, D, E: LongInt); overload;
    function Here: Integer; inline;
    { The position of the last word emitted (a jump's target operand). }
    function LastOperand: Integer; inline;
    procedure Patch(Position, Target: Integer); inline;
    procedure PatchHere(Position: Integer); inline;
    function EmitJump: Integer;
    function EmitJumpIf(Opcode: TJsOpcode; Register: Integer): Integer;
    procedure EmitJumpTo(Target: Integer);
    procedure NoteLine(Node: TJsNode);

    { Constants and caches }
    function AtomConstant(const Name: UnicodeString): Integer;
    function ValueConstant(Value: TJsValue): Integer;
    function NumberConstant(Value: Double): Integer;
    function StringConstant(const Text: UnicodeString): Integer;
    function NewCache: Integer;
    function AddFunction(Code: TJsCode): Integer;
    procedure AddHandler(StartPC, EndPC, HandlerPC, Register, EnvironmentDepth: Integer; IsFinally: Boolean;
      const Gaps: array of TJsGap);

    { Registers }
    function AllocateRegister: Integer;
    function AllocateRegisters(Count: Integer): Integer;
    function AllocateLocal: Integer;
    procedure ReleaseTo(Mark: Integer); inline;
    function IsLocalRegister(Register: Integer): Boolean; inline;

    { Scopes and variables }
    procedure LayoutScope(Scope: TJsScope; IncludeFunctionScope: Boolean);
    procedure EnterScope(Scope: TJsScope);
    procedure LeaveScope(Scope: TJsScope);
    function EnvironmentHops(Target: TJsScope): Integer;
    { The variable's value into Target (or a register holding it: the
      local itself when Target is -1). }
    function LoadVariable(Variable: TJsVariable; const Name: UnicodeString; Target: Integer;
      Reference: TJsNode = nil): Integer;
    procedure StoreVariable(Variable: TJsVariable; const Name: UnicodeString; Source: Integer;
      Initializing: Boolean; Reference: TJsNode = nil);
    function NeedsTdzCheck(Variable: TJsVariable; Reference: TJsNode): Boolean;
    procedure InitializeLexicals(Scope: TJsScope);

    { Control contexts }
    function PushControl(Kind: TJsControlKind): TJsControl;
    procedure PopControl(Control: TJsControl; BreakTarget, ContinueTarget: Integer);
    { Leaves the contexts above Index (finally blocks, iterators,
      environments) before a jump to the context at Index (-1: all). }
    procedure EmitExitTo(Index: Integer; TargetDepth: Integer);
    procedure EmitPopScopesTo(Depth: Integer);
    { Inlines a finally block (implemented by the statement layer). }
    procedure CompileFinallyBlock(Block: TJsNode); virtual; abstract;

    { Finishing }
    function FinishCode: TJsCode;
    property Code: TJsCode read FCode;
  end;

function DeclarationIsConstant(Variable: TJsVariable): Boolean; inline;

implementation

function DeclarationIsConstant(Variable: TJsVariable): Boolean;
begin
  Result := (Variable <> nil) and (Variable.Kind in [dkConst, dkClassInner]);
end;

{ TJsControl }

function TJsControl.HasLabel(const Name: UnicodeString): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Labels) do
    if Labels[Index] = Name then
      Exit(True);
  Result := False;
end;

procedure TJsControl.AddGap(Start, Finish: Integer);
begin
  if Finish <= Start then
    Exit;
  SetLength(Gaps, Length(Gaps) + 1);
  Gaps[High(Gaps)].Start := Start;
  Gaps[High(Gaps)].Finish := Finish;
end;

{ TJsCodeBuilder }

constructor TJsCodeBuilder.Create(Context: TJsCompileContext; Info: TJsFunctionInfo);
begin
  inherited Create;
  FContext := Context;
  FInfo := Info;
  FCode := TJsCode.Create;
  Heap.Register(FCode, ckCode);
  FCode.Source := Context.Source;
  FCode.ArgumentsRegister := -1;
  FCode.RestRegister := -1;
  SetLength(FInstructions, 64);
  SetLength(FAtomIndex, 16);
  FAtomMask := 15;
  FLastLine := -1;
end;

destructor TJsCodeBuilder.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FControlCount - 1 do
    FControls[Index].Free;
  inherited Destroy;
end;

function TJsCodeBuilder.Heap: TJsHeap;
begin
  Result := FContext.Realm.Heap;
end;

function TJsCodeBuilder.Runtime: TJsRuntime;
begin
  Result := FContext.Realm.Runtime;
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode);
begin
  if FCount + 8 > Length(FInstructions) then
    SetLength(FInstructions, Length(FInstructions) * 2);
  FInstructions[FCount] := Ord(Opcode);
  Inc(FCount);
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode; A: LongInt);
begin
  Emit(Opcode);
  FInstructions[FCount] := A;
  Inc(FCount);
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode; A, B: LongInt);
begin
  Emit(Opcode);
  FInstructions[FCount] := A;
  FInstructions[FCount + 1] := B;
  Inc(FCount, 2);
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode; A, B, C: LongInt);
begin
  Emit(Opcode);
  FInstructions[FCount] := A;
  FInstructions[FCount + 1] := B;
  FInstructions[FCount + 2] := C;
  Inc(FCount, 3);
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode; A, B, C, D: LongInt);
begin
  Emit(Opcode);
  FInstructions[FCount] := A;
  FInstructions[FCount + 1] := B;
  FInstructions[FCount + 2] := C;
  FInstructions[FCount + 3] := D;
  Inc(FCount, 4);
end;

procedure TJsCodeBuilder.Emit(Opcode: TJsOpcode; A, B, C, D, E: LongInt);
begin
  Emit(Opcode);
  FInstructions[FCount] := A;
  FInstructions[FCount + 1] := B;
  FInstructions[FCount + 2] := C;
  FInstructions[FCount + 3] := D;
  FInstructions[FCount + 4] := E;
  Inc(FCount, 5);
end;

function TJsCodeBuilder.Here: Integer;
begin
  Result := FCount;
end;

function TJsCodeBuilder.LastOperand: Integer;
begin
  Result := FCount - 1;
end;

procedure TJsCodeBuilder.Patch(Position, Target: Integer);
begin
  FInstructions[Position] := Target;
end;

procedure TJsCodeBuilder.PatchHere(Position: Integer);
begin
  FInstructions[Position] := FCount;
end;

function TJsCodeBuilder.EmitJump: Integer;
begin
  Emit(opJump, 0);
  Result := LastOperand;
end;

function TJsCodeBuilder.EmitJumpIf(Opcode: TJsOpcode; Register: Integer): Integer;
begin
  Emit(Opcode, Register, 0);
  Result := LastOperand;
end;

procedure TJsCodeBuilder.EmitJumpTo(Target: Integer);
begin
  Emit(opJump, Target);
end;

procedure TJsCodeBuilder.NoteLine(Node: TJsNode);
begin
  if (Node = nil) or ((Node.Line = FLastLine) and (Node.Column = FLastColumn)) then
    Exit;
  if (FLineCount > 0) and (FLines[FLineCount - 1].PC = FCount) then
    Dec(FLineCount);
  if FLineCount >= Length(FLines) then
    SetLength(FLines, Length(FLines) * 2 + 16);
  FLines[FLineCount].PC := FCount;
  FLines[FLineCount].Line := Node.Line;
  FLines[FLineCount].Column := Node.Column;
  Inc(FLineCount);
  FLastLine := Node.Line;
  FLastColumn := Node.Column;
end;

procedure TJsCodeBuilder.GrowAtomIndex;
var
  Index, Slot: Integer;
  Hash: LongWord;
begin
  SetLength(FAtomIndex, 0);
  SetLength(FAtomIndex, (FAtomMask + 1) * 2);
  FAtomMask := Length(FAtomIndex) - 1;
  for Index := 0 to FConstantCount - 1 do
    if JsIsString(FConstants[Index]) and JsAsString(FConstants[Index]).IsAtom then
    begin
      Hash := LongWord(PtrUInt(JsAsCell(FConstants[Index])) shr 4);
      Slot := Integer(Hash and LongWord(FAtomMask));
      while FAtomIndex[Slot] <> 0 do
        Slot := (Slot + 1) and FAtomMask;
      FAtomIndex[Slot] := Index + 1;
    end;
end;

function TJsCodeBuilder.ValueConstant(Value: TJsValue): Integer;
var
  Slot: Integer;
  Hash: LongWord;
  IsAtom: Boolean;
begin
  IsAtom := JsIsString(Value) and JsAsString(Value).IsAtom;
  if IsAtom then
  begin
    Hash := LongWord(PtrUInt(JsAsCell(Value)) shr 4);
    Slot := Integer(Hash and LongWord(FAtomMask));
    while FAtomIndex[Slot] <> 0 do
    begin
      if FConstants[FAtomIndex[Slot] - 1] = Value then
        Exit(FAtomIndex[Slot] - 1);
      Slot := (Slot + 1) and FAtomMask;
    end;
  end;
  if FConstantCount >= Length(FConstants) then
    SetLength(FConstants, Length(FConstants) * 2 + 8);
  FConstants[FConstantCount] := Value;
  Result := FConstantCount;
  Inc(FConstantCount);
  if IsAtom then
  begin
    if FConstantCount * 2 > Length(FAtomIndex) then
      GrowAtomIndex
    else
    begin
      Slot := Integer(Hash and LongWord(FAtomMask));
      while FAtomIndex[Slot] <> 0 do
        Slot := (Slot + 1) and FAtomMask;
      FAtomIndex[Slot] := Result + 1;
    end;
  end;
end;

function TJsCodeBuilder.AtomConstant(const Name: UnicodeString): Integer;
var
  Atom: TJsString;
begin
  Atom := Runtime.Atoms.Intern(NewStringFromUnicode(Heap, Name));
  Result := ValueConstant(JsStringValue(Atom));
end;

function TJsCodeBuilder.NumberConstant(Value: Double): Integer;
var
  Index: Integer;
  Encoded: TJsValue;
begin
  Encoded := JsNumber(Value);
  for Index := 0 to FConstantCount - 1 do
    if FConstants[Index] = Encoded then
      Exit(Index);
  Result := ValueConstant(Encoded);
end;

function TJsCodeBuilder.StringConstant(const Text: UnicodeString): Integer;
begin
  { String literals are atoms: equal literals share one string. }
  Result := AtomConstant(Text);
end;

function TJsCodeBuilder.NewCache: Integer;
begin
  Result := FCacheCount;
  Inc(FCacheCount);
end;

function TJsCodeBuilder.AddFunction(Code: TJsCode): Integer;
begin
  if FFunctionCount >= Length(FFunctions) then
    SetLength(FFunctions, Length(FFunctions) * 2 + 4);
  FFunctions[FFunctionCount] := Code;
  Result := FFunctionCount;
  Inc(FFunctionCount);
end;

procedure TJsCodeBuilder.AddHandler(StartPC, EndPC, HandlerPC, Register, EnvironmentDepth: Integer;
  IsFinally: Boolean; const Gaps: array of TJsGap);
var
  Position, Index, Best: Integer;
  Sorted: array of TJsGap;
  Swap: TJsGap;

  procedure Add(First, Last: Integer);
  begin
    if Last <= First then
      Exit;
    if FHandlerCount >= Length(FHandlers) then
      SetLength(FHandlers, Length(FHandlers) * 2 + 4);
    FHandlers[FHandlerCount].StartPC := First;
    FHandlers[FHandlerCount].EndPC := Last;
    FHandlers[FHandlerCount].HandlerPC := HandlerPC;
    FHandlers[FHandlerCount].Register := Register;
    FHandlers[FHandlerCount].EnvironmentDepth := EnvironmentDepth;
    FHandlers[FHandlerCount].IsFinally := IsFinally;
    Inc(FHandlerCount);
  end;

begin
  Sorted := nil;
  SetLength(Sorted, Length(Gaps));
  for Index := 0 to High(Gaps) do
    Sorted[Index] := Gaps[Index];
  for Index := 0 to High(Sorted) do
  begin
    Best := Index;
    for Position := Index + 1 to High(Sorted) do
      if Sorted[Position].Start < Sorted[Best].Start then
        Best := Position;
    Swap := Sorted[Index];
    Sorted[Index] := Sorted[Best];
    Sorted[Best] := Swap;
  end;
  Position := StartPC;
  for Index := 0 to High(Sorted) do
  begin
    if (Sorted[Index].Finish <= StartPC) or (Sorted[Index].Start >= EndPC) then
      Continue;
    Add(Position, Sorted[Index].Start);
    if Sorted[Index].Finish > Position then
      Position := Sorted[Index].Finish;
  end;
  Add(Position, EndPC);
end;

function TJsCodeBuilder.AllocateRegister: Integer;
begin
  Result := FNextRegister;
  Inc(FNextRegister);
  if FNextRegister > FMaxRegister then
    FMaxRegister := FNextRegister;
end;

function TJsCodeBuilder.AllocateRegisters(Count: Integer): Integer;
begin
  Result := FNextRegister;
  Inc(FNextRegister, Count);
  if FNextRegister > FMaxRegister then
    FMaxRegister := FNextRegister;
end;

function TJsCodeBuilder.AllocateLocal: Integer;
begin
  Result := FLocalCount;
  Inc(FLocalCount);
  if FNextRegister < FLocalCount then
    FNextRegister := FLocalCount;
  if FMaxRegister < FLocalCount then
    FMaxRegister := FLocalCount;
end;

procedure TJsCodeBuilder.ReleaseTo(Mark: Integer);
begin
  FNextRegister := Mark;
end;

function TJsCodeBuilder.IsLocalRegister(Register: Integer): Boolean;
begin
  Result := Register < FLocalCount;
end;

{ Gives each variable of Scope and its nested non-function scopes a
  register or an environment slot. }
procedure TJsCodeBuilder.LayoutScope(Scope: TJsScope; IncludeFunctionScope: Boolean);
var
  Index: Integer;
  Variable: TJsVariable;
begin
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if Variable.IsGlobal then
      Continue;
    if Variable.Captured then
    begin
      Variable.Index := Scope.EnvironmentSize;
      Inc(Scope.EnvironmentSize);
    end
    else if Variable.Index < 0 then
      Variable.Index := AllocateLocal;
  end;
  for Index := 0 to Scope.ChildCount - 1 do
    if not (Scope.Children[Index].Kind in [skFunction, skScript, skEval]) then
      LayoutScope(Scope.Children[Index], False);
end;

procedure TJsCodeBuilder.EnterScope(Scope: TJsScope);
begin
  FScope := Scope;
  if Scope.HasEnvironment then
  begin
    Emit(opPushScope, Scope.EnvironmentSize);
    Inc(FEnvironmentDepth);
  end;
  InitializeLexicals(Scope);
end;

procedure TJsCodeBuilder.LeaveScope(Scope: TJsScope);
begin
  if Scope.HasEnvironment then
  begin
    Emit(opPopScope);
    Dec(FEnvironmentDepth);
  end;
  FScope := Scope.Parent;
end;

procedure TJsCodeBuilder.InitializeLexicals(Scope: TJsScope);
var
  Index: Integer;
  Variable: TJsVariable;
  Hole: Integer;
  Mark: Integer;
begin
  Mark := FNextRegister;
  Hole := -1;
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if not Variable.IsLexical or Variable.IsGlobal then
      Continue;
    if Variable.Captured then
    begin
      if Hole < 0 then
      begin
        Hole := AllocateRegister;
        Emit(opLoadHole, Hole);
      end;
      Emit(opSetEnvironment, 0, Variable.Index, Hole);
    end
    else
      Emit(opLoadHole, Variable.Index);
  end;
  ReleaseTo(Mark);
end;

function TJsCodeBuilder.EnvironmentHops(Target: TJsScope): Integer;
var
  Walk: TJsScope;
begin
  Result := 0;
  Walk := FScope;
  while (Walk <> nil) and (Walk <> Target) do
  begin
    if Walk.HasEnvironment then
      Inc(Result);
    Walk := Walk.Parent;
  end;
  if Walk = nil then
    raise EJsSyntaxError.CreateAt('Internal error: scope not on the chain', 0, 0);
end;

function TJsCodeBuilder.NeedsTdzCheck(Variable: TJsVariable; Reference: TJsNode): Boolean;
begin
  if Variable.Kind = dkImplicit then
    Exit((Variable.Name = '%this') and (Variable.Scope.Func <> nil) and
      (Variable.Scope.Func.Kind = fkDerivedConstructor));
  if not Variable.IsLexical or Variable.IsGlobal then
    Exit(False);
  if Variable.Kind = dkClassInner then
    Exit(True);
  if Reference = nil then
    Exit(True);
  if Variable.Scope.FunctionScope <> FScope.FunctionScope then
    Exit(True);
  if Variable.Scope.Kind = skSwitch then
    Exit(True);
  Result := Trunc(Reference.Number) < Variable.DeclarationStart;
end;

function TJsCodeBuilder.LoadVariable(Variable: TJsVariable; const Name: UnicodeString; Target: Integer;
  Reference: TJsNode): Integer;
var
  Check: Boolean;
begin
  if (Variable = nil) or Variable.IsGlobal then
  begin
    if Target < 0 then
      Target := AllocateRegister;
    Emit(opGetGlobal, Target, AtomConstant(Name), NewCache);
    Exit(Target);
  end;
  Check := NeedsTdzCheck(Variable, Reference);
  if Variable.Captured then
  begin
    if Target < 0 then
      Target := AllocateRegister;
    if Check then
      Emit(opGetEnvironmentChecked, Target, EnvironmentHops(Variable.Scope), Variable.Index, AtomConstant(Name))
    else
      Emit(opGetEnvironment, Target, EnvironmentHops(Variable.Scope), Variable.Index);
    Exit(Target);
  end;
  if Check then
    Emit(opCheckInitialized, Variable.Index, AtomConstant(Name));
  if (Target < 0) or (Target = Variable.Index) then
    Exit(Variable.Index);
  Emit(opMove, Target, Variable.Index);
  Result := Target;
end;

procedure TJsCodeBuilder.StoreVariable(Variable: TJsVariable; const Name: UnicodeString; Source: Integer;
  Initializing: Boolean; Reference: TJsNode);
begin
  if (Variable <> nil) and Variable.IsGlobal and Initializing and Variable.IsLexical then
  begin
    Emit(opInitializeGlobalLexical, AtomConstant(Name), Source);
    Exit;
  end;
  if (Variable = nil) or Variable.IsGlobal then
  begin
    Emit(opSetGlobal, Source, AtomConstant(Name), NewCache, Ord(FStrict));
    Exit;
  end;
  if not Initializing then
  begin
    if DeclarationIsConstant(Variable) then
    begin
      { Reading first gives the temporal dead zone's error first. }
      LoadVariable(Variable, Name, -1, Reference);
      if (Variable.Kind = dkClassInner) or FStrict or (Variable.Kind = dkConst) then
        Emit(opThrowConstAssign, AtomConstant(Name));
      Exit;
    end;
    if (Variable.Kind = dkImplicit) and (Variable.Name <> 'arguments') and (Variable.Name <> '%this') then
      Exit;
  end;
  if Variable.Captured then
  begin
    if (not Initializing) and NeedsTdzCheck(Variable, Reference) then
      Emit(opSetEnvironmentChecked, EnvironmentHops(Variable.Scope), Variable.Index, Source, AtomConstant(Name))
    else
      Emit(opSetEnvironment, EnvironmentHops(Variable.Scope), Variable.Index, Source);
    Exit;
  end;
  if (not Initializing) and NeedsTdzCheck(Variable, Reference) then
    Emit(opCheckInitialized, Variable.Index, AtomConstant(Name));
  if Source <> Variable.Index then
    Emit(opMove, Variable.Index, Source);
end;

{ Control contexts }

function TJsCodeBuilder.PushControl(Kind: TJsControlKind): TJsControl;
begin
  Result := TJsControl.Create;
  Result.Kind := Kind;
  Result.EnvironmentDepth := FEnvironmentDepth;
  Result.IteratorRegister := -1;
  if FControlCount >= Length(FControls) then
    SetLength(FControls, Length(FControls) * 2 + 4);
  FControls[FControlCount] := Result;
  Inc(FControlCount);
end;

procedure TJsCodeBuilder.PopControl(Control: TJsControl; BreakTarget, ContinueTarget: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(Control.BreakPatches) do
    Patch(Control.BreakPatches[Index], BreakTarget);
  for Index := 0 to High(Control.ContinuePatches) do
    Patch(Control.ContinuePatches[Index], ContinueTarget);
  Dec(FControlCount);
  Control.Free;
end;

procedure TJsCodeBuilder.EmitPopScopesTo(Depth: Integer);
var
  Index: Integer;
begin
  for Index := Depth + 1 to FEnvironmentDepth do
    Emit(opPopScope);
end;

procedure TJsCodeBuilder.EmitExitTo(Index: Integer; TargetDepth: Integer);
var
  Level, Inner, SavedCount, SavedDepth, Start: Integer;
  Control: TJsControl;
  SavedScope: TJsScope;
begin
  SavedDepth := FEnvironmentDepth;
  SavedScope := FScope;
  Level := FControlCount - 1;
  while Level > Index do
  begin
    Control := FControls[Level];
    if Control.Kind in [ctFinally, ctIterator] then
    begin
      Start := Here;
      EmitPopScopesTo(Control.EnvironmentDepth);
      FEnvironmentDepth := Control.EnvironmentDepth;
      SavedCount := FControlCount;
      FControlCount := Level;
      if Control.Kind = ctFinally then
        CompileFinallyBlock(Control.FinallyBlock)
      else
        Emit(opIteratorClose, Control.IteratorRegister);
      FControlCount := SavedCount;
      for Inner := Level to FControlCount - 1 do
        FControls[Inner].AddGap(Start, Here);
    end;
    Dec(Level);
  end;
  EmitPopScopesTo(TargetDepth);
  FEnvironmentDepth := SavedDepth;
  FScope := SavedScope;
end;

function TJsCodeBuilder.FinishCode: TJsCode;
begin
  Result := FCode;
  Result.Instructions := Copy(FInstructions, 0, FCount);
  Result.Constants := Copy(FConstants, 0, FConstantCount);
  Result.Functions := Copy(FFunctions, 0, FFunctionCount);
  SetLength(Result.Caches, FCacheCount);
  if FCacheCount > 0 then
    FillChar(Result.Caches[0], FCacheCount * SizeOf(TJsPropertyCache), 0);
  Result.Handlers := Copy(FHandlers, 0, FHandlerCount);
  Result.Lines := Copy(FLines, 0, FLineCount);
  Result.RegisterCount := FMaxRegister;
  SetLength(Result.TemplateObjects, FTemplateSites);
  Heap.Account(Result.MemorySize - Result.InstanceSize);
end;

end.
