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
  The compiler's statement layer.

  Blocks enter their scope (pushing an environment when something in
  them is captured) and make their function declarations first. Loops,
  switches and labelled statements are control contexts that break and
  continue find by label. A for loop whose let variable is captured
  copies its environment before each iteration's update, so each
  closure sees its own iteration's variable.

  try/catch/finally: the protected ranges go to the handler table when
  the statement is done (inner statements' handlers first, so the
  innermost handler is found first). A finally block is compiled once
  for the exception path (it rethrows what it caught) and copied in
  front of every other way out: the end of the try or catch block, and
  each break, continue or return that leaves it; the copies are gaps in
  the ranges, so an exception in a finally block is not caught by its
  own try.

  for-of keeps its iterator in two registers; leaving the loop early
  closes the iterator, and an exception in the body closes it quietly
  and goes on.
}
unit Js.StatementCompiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Lexer,
  Js.Ast,
  Js.Bytecode,
  Js.CodeBuilder,
  Js.ExpressionCompiler;

type
  TJsStatementCompiler = class(TJsExpressionCompiler)
  protected
    FPendingLabels: array of UnicodeString;
    { Scripts: the value of the last expression statement. }
    FCompletionRegister: Integer;
    function TakeLabels: TJsControl;
    procedure CompileStatements(const List: array of TJsNode; Count: Integer);
    procedure HoistFunctions(const List: array of TJsNode; Count: Integer);
    procedure CompileVariables(Node: TJsNode);
    procedure CompileBlock(Node: TJsNode);
    procedure CompileIf(Node: TJsNode);
    procedure CompileWhile(Node: TJsNode);
    procedure CompileDoWhile(Node: TJsNode);
    procedure CompileFor(Node: TJsNode);
    procedure CompileForIn(Node: TJsNode);
    procedure CompileForOf(Node: TJsNode);
    procedure CompileForAwait(Node: TJsNode);
    procedure BindLoopTarget(Left: TJsNode; Value: Integer);
    procedure CompileJump(Node: TJsNode);
    procedure CompileReturn(Node: TJsNode);
    procedure CompileTry(Node: TJsNode);
    procedure CompileSwitch(Node: TJsNode);
    procedure CompileLabeled(Node: TJsNode);
    procedure CompileFunctionDeclaration(Node: TJsNode);
    procedure CompileClassDeclaration(Node: TJsNode);
    { The value a return statement gives back (derived constructors
      give this when it is undefined). }
    procedure EmitReturnValue(Value: Integer); virtual;
  public
    procedure Statement(Node: TJsNode);
    procedure CompileFinallyBlock(Block: TJsNode); override;
  end;

implementation

function TJsStatementCompiler.TakeLabels: TJsControl;
begin
  Result := nil;
end;

procedure TJsStatementCompiler.HoistFunctions(const List: array of TJsNode; Count: Integer);
var
  Index, Mark, Value: Integer;
  Node: TJsNode;
begin
  for Index := 0 to Count - 1 do
  begin
    Node := List[Index];
    while (Node.Kind = nkLabeled) and (Node.A <> nil) do
      Node := Node.A;
    if Node.Kind <> nkFunctionDeclaration then
      Continue;
    Mark := FNextRegister;
    Value := CompileFunctionNode(Node, -1, Node.Func.Name, True);
    if (Node.A.Variable <> nil) and Node.A.Variable.IsGlobal then
      Emit(opDeclareGlobalVar, AtomConstant(Node.Func.Name), Value)
    else
      StoreVariable(Node.A.Variable, Node.Func.Name, Value, True);
    ReleaseTo(Mark);
  end;
end;

