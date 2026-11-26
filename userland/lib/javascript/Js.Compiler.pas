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
  The compiler's top layer: functions, classes and whole programs.

  A function's prologue: its parameters arrive in registers 0..n-1
  (the rest array and the arguments object, when used, are made by the
  interpreter before anything else); captured parameters are copied to
  the function's environment, the implicit variables (this, new.target,
  the home object, the function itself) filled in, parameters with
  defaults or patterns bound, the function declarations made; a class
  constructor runs its field initializer; a generator suspends.

  A class: its scope (inner name, private names), the heritage, the
  constructor (written or default), MakeClass (constructor and
  prototype), the methods and accessors, the field initializers - one
  function for the instance fields, called by the constructor, one for
  the static fields and blocks, called once - with computed keys and
  private methods made now and kept in the initializer's class slots.

  A script's own declarations are globals: var and function become
  properties of the global object, let, const and class bindings of the
  global lexical environment, both found by name.

  CompileScript is the entry: source to code, raising EJsSyntaxError.
}
unit Js.Compiler;

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
  Js.Lexer,
  Js.Ast,
  Js.Parser,
  Js.Scopes,
  Js.Bytecode,
  Js.CodeBuilder,
  Js.ExpressionCompiler,
  Js.StatementCompiler,
  Js.EvalScopes,
  Js.ModuleRecords;

type
  TJsFunctionCompiler = class(TJsStatementCompiler)
  protected
    FParent: TJsFunctionCompiler;
    { A sloppy function with simple parameters using arguments. }
    FMappedArguments: Boolean;
    procedure EmitReturnValue(Value: Integer); override;
    procedure CompilePrologue;
    procedure CompileFieldInitializerBody;
    function PrivateNameVariable(ClassNode: TJsNode; const Name: UnicodeString): TJsVariable;
    procedure SetCodeFlags(const Name: UnicodeString);
    function LazyStub(Info: TJsFunctionInfo; const Name: UnicodeString): TJsCode;
    procedure SetParameterSlots(FormalCount: Integer);
  public
    constructor Create(Context: TJsCompileContext; Info: TJsFunctionInfo; Parent: TJsFunctionCompiler);
    function CompileFunction(const Name: UnicodeString): TJsCode;
    function CompileScriptBody(Program_: TJsNode): TJsCode;
    function CompileModuleBody(Program_: TJsNode): TJsCode;
    { A direct eval's code: EvalVarNames go to the eval var object of
      VariableScope's function. }
    function CompileEvalBody(Program_: TJsNode; const EvalVarNames: TJsNameArray; VariableScope: TJsScope): TJsCode;
    function CompileModuleInitializer(Program_: TJsNode): TJsCode;
    function CompileFunctionNode(Node: TJsNode; Target: Integer; const Name: UnicodeString;
      HasName: Boolean): Integer; override;
    function CompileClass(Node: TJsNode; Target: Integer; const Name: UnicodeString): Integer; override;
    function IsCurrentFunction(Scope: TJsScope): Boolean; override;
  end;

{ Compiles a script (or the code of an indirect eval: global). }
function CompileScript(Realm: TJsRealm; const Source: UnicodeString; const FileName: string;
  Strict: Boolean = False): TJsCode;
{ Compiles a module's source into Module (its codes, requests, imports,
  exports and environment); raises EJsSyntaxError. }
procedure CompileModule(Realm: TJsRealm; const Source: UnicodeString; const FileName: string; Module: TJsModule);
{ Compiles a lazy function's code in place (its first call); raises
  EJsSyntaxError. }
procedure CompileLazyFunction(Realm: TJsRealm; Code: TJsCode);
{ The code of a function made by the Function constructor. }
function CompileFunctionSource(Realm: TJsRealm; const Parameters, Body: UnicodeString; IsAsync,
  IsGenerator: Boolean): TJsCode;

implementation

function BuildDefaultConstructor(Context: TJsCompileContext; Derived: Boolean; const Name: UnicodeString): TJsCode;
var
  Info: TJsFunctionInfo;
  Builder: TJsFunctionCompiler;
  Callee, NewTarget, Result_: Integer;
begin
  Info := TJsFunctionInfo.Create;
  Builder := TJsFunctionCompiler.Create(Context, Info, nil);
  try
    Info.IsStrict := True;
    if Derived then
    begin
      Info.Kind := fkDerivedConstructor;
      Builder.FCode.RestRegister := Builder.AllocateLocal;
      Callee := Builder.AllocateLocal;
      NewTarget := Builder.AllocateLocal;
      Result_ := Builder.AllocateLocal;
      Builder.Emit(opLoadCallee, Callee);
      Builder.Emit(opLoadNewTarget, NewTarget);
      Builder.Emit(opSuperCallSpread, Result_, Callee, NewTarget, Builder.FCode.RestRegister);
      Builder.Emit(opRunClassFields, Result_, Callee);
      Builder.Emit(opReturn, Result_);
      Builder.FCode.Flags := CodeStrict or CodeClassConstructor or CodeConstructor or CodeDerivedConstructor or
        CodeHasRest;
    end
    else
    begin
      Info.Kind := fkClassConstructor;
      Builder.Emit(opRunClassFields, -1, -2);
      Builder.Emit(opReturnUndefined);
      Builder.FCode.Flags := CodeStrict or CodeClassConstructor or CodeConstructor;
    end;
    Builder.FCode.Name := Context.Realm.Runtime.Atoms.Intern(NewStringFromUnicode(Context.Realm.Heap, Name));
    Result := Builder.FinishCode;
  finally
    Builder.Free;
    Info.Free;
  end;
end;

{ TJsFunctionCompiler }

