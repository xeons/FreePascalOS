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

  A lazily compiled function keeps such a chain too. A chain is a cell
  per scope, linked outward (Outer), and a scope's cell is made once
  (TJsScope.Snapshot): the functions of one scope share it, and so do
  the functions compiled later inside a function rebuilt from it - a
  bundle's top level scope of thousands of names is described once, not
  once per lazy function.
}
unit Js.EvalScopes;

{$mode objfpc}{$H+}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Lexer,
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

  TJsEvalChain = class;

  { A level's variables by name, restored into a rebuilt scope as they
    are looked for. }
  TJsLevelNames = class(TJsScopeBacking)
  private
    FChain: TJsEvalChain;
    { Open addressing: variable index + 1, 0 empty. }
    FSlots: array of Integer;
    function IndexOf(const Name: UnicodeString): Integer;
  public
    constructor Create(Chain: TJsEvalChain);
    function Restore(Scope: TJsScope; const Name: UnicodeString): TJsVariable; override;
    { Restores the variable at Index of the level. }
    function RestoreIndex(Scope: TJsScope; Index: Integer): TJsVariable;
  end;

  TJsEvalChain = class(TJsCell)
  private
    FNames: TJsLevelNames;
  public
    { The scope this cell describes, and the chain of the one around it
      (nil: this is the outermost). }
    Level: TJsEvalLevel;
    Outer: TJsEvalChain;
    { A direct eval's chain: whether the eval's code is strict. }
    IsStrict: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
    function Names: TJsLevelNames;
    destructor Destroy; override;
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