procedure TJsStatementCompiler.CompileStatements(const List: array of TJsNode; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    Statement(List[Index]);
end;

procedure TJsStatementCompiler.CompileFinallyBlock(Block: TJsNode);
var
  Mark: Integer;
begin
  Mark := FNextRegister;
  CompileBlock(Block);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.Statement(Node: TJsNode);
var
  Mark, Value: Integer;
begin
  Mark := FNextRegister;
  NoteLine(Node);
  case Node.Kind of
    nkExpressionStatement:
      if FCompletionRegister >= 0 then
      begin
        Value := Expression(Node.A, FCompletionRegister);
        if Value <> FCompletionRegister then
          Emit(opMove, FCompletionRegister, Value);
      end
      else
        ExpressionDiscard(Node.A);
    nkVariables: CompileVariables(Node);
    nkBlock: CompileBlock(Node);
    nkEmpty: ;
    nkIf: CompileIf(Node);
    nkWhile: CompileWhile(Node);
    nkDoWhile: CompileDoWhile(Node);
    nkFor: CompileFor(Node);
    nkForIn: CompileForIn(Node);
    nkForOf:
      if (Node.Flags and ForFlagAwait) <> 0 then
        CompileForAwait(Node)
      else
        CompileForOf(Node);
    nkBreak, nkContinue: CompileJump(Node);
    nkReturn: CompileReturn(Node);
    nkThrow:
      begin
        Value := Expression(Node.A, -1);
        NoteLine(Node);
        Emit(opThrow, Value);
      end;
    nkTry: CompileTry(Node);
    nkSwitch: CompileSwitch(Node);
    nkLabeled: CompileLabeled(Node);
    nkDebugger: Emit(opDebugger);
    nkFunctionDeclaration: CompileFunctionDeclaration(Node);
    nkClassDeclaration: CompileClassDeclaration(Node);
    nkWith:
      raise EJsSyntaxError.CreateAt('The with statement is not supported', Node.Line, Node.Column);
  else
    raise EJsSyntaxError.CreateAt('Unsupported statement', Node.Line, Node.Column);
  end;
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileVariables(Node: TJsNode);
var
  Index, Mark, Value: Integer;
  Declarator: TJsNode;
  Kind: TJsDeclarationKind;
begin
  Kind := TJsDeclarationKind(Node.Flags);
  for Index := 0 to Node.Count - 1 do
  begin
    Mark := FNextRegister;
    Declarator := Node.List[Index];
    if Declarator.B = nil then
    begin
      if Kind = dkVar then
        Continue;
      Value := AllocateRegister;
      Emit(opLoadUndefined, Value);
      BindPattern(Declarator.A, Value, bmInitialize);
    end
    else if Declarator.A.Kind = nkIdentifier then
    begin
      Value := NamedExpression(Declarator.B, -1, Declarator.A.Text);
      if Kind = dkVar then
        BindPattern(Declarator.A, Value, bmVar)
      else
        BindPattern(Declarator.A, Value, bmInitialize);
    end
    else
    begin
      Value := Expression(Declarator.B, -1);
      if Kind = dkVar then
        BindPattern(Declarator.A, Value, bmVar)
      else
        BindPattern(Declarator.A, Value, bmInitialize);
    end;
    ReleaseTo(Mark);
  end;
end;

procedure TJsStatementCompiler.CompileBlock(Node: TJsNode);
begin
  if Node.Scope <> nil then
    EnterScope(Node.Scope);
  HoistFunctions(Node.List, Node.Count);
  CompileStatements(Node.List, Node.Count);
  if Node.Scope <> nil then
    LeaveScope(Node.Scope);
end;

procedure TJsStatementCompiler.CompileIf(Node: TJsNode);
var
  ElsePatches: TJsPatchList;
  Skip: Integer;
begin
  ElsePatches := nil;
  Branch(Node.A, False, ElsePatches);
  Statement(Node.B);
  if Node.C <> nil then
  begin
    Skip := EmitJump;
    PatchAll(ElsePatches, Here);
    Statement(Node.C);
    PatchHere(Skip);
  end
  else
    PatchAll(ElsePatches, Here);
end;

function NewLoopControl(Compiler: TJsStatementCompiler): TJsControl;
begin
  Result := Compiler.PushControl(ctLoop);
  Result.Labels := Compiler.FPendingLabels;
  Compiler.FPendingLabels := nil;
end;

procedure TJsStatementCompiler.CompileWhile(Node: TJsNode);
var
  Control: TJsControl;
  Start: Integer;
  ExitPatches: TJsPatchList;
begin
  Control := NewLoopControl(Self);
  Start := Here;
  ExitPatches := nil;
  Branch(Node.A, False, ExitPatches);
  Statement(Node.D);
  EmitJumpTo(Start);
  PatchAll(ExitPatches, Here);
  PopControl(Control, Here, Start);
end;

procedure TJsStatementCompiler.CompileDoWhile(Node: TJsNode);
var
  Control: TJsControl;
  Start, ContinueTarget, Index: Integer;
  Again: TJsPatchList;
begin
  Control := NewLoopControl(Self);
  Start := Here;
  Statement(Node.D);
  ContinueTarget := Here;
  Again := nil;
  Branch(Node.A, True, Again);
  for Index := 0 to High(Again) do
    Patch(Again[Index], Start);
  PopControl(Control, Here, ContinueTarget);
end;

procedure TJsStatementCompiler.CompileFor(Node: TJsNode);
var
  Control: TJsControl;
  Start, ContinueTarget: Integer;
  ExitPatches: TJsPatchList;
  Scope: TJsScope;
begin
  Scope := Node.Scope;
  EnterScope(Scope);
  if Node.A <> nil then
  begin
    if Node.A.Kind = nkVariables then
      CompileVariables(Node.A)
    else
      ExpressionDiscard(Node.A);
  end;
  Control := NewLoopControl(Self);
  Start := Here;
  ExitPatches := nil;
  if Node.B <> nil then
    Branch(Node.B, False, ExitPatches);
  Statement(Node.D);
  ContinueTarget := Here;
  if Scope.HasEnvironment then
    Emit(opCopyScope);
  if Node.C <> nil then
    ExpressionDiscard(Node.C);
  EmitJumpTo(Start);
  PatchAll(ExitPatches, Here);
  PopControl(Control, Here, ContinueTarget);
  LeaveScope(Scope);
end;

{ Assigns the loop's value to its left side: a declaration (fresh each
  iteration), a pattern or a simple target. }