constructor TJsFunctionCompiler.Create(Context: TJsCompileContext; Info: TJsFunctionInfo; Parent: TJsFunctionCompiler);
begin
  inherited Create(Context, Info);
  FParent := Parent;
  FCompletionRegister := -1;
  if Info <> nil then
    FStrict := Info.IsStrict;
end;

function TJsFunctionCompiler.IsCurrentFunction(Scope: TJsScope): Boolean;
begin
  Result := (FInfo <> nil) and (Scope = FInfo.Scope);
end;

const
  { Functions with less source than this are compiled at once. }
  LazySourceLength = 160;

function FunctionCodeFlags(Info: TJsFunctionInfo): LongWord;
begin
  Result := 0;
  if Info.IsStrict then
    Result := Result or CodeStrict;
  if Info.IsGenerator then
    Result := Result or CodeGenerator;
  if Info.IsAsync then
    Result := Result or CodeAsync;
  case Info.Kind of
    fkArrow: Result := Result or CodeArrow;
    fkNormal:
      if not Info.IsAsync and not Info.IsGenerator then
        Result := Result or CodeConstructor;
    fkMethod, fkClassFieldInitializer: Result := Result or CodeMethod;
    fkGetter: Result := Result or CodeMethod or CodeGetter;
    fkSetter: Result := Result or CodeMethod or CodeSetter;
    fkClassConstructor: Result := Result or CodeClassConstructor or CodeConstructor;
    fkDerivedConstructor: Result := Result or CodeClassConstructor or CodeConstructor or CodeDerivedConstructor;
    fkScript, fkModule: Result := Result or CodeScript;
  end;
end;

function FunctionFullName(Info: TJsFunctionInfo; const Name: UnicodeString): UnicodeString;
begin
  Result := Name;
  if Info.Kind = fkGetter then
    Result := 'get ' + Name
  else if Info.Kind = fkSetter then
    Result := 'set ' + Name;
end;

{ A function compiled on its first call: its body was parsed (early
  errors checked, its free variables marked captured), but it gets no
  bytecode until then. Not for class constructors and field
  initializers, functions using private names, or short ones. }
function IsLazyCandidate(Info: TJsFunctionInfo): Boolean;
begin
  Result := (Info.Kind in [fkNormal, fkArrow, fkMethod, fkGetter, fkSetter]) and not Info.UsesPrivateNames and
    (Info.SourceFinish - Info.SourceStart >= LazySourceLength) and
    ((Info.Kind = fkArrow) or (Info.ParametersLine > 0));
end;

function TJsFunctionCompiler.LazyStub(Info: TJsFunctionInfo; const Name: UnicodeString): TJsCode;
var
  Lazy: TJsLazyFunction;
begin
  Result := TJsCode.Create;
  Heap.Register(Result, ckCode);
  Result.Source := FContext.Source;
  Result.Module := FContext.Module;
  Result.ArgumentsRegister := -1;
  Result.RestRegister := -1;
  Result.Flags := FunctionCodeFlags(Info) or CodeLazy;
  Result.Name := Runtime.Atoms.Intern(NewStringFromUnicode(Heap, FunctionFullName(Info, Name)));
  Result.Length := Info.Length;
  Result.SourceStart := Info.SourceStart;
  Result.SourceFinish := Info.SourceFinish;
  Lazy := TJsLazyFunction.Create;
  Heap.Register(Lazy, ckOther);
  Lazy.Chain := FContext.ChainFor(Info.Scope.Parent);
  if Info.Kind = fkArrow then
  begin
    Lazy.Start := Info.SourceStart;
    Lazy.Line := Info.Line;
    Lazy.Column := Info.Column;
  end
  else
  begin
    Lazy.Start := Info.ParametersStart;
    Lazy.Line := Info.ParametersLine;
    Lazy.Column := Info.ParametersColumn;
  end;
  Lazy.FunctionKind := Info.Kind;
  Lazy.IsAsync := Info.IsAsync;
  Lazy.IsGenerator := Info.IsGenerator;
  Lazy.IsStrict := Info.IsStrict;
  Lazy.HasSelfName := Info.SelfVariable <> nil;
  Lazy.Name := Name;
  Result.Lazy := Lazy;
end;

function TJsFunctionCompiler.CompileFunctionNode(Node: TJsNode; Target: Integer; const Name: UnicodeString;
  HasName: Boolean): Integer;
var
  Child: TJsFunctionCompiler;
  NewCode: TJsCode;
  FunctionName: UnicodeString;
begin
  FunctionName := Node.Func.Name;
  if (FunctionName = '') and HasName then
    FunctionName := Name;
  if IsLazyCandidate(Node.Func) then
    NewCode := LazyStub(Node.Func, FunctionName)
  else
  begin
    Child := TJsFunctionCompiler.Create(FContext, Node.Func, Self);
    try
      NewCode := Child.CompileFunction(FunctionName);
    finally
      Child.Free;
    end;
  end;
  if Target < 0 then
    Target := AllocateRegister;
  Emit(opClosure, Target, AddFunction(NewCode));
  Result := Target;
end;

procedure TJsFunctionCompiler.EmitReturnValue(Value: Integer);
var
  Skip: Integer;
  This: TJsVariable;
begin
  if (FInfo <> nil) and (FInfo.Kind = fkDerivedConstructor) then
  begin
    { undefined gives this, which must be initialised by then. }
    Skip := EmitJumpIf(opJumpIfNotUndefined, Value);
    This := FInfo.ThisVariable;
    if This.Captured then
      Emit(opGetEnvironmentChecked, Value, EnvironmentHops(This.Scope), This.Index, AtomConstant('this'))
    else
    begin
      Emit(opMove, Value, This.Index);
      Emit(opCheckInitialized, Value, AtomConstant('this'));
    end;
    PatchHere(Skip);
  end;
  Emit(opReturn, Value);
