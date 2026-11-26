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
  The syntax tree the parser builds and the compiler walks, and the
  scopes in it.

  One node class serves every construct: a kind, an operator, up to
  four children (A..D), a list, a name, a number or text, flags and the
  source position. What the fields mean per kind is written at the
  kind.

  Scopes are made while parsing: every function, block, catch clause,
  class body and for-loop head with lexical declarations gets one, the
  declarations go into it, and every identifier the parser meets is
  recorded as a reference in the scope it appears in. When the whole
  program is parsed, Js.Scopes resolves each reference to its variable,
  marks the variables an inner function uses as captured (they then
  live in an environment instead of a register) and gives every
  variable its place.
}
unit Js.Ast;

{$mode objfpc}{$H+}

interface

uses
  Js.Lexer;

type
  TJsNodeKind = (
    { Expressions }
    nkNumber,          { Number }
    nkBigInt,          { Text: digits, Number: radix }
    nkString,          { Text }
    nkTemplate,        { List: pieces (nkString, Raw in Name) and expressions alternating }
    nkTaggedTemplate,  { A: tag, B: nkTemplate }
    nkRegExp,          { Text: body, Name: flags }
    nkIdentifier,      { Text: name; Variable after resolution }
    nkThis,
    nkSuperMember,     { A: property expression (computed) or nil; Text: name }
    nkSuperCall,       { List: arguments }
    nkNull, nkTrue, nkFalse,
    nkArray,           { List: elements (nkHole, nkSpread) }
    nkObject,          { List: nkProperty }
    nkProperty,        { A: key, B: value; Flags }
    nkFunction,        { Func: the function }
    nkClass,           { Text: name; A: heritage; List: members (nkClassMember); B: binding identifier }
    nkClassMember,     { A: key, B: value (function / field initializer); Flags }
    nkUnary,           { Op, A }
    nkUpdate,          { Op (++ / --), A; Flags: prefix }
    nkBinary,          { Op, A, B }
    nkLogical,         { Op (&&, ||, ??), A, B }
    nkAssign,          { Op (= or compound), A: target, B: value }
    nkConditional,     { A ? B : C }
    nkCall,            { A: callee, List: arguments; Flags: optional }
    nkNew,             { A: callee, List: arguments }
    nkMember,          { A: object; B: property (computed) or nil; Text: name; Flags }
    nkOptionalChain,   { A: the chain: where an optional link short-circuits to }
    nkSequence,        { List }
    nkSpread,          { A }
    nkYield,           { A (or nil); Flags: delegate }
    nkAwait,           { A }
    nkNewTarget,
    nkImportMeta,
    nkHole,
    nkPrivateName,     { Text }
    nkPrivateIn,       { Text: private name, B: object }
    nkArrayPattern,    { List: targets (nkHole, nkRest, nkAssignPattern...) }
    nkObjectPattern,   { List: nkProperty (A key, B target), nkRest }
    nkAssignPattern,   { A: target, B: default }
    nkRest,            { A: target }
    nkDynamicImport,   { A }
    { Statements }
    nkProgram,         { List; Scope }
    nkVariables,       { List: nkDeclarator; Op: tkVar / tkLet... (DeclarationKind) }
    nkDeclarator,      { A: target, B: initializer }
    nkExpressionStatement, { A }
    nkBlock,           { List; Scope }
    nkEmpty,
    nkIf,              { A test, B consequent, C alternate }
    nkFor,             { A init, B test, C update, D body; Scope }
    nkForIn,           { A left, B right, D body; Scope }
    nkForOf,           { A left, B right, D body; Scope; Flags: await }
    nkWhile,           { A test, D body }
    nkDoWhile,         { D body, A test }
    nkContinue,        { Text: label }
    nkBreak,           { Text: label }
    nkReturn,          { A }
    nkThrow,           { A }
    nkTry,             { A block, B catch parameter, C catch block, D finally; Scope: catch scope }
    nkSwitch,          { A discriminant, List: nkCase; Scope }
    nkCase,            { A test (nil: default), List: statements }
    nkLabeled,         { Text: label, A: statement }
    nkDebugger,
    nkFunctionDeclaration, { Func }
    nkClassDeclaration,    { as nkClass }
    nkWith,            { A object, B body }
    nkImport,          { unused: imports are entries of the module syntax }
    nkExport);         { export default expression: A; Variable: the *default* binding }

  TJsDeclarationKind = (dkVar, dkLet, dkConst, dkFunction, dkParameter, dkClass,
    dkCatch, dkImplicit, dkClassInner, dkImport);

  TJsScope = class;
  TJsFunctionInfo = class;
  TJsNameArray = array of UnicodeString;
  TJsVariable = class;

  TJsNode = class
  public
    Kind: TJsNodeKind;
    Op: TJsTokenKind;
    Flags: Word;
    Line: Integer;
    Column: Integer;
    A, B, C, D: TJsNode;
    List: array of TJsNode;
    Count: Integer;
    Text: UnicodeString;
    Name: UnicodeString;
    Number: Double;
    Scope: TJsScope;
    Func: TJsFunctionInfo;
    { An identifier's variable (nil: a global by name). }
    Variable: TJsVariable;
    { The scope an identifier appears in. }
    ReferenceScope: TJsScope;
    { An identifier inside with statements or below a function with a
      sloppy direct eval: the objects (variables holding them, innermost
      first) to look the name up in before Variable. }
    DynamicScopes: array of TJsVariable;
    procedure Add(Node: TJsNode);
  end;

  TJsVariable = class
  public
    Name: UnicodeString;
    Kind: TJsDeclarationKind;
    Scope: TJsScope;
    { Used by a function nested deeper than the declaring one. }
    Captured: Boolean;
    { Register (not captured) or environment slot (captured). }
    Index: Integer;
    { Position of the declaration, for the temporal dead zone. }
    DeclarationStart: Integer;
    { Var bindings declared by sloppy block functions (Annex B). }
    IsAnnexB: Boolean;
    { A block's binding of a plain (not async, not generator) function:
      sloppy code may declare it again in the same block (B.3.2.4). }
    IsPlainBlockFunction: Boolean;
    { A declaration of a script's top level: a property of the global
      object or a binding of the global lexical environment, by name. }
    IsGlobal: Boolean;
    function IsLexical: Boolean;
  end;

  TJsScopeKind = (skScript, skFunction, skBlock, skCatch, skClass, skFor, skSwitch, skEval, skModule);

  TJsScope = class
  public
    Kind: TJsScopeKind;
    Parent: TJsScope;
    { The function (or script) this scope belongs to. }
    FunctionScope: TJsScope;
    Func: TJsFunctionInfo;
    Variables: array of TJsVariable;
    VariableCount: Integer;
    References: array of TJsNode;
    ReferenceCount: Integer;
    Children: array of TJsScope;
    ChildCount: Integer;
    { Captured variables need an environment made when the scope is
      entered. }
    EnvironmentSize: Integer;
    { The environment exists before the code runs (a module's, made when
      the module is linked): entering the scope makes none. }
    EnvironmentProvided: Boolean;
    { A with statement's scope: the variable holding its object. }
    WithVariable: TJsVariable;
    { A direct eval can see the scope's bindings by name: they all live
      in its environment. }
    EvalExposed: Boolean;
  private
    { Name lookup for a scope with many variables (a bundle's top level
      holds thousands): open addressing, slot = variable index + 1 (0:
      empty), covering Variables[0..FIndexedCount - 1]. }
    FNameSlots: array of Integer;
    FIndexedCount: Integer;
    procedure IndexVariable(Index: Integer);
    procedure UpdateNameIndex;
  public
    procedure RemoveVariable(Variable: TJsVariable);
    { The scope's environment, at run time, is pushed on entry. }
    function HasEnvironment: Boolean; inline;
    function Find(const Name: UnicodeString): TJsVariable;
    function Declare(const Name: UnicodeString; DeclarationKind: TJsDeclarationKind; Start: Integer): TJsVariable;
    procedure AddReference(Node: TJsNode);
    procedure AddChild(Scope: TJsScope);
    destructor Destroy; override;
  end;

  TJsFunctionKind = (fkNormal, fkArrow, fkMethod, fkGetter, fkSetter, fkClassConstructor,
    fkDerivedConstructor, fkClassFieldInitializer, fkScript, fkModule);

  TJsModuleSyntax = class;

  TJsFunctionInfo = class
  public
    Name: UnicodeString;
    Kind: TJsFunctionKind;
    IsAsync: Boolean;
    IsGenerator: Boolean;
    IsStrict: Boolean;
    IsExpression: Boolean;
    Parameters: array of TJsNode;
    ParameterCount: Integer;
    { The expected argument count (parameters before the first default or rest). }
    Length: Integer;
    HasSimpleParameters: Boolean;
    Body: array of TJsNode;
    BodyCount: Integer;
    { An arrow's expression body. }
    ExpressionBody: TJsNode;
    Scope: TJsScope;
    { The binding of a named function expression's own name. }
    SelfVariable: TJsVariable;
    { Implicit variables. }
    ThisVariable: TJsVariable;
    ArgumentsVariable: TJsVariable;
    NewTargetVariable: TJsVariable;
    HomeVariable: TJsVariable;
    FunctionVariable: TJsVariable;
    UsesArguments: Boolean;
    UsesThis: Boolean;
    UsesSuper: Boolean;
    UsesNewTarget: Boolean;
    ContainsDirectEval: Boolean;
    { A sloppy function with a direct eval: the variable holding the
      object the eval's var declarations go to. }
    EvalVarsVariable: TJsVariable;
    SourceStart: Integer;
    SourceFinish: Integer;
    Line: Integer;
    Column: Integer;
    { Where the parameter list starts (a lazy function is parsed again
      from there when first called). }
    ParametersStart: Integer;
    ParametersLine: Integer;
    ParametersColumn: Integer;
    { Private names appear in it (it needs its class's private scope:
      not compiled lazily). }
    UsesPrivateNames: Boolean;
    { Class constructors: the class's field initializers. }
    FieldInitializer: TJsNode;
    ClassNode: TJsNode;
    { A module: its imports and exports. }
    ModuleSyntax: TJsModuleSyntax;
    destructor Destroy; override;
  end;

  { A module request: the specifier and whether it asks for JSON
    (with type "json"). }
  TJsModuleRequestEntry = record
    Specifier: UnicodeString;
    Json: Boolean;
  end;

  { import ImportName as LocalName from Request; ImportName '*' with
    IsNamespace for import * as LocalName. }
  TJsImportEntry = record
    Request: Integer;
    ImportName: UnicodeString;
    IsNamespace: Boolean;
    LocalName: UnicodeString;
    Variable: TJsVariable;
  end;

  { An export: of a local binding (Request -1, LocalName, Variable), or
    of what another module exports (Request, ImportName; IsNamespace
    for export * as ExportName). }
  TJsExportEntry = record
    ExportName: UnicodeString;
    Request: Integer;
    ImportName: UnicodeString;
    IsNamespace: Boolean;
    LocalName: UnicodeString;
    Variable: TJsVariable;
    Line: Integer;
    Column: Integer;
  end;

  TJsModuleSyntax = class
  public
    Requests: array of TJsModuleRequestEntry;
    Imports: array of TJsImportEntry;
    LocalExports: array of TJsExportEntry;
    IndirectExports: array of TJsExportEntry;
    { export * from: the requests. }
    StarExports: array of Integer;
    { The request for Specifier (made the first time). }
    function AddRequest(const Specifier: UnicodeString; Json: Boolean): Integer;
    function AddImport(Request: Integer; const ImportName, LocalName: UnicodeString; IsNamespace: Boolean;
      Variable: TJsVariable): Integer;
    function HasExport(const Name: UnicodeString): Boolean;
    procedure AddExport(const Entry: TJsExportEntry);
  end;

  { Owns every node and scope made for one compilation. }
  TJsAstArena = class
  private
    FNodes: array of TJsNode;
    FNodeCount: Integer;
    FObjects: array of TObject;
    FObjectCount: Integer;
  public
    destructor Destroy; override;
    function NewNode(Kind: TJsNodeKind; Line, Column: Integer): TJsNode;
    procedure Own(Item: TObject);
  end;

const
  { nkProperty / nkClassMember flags }
  PropertyFlagComputed = 1;
  PropertyFlagShorthand = 2;
  PropertyFlagMethod = 4;
  PropertyFlagGetter = 8;
  PropertyFlagSetter = 16;
  PropertyFlagSpread = 32;
  PropertyFlagStatic = 64;
  PropertyFlagField = 128;
  PropertyFlagPrivate = 256;
  PropertyFlagStaticBlock = 512;
  PropertyFlagProto = 1024;
  { nkMember / nkCall flags }
  MemberFlagComputed = 1;
  MemberFlagOptional = 2;
  MemberFlagPrivate = 4;
  { nkCall: eval(...), a direct eval when eval is the intrinsic }
  CallFlagDirectEval = 8;
  { nkUpdate }
  UpdateFlagPrefix = 1;
  { nkYield }
  YieldFlagDelegate = 1;
  { nkForOf }
  ForFlagAwait = 1;
  { nkFunction: parenthesized (for the name inference rules) }
  NodeFlagParenthesized = 2048;

function DeclarationIsLexical(Kind: TJsDeclarationKind): Boolean; inline;

implementation

function DeclarationIsLexical(Kind: TJsDeclarationKind): Boolean;
begin
  Result := Kind in [dkLet, dkConst, dkClass, dkClassInner, dkImport];
end;

{ TJsModuleSyntax }

function TJsModuleSyntax.AddRequest(const Specifier: UnicodeString; Json: Boolean): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Requests) do
    if (Requests[Index].Specifier = Specifier) and (Requests[Index].Json = Json) then
      Exit(Index);
  Result := Length(Requests);
  SetLength(Requests, Result + 1);
  Requests[Result].Specifier := Specifier;
  Requests[Result].Json := Json;
end;

function TJsModuleSyntax.AddImport(Request: Integer; const ImportName, LocalName: UnicodeString;
  IsNamespace: Boolean; Variable: TJsVariable): Integer;
begin
  Result := Length(Imports);
  SetLength(Imports, Result + 1);
  Imports[Result].Request := Request;
  Imports[Result].ImportName := ImportName;
  Imports[Result].IsNamespace := IsNamespace;
  Imports[Result].LocalName := LocalName;
  Imports[Result].Variable := Variable;
end;

function TJsModuleSyntax.HasExport(const Name: UnicodeString): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(LocalExports) do
    if LocalExports[Index].ExportName = Name then
      Exit(True);
  for Index := 0 to High(IndirectExports) do
    if IndirectExports[Index].ExportName = Name then
      Exit(True);
  Result := False;
end;

procedure TJsModuleSyntax.AddExport(const Entry: TJsExportEntry);
begin
  if Entry.Request < 0 then
  begin
    SetLength(LocalExports, Length(LocalExports) + 1);
    LocalExports[High(LocalExports)] := Entry;
  end
  else
  begin
    SetLength(IndirectExports, Length(IndirectExports) + 1);
    IndirectExports[High(IndirectExports)] := Entry;
  end;
end;

procedure TJsNode.Add(Node: TJsNode);
begin
  if Count >= Length(List) then
    SetLength(List, Length(List) * 2 + 4);
  List[Count] := Node;
  Inc(Count);
end;

function TJsVariable.IsLexical: Boolean;
begin
  Result := DeclarationIsLexical(Kind);
end;

function TJsScope.HasEnvironment: Boolean;
begin
  Result := EnvironmentSize > 0;
end;

const
  { Scopes with more variables than this find names through a hash. }
  LinearFindLimit = 12;

function NameHash(const Name: UnicodeString): Cardinal;
var
  Index: Integer;
begin
  Result := 2166136261;
  for Index := 1 to Length(Name) do
    Result := (Result xor Ord(Name[Index])) * 16777619;
end;

{ Adds Variables[Index] unless an earlier variable has its name (Find
  gives the first declaration). }
procedure TJsScope.IndexVariable(Index: Integer);
var
  Mask, Slot: Cardinal;
  Name: UnicodeString;
begin
  Name := Variables[Index].Name;
  Mask := Cardinal(Length(FNameSlots) - 1);
  Slot := NameHash(Name) and Mask;
  while FNameSlots[Slot] <> 0 do
  begin
    if Variables[FNameSlots[Slot] - 1].Name = Name then
      Exit;
    Slot := (Slot + 1) and Mask;
  end;
  FNameSlots[Slot] := Index + 1;
end;

procedure TJsScope.UpdateNameIndex;
var
  Size, Index: Integer;
begin
  if VariableCount * 2 > Length(FNameSlots) then
  begin
    Size := 64;
    while Size < VariableCount * 4 do
      Size := Size * 2;
    FNameSlots := nil;
    SetLength(FNameSlots, Size);
    FIndexedCount := 0;
  end;
  for Index := FIndexedCount to VariableCount - 1 do
    IndexVariable(Index);
  FIndexedCount := VariableCount;
end;

function TJsScope.Find(const Name: UnicodeString): TJsVariable;
var
  Index: Integer;
  Mask, Slot: Cardinal;
begin
  if VariableCount <= LinearFindLimit then
  begin
    for Index := 0 to VariableCount - 1 do
      if Variables[Index].Name = Name then
        Exit(Variables[Index]);
    Exit(nil);
  end;
  if FIndexedCount <> VariableCount then
    UpdateNameIndex;
  Mask := Cardinal(Length(FNameSlots) - 1);
  Slot := NameHash(Name) and Mask;
  while FNameSlots[Slot] <> 0 do
  begin
    Result := Variables[FNameSlots[Slot] - 1];
    if Result.Name = Name then
      Exit;
    Slot := (Slot + 1) and Mask;
  end;
  Result := nil;
end;

function TJsScope.Declare(const Name: UnicodeString; DeclarationKind: TJsDeclarationKind; Start: Integer): TJsVariable;
begin
  Result := TJsVariable.Create;
  Result.Name := Name;
  Result.Kind := DeclarationKind;
  Result.Scope := Self;
  Result.DeclarationStart := Start;
  Result.Index := -1;
  if VariableCount >= Length(Variables) then
    SetLength(Variables, Length(Variables) * 2 + 4);
  Variables[VariableCount] := Result;
  Inc(VariableCount);
end;

procedure TJsScope.AddReference(Node: TJsNode);
begin
  if ReferenceCount >= Length(References) then
    SetLength(References, Length(References) * 2 + 8);
  References[ReferenceCount] := Node;
  Inc(ReferenceCount);
  Node.ReferenceScope := Self;
end;

procedure TJsScope.RemoveVariable(Variable: TJsVariable);
var
  Index: Integer;
begin
  for Index := 0 to VariableCount - 1 do
    if Variables[Index] = Variable then
    begin
      Variables[Index] := Variables[VariableCount - 1];
      Dec(VariableCount);
      Variable.Free;
      { The index is rebuilt on the next search. }
      FNameSlots := nil;
      FIndexedCount := 0;
      Exit;
    end;
end;

procedure TJsScope.AddChild(Scope: TJsScope);
begin
  if ChildCount >= Length(Children) then
    SetLength(Children, Length(Children) * 2 + 4);
  Children[ChildCount] := Scope;
  Inc(ChildCount);
end;

destructor TJsScope.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to VariableCount - 1 do
    Variables[Index].Free;
  inherited Destroy;
end;

destructor TJsFunctionInfo.Destroy;
begin
  inherited Destroy;
end;

destructor TJsAstArena.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FNodeCount - 1 do
    FNodes[Index].Free;
  for Index := 0 to FObjectCount - 1 do
    FObjects[Index].Free;
  inherited Destroy;
end;

function TJsAstArena.NewNode(Kind: TJsNodeKind; Line, Column: Integer): TJsNode;
begin
  Result := TJsNode.Create;
  Result.Kind := Kind;
  Result.Line := Line;
  Result.Column := Column;
  if FNodeCount >= Length(FNodes) then
    SetLength(FNodes, Length(FNodes) * 2 + 256);
  FNodes[FNodeCount] := Result;
  Inc(FNodeCount);
end;

procedure TJsAstArena.Own(Item: TObject);
begin
  if FObjectCount >= Length(FObjects) then
    SetLength(FObjects, Length(FObjects) * 2 + 64);
  FObjects[FObjectCount] := Item;
  Inc(FObjectCount);
end;

end.
