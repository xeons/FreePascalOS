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
  Scope analysis: every recorded reference to its variable.

  An identifier resolves to the nearest declaration up the scope chain,
  or to nothing (a global, looked up by name at run time). A variable
  used by a function nested inside the declaring one is captured: it
  will live in an environment instead of a register.

  this, new.target, super and arguments belong to the nearest function
  that is not an arrow. Used from that function itself they come
  straight from the frame; used from an arrow inside it they become
  implicit variables of that function ('%this', '%newtarget', '%home',
  '%function', 'arguments'), captured, that its prologue fills in. A
  derived class constructor keeps its this in such a variable always,
  since super() initialises it.

  Locations (registers and environment slots) are given out by the
  compiler, per function.

  A direct eval sees every binding of the scopes around it by name, so
  those scopes are exposed: all their variables live in environments
  (described to the eval's compiler at run time), and the function's
  this, new.target, home object and arguments are kept as implicit
  variables too. A sloppy function containing one also gets an object
  for the var declarations the eval makes, and every name in a with
  statement's body is looked up in the with object first: the
  identifiers that pass such objects on their way out record them
  (DynamicScopes) for the compiler.
}
unit Js.Scopes;

{$mode objfpc}{$H+}

interface

uses
  Js.Lexer,
  Js.Ast;

{ Resolves every reference of the program; raises EJsSyntaxError for a
  misplaced new.target or super. }
procedure ResolveProgram(Program_: TJsNode);

{ The nearest scope that has its own this (a function not an arrow, a
  script, an eval). }
function ThisScopeOf(Scope: TJsScope): TJsScope;

implementation