end;

procedure TJsFunctionCompiler.SetCodeFlags(const Name: UnicodeString);
var
  Flags: LongWord;
  FullName: UnicodeString;
begin
  Flags := FunctionCodeFlags(FInfo);
  if FCode.RestRegister >= 0 then
    Flags := Flags or CodeHasRest;
  if FCode.ArgumentsRegister >= 0 then
    Flags := Flags or CodeNeedsArguments;
  if FMappedArguments then
    Flags := Flags or CodeMappedArguments;
  FCode.Flags := Flags;
  FullName := FunctionFullName(FInfo, Name);
  FCode.Name := Runtime.Atoms.Intern(NewStringFromUnicode(Heap, FullName));
  FCode.Length := FInfo.Length;
  FCode.SourceStart := FInfo.SourceStart;
  FCode.SourceFinish := FInfo.SourceFinish;
end;

procedure TJsFunctionCompiler.CompilePrologue;
var
  Index, Mark, Value: Integer;
  Parameter: TJsNode;
  Variable: TJsVariable;
begin
  Mark := FNextRegister;
  EnterScope(FInfo.Scope);
  { Captured simple parameters into the environment. }
  for Index := 0 to FCode.ParameterCount - 1 do
  begin
    Parameter := FInfo.Parameters[Index];
    if (Parameter.Kind = nkIdentifier) and (Parameter.Variable <> nil) and Parameter.Variable.Captured then
      StoreVariable(Parameter.Variable, Parameter.Text, Index, True);
  end;
  if FMappedArguments then
    Emit(opMapArguments, FCode.ArgumentsRegister);
  if FCode.RestRegister >= 0 then
  begin
    Parameter := FInfo.Parameters[FInfo.ParameterCount - 1].A;
    if (Parameter.Kind = nkIdentifier) and Parameter.Variable.Captured then
      StoreVariable(Parameter.Variable, Parameter.Text, FCode.RestRegister, True);
  end;
  Value := AllocateRegister;
  Variable := FInfo.ThisVariable;
  if Variable <> nil then
  begin
    if FInfo.Kind = fkDerivedConstructor then
    begin
      Emit(opLoadHole, Value);
      StoreVariable(Variable, '%this', Value, True);
    end
    else
      StoreVariable(Variable, '%this', -1, True);
  end;
  Variable := FInfo.ArgumentsVariable;
  if (Variable <> nil) and Variable.Captured then
    StoreVariable(Variable, 'arguments', FCode.ArgumentsRegister, True);
  if FInfo.FunctionVariable <> nil then
  begin
    Emit(opLoadCallee, Value);
    StoreVariable(FInfo.FunctionVariable, '%function', Value, True);
  end;
  if FInfo.NewTargetVariable <> nil then
  begin
    Emit(opLoadNewTarget, Value);
    StoreVariable(FInfo.NewTargetVariable, '%newtarget', Value, True);
  end;
  if FInfo.HomeVariable <> nil then
  begin
    Emit(opLoadHome, Value);
    StoreVariable(FInfo.HomeVariable, '%home', Value, True);
  end;
  if FInfo.SelfVariable <> nil then
  begin
    Emit(opLoadCallee, Value);
    StoreVariable(FInfo.SelfVariable, FInfo.SelfVariable.Name, Value, True);
  end;
  ReleaseTo(Mark);
  { Parameters with defaults or patterns. }
  for Index := 0 to FInfo.ParameterCount - 1 do
  begin
    Parameter := FInfo.Parameters[Index];
    case Parameter.Kind of
      nkIdentifier: ;
      nkRest:
        if Parameter.A.Kind <> nkIdentifier then
          BindPattern(Parameter.A, FCode.RestRegister, bmInitialize);
    else
      BindPattern(Parameter, Index, bmInitialize);
    end;
    ReleaseTo(Mark);
  end;
  HoistFunctions(FInfo.Body, FInfo.BodyCount);
  if FInfo.Kind = fkClassConstructor then
    Emit(opRunClassFields, -1, -2);
  if FInfo.IsGenerator then
    Emit(opInitialYield);
end;

function TJsFunctionCompiler.CompileFunction(const Name: UnicodeString): TJsCode;
var
  Index, FormalCount, Value: Integer;
  Parameter: TJsNode;
  Variable: TJsVariable;
