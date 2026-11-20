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
  What a direct eval sees: the scopes around its call, kept with the
  calling code so the eval's source can be compiled against them at run
  time.

  When a function containing eval(...) is compiled, every scope around
  the call is exposed (Js.Scopes): its variables live in environments.
  TJsEvalChain records, innermost first, each scope's kind, whether it
  has an environment, and its variables with their slots. The eval's
  compiler rebuilds those as scopes of its own (BuildScopes), so the
  eval's identifiers resolve while compiling to environment hops and
  slots counted from the caller's environment at the call - no lookup
  by name when the eval's code runs - and to with objects and the
  function's eval var object where those are in the way.
}
unit Js.EvalScopes;

{$mode objfpc}{$H+}

interface

uses
  Js.Values,
  Js.Ast;

type
  TJsEvalVariable = record
    Name: UnicodeString;
    Kind: TJsDeclarationKind;
    Index: Integer;
    IsGlobal: Boolean;
    Captured: Boolean;
  end;

  TJsEvalLevel = record
    Kind: TJsScopeKind;
    FunctionKind: TJsFunctionKind;
    IsStrict: Boolean;
    EnvironmentSize: Integer;
    EnvironmentProvided: Boolean;
    Variables: array of TJsEvalVariable;
    { Indices in Variables (-1: none). }
    WithVariable: Integer;
    EvalVarsVariable: Integer;
  end;

  TJsEvalChain = class(TJsCell)
  public
    { Innermost first. }
    Levels: array of TJsEvalLevel;
    IsStrict: Boolean;
    function MemorySize: SizeInt; override;
  end;

  { A function compiled when first called: where its parameters start
    in the source, what it is, and the scopes around it. }
  TJsLazyFunction = class(TJsCell)
  public
    Chain: TJsEvalChain;
    Start: Integer;
    Line: Integer;
    Column: Integer;
    FunctionKind: TJsFunctionKind;
    IsAsync: Boolean;
    IsGenerator: Boolean;
    IsStrict: Boolean;
    HasSelfName: Boolean;
    Name: UnicodeString;
    procedure Trace(Tracer: TJsTracer); override;
  end;

{ The chain of scopes from Scope out (the call of a direct eval). }
function BuildEvalChain(Scope: TJsScope; Strict: Boolean): TJsEvalChain;
{ Scopes like the chain's (owned by Arena); the innermost is returned. }
function BuildScopes(Chain: TJsEvalChain; Arena: TJsAstArena): TJsScope;

implementation

procedure TJsLazyFunction.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkCell(Chain);
end;

function TJsEvalChain.MemorySize: SizeInt;
var
  Index: Integer;
begin
  Result := InstanceSize;
  for Index := 0 to High(Levels) do
    Inc(Result, SizeOf(TJsEvalLevel) + Length(Levels[Index].Variables) * (SizeOf(TJsEvalVariable) + 16));
end;

function BuildEvalChain(Scope: TJsScope; Strict: Boolean): TJsEvalChain;
var
  Walk: TJsScope;
  Count, Index: Integer;
  Level: ^TJsEvalLevel;
  Variable: TJsVariable;
begin
  Result := TJsEvalChain.Create;
  Result.IsStrict := Strict;
  Count := 0;
  Walk := Scope;
  while Walk <> nil do
  begin
    Inc(Count);
    Walk := Walk.Parent;
  end;
  SetLength(Result.Levels, Count);
  Walk := Scope;
  Count := 0;
  while Walk <> nil do
  begin
    Level := @Result.Levels[Count];
    Level^.Kind := Walk.Kind;
    Level^.FunctionKind := fkNormal;
    Level^.IsStrict := False;
    if Walk.Func <> nil then
    begin
      Level^.FunctionKind := Walk.Func.Kind;
      Level^.IsStrict := Walk.Func.IsStrict;
    end;
    Level^.EnvironmentSize := Walk.EnvironmentSize;
    Level^.EnvironmentProvided := Walk.EnvironmentProvided;
    Level^.WithVariable := -1;
    Level^.EvalVarsVariable := -1;
    SetLength(Level^.Variables, Walk.VariableCount);
    for Index := 0 to Walk.VariableCount - 1 do
    begin
      Variable := Walk.Variables[Index];
      Level^.Variables[Index].Name := Variable.Name;
      Level^.Variables[Index].Kind := Variable.Kind;
      Level^.Variables[Index].Index := Variable.Index;
      Level^.Variables[Index].IsGlobal := Variable.IsGlobal;
      Level^.Variables[Index].Captured := Variable.Captured;
      if Variable = Walk.WithVariable then
        Level^.WithVariable := Index;
      if (Walk.Func <> nil) and (Variable = Walk.Func.EvalVarsVariable) then
        Level^.EvalVarsVariable := Index;
    end;
    Inc(Count);
    Walk := Walk.Parent;
  end;
end;

function BuildScopes(Chain: TJsEvalChain; Arena: TJsAstArena): TJsScope;
var
  Index, VariableIndex: Integer;
  Level: ^TJsEvalLevel;
  Scope, Outer: TJsScope;
  Info: TJsFunctionInfo;
  Variable: TJsVariable;
begin
  Outer := nil;
  Info := nil;
  Index := High(Chain.Levels);
  while Index >= 0 do
  begin
    Level := @Chain.Levels[Index];
    Scope := TJsScope.Create;
    Arena.Own(Scope);
    Scope.Kind := Level^.Kind;
    Scope.Parent := Outer;
    Scope.EnvironmentSize := Level^.EnvironmentSize;
    Scope.EnvironmentProvided := Level^.EnvironmentProvided;
    if Scope.Kind in [skScript, skFunction, skEval, skModule] then
    begin
      Scope.FunctionScope := Scope;
      Info := TJsFunctionInfo.Create;
      Arena.Own(Info);
      Info.Kind := Level^.FunctionKind;
      Info.IsStrict := Level^.IsStrict;
      Info.Scope := Scope;
    end
    else
      Scope.FunctionScope := Outer.FunctionScope;
    Scope.Func := Info;
    for VariableIndex := 0 to High(Level^.Variables) do
    begin
      Variable := Scope.Declare(Level^.Variables[VariableIndex].Name, Level^.Variables[VariableIndex].Kind, 0);
      Variable.Index := Level^.Variables[VariableIndex].Index;
      Variable.IsGlobal := Level^.Variables[VariableIndex].IsGlobal;
      Variable.Captured := Level^.Variables[VariableIndex].Captured;
      if VariableIndex = Level^.WithVariable then
        Scope.WithVariable := Variable;
      if VariableIndex = Level^.EvalVarsVariable then
        Info.EvalVarsVariable := Variable;
      { What the scope analysis looks for by name. }
      if Variable.Name = '%this' then
        Info.ThisVariable := Variable
      else if Variable.Name = '%newtarget' then
        Info.NewTargetVariable := Variable
      else if Variable.Name = '%home' then
        Info.HomeVariable := Variable
      else if Variable.Name = '%function' then
        Info.FunctionVariable := Variable
      else if (Variable.Name = 'arguments') and (Variable.Kind = dkImplicit) then
        Info.ArgumentsVariable := Variable;
    end;
    Outer := Scope;
    Dec(Index);
  end;
  Result := Outer;
end;

end.
