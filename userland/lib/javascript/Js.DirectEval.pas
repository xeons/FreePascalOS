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
  Direct eval: eval(source) called as eval in a scope.

  The source is parsed inside scopes rebuilt from the call site's
  TJsEvalChain (Js.EvalScopes), resolved and compiled like an arrow
  function's body (this, new.target, super and arguments come from the
  function around it), and run as a closure on the caller's
  environment at the call.

  Declarations (EvalDeclarationInstantiation): let, const and class
  stay in the eval's own scope. In strict code var and function do
  too. In sloppy code they go where the caller's var declarations go: a
  name the function has already is that binding; at a script's top
  level they are properties of the global object; otherwise they are
  properties of the function's eval var object, which the function's
  names look in before the scopes outside it. A var that would cross a
  let of the same name around the call is a SyntaxError.
}
unit Js.DirectEval;

{$mode objfpc}{$H+}

interface

uses
  Js.Interpreter;

procedure InstallDirectEval(R: TJsInterpreterRealm);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Lexer,
  Js.Ast,
  Js.Parser,
  Js.Scopes,
  Js.EvalScopes,
  Js.CodeBuilder,
  Js.Compiler;

{ The scope the caller's var declarations go to. }
function VariableScopeOf(Scope: TJsScope): TJsScope;
begin
  Result := Scope.FunctionScope;
  while (Result.Kind = skEval) and (Result.Parent <> nil) do
    Result := Result.Parent.FunctionScope;
end;

{ Moves the sloppy eval's var and function declarations out of its
  scope; the names that go to the eval var object in Names. }
procedure PlaceVarDeclarations(EvalScope, VariableScope: TJsScope; var Names: TJsNameArray);
var
  Index: Integer;
  Variable, Existing: TJsVariable;
  Walk: TJsScope;
  Pending: array of TJsVariable;
begin
  Pending := nil;
  for Index := 0 to EvalScope.VariableCount - 1 do
    if EvalScope.Variables[Index].Kind in [dkVar, dkFunction] then
    begin
      SetLength(Pending, Length(Pending) + 1);
      Pending[High(Pending)] := EvalScope.Variables[Index];
    end;
  for Index := 0 to High(Pending) do
  begin
    Variable := Pending[Index];
    Walk := EvalScope.Parent;
    while Walk <> nil do
    begin
      Existing := Walk.Find(Variable.Name);
      if (Existing <> nil) and Existing.IsLexical and not Existing.IsGlobal then
        raise EJsSyntaxError.CreateAt('Identifier ''' + string(Variable.Name) + ''' has already been declared', 1, 1);
      if Walk = VariableScope then
        Break;
      Walk := Walk.Parent;
    end;
    if VariableScope.Kind = skScript then
    begin
      { A script's var: a global by name. }
      Variable.IsGlobal := True;
      Continue;
    end;
    if (VariableScope.Func = nil) or (VariableScope.Func.EvalVarsVariable = nil) then
      Continue;
    Existing := VariableScope.Find(Variable.Name);
    if Existing = nil then
    begin
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := Variable.Name;
    end;
    EvalScope.RemoveVariable(Variable);
  end;
end;

function CompileDirectEval(R: TJsRealm; const Source: UnicodeString; Chain: TJsEvalChain; Caller: TJsCode): TJsCode;
var
  Arena: TJsAstArena;
  Parser: TJsParser;
  Program_: TJsNode;
  Outer, VariableScope: TJsScope;
  Names: TJsNameArray;
  Context: TJsCompileContext;
  Compiler: TJsFunctionCompiler;
  FileName: string;
begin
  Arena := TJsAstArena.Create;
  Parser := nil;
  Context := nil;
  try
    Outer := BuildScopes(Chain, Arena);
    Parser := TJsParser.Create(Source, Arena);
    Program_ := Parser.ParseEval(Chain.IsStrict, Outer);
    { this and the others from around it, as in an arrow. }
    Program_.Func.Kind := fkArrow;
    Names := nil;
    VariableScope := VariableScopeOf(Outer);
    if not Program_.Func.IsStrict then
      PlaceVarDeclarations(Program_.Scope, VariableScope, Names);
    ResolveProgram(Program_);
    FileName := '';
    if Caller.Source <> nil then
      FileName := Caller.Source.FileName;
    Context := TJsCompileContext.Create;
    Context.Realm := R;
    Context.FileName := FileName;
    Context.Module := Caller.Module;
    Context.Source := TJsSource.Create;
    R.Heap.Register(Context.Source, ckOther);
    Context.Source.FileName := FileName;
    Context.Source.Text := Source;
    R.Heap.Account(Length(Source) * 2);
    Compiler := TJsFunctionCompiler.Create(Context, Program_.Func, nil);
    try
      Result := Compiler.CompileEvalBody(Program_, Names, VariableScope);
    finally
      Compiler.Free;
    end;
  finally
    Context.Free;
    Parser.Free;
    Arena.Free;
  end;
end;

function DirectEval(R: TJsRealm; Source: TJsValue; Chain: TJsCell; Caller: TJsCode; Environment: TJsEnvironment;
  This: TJsValue): TJsValue;
var
  Code: TJsCode;
  Closure: TJsClosure;
  Mark: Integer;
begin
  try
    Code := CompileDirectEval(R, StringToUnicode(R.Heap, JsAsString(Source)), TJsEvalChain(Chain), Caller);
  except
    on Error: EJsSyntaxError do
      Exit(R.ThrowError(ekSyntax, Error.Message));
  end;
  Mark := R.Runtime.PushRoot(JsCellValue(JsObjectBase, Code));
  try
    Closure := TJsInterpreterRealm(R).NewClosure(Code, Environment);
    R.Runtime.SetRoot(Mark, JsObjectValue(Closure));
    Result := R.Call(JsObjectValue(Closure), This, nil, 0);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

procedure InstallDirectEval(R: TJsInterpreterRealm);
begin
  JsDirectEvalHook := @DirectEval;
end;

end.