begin
  FScope := FInfo.Scope;
  FormalCount := FInfo.ParameterCount;
  if (FormalCount > 0) and (FInfo.Parameters[FormalCount - 1].Kind = nkRest) then
    Dec(FormalCount);
  FCode.ParameterCount := FormalCount;
  { arguments[i] aliases the i-th parameter: the parameters live in the
    environment the arguments object reads. }
  FMappedArguments := not FInfo.IsStrict and FInfo.HasSimpleParameters and (FInfo.ArgumentsVariable <> nil) and
    (FormalCount > 0);
  if FMappedArguments then
    for Index := 0 to FormalCount - 1 do
      if (FInfo.Parameters[Index].Kind = nkIdentifier) and (FInfo.Parameters[Index].Variable <> nil) then
        FInfo.Parameters[Index].Variable.Captured := True;
  FLocalCount := FormalCount;
  FNextRegister := FormalCount;
  FMaxRegister := FormalCount;
  for Index := 0 to FormalCount - 1 do
  begin
    Parameter := FInfo.Parameters[Index];
    if (Parameter.Kind = nkIdentifier) and (Parameter.Variable <> nil) and not Parameter.Variable.Captured then
      Parameter.Variable.Index := Index;
  end;
  if FormalCount < FInfo.ParameterCount then
  begin
    FCode.RestRegister := AllocateLocal;
    Parameter := FInfo.Parameters[FormalCount].A;
    if (Parameter.Kind = nkIdentifier) and not Parameter.Variable.Captured then
      Parameter.Variable.Index := FCode.RestRegister;
  end;
  Variable := FInfo.ArgumentsVariable;
  if Variable <> nil then
  begin
    FCode.ArgumentsRegister := AllocateLocal;
    if not Variable.Captured then
      Variable.Index := FCode.ArgumentsRegister;
  end;
  LayoutScope(FInfo.Scope, True);
  if FMappedArguments then
    SetParameterSlots(FormalCount);
  CompilePrologue;
  if FInfo.Kind = fkClassFieldInitializer then
  begin
    CompileFieldInitializerBody;
    Emit(opReturnUndefined);
  end
  else if FInfo.ExpressionBody <> nil then
  begin
    Value := AllocateRegister;
    ExpressionInto(FInfo.ExpressionBody, Value);
    EmitReturnValue(Value);
  end
  else
  begin
    CompileStatements(FInfo.Body, FInfo.BodyCount);
    if FInfo.Kind = fkDerivedConstructor then
    begin
      Value := AllocateRegister;
      Emit(opLoadUndefined, Value);
      EmitReturnValue(Value);
    end
    else
      Emit(opReturnUndefined);
  end;
  SetCodeFlags(Name);
  Result := FinishCode;
end;

{ The environment slot of each parameter; of parameters with one name
  only the last maps. }
procedure TJsFunctionCompiler.SetParameterSlots(FormalCount: Integer);
var
  Index, Later: Integer;
  Parameter: TJsNode;
  Shadowed: Boolean;
begin
  SetLength(FCode.ParameterSlots, FormalCount);
  for Index := 0 to FormalCount - 1 do
  begin
    Parameter := FInfo.Parameters[Index];
    FCode.ParameterSlots[Index] := -1;
    if (Parameter.Kind <> nkIdentifier) or (Parameter.Variable = nil) then
      Continue;
    Shadowed := False;
    for Later := Index + 1 to FormalCount - 1 do
      if (FInfo.Parameters[Later].Kind = nkIdentifier) and (FInfo.Parameters[Later].Text = Parameter.Text) then
        Shadowed := True;
    if not Shadowed then
      FCode.ParameterSlots[Index] := Parameter.Variable.Index;
  end;
end;

function TJsFunctionCompiler.PrivateNameVariable(ClassNode: TJsNode; const Name: UnicodeString): TJsVariable;
begin
  Result := ClassNode.Scope.Find(Name);
end;

procedure TJsFunctionCompiler.CompileFieldInitializerBody;
var
  ClassNode, Member: TJsNode;
  IsStatic, MemberStatic: Boolean;
  Index, Mark, Value, Key, Name_, Slot: Integer;
  Variable: TJsVariable;
  Name: UnicodeString;
  Flags: Word;
begin
  ClassNode := FInfo.ClassNode;
  IsStatic := (ClassNode.D <> nil) and (ClassNode.D.Func = FInfo);
  Mark := FNextRegister;
  { Private methods and accessors first (instances). }
  if not IsStatic then
    for Index := 0 to ClassNode.Count - 1 do
    begin
      Member := ClassNode.List[Index];
      Flags := Member.Flags;
      if ((Flags and PropertyFlagPrivate) = 0) or ((Flags and PropertyFlagStatic) <> 0) or
        ((Flags and PropertyFlagField) <> 0) then
        Continue;
      Variable := PrivateNameVariable(ClassNode, Member.A.Text);
      Name_ := LoadVariable(Variable, Member.A.Text, -1, nil);
      Value := AllocateRegister;
      Emit(opGetClassSlot, Value, Trunc(Member.Number));
      if (Flags and PropertyFlagGetter) <> 0 then
        Emit(opDefinePrivateAccessor, -1, Name_, Value, -1)
      else if (Flags and PropertyFlagSetter) <> 0 then
        Emit(opDefinePrivateAccessor, -1, Name_, -1, Value)
      else
        Emit(opDefinePrivate, -1, Name_, Value);
      ReleaseTo(Mark);
    end;
  for Index := 0 to ClassNode.Count - 1 do
  begin
    Member := ClassNode.List[Index];
    Flags := Member.Flags;
    MemberStatic := (Flags and PropertyFlagStatic) <> 0;
    if MemberStatic <> IsStatic then
      Continue;
    if (Flags and PropertyFlagStaticBlock) <> 0 then
    begin
      CompileBlock(Member.B);
      ReleaseTo(Mark);
      Continue;
    end;
    if (Flags and PropertyFlagField) = 0 then
      Continue;
    NoteLine(Member);
    Name := '';
    if (Flags and PropertyFlagPrivate) <> 0 then
      Name := Member.A.Text
    else if ((Flags and PropertyFlagComputed) = 0) and not KeyIsName(Member.A, Name) then
      Name := '';
    if Member.B <> nil then
      Value := NamedExpression(Member.B, -1, Name)
    else
    begin
      Value := AllocateRegister;
      Emit(opLoadUndefined, Value);
    end;
    if (Flags and PropertyFlagPrivate) <> 0 then
    begin
      Variable := PrivateNameVariable(ClassNode, Member.A.Text);
      Emit(opDefinePrivate, -1, LoadVariable(Variable, Member.A.Text, -1, nil), Value);
    end
    else if (Flags and PropertyFlagComputed) <> 0 then
    begin
      Key := AllocateRegister;
      Slot := Trunc(Member.Number);
      Emit(opGetClassSlot, Key, Slot);
      if (Member.B <> nil) and IsAnonymousDefinition(Member.B) then
        Emit(opSetFunctionName, Value, Key, 0);
      Emit(opDefineIndex, -1, Key, Value);
    end
    else if KeyIsName(Member.A, Name) then
      Emit(opDefineField, -1, AtomConstant(Name), Value, NewCache)
    else
      Emit(opDefineIndex, -1, CompileKey(Member.A, False, -1), Value);
    ReleaseTo(Mark);
  end;