function IsArrowScope(Scope: TJsScope): Boolean;
begin
  { A direct eval's code takes this from around it, like an arrow. }
  Result := (Scope.Kind in [skFunction, skEval]) and (Scope.Func <> nil) and (Scope.Func.Kind = fkArrow);
end;

function ThisScopeOf(Scope: TJsScope): TJsScope;
begin
  Result := Scope.FunctionScope;
  while IsArrowScope(Result) do
    Result := Result.Parent.FunctionScope;
end;

function EnsureImplicit(Scope: TJsScope; const Name: UnicodeString; var Field: TJsVariable): TJsVariable;
begin
  if Field = nil then
  begin
    Field := Scope.Find(Name);
    if Field = nil then
      Field := Scope.Declare(Name, dkImplicit, 0);
  end;
  Result := Field;
end;

procedure Fail(Node: TJsNode; const Text: string);
begin
  raise EJsSyntaxError.CreateAt(Text, Node.Line, Node.Column);
end;

procedure AddDynamicScope(Node: TJsNode; Variable: TJsVariable);
begin
  SetLength(Node.DynamicScopes, Length(Node.DynamicScopes) + 1);
  Node.DynamicScopes[High(Node.DynamicScopes)] := Variable;
  Variable.Captured := True;
end;

procedure ResolveIdentifier(Node: TJsNode; Scope: TJsScope);
var
  Walk: TJsScope;
  Variable: TJsVariable;
  Name: UnicodeString;
begin
  Name := Node.Text;
  Walk := Scope;
  Variable := nil;
  Node.DynamicScopes := nil;
  while Walk <> nil do
  begin
    Variable := Walk.Find(Name);
    if Variable <> nil then
      Break;
    if (Name = 'arguments') and (Walk.Kind = skFunction) and (Walk.Func <> nil) and
      not (Walk.Func.Kind in [fkArrow, fkClassFieldInitializer]) then
    begin
      Variable := EnsureImplicit(Walk, 'arguments', Walk.Func.ArgumentsVariable);
      Walk.Func.UsesArguments := True;
      Break;
    end;
    if Walk.WithVariable <> nil then
      AddDynamicScope(Node, Walk.WithVariable);
    if (Walk.Kind = skFunction) and (Walk.Func <> nil) and (Walk.Func.EvalVarsVariable <> nil) and
      (Walk = Walk.FunctionScope) then
      AddDynamicScope(Node, Walk.Func.EvalVarsVariable);
    Walk := Walk.Parent;
  end;
  Node.Variable := Variable;
  if (Variable <> nil) and (Variable.Scope.FunctionScope <> Scope.FunctionScope) then
    Variable.Captured := True;
end;

procedure ResolveThis(Node: TJsNode; Scope: TJsScope);
var
  Owner: TJsScope;
  Variable: TJsVariable;
begin
  Owner := ThisScopeOf(Scope);
  Node.Scope := Owner;
  if (Owner = Scope.FunctionScope) and not ((Owner.Func <> nil) and (Owner.Func.Kind = fkDerivedConstructor)) then
  begin
    Node.Variable := nil;
    Exit;
  end;
  if Owner.Func = nil then
    Exit;
  Variable := EnsureImplicit(Owner, '%this', Owner.Func.ThisVariable);
  Owner.Func.UsesThis := True;
  if Owner <> Scope.FunctionScope then
    Variable.Captured := True;
  Node.Variable := Variable;
end;

procedure ResolveNewTarget(Node: TJsNode; Scope: TJsScope);
var
  Owner: TJsScope;
  Variable: TJsVariable;
begin
  Owner := ThisScopeOf(Scope);
  if Owner.Kind <> skFunction then
    Fail(Node, 'new.target expression is not allowed here');
  Node.Scope := Owner;
  if Owner = Scope.FunctionScope then
    Exit;
  Variable := EnsureImplicit(Owner, '%newtarget', Owner.Func.NewTargetVariable);
  Variable.Captured := True;
  Node.Variable := Variable;
end;

procedure ResolveSuperMember(Node: TJsNode; Scope: TJsScope);
var
  Owner: TJsScope;
  Variable: TJsVariable;
begin
  Owner := ThisScopeOf(Scope);
  if (Owner.Kind <> skFunction) or not (Owner.Func.Kind in [fkMethod, fkGetter, fkSetter, fkClassConstructor,
    fkDerivedConstructor, fkClassFieldInitializer]) then
    Fail(Node, '''super'' keyword unexpected here');
  { Node.Variable: the this value's variable (nil: the frame's). }
  ResolveThis(Node, Scope);
  if Owner = Scope.FunctionScope then
    Exit;
  Variable := EnsureImplicit(Owner, '%home', Owner.Func.HomeVariable);
  Variable.Captured := True;
end;

procedure ResolveSuperCall(Node: TJsNode; Scope: TJsScope);
var
  Owner: TJsScope;
  Variable: TJsVariable;
begin
  Owner := ThisScopeOf(Scope);
  if (Owner.Kind <> skFunction) or (Owner.Func.Kind <> fkDerivedConstructor) then
    Fail(Node, '''super'' keyword unexpected here');
  Node.Scope := Owner;
  Variable := EnsureImplicit(Owner, '%this', Owner.Func.ThisVariable);
  Node.Variable := Variable;
  if Owner <> Scope.FunctionScope then
  begin
    Variable.Captured := True;
    EnsureImplicit(Owner, '%function', Owner.Func.FunctionVariable).Captured := True;
    EnsureImplicit(Owner, '%newtarget', Owner.Func.NewTargetVariable).Captured := True;
  end;
end;

{ A direct eval in Scope: expose the scopes around it, keep what the
  eval's code may ask of its function. }
procedure PrepareDirectEval(Scope: TJsScope);
var
  Walk, Owner, VarScope: TJsScope;
  Info: TJsFunctionInfo;
begin
  Walk := Scope;
  while Walk <> nil do
  begin
    Walk.EvalExposed := True;
    Walk := Walk.Parent;
  end;
  { The scope the eval's var declarations go to (sloppy code). }
  VarScope := Scope.FunctionScope;
  while (VarScope.Kind = skEval) and (VarScope.Parent <> nil) do
    VarScope := VarScope.Parent.FunctionScope;
  if (VarScope.Kind = skFunction) and (VarScope.Func <> nil) and not VarScope.Func.IsStrict and
    (VarScope.Func.EvalVarsVariable = nil) then
  begin
    VarScope.Func.EvalVarsVariable := VarScope.Declare('%evalvars', dkImplicit, 0);
    VarScope.Func.EvalVarsVariable.Captured := True;
  end;
  Owner := ThisScopeOf(Scope);
  Info := Owner.Func;
  if Info = nil then
    Exit;
  if Owner.Kind in [skScript, skModule] then
  begin
    EnsureImplicit(Owner, '%this', Info.ThisVariable).Captured := True;
    Info.UsesThis := True;
    Exit;
  end;
  if Owner.Kind <> skFunction then
    Exit;
  EnsureImplicit(Owner, '%this', Info.ThisVariable).Captured := True;
  Info.UsesThis := True;
  EnsureImplicit(Owner, '%newtarget', Info.NewTargetVariable).Captured := True;
  if Info.Kind in [fkMethod, fkGetter, fkSetter, fkClassConstructor, fkDerivedConstructor,
    fkClassFieldInitializer] then
    EnsureImplicit(Owner, '%home', Info.HomeVariable).Captured := True;
  if Info.Kind = fkDerivedConstructor then
    EnsureImplicit(Owner, '%function', Info.FunctionVariable).Captured := True;
  if not (Info.Kind in [fkArrow, fkClassFieldInitializer]) then
  begin
    EnsureImplicit(Owner, 'arguments', Info.ArgumentsVariable).Captured := True;
    Info.UsesArguments := True;
  end;
end;

procedure PrepareScope(Scope: TJsScope);
var
  Index: Integer;
begin
  if (Scope.Kind = skFunction) and (Scope.Func <> nil) and (Scope.Func.Kind = fkDerivedConstructor) then
    EnsureImplicit(Scope, '%this', Scope.Func.ThisVariable);
  for Index := 0 to Scope.ReferenceCount - 1 do
    if (Scope.References[Index].Kind = nkCall) and
      ((Scope.References[Index].Flags and CallFlagDirectEval) <> 0) then
      PrepareDirectEval(Scope);
  for Index := 0 to Scope.ChildCount - 1 do
    PrepareScope(Scope.Children[Index]);
end;

{ Every variable of an exposed scope lives in its environment. }
procedure CaptureExposed(Scope: TJsScope);
var
  Index: Integer;
begin
  if Scope.EvalExposed then
    for Index := 0 to Scope.VariableCount - 1 do
      if Scope.Variables[Index].Kind <> dkImport then
        Scope.Variables[Index].Captured := True;
  for Index := 0 to Scope.ChildCount - 1 do
    CaptureExposed(Scope.Children[Index]);
end;

procedure ResolveScope(Scope: TJsScope);
var
  Index: Integer;
  Node: TJsNode;
begin
  for Index := 0 to Scope.ReferenceCount - 1 do
  begin
    Node := Scope.References[Index];
    case Node.Kind of
      nkIdentifier: ResolveIdentifier(Node, Scope);
      nkThis: ResolveThis(Node, Scope);
      nkNewTarget: ResolveNewTarget(Node, Scope);
      nkSuperMember: ResolveSuperMember(Node, Scope);
      nkSuperCall: ResolveSuperCall(Node, Scope);
    end;
  end;
  for Index := 0 to Scope.ChildCount - 1 do
    ResolveScope(Scope.Children[Index]);
end;

procedure ResolveProgram(Program_: TJsNode);
begin
  PrepareScope(Program_.Scope);
  ResolveScope(Program_.Scope);
  CaptureExposed(Program_.Scope);
end;

end.