procedure TJsStatementCompiler.BindLoopTarget(Left: TJsNode; Value: Integer);
var
  Kind: TJsDeclarationKind;
begin
  if Left.Kind = nkVariables then
  begin
    Kind := TJsDeclarationKind(Left.Flags);
    if Kind = dkVar then
      BindPattern(Left.List[0].A, Value, bmVar)
    else
      BindPattern(Left.List[0].A, Value, bmInitialize);
  end
  else
    BindPattern(Left, Value, bmAssign);
end;

procedure TJsStatementCompiler.CompileForIn(Node: TJsNode);
var
  Control: TJsControl;
  Mark, Iterator, Value, Start, Done: Integer;
  Scope: TJsScope;
  Labels: array of UnicodeString;
begin
  Mark := FNextRegister;
  Scope := Node.Scope;
  Labels := FPendingLabels;
  FPendingLabels := nil;
  Iterator := AllocateRegister;
  Value := AllocateRegister;
  { The object is evaluated with the loop's names in their dead zone. }
  EnterScope(Scope);
  Emit(opForInStart, Iterator, Expression(Node.B, -1));
  LeaveScope(Scope);
  ReleaseTo(Value + 1);
  Control := PushControl(ctLoop);
  Control.Labels := Labels;
  Start := Here;
  Emit(opForInNext, Value, Iterator, 0);
  Done := LastOperand;
  EnterScope(Scope);
  BindLoopTarget(Node.A, Value);
  Statement(Node.D);
  LeaveScope(Scope);
  EmitJumpTo(Start);
  PatchHere(Done);
  PopControl(Control, Here, Start);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileForOf(Node: TJsNode);
var
  Control, Closer: TJsControl;
  Mark, Iterator, Value, Start, Done, BodyStart, BodyEnd, Skip, HandlerPC, Caught: Integer;
  Scope: TJsScope;
  Labels: array of UnicodeString;
begin
  Mark := FNextRegister;
  Scope := Node.Scope;
  Labels := FPendingLabels;
  FPendingLabels := nil;
  Iterator := AllocateRegisters(2);
  Value := AllocateRegister;
  EnterScope(Scope);
  NoteLine(Node);
  Emit(opGetIterator, Iterator, Expression(Node.B, -1), 0);
  LeaveScope(Scope);
  ReleaseTo(Value + 1);
  Control := PushControl(ctLoop);
  Control.Labels := Labels;
  Closer := PushControl(ctIterator);
  Closer.IteratorRegister := Iterator;
  { continue goes through the closer without closing: see EmitExitTo. }
  Closer.Labels := nil;
  Start := Here;
  Emit(opIteratorNext, Value, Iterator, 0);
  Done := LastOperand;
  BodyStart := Here;
  EnterScope(Scope);
  BindLoopTarget(Node.A, Value);
  Statement(Node.D);
  LeaveScope(Scope);
  EmitJumpTo(Start);
  BodyEnd := Here;
  { An exception in the body: close the iterator, ignoring its errors,
    and carry on with the exception. }
  Skip := EmitJump;
  HandlerPC := Here;
  Caught := AllocateRegister;
  Emit(opIteratorCloseQuiet, Iterator);
  Emit(opRethrowCompletion, Caught);
  ReleaseTo(Value + 1);
  AddHandler(BodyStart, BodyEnd, HandlerPC, Caught, Control.EnvironmentDepth, True, Closer.Gaps);
  Dec(FControlCount);
  Closer.Free;
  PatchHere(Skip);
  PatchHere(Done);
  PopControl(Control, Here, Start);
  ReleaseTo(Mark);
end;

{ for await: next() is awaited each time; leaving early calls return()
  (not awaited). }
procedure TJsStatementCompiler.CompileForAwait(Node: TJsNode);
var
  Control, Closer: TJsControl;
  Mark, Iterator, Value, Start, Done, Base, Flag: Integer;
  Scope: TJsScope;
  Labels: array of UnicodeString;
begin
  Mark := FNextRegister;
  Scope := Node.Scope;
  Labels := FPendingLabels;
  FPendingLabels := nil;
  Iterator := AllocateRegisters(2);
  Value := AllocateRegister;
  EnterScope(Scope);
  Emit(opGetIterator, Iterator, Expression(Node.B, -1), 1);
  LeaveScope(Scope);
  ReleaseTo(Value + 1);
  Control := PushControl(ctLoop);
  Control.Labels := Labels;
  Closer := PushControl(ctIterator);
  Closer.IteratorRegister := Iterator;
  Closer.IsAsync := True;
  Start := Here;
  Base := AllocateRegisters(2);
  Emit(opMove, Base, Iterator + 1);
  Emit(opMove, Base + 1, Iterator);
  Emit(opCallMethod, Value, Base, 0);
  Emit(opAwait, Value, Value);
  Emit(opThrowIfNotObject, Value, 2);
  Flag := AllocateRegister;
  Emit(opGetNamed, Flag, Value, AtomConstant('done'), NewCache);
  Done := EmitJumpIf(opJumpIfTrue, Flag);
  Emit(opGetNamed, Value, Value, AtomConstant('value'), NewCache);
  ReleaseTo(Value + 1);
  EnterScope(Scope);
  BindLoopTarget(Node.A, Value);
  Statement(Node.D);
  LeaveScope(Scope);
  EmitJumpTo(Start);
  Dec(FControlCount);
  Closer.Free;
  PatchHere(Done);
  PopControl(Control, Here, Start);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileJump(Node: TJsNode);
var
  Index, Level: Integer;
  Control: TJsControl;
  IsBreak: Boolean;
  Found: Boolean;
  Position: Integer;
  Closer: TJsControl;
begin
  IsBreak := Node.Kind = nkBreak;
  Found := False;
  Index := FControlCount - 1;
  Control := nil;
  while Index >= 0 do
  begin
    Control := FControls[Index];
    if Node.Text <> '' then
    begin
      if Control.HasLabel(Node.Text) and ((Control.Kind <> ctLabel) or IsBreak) then
      begin
        Found := True;
        Break;
      end;
    end
    else if (Control.Kind = ctLoop) or (IsBreak and (Control.Kind = ctSwitch)) then
    begin
      Found := True;
      Break;
    end;
    Dec(Index);
  end;
  if not Found then
    raise EJsSyntaxError.CreateAt('Illegal break or continue', Node.Line, Node.Column);
  if not IsBreak then
  begin
    { continue: the loop's own iterator stays open. }
    Closer := nil;
    if (Index + 1 < FControlCount) and (FControls[Index + 1].Kind = ctIterator) then
    begin
      Closer := FControls[Index + 1];
      Closer.Kind := ctLabel;
    end;
    EmitExitTo(Index, Control.EnvironmentDepth);
    if Closer <> nil then
      Closer.Kind := ctIterator;
  end
  else
    EmitExitTo(Index, Control.EnvironmentDepth);
  Position := EmitJump;
  if IsBreak then
  begin
    SetLength(Control.BreakPatches, Length(Control.BreakPatches) + 1);
    Control.BreakPatches[High(Control.BreakPatches)] := Position;
  end
  else
  begin
    SetLength(Control.ContinuePatches, Length(Control.ContinuePatches) + 1);
    Control.ContinuePatches[High(Control.ContinuePatches)] := Position;
  end;
  Level := 0;
  if Level <> 0 then;
end;

procedure TJsStatementCompiler.EmitReturnValue(Value: Integer);
begin
  Emit(opReturn, Value);
end;

procedure TJsStatementCompiler.CompileReturn(Node: TJsNode);
var
  Value: Integer;
begin
  Value := AllocateRegister;
  if Node.A <> nil then
    ExpressionInto(Node.A, Value)
  else
    Emit(opLoadUndefined, Value);
  if FInfo.IsAsync and not FInfo.IsGenerator and (Node.A <> nil) then
    ;
  EmitExitTo(-1, FEnvironmentDepth);
  NoteLine(Node);
  EmitReturnValue(Value);
end;

procedure TJsStatementCompiler.CompileTry(Node: TJsNode);
var
  Finally_: TJsControl;
  TryStart, TryEnd, CatchPC, CatchEnd, AfterCatch, FinallyPC, EndJump: Integer;
  Caught, FinallyCaught, Mark, Depth: Integer;
  Gaps: array of TJsGap;
begin
  Mark := FNextRegister;
  Depth := FEnvironmentDepth;
  Finally_ := nil;
  if Node.D <> nil then
  begin
    Finally_ := PushControl(ctFinally);
    Finally_.FinallyBlock := Node.D;
  end;
  TryStart := Here;
  CompileBlock(Node.A);
  TryEnd := Here;
  CatchPC := -1;
  Caught := -1;
  CatchEnd := TryEnd;
  if Node.C <> nil then
  begin
    AfterCatch := EmitJump;
    CatchPC := Here;
    Caught := AllocateRegister;
    if Node.Scope <> nil then
      EnterScope(Node.Scope);
    if Node.B <> nil then
      BindPattern(Node.B, Caught, bmInitialize);
    CompileBlock(Node.C);
    if Node.Scope <> nil then
      LeaveScope(Node.Scope);
    CatchEnd := Here;
    PatchHere(AfterCatch);
  end;
  Gaps := nil;
  if Finally_ <> nil then
  begin
    Gaps := Copy(Finally_.Gaps);
    Dec(FControlCount);
    Finally_.Free;
    { The normal way out runs the finally block. }
    CompileFinallyBlock(Node.D);
    EndJump := EmitJump;
    FinallyPC := Here;
    FinallyCaught := AllocateRegister;
    CompileFinallyBlock(Node.D);
    Emit(opRethrowCompletion, FinallyCaught);
    PatchHere(EndJump);
    if CatchPC >= 0 then
      AddHandler(TryStart, TryEnd, CatchPC, Caught, Depth, False, Gaps);
    AddHandler(TryStart, CatchEnd, FinallyPC, FinallyCaught, Depth, True, Gaps);
  end
  else
    AddHandler(TryStart, TryEnd, CatchPC, Caught, Depth, False, []);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileSwitch(Node: TJsNode);
var
  Control: TJsControl;
  Mark, Discriminant, Index, Value, Compare, DefaultIndex, NoMatch: Integer;
  CaseJumps: array of Integer;
  CaseNode: TJsNode;
  Statements: array of TJsNode;
  StatementCount, Inner: Integer;
begin
  Mark := FNextRegister;
  Discriminant := AllocateRegister;
  ExpressionInto(Node.A, Discriminant);
  EnterScope(Node.Scope);
  { The functions of every case are made on entry. }
  StatementCount := 0;
  Statements := nil;
  for Index := 0 to Node.Count - 1 do
    for Inner := 0 to Node.List[Index].Count - 1 do
    begin
      SetLength(Statements, StatementCount + 1);
      Statements[StatementCount] := Node.List[Index].List[Inner];
      Inc(StatementCount);
    end;
  HoistFunctions(Statements, StatementCount);
  Control := PushControl(ctSwitch);
  Control.Labels := FPendingLabels;
  FPendingLabels := nil;
  CaseJumps := nil;
  SetLength(CaseJumps, Node.Count);
  DefaultIndex := -1;
  for Index := 0 to Node.Count - 1 do
  begin
    CaseNode := Node.List[Index];
    CaseJumps[Index] := -1;
    if CaseNode.A = nil then
    begin
      DefaultIndex := Index;
      Continue;
    end;
    Value := Expression(CaseNode.A, -1);
    Compare := AllocateRegister;
    Emit(opStrictEqual, Compare, Discriminant, Value);
    CaseJumps[Index] := EmitJumpIf(opJumpIfTrue, Compare);
    ReleaseTo(Discriminant + 1);
  end;
  NoMatch := EmitJump;
  for Index := 0 to Node.Count - 1 do
  begin
    if Index = DefaultIndex then
      Patch(NoMatch, Here)
    else
      PatchHere(CaseJumps[Index]);
    CompileStatements(Node.List[Index].List, Node.List[Index].Count);
  end;
  if DefaultIndex < 0 then
    PatchHere(NoMatch);
  PopControl(Control, Here, 0);
  LeaveScope(Node.Scope);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileLabeled(Node: TJsNode);
var
  Control: TJsControl;
  Inner: TJsNode;
begin
  SetLength(FPendingLabels, Length(FPendingLabels) + 1);
  FPendingLabels[High(FPendingLabels)] := Node.Text;
  Inner := Node.A;
  if Inner.Kind in [nkFor, nkForIn, nkForOf, nkWhile, nkDoWhile, nkLabeled, nkSwitch] then
  begin
    Statement(Inner);
    FPendingLabels := nil;
    Exit;
  end;
  Control := PushControl(ctLabel);
  Control.Labels := FPendingLabels;
  FPendingLabels := nil;
  Statement(Inner);
  PopControl(Control, Here, 0);
end;

procedure TJsStatementCompiler.CompileFunctionDeclaration(Node: TJsNode);
var
  Variable: TJsVariable;
  Mark, Value: Integer;
begin
  { Made when the scope was entered; a sloppy block function also sets
    the function's var of that name here (Annex B). }
  if Node.Name = '' then
    Exit;
  Variable := FScope.FunctionScope.Find(Node.Name);
  if (Variable = nil) or (Variable = Node.A.Variable) then
    Exit;
  Mark := FNextRegister;
  Value := LoadVariable(Node.A.Variable, Node.Name, -1, nil);
  StoreVariable(Variable, Node.Name, Value, True);
  ReleaseTo(Mark);
end;

procedure TJsStatementCompiler.CompileClassDeclaration(Node: TJsNode);
var
  Mark, Value: Integer;
begin
  Mark := FNextRegister;
  Value := CompileClass(Node, -1, Node.Text);
  StoreVariable(Node.B.Variable, Node.Text, Value, True);
  ReleaseTo(Mark);
end;

end.