end;

function TJsFunctionCompiler.CompileClass(Node: TJsNode; Target: Integer; const Name: UnicodeString): Integer;
var
  Mark, MemberMark, Index, Heritage, Constructor_, Pair, Prototype, InstanceInit, StaticInit: Integer;
  Value, Key, TargetObject, Name_, Base, InstanceSlots, StaticSlots, Slot: Integer;
  TheClassName, MemberName: UnicodeString;
  Member, ConstructorMember: TJsNode;
  Variable: TJsVariable;
  Flags: Word;
  IsStatic, Computed: Boolean;
  Scope: TJsScope;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  TheClassName := Node.Text;
  if TheClassName = '' then
    TheClassName := Name;
  Scope := Node.Scope;
  NoteLine(Node);
  EnterScope(Scope);
  { Private names: one new private symbol each. }
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if (Length(Variable.Name) > 0) and (Variable.Name[1] = '#') then
    begin
      Value := AllocateRegister;
      Emit(opNewPrivateName, Value, StringConstant(Variable.Name));
      StoreVariable(Variable, Variable.Name, Value, True);
      ReleaseTo(Mark);
    end;
  end;
  Heritage := -1;
  if Node.A <> nil then
  begin
    Heritage := AllocateRegister;
    ExpressionInto(Node.A, Heritage);
  end;
  ConstructorMember := nil;
  for Index := 0 to Node.Count - 1 do
    if (Node.List[Index].Flags and PropertyFlagProto) <> 0 then
      ConstructorMember := Node.List[Index];
  Constructor_ := AllocateRegister;
  if ConstructorMember <> nil then
    CompileFunctionNode(ConstructorMember.B, Constructor_, TheClassName, True)
  else
    Emit(opClosure, Constructor_, AddFunction(BuildDefaultConstructor(FContext, Node.A <> nil, TheClassName)));
  Pair := AllocateRegisters(2);
  Prototype := Pair + 1;
  Emit(opMakeClass, Pair, Constructor_, Heritage);
  { The class slots, numbered before the initializers are compiled (they
    read them): the computed field keys, and the instance private
    methods and accessors the instance initializer installs. }
  InstanceSlots := 0;
  StaticSlots := 0;
  for Index := 0 to Node.Count - 1 do
  begin
    Member := Node.List[Index];
    Flags := Member.Flags;
    if ((Flags and PropertyFlagStaticBlock) <> 0) or (Member = ConstructorMember) then
      Continue;
    if (Flags and PropertyFlagField) <> 0 then
    begin
      if (Flags and PropertyFlagComputed) = 0 then
        Continue;
    end
    else if ((Flags and PropertyFlagPrivate) = 0) or ((Flags and PropertyFlagStatic) <> 0) then
      Continue;
    if (Flags and PropertyFlagStatic) <> 0 then
    begin
      Member.Number := StaticSlots;
      Inc(StaticSlots);
    end
    else
    begin
      Member.Number := InstanceSlots;
      Inc(InstanceSlots);
    end;
  end;
  InstanceInit := -1;
  StaticInit := -1;
  if Node.C <> nil then
  begin
    InstanceInit := AllocateRegister;
    CompileFunctionNode(Node.C, InstanceInit, '<instance_members_initializer>', True);
    Emit(opSetHome, InstanceInit, Prototype);
    Emit(opSetClassFields, Pair, InstanceInit);
  end;
  if Node.D <> nil then
  begin
    StaticInit := AllocateRegister;
    CompileFunctionNode(Node.D, StaticInit, '<static_initializer>', True);
    Emit(opSetHome, StaticInit, Pair);
  end;
  for Index := 0 to Node.Count - 1 do
  begin
    Member := Node.List[Index];
    Flags := Member.Flags;
    if ((Flags and PropertyFlagStaticBlock) <> 0) or (Member = ConstructorMember) then
      Continue;
    MemberMark := FNextRegister;
    IsStatic := (Flags and PropertyFlagStatic) <> 0;
    Computed := (Flags and PropertyFlagComputed) <> 0;
    if IsStatic then
      TargetObject := Pair
    else
      TargetObject := Prototype;
    if (Flags and PropertyFlagField) <> 0 then
    begin
      if Computed then
      begin
        Key := CompileKey(Member.A, True, -1);
        Slot := Trunc(Member.Number);
        if IsStatic then
          Emit(opSetClassSlot, StaticInit, Slot, Key)
        else
          Emit(opSetClassSlot, InstanceInit, Slot, Key);
      end;
      ReleaseTo(MemberMark);
      Continue;
    end;
    if (Flags and PropertyFlagPrivate) <> 0 then
    begin
      Value := CompileFunctionNode(Member.B, -1, Member.A.Text, True);
      Emit(opSetHome, Value, TargetObject);
      if IsStatic then
      begin
        Name_ := LoadVariable(PrivateNameVariable(Node, Member.A.Text), Member.A.Text, -1, nil);
        if (Flags and PropertyFlagGetter) <> 0 then
          Emit(opDefinePrivateAccessor, Pair, Name_, Value, -1)
        else if (Flags and PropertyFlagSetter) <> 0 then
          Emit(opDefinePrivateAccessor, Pair, Name_, -1, Value)
        else
          Emit(opDefinePrivate, Pair, Name_, Value);
      end
      else
      begin
        Emit(opSetClassSlot, InstanceInit, Trunc(Member.Number), Value);
      end;
      ReleaseTo(MemberMark);
      Continue;
    end;
    Key := CompileKey(Member.A, Computed, -1);
    MemberName := '';
    if not Computed then
      KeyIsName(Member.A, MemberName);
    if (not Computed) and (Member.A.Kind = nkNumber) then
      MemberName := UnicodeString(FloatToStr(Member.A.Number));
    Value := CompileFunctionNode(Member.B, -1, MemberName, not Computed);
    Emit(opSetHome, Value, TargetObject);
    if Computed then
      Emit(opSetFunctionName, Value, Key, Ord((Flags and PropertyFlagGetter) <> 0) +
        2 * Ord((Flags and PropertyFlagSetter) <> 0));
    if (Flags and PropertyFlagGetter) <> 0 then
      Emit(opDefineGetter, TargetObject, Key, Value, 0)
    else if (Flags and PropertyFlagSetter) <> 0 then
      Emit(opDefineSetter, TargetObject, Key, Value, 0)
    else
      Emit(opDefineMethod, TargetObject, Key, Value, 0);
    ReleaseTo(MemberMark);
  end;
  { The inner name binding. }
  for Index := 0 to Scope.VariableCount - 1 do
    if Scope.Variables[Index].Kind = dkClassInner then
      StoreVariable(Scope.Variables[Index], TheClassName, Pair, True);
  if StaticInit >= 0 then
  begin
    Base := AllocateRegisters(2);
    Emit(opMove, Base, StaticInit);
    Emit(opMove, Base + 1, Pair);
    Emit(opCall, Base, Base, 0);
  end;
  LeaveScope(Scope);
  Emit(opMove, Target, Pair);
  ReleaseTo(Mark);