{ The chain of scopes from Scope out, shared (a lazy function's): the
  cells made are registered in Heap. }
function SharedEvalChain(Heap: TJsHeap; Scope: TJsScope): TJsEvalChain;
{ The chain of a direct eval's call in Scope: a cell of its own for the
  innermost scope (with Strict), shared ones around it. }
function BuildEvalChain(Heap: TJsHeap; Scope: TJsScope; Strict: Boolean): TJsEvalChain;
{ Scopes like the chain's (owned by Arena); the innermost is returned. }
function BuildScopes(Chain: TJsEvalChain; Arena: TJsAstArena): TJsScope;

implementation

procedure TJsLazyFunction.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkCell(Chain);
end;

procedure TJsEvalChain.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkCell(Outer);
end;

function TJsEvalChain.MemorySize: SizeInt;
begin
  Result := InstanceSize + Length(Level.Variables) * (SizeOf(TJsEvalVariable) + 16);
end;

function TJsEvalChain.Names: TJsLevelNames;
begin
  if FNames = nil then
    FNames := TJsLevelNames.Create(Self);
  Result := FNames;
end;

destructor TJsEvalChain.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

function NameHash(const Name: UnicodeString): Cardinal; inline;
begin
  Result := Js.Lexer.NameHash(PWideChar(Name), Length(Name));
end;

constructor TJsLevelNames.Create(Chain: TJsEvalChain);
var
  Size, Index: Integer;
  Mask, Slot: Cardinal;
  Duplicate: Boolean;
begin
  inherited Create;
  FChain := Chain;
  Size := 16;
  while Size < Length(Chain.Level.Variables) * 2 do
    Size := Size * 2;
  SetLength(FSlots, Size);
  Mask := Cardinal(Size - 1);
  for Index := 0 to High(Chain.Level.Variables) do
  begin
    Slot := NameHash(Chain.Level.Variables[Index].Name) and Mask;
    Duplicate := False;
    while FSlots[Slot] <> 0 do
    begin
      if Chain.Level.Variables[FSlots[Slot] - 1].Name = Chain.Level.Variables[Index].Name then
      begin
        Duplicate := True;
        Break;
      end;
      Slot := (Slot + 1) and Mask;
    end;
    { The first declaration of a name is the one found. }
    if not Duplicate then
      FSlots[Slot] := Index + 1;
  end;
end;

function TJsLevelNames.IndexOf(const Name: UnicodeString): Integer;
var
  Mask, Slot: Cardinal;
begin
  Mask := Cardinal(Length(FSlots) - 1);
  Slot := NameHash(Name) and Mask;
  while FSlots[Slot] <> 0 do
  begin
    if FChain.Level.Variables[FSlots[Slot] - 1].Name = Name then
      Exit(FSlots[Slot] - 1);
    Slot := (Slot + 1) and Mask;
  end;
  Result := -1;
end;

function TJsLevelNames.RestoreIndex(Scope: TJsScope; Index: Integer): TJsVariable;
var
  Entry: ^TJsEvalVariable;
  Info: TJsFunctionInfo;
begin
  Entry := @FChain.Level.Variables[Index];
  Result := Scope.DeclareRestored(Entry^.Name, Entry^.Kind);
  Result.Index := Entry^.Index;
  Result.IsGlobal := Entry^.IsGlobal;
  Result.Captured := Entry^.Captured;
  Info := Scope.Func;
  if (Info = nil) or (Info.Scope <> Scope) then
    Exit;
  { What the scope analysis keeps of a function. }
  if Result.Name = '%this' then
    Info.ThisVariable := Result
  else if Result.Name = '%newtarget' then
    Info.NewTargetVariable := Result
  else if Result.Name = '%home' then
    Info.HomeVariable := Result
  else if Result.Name = '%function' then
    Info.FunctionVariable := Result
  else if (Result.Name = 'arguments') and (Result.Kind = dkImplicit) then
    Info.ArgumentsVariable := Result;
end;

function TJsLevelNames.Restore(Scope: TJsScope; const Name: UnicodeString): TJsVariable;
var
  Index: Integer;
begin
  Index := IndexOf(Name);
  if Index < 0 then
    Exit(nil);
  Result := RestoreIndex(Scope, Index);
end;

procedure DescribeScope(Scope: TJsScope; out Level: TJsEvalLevel);
var
  Index: Integer;
  Variable: TJsVariable;
begin
  Level.Kind := Scope.Kind;
  Level.FunctionKind := fkNormal;
  Level.IsStrict := False;
  if Scope.Func <> nil then
  begin
    Level.FunctionKind := Scope.Func.Kind;
    Level.IsStrict := Scope.Func.IsStrict;
  end;
  Level.EnvironmentSize := Scope.EnvironmentSize;
  Level.EnvironmentProvided := Scope.EnvironmentProvided;
  Level.WithVariable := -1;
  Level.EvalVarsVariable := -1;
  SetLength(Level.Variables, Scope.VariableCount);
  for Index := 0 to Scope.VariableCount - 1 do
  begin
    Variable := Scope.Variables[Index];
    Level.Variables[Index].Name := Variable.Name;
    Level.Variables[Index].Kind := Variable.Kind;
    Level.Variables[Index].Index := Variable.Index;
    Level.Variables[Index].IsGlobal := Variable.IsGlobal;
    Level.Variables[Index].Captured := Variable.Captured;
    if Variable = Scope.WithVariable then
      Level.WithVariable := Index;
    if (Scope.Func <> nil) and (Variable = Scope.Func.EvalVarsVariable) then
      Level.EvalVarsVariable := Index;
  end;
end;

function NewChainCell(Heap: TJsHeap; Scope: TJsScope; Outer: TJsEvalChain): TJsEvalChain;
begin
  Result := TJsEvalChain.Create;
  DescribeScope(Scope, Result.Level);
  Result.Outer := Outer;
  Heap.Register(Result, ckOther);
  Heap.Account(Result.MemorySize - Result.InstanceSize);
end;

function SharedEvalChain(Heap: TJsHeap; Scope: TJsScope): TJsEvalChain;
begin
  if Scope = nil then
    Exit(nil);
  if Scope.Snapshot <> nil then
    Exit(TJsEvalChain(Scope.Snapshot));
  Result := NewChainCell(Heap, Scope, SharedEvalChain(Heap, Scope.Parent));
  Scope.Snapshot := Result;
end;

function BuildEvalChain(Heap: TJsHeap; Scope: TJsScope; Strict: Boolean): TJsEvalChain;
begin
  Result := NewChainCell(Heap, Scope, SharedEvalChain(Heap, Scope.Parent));
  Result.IsStrict := Strict;
end;

function BuildScopes(Chain: TJsEvalChain; Arena: TJsAstArena): TJsScope;
var
  Index: Integer;
  Cells: array of TJsEvalChain;
  Walk: TJsEvalChain;
  Level: ^TJsEvalLevel;
  Scope, Outer: TJsScope;
  Info: TJsFunctionInfo;
begin
  Cells := nil;
  Walk := Chain;
  while Walk <> nil do
  begin
    SetLength(Cells, Length(Cells) + 1);
    Cells[High(Cells)] := Walk;
    Walk := Walk.Outer;
  end;
  Outer := nil;
  Info := nil;
  Index := High(Cells);
  while Index >= 0 do
  begin
    Level := @Cells[Index].Level;
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
    { The variables come when looked for; these are looked at directly. }
    if Level^.WithVariable >= 0 then
      Scope.WithVariable := Cells[Index].Names.RestoreIndex(Scope, Level^.WithVariable);
    if Level^.EvalVarsVariable >= 0 then
      Info.EvalVarsVariable := Cells[Index].Names.RestoreIndex(Scope, Level^.EvalVarsVariable);
    Scope.Backing := Cells[Index].Names;
    { The functions compiled inside share the cell this came from. }
    Scope.Snapshot := Cells[Index];
    Outer := Scope;
    Dec(Index);
  end;
  Result := Outer;
end;

end.