end;

function TJsFunctionCompiler.CompileScriptBody(Program_: TJsNode): TJsCode;
var
  Index, Value: Integer;
  Scope: TJsScope;
  Variable: TJsVariable;
begin
  Scope := Program_.Scope;
  FScope := Scope;
  FCompletionRegister := AllocateLocal;
  LayoutScope(Scope, True);
  EnterScope(Scope);
  Emit(opLoadUndefined, FCompletionRegister);
  if FInfo.ThisVariable <> nil then
    StoreVariable(FInfo.ThisVariable, '%this', -1, True);
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if not Variable.IsGlobal then
      Continue;
    case Variable.Kind of
      dkVar:
        Emit(opDeclareGlobalVar, AtomConstant(Variable.Name), -1);
      dkLet, dkClass:
        Emit(opDeclareGlobalLexical, AtomConstant(Variable.Name), 0);
      dkConst:
        Emit(opDeclareGlobalLexical, AtomConstant(Variable.Name), 1);
    end;
  end;
  HoistFunctions(Program_.List, Program_.Count);
  CompileStatements(Program_.List, Program_.Count);
  Value := FCompletionRegister;
  Emit(opReturn, Value);
  SetCodeFlags('');
  Result := FinishCode;
end;

{ A module's top level: its declarations live in the module's
  environment (made before the code runs), its function declarations
  are made by the initializer when the module is linked. }
function TJsFunctionCompiler.CompileModuleBody(Program_: TJsNode): TJsCode;
var
  Scope: TJsScope;
begin
  Scope := Program_.Scope;
  FScope := Scope;
  LayoutScope(Scope, True);
  EnterScope(Scope);
  if FInfo.ThisVariable <> nil then
    StoreVariable(FInfo.ThisVariable, '%this', -1, True);
  CompileStatements(Program_.List, Program_.Count);
  Emit(opReturnUndefined);
  SetCodeFlags('');
  Result := FinishCode;
end;

function TJsFunctionCompiler.CompileEvalBody(Program_: TJsNode; const EvalVarNames: TJsNameArray;
  VariableScope: TJsScope): TJsCode;
var
  Scope: TJsScope;
  Index, Mark, Value: Integer;
  Node: TJsNode;
  Variable, Holder: TJsVariable;

  function GoesToEvalVars(const Name: UnicodeString): Boolean;
  var
    Position: Integer;
  begin
    for Position := 0 to High(EvalVarNames) do
      if EvalVarNames[Position] = Name then
        Exit(True);
    Result := False;
  end;

begin
  Scope := Program_.Scope;
  FScope := Scope;
  FCompletionRegister := AllocateLocal;
  LayoutScope(Scope, True);
  EnterScope(Scope);
  Emit(opLoadUndefined, FCompletionRegister);
  Holder := nil;
  if VariableScope.Func <> nil then
    Holder := VariableScope.Func.EvalVarsVariable;
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if Variable.IsGlobal and (Variable.Kind = dkVar) then
      Emit(opDeclareGlobalVar, AtomConstant(Variable.Name), -1);
  end;
  if Holder <> nil then
    for Index := 0 to High(EvalVarNames) do
      Emit(opDeclareEvalVar, EnvironmentHops(Holder.Scope), Holder.Index, AtomConstant(EvalVarNames[Index]), -1);
  { The functions, made before the code runs. }
  for Index := 0 to Program_.Count - 1 do
  begin
    Node := Program_.List[Index];
    while (Node.Kind = nkLabeled) and (Node.A <> nil) do
      Node := Node.A;
    if Node.Kind <> nkFunctionDeclaration then
      Continue;
    Mark := FNextRegister;
    Value := CompileFunctionNode(Node, -1, Node.Func.Name, True);
    if (Holder <> nil) and GoesToEvalVars(Node.A.Text) then
      Emit(opDeclareEvalVar, EnvironmentHops(Holder.Scope), Holder.Index, AtomConstant(Node.A.Text), Value)
    else if (Node.A.Variable <> nil) and Node.A.Variable.IsGlobal then
      Emit(opDeclareGlobalVar, AtomConstant(Node.A.Text), Value)
    else
      StoreVariable(Node.A.Variable, Node.A.Text, Value, True, Node.A);
    ReleaseTo(Mark);
  end;
  CompileStatements(Program_.List, Program_.Count);
  Emit(opReturn, FCompletionRegister);
  SetCodeFlags('eval');
  Result := FinishCode;
end;

{ After CompileModuleBody (which laid the scope out). }
function TJsFunctionCompiler.CompileModuleInitializer(Program_: TJsNode): TJsCode;
begin
  FScope := Program_.Scope;
  EnterScope(Program_.Scope);
  HoistFunctions(Program_.List, Program_.Count);
  Emit(opReturnUndefined);
  SetCodeFlags('');
  FCode.Flags := CodeStrict or CodeScript;
  Result := FinishCode;
end;

procedure MarkGlobals(Scope: TJsScope);
var
  Index: Integer;
  Variable: TJsVariable;
begin
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if Variable.Kind in [dkVar, dkFunction, dkLet, dkConst, dkClass] then
    begin
      Variable.IsGlobal := True;
      Variable.Captured := False;
      Variable.Index := -2;
    end;
  end;
end;

function CompileProgramNode(Realm: TJsRealm; Program_: TJsNode; const Source: UnicodeString;
  const FileName: string): TJsCode;
var
  Context: TJsCompileContext;
  Compiler: TJsFunctionCompiler;
begin
  ResolveProgram(Program_);
  MarkGlobals(Program_.Scope);
  Context := TJsCompileContext.Create;
  try
    Context.Realm := Realm;
    Context.FileName := FileName;
    Context.Source := TJsSource.Create;
    Realm.Heap.Register(Context.Source, ckOther);
    Context.Source.FileName := FileName;
    Context.Source.Text := Source;
    Realm.Heap.Account(Length(Source) * 2);
    Compiler := TJsFunctionCompiler.Create(Context, Program_.Func, nil);
    try
      Result := Compiler.CompileScriptBody(Program_);
    finally
      Compiler.Free;
    end;
  finally
    Context.Free;
  end;
end;

function CompileScript(Realm: TJsRealm; const Source: UnicodeString; const FileName: string;
  Strict: Boolean): TJsCode;
var
  Arena: TJsAstArena;
  Parser: TJsParser;
  Program_: TJsNode;
begin
  Arena := TJsAstArena.Create;
  Parser := TJsParser.Create(Source, Arena);
  try
    Program_ := Parser.ParseProgram(Strict);
    Result := CompileProgramNode(Realm, Program_, Source, FileName);
  finally
    Parser.Free;
    Arena.Free;
  end;
end;

procedure FillModuleRecord(Realm: TJsRealm; Module: TJsModule; Syntax: TJsModuleSyntax; Scope: TJsScope);
var
  Index: Integer;
  Variable: TJsVariable;
begin
  SetLength(Module.Requests, Length(Syntax.Requests));
  SetLength(Module.RequestedModules, Length(Syntax.Requests));
  for Index := 0 to High(Syntax.Requests) do
  begin
    Module.Requests[Index].Specifier := Syntax.Requests[Index].Specifier;
    Module.Requests[Index].Json := Syntax.Requests[Index].Json;
  end;
  SetLength(Module.Imports, Length(Syntax.Imports));
  SetLength(Module.ImportBindings, Length(Syntax.Imports));
  for Index := 0 to High(Syntax.Imports) do
  begin
    Module.Imports[Index].Request := Syntax.Imports[Index].Request;
    Module.Imports[Index].ImportName := Syntax.Imports[Index].ImportName;
    Module.Imports[Index].IsNamespace := Syntax.Imports[Index].IsNamespace;
    Module.ImportBindings[Index].Value := JsUndefined;
  end;
  SetLength(Module.LocalExports, Length(Syntax.LocalExports));
  for Index := 0 to High(Syntax.LocalExports) do
  begin
    Module.LocalExports[Index].ExportName := Syntax.LocalExports[Index].ExportName;
    Module.LocalExports[Index].Slot := Syntax.LocalExports[Index].Variable.Index;
  end;
  SetLength(Module.IndirectExports, Length(Syntax.IndirectExports));
  for Index := 0 to High(Syntax.IndirectExports) do
  begin
    Module.IndirectExports[Index].ExportName := Syntax.IndirectExports[Index].ExportName;
    Module.IndirectExports[Index].Request := Syntax.IndirectExports[Index].Request;
    Module.IndirectExports[Index].ImportName := Syntax.IndirectExports[Index].ImportName;
    Module.IndirectExports[Index].IsNamespace := Syntax.IndirectExports[Index].IsNamespace;
  end;
  Module.StarExports := Copy(Syntax.StarExports);
  { The environment, with its lexical bindings in the dead zone. }
  Module.Environment := NewEnvironment(Realm.Heap, nil, Scope.EnvironmentSize);
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    if Variable.IsLexical and (Variable.Kind <> dkImport) and (Variable.Index >= 0) then
      Module.Environment.Slots^[Variable.Index] := JsHole;
  end;
end;

procedure CompileModule(Realm: TJsRealm; const Source: UnicodeString; const FileName: string; Module: TJsModule);
var
  Arena: TJsAstArena;
  Parser: TJsParser;
  Program_: TJsNode;
  Context: TJsCompileContext;
  Compiler: TJsFunctionCompiler;
  Scope: TJsScope;
  Syntax: TJsModuleSyntax;
  Index: Integer;
begin
  Arena := TJsAstArena.Create;
  Parser := TJsParser.Create(Source, Arena);
  Context := nil;
  try
    Program_ := Parser.ParseProgram(True, pgModule);
    ResolveProgram(Program_);
    Scope := Program_.Scope;
    Syntax := Program_.Func.ModuleSyntax;
    Scope.EnvironmentProvided := True;
    for Index := 0 to High(Syntax.Imports) do
      if Syntax.Imports[Index].Variable <> nil then
        Syntax.Imports[Index].Variable.Index := Index;
    for Index := 0 to Scope.VariableCount - 1 do
      if Scope.Variables[Index].Kind <> dkImport then
        Scope.Variables[Index].Captured := True;
    Context := TJsCompileContext.Create;
    Context.Realm := Realm;
    Context.FileName := FileName;
    Context.Module := Module;
    Context.Source := TJsSource.Create;
    Realm.Heap.Register(Context.Source, ckOther);
    Context.Source.FileName := FileName;
    Context.Source.Text := Source;
    Realm.Heap.Account(Length(Source) * 2);
    Compiler := TJsFunctionCompiler.Create(Context, Program_.Func, nil);
    try
      Module.Body := Compiler.CompileModuleBody(Program_);
    finally
      Compiler.Free;
    end;
    Compiler := TJsFunctionCompiler.Create(Context, Program_.Func, nil);
    try
      Module.Initializer := Compiler.CompileModuleInitializer(Program_);
    finally
      Compiler.Free;
    end;
    Module.HasTopLevelAwait := Program_.Func.IsAsync;
    FillModuleRecord(Realm, Module, Syntax, Scope);
  finally
    Context.Free;
    Parser.Free;
    Arena.Free;
  end;
end;

procedure CompileLazyFunction(Realm: TJsRealm; Code: TJsCode);
var
  Lazy: TJsLazyFunction;
  Arena: TJsAstArena;
  Parser: TJsParser;
  Info: TJsFunctionInfo;
  Context: TJsCompileContext;
  Compiler: TJsFunctionCompiler;
  Compiled: TJsCode;
begin
  Lazy := TJsLazyFunction(Code.Lazy);
  Arena := TJsAstArena.Create;
  Parser := nil;
  Context := nil;
  try
    Parser := TJsParser.Create(Code.Source.Text, Arena);
    Info := Parser.ParseLazyFunction(Lazy.Start, Lazy.Line, Lazy.Column, BuildScopes(Lazy.Chain, Arena), Lazy.FunctionKind,
      Lazy.IsAsync, Lazy.IsGenerator, Lazy.IsStrict, Lazy.HasSelfName, Lazy.Name);
    ResolveFunctionScope(Info.Scope);
    Context := TJsCompileContext.Create;
    Context.Realm := Realm;
    Context.FileName := Code.Source.FileName;
    Context.Source := Code.Source;
    Context.Module := Code.Module;
    Compiler := TJsFunctionCompiler.Create(Context, Info, nil);
    try
      Compiled := Compiler.CompileFunction(Lazy.Name);
    finally
      Compiler.Free;
    end;
    { The closures hold Code: it becomes the compiled code. }
    Code.Instructions := Compiled.Instructions;
    Code.Constants := Compiled.Constants;
    Code.Functions := Compiled.Functions;
    Code.Caches := Compiled.Caches;
    Compiled.Caches := nil;
    Code.Handlers := Compiled.Handlers;
    Code.Lines := Compiled.Lines;
    Code.RegisterCount := Compiled.RegisterCount;
    Code.ParameterCount := Compiled.ParameterCount;
    Code.ArgumentsRegister := Compiled.ArgumentsRegister;
    Code.RestRegister := Compiled.RestRegister;
    Code.TemplateObjects := Compiled.TemplateObjects;
    Code.EvalChains := Compiled.EvalChains;
    Code.ParameterSlots := Compiled.ParameterSlots;
    Code.Flags := Compiled.Flags;
    Code.Lazy := nil;
    Realm.Heap.Account(Code.MemorySize - Code.InstanceSize);
  finally
    Context.Free;
    Parser.Free;
    Arena.Free;
  end;
end;

function CompileFunctionSource(Realm: TJsRealm; const Parameters, Body: UnicodeString; IsAsync,
  IsGenerator: Boolean): TJsCode;
var
  Source, Prefix: UnicodeString;
  Arena: TJsAstArena;
  Parser: TJsParser;
  Program_: TJsNode;
  Statement: TJsNode;
  Script: TJsCode;
begin
  Prefix := '';
  if IsAsync then
    Prefix := 'async ';
  Prefix := Prefix + 'function';
  if IsGenerator then
    Prefix := Prefix + '*';
  Source := '(' + Prefix + ' anonymous(' + Parameters + #10') {' + #10 + Body + #10 + '})';
  Arena := TJsAstArena.Create;
  Parser := TJsParser.Create(Source, Arena);
  try
    Program_ := Parser.ParseProgram(False);
    if (Program_.Count <> 1) or (Program_.List[0].Kind <> nkExpressionStatement) or
      (Program_.List[0].A.Kind <> nkFunction) then
      raise EJsSyntaxError.CreateAt('Invalid function body', 1, 1);
    Statement := Program_.List[0];
    Script := CompileProgramNode(Realm, Program_, Source, 'anonymous');
    { The function is the script's only nested code. }
    Result := Script.Functions[0];
    if Statement = nil then;
  finally
    Parser.Free;
    Arena.Free;
  end;
end;

end.
