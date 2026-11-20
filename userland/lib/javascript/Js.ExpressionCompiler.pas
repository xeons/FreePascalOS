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
  The compiler's expression layer.

  Expression(Node, Target) compiles an expression and returns the
  register holding its value: Target when Target >= 0, else a register
  of its choosing - a fresh temporary, or a local variable's own
  register, which the caller must only read. A result temporary is
  always allocated before the temporaries of the operands, so that the
  caller can release everything above its mark and keep the result.

  Branch compiles a condition as jumps (with the fused compare-and-jump
  instructions for loop conditions); BindPattern assigns a value to a
  destructuring pattern or a simple target; anonymous functions and
  classes get the name of what they are assigned to (PendingName).
}
unit Js.ExpressionCompiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Atoms,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.BigIntegers,
  Js.Lexer,
  Js.Ast,
  Js.Bytecode,
  Js.CodeBuilder;

type
  TJsPatchList = array of Integer;

  TJsBindMode = (bmAssign, bmInitialize, bmVar);

  TJsExpressionCompiler = class(TJsCodeBuilder)
  protected
    FOptionalExits: array of TJsPatchList;
    FOptionalDepth: Integer;
    procedure AddPatch(var Patches: TJsPatchList; Position: Integer);
    procedure PatchAll(const Patches: TJsPatchList; Target: Integer);
    function KeyIsName(Node: TJsNode; out Name: UnicodeString): Boolean;
    function NumberIsIndex(Value: Double): Boolean;
    function IsSimple(Node: TJsNode): Boolean;
    function WritesTargetLast(Node: TJsNode): Boolean;
    procedure OptionalExit(Register: Integer);

    function CompileLiteral(Node: TJsNode; Target: Integer): Integer;
    function CompileTemplate(Node: TJsNode; Target: Integer): Integer;
    function CompileTaggedTemplate(Node: TJsNode; Target: Integer): Integer;
    function CompileArray(Node: TJsNode; Target: Integer): Integer;
    function CompileObject(Node: TJsNode; Target: Integer): Integer;
    function CompileMember(Node: TJsNode; Target: Integer): Integer;
    function CompileSuperMember(Node: TJsNode; Target: Integer): Integer;
    function CompileCall(Node: TJsNode; Target: Integer): Integer;
    function CompileNew(Node: TJsNode; Target: Integer): Integer;
    function CompileSuperCall(Node: TJsNode; Target: Integer): Integer;
    procedure CompileArguments(Node: TJsNode; Base: Integer; out Count: Integer; out SpreadArray: Integer);
    function CompileUnary(Node: TJsNode; Target: Integer): Integer;
    function CompileUpdate(Node: TJsNode; Target: Integer; Discard: Boolean): Integer;
    function CompileBinary(Node: TJsNode; Target: Integer): Integer;
    function CompileLogical(Node: TJsNode; Target: Integer): Integer;
    function CompileAssign(Node: TJsNode; Target: Integer; Discard: Boolean): Integer;
    function CompileConditional(Node: TJsNode; Target: Integer): Integer;
    function CompileSequence(Node: TJsNode; Target: Integer): Integer;
    function CompileOptionalChain(Node: TJsNode; Target: Integer): Integer;
    function CompileThis(Node: TJsNode; Target: Integer): Integer;
    function CompileYield(Node: TJsNode; Target: Integer): Integer;
    function CompileAwait(Node: TJsNode; Target: Integer): Integer;
    function CompilePrivateName(Node: TJsNode; Target: Integer): Integer;
    function CompileKey(Node: TJsNode; Computed: Boolean; Target: Integer): Integer;
    procedure StoreToMember(Member: TJsNode; ObjectRegister, KeyRegister, Value: Integer);
    { The home object of the method a super reference is in. }
    function LoadHomeObject(Node: TJsNode): Integer;
    { super[key] read into Target, with this as the receiver. }
    procedure EmitGetSuper(Node: TJsNode; Target, Key: Integer);
    function BinaryOpcode(Kind: TJsTokenKind): TJsOpcode;
  public
    PendingName: UnicodeString;
    HasPendingName: Boolean;
    function Expression(Node: TJsNode; Target: Integer): Integer;
    procedure ExpressionInto(Node: TJsNode; Target: Integer);
    procedure ExpressionDiscard(Node: TJsNode);
    { Compiles Node with the name an anonymous function or class takes. }
    function NamedExpression(Node: TJsNode; Target: Integer; const Name: UnicodeString): Integer;
    { Jumps (added to Patches) when Node is WhenTrue, falls through otherwise. }
    procedure Branch(Node: TJsNode; WhenTrue: Boolean; var Patches: TJsPatchList);
    procedure BindPattern(Pattern: TJsNode; Value: Integer; Mode: TJsBindMode);
    { The this value into a register (frame or captured variable). }
    function LoadThis(Owner: TJsScope; Variable: TJsVariable; Target: Integer; Reference: TJsNode): Integer;

    { Provided by the function layer. }
    function CompileFunctionNode(Node: TJsNode; Target: Integer; const Name: UnicodeString;
      HasName: Boolean): Integer; virtual; abstract;
    function CompileClass(Node: TJsNode; Target: Integer; const Name: UnicodeString): Integer; virtual; abstract;
    function IsCurrentFunction(Scope: TJsScope): Boolean; virtual; abstract;
  end;

function IsAnonymousDefinition(Node: TJsNode): Boolean;

implementation

function IsAnonymousDefinition(Node: TJsNode): Boolean;
begin
  Result := ((Node.Kind = nkFunction) and (Node.Func.Name = '')) or
    ((Node.Kind = nkClass) and (Node.Text = ''));
end;

procedure TJsExpressionCompiler.AddPatch(var Patches: TJsPatchList; Position: Integer);
begin
  SetLength(Patches, Length(Patches) + 1);
  Patches[High(Patches)] := Position;
end;

procedure TJsExpressionCompiler.PatchAll(const Patches: TJsPatchList; Target: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(Patches) do
    Patch(Patches[Index], Target);
end;

function TJsExpressionCompiler.NumberIsIndex(Value: Double): Boolean;
begin
  Result := (Value >= 0) and (Value <= 2147483647.0) and (Int(Value) = Value) and
    not ((Value = 0) and (DoubleBits(Value) <> 0));
end;

{ A key written as a name ("a", a: , 'a':) that is not an index. }
function TJsExpressionCompiler.KeyIsName(Node: TJsNode; out Name: UnicodeString): Boolean;
var
  Index: Integer;
  AllDigits: Boolean;
begin
  Name := '';
  if Node.Kind <> nkString then
    Exit(False);
  Name := Node.Text;
  if (Length(Name) = 0) or (Length(Name) > 10) then
    Exit(True);
  AllDigits := True;
  for Index := 1 to Length(Name) do
    if (Name[Index] < '0') or (Name[Index] > '9') then
    begin
      AllDigits := False;
      Break;
    end;
  if not AllDigits then
    Exit(True);
  { "0", "12": indices; "012" is a name. }
  Result := (Length(Name) > 1) and (Name[1] = '0') or (StrToInt64Def(string(Name), MaxInt) > 2147483646);
end;

function TJsExpressionCompiler.IsSimple(Node: TJsNode): Boolean;
begin
  Result := Node.Kind in [nkNumber, nkString, nkNull, nkTrue, nkFalse, nkThis, nkBigInt];
  if (Node.Kind = nkIdentifier) then
    Result := True;
end;

function TJsExpressionCompiler.WritesTargetLast(Node: TJsNode): Boolean;
begin
  Result := Node.Kind in [nkNumber, nkString, nkNull, nkTrue, nkFalse, nkBigInt, nkIdentifier, nkBinary,
    nkCall, nkNew, nkMember, nkThis, nkFunction, nkArray, nkObject, nkRegExp];
  if (Node.Kind = nkUnary) and (Node.Op <> tkDelete) then
    Result := True;
end;

procedure TJsExpressionCompiler.OptionalExit(Register: Integer);
begin
  if FOptionalDepth = 0 then
    Exit;
  AddPatch(FOptionalExits[FOptionalDepth - 1], EmitJumpIf(opJumpIfNullish, Register));
end;

function TJsExpressionCompiler.NamedExpression(Node: TJsNode; Target: Integer; const Name: UnicodeString): Integer;
begin
  if IsAnonymousDefinition(Node) then
  begin
    if Node.Kind = nkFunction then
      Exit(CompileFunctionNode(Node, Target, Name, True));
    Exit(CompileClass(Node, Target, Name));
  end;
  Result := Expression(Node, Target);
end;

procedure TJsExpressionCompiler.ExpressionInto(Node: TJsNode; Target: Integer);
var
  Register: Integer;
begin
  Register := Expression(Node, Target);
  if Register <> Target then
    Emit(opMove, Target, Register);
end;

procedure TJsExpressionCompiler.ExpressionDiscard(Node: TJsNode);
var
  Mark: Integer;
begin
  Mark := FNextRegister;
  case Node.Kind of
    nkUpdate: CompileUpdate(Node, -1, True);
    nkAssign: CompileAssign(Node, -1, True);
    nkIdentifier:
      if Node.Variable = nil then
        Expression(Node, -1)
      else if NeedsTdzCheck(Node.Variable, Node) then
        LoadVariable(Node.Variable, Node.Text, -1, Node);
    nkNumber, nkString, nkNull, nkTrue, nkFalse, nkThis, nkFunction:
      ;
    nkSequence:
      CompileSequence(Node, -1);
  else
    Expression(Node, -1);
  end;
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.Expression(Node: TJsNode; Target: Integer): Integer;
var
  Name: UnicodeString;
  Specifier, Options: Integer;
begin
  case Node.Kind of
    nkNumber, nkString, nkNull, nkTrue, nkFalse, nkBigInt, nkRegExp:
      Result := CompileLiteral(Node, Target);
    nkTemplate:
      Result := CompileTemplate(Node, Target);
    nkTaggedTemplate:
      Result := CompileTaggedTemplate(Node, Target);
    nkIdentifier:
      begin
        if (Node.Variable = nil) and (Node.Text = 'undefined') then
        begin
          if Target < 0 then
            Target := AllocateRegister;
          Emit(opLoadUndefined, Target);
          Exit(Target);
        end;
        Result := LoadVariable(Node.Variable, Node.Text, Target, Node);
      end;
    nkThis:
      Result := CompileThis(Node, Target);
    nkArray:
      Result := CompileArray(Node, Target);
    nkObject:
      Result := CompileObject(Node, Target);
    nkFunction:
      begin
        if HasPendingName then
        begin
          Name := PendingName;
          HasPendingName := False;
          Result := CompileFunctionNode(Node, Target, Name, True);
        end
        else
          Result := CompileFunctionNode(Node, Target, '', False);
      end;
    nkClass:
      Result := CompileClass(Node, Target, '');
    nkMember:
      Result := CompileMember(Node, Target);
    nkSuperMember:
      Result := CompileSuperMember(Node, Target);
    nkCall:
      Result := CompileCall(Node, Target);
    nkNew:
      Result := CompileNew(Node, Target);
    nkSuperCall:
      Result := CompileSuperCall(Node, Target);
    nkUnary:
      Result := CompileUnary(Node, Target);
    nkUpdate:
      Result := CompileUpdate(Node, Target, False);
    nkBinary:
      Result := CompileBinary(Node, Target);
    nkLogical:
      Result := CompileLogical(Node, Target);
    nkAssign:
      Result := CompileAssign(Node, Target, False);
    nkConditional:
      Result := CompileConditional(Node, Target);
    nkSequence:
      Result := CompileSequence(Node, Target);
    nkOptionalChain:
      Result := CompileOptionalChain(Node, Target);
    nkYield:
      Result := CompileYield(Node, Target);
    nkAwait:
      Result := CompileAwait(Node, Target);
    nkNewTarget:
      begin
        if Node.Variable <> nil then
          Result := LoadVariable(Node.Variable, '%newtarget', Target, nil)
        else
        begin
          if Target < 0 then
            Target := AllocateRegister;
          Emit(opLoadNewTarget, Target);
          Result := Target;
        end;
      end;
    nkPrivateIn:
      begin
        if Target < 0 then
          Target := AllocateRegister;
        Name := '';
        Result := Target;
        Target := FNextRegister;
        Emit(opPrivateIn, Result, LoadVariable(Node.A.Variable, Node.A.Text, -1, Node.A), Expression(Node.B, -1));
        ReleaseTo(Target);
      end;
    nkSpread:
      raise EJsSyntaxError.CreateAt('Unexpected spread', Node.Line, Node.Column);
    nkDynamicImport:
      begin
        if Target < 0 then
          Target := AllocateRegister;
        Result := Target;
        Target := FNextRegister;
        Specifier := AllocateRegister;
        ExpressionInto(Node.A, Specifier);
        Options := -1;
        if Node.B <> nil then
        begin
          Options := AllocateRegister;
          ExpressionInto(Node.B, Options);
        end;
        Emit(opImportCall, Result, Specifier, Options);
        ReleaseTo(Target);
      end;
    nkImportMeta:
      begin
        if Target < 0 then
          Target := AllocateRegister;
        Emit(opImportMeta, Target);
        Result := Target;
      end;
  else
    raise EJsSyntaxError.CreateAt('Unsupported expression', Node.Line, Node.Column);
  end;
end;

function TJsExpressionCompiler.CompileLiteral(Node: TJsNode; Target: Integer): Integer;
var
  Integer32: LongInt;
  Value: TJsBigInt;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  case Node.Kind of
    nkNumber:
      if DoubleIsInt32(Node.Number, Integer32) then
        Emit(opLoadInteger, Target, Integer32)
      else
        Emit(opLoadConstant, Target, NumberConstant(Node.Number));
    nkString:
      Emit(opLoadConstant, Target, StringConstant(Node.Text));
    nkNull:
      Emit(opLoadNull, Target);
    nkTrue:
      Emit(opLoadTrue, Target);
    nkFalse:
      Emit(opLoadFalse, Target);
    nkBigInt:
      begin
        Value := BigIntFromText(Heap, string(Node.Text), Trunc(Node.Number), False);
        if Value = nil then
          raise EJsSyntaxError.CreateAt('Invalid BigInt literal', Node.Line, Node.Column);
        Emit(opLoadConstant, Target, ValueConstant(JsCellValue(JsBigIntBase, Value)));
      end;
    nkRegExp:
      Emit(opRegExp, Target, ValueConstant(JsStringValue(NewStringFromUnicode(Heap, Node.Text))),
        ValueConstant(JsStringValue(NewStringFromUnicode(Heap, Node.Name))));
  end;
end;

function TJsExpressionCompiler.CompileTemplate(Node: TJsNode; Target: Integer): Integer;
var
  Index, Mark, Piece: Integer;
  Started: Boolean;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Emit(opLoadConstant, Target, StringConstant(Node.List[0].Text));
  Started := True;
  for Index := 1 to Node.Count - 1 do
  begin
    if Odd(Index) then
    begin
      Piece := Expression(Node.List[Index], -1);
      Emit(opTemplateAppend, Target, Piece);
    end
    else if Node.List[Index].Text <> '' then
    begin
      Piece := AllocateRegister;
      Emit(opLoadConstant, Piece, StringConstant(Node.List[Index].Text));
      Emit(opTemplateAppend, Target, Piece);
    end;
    ReleaseTo(Mark);
  end;
  if not Started then
    Emit(opToString, Target, Target);
end;

function TJsExpressionCompiler.CompileTaggedTemplate(Node: TJsNode; Target: Integer): Integer;
var
  Template: TJsNode;
  Strings, Raws: TJsArray;
  Index, Base, Count, Mark: Integer;
  R: TJsRealm;
  Piece: TJsNode;
  Callee: TJsNode;
begin
  R := FContext.Realm;
  Template := Node.B;
  Strings := R.NewArray(0);
  Raws := R.NewArray(0);
  Index := 0;
  while Index < Template.Count do
  begin
    Piece := Template.List[Index];
    if Piece.Flags = 1 then
      Strings.Put(R, JsInteger(Index div 2), JsUndefined)
    else
      Strings.Put(R, JsInteger(Index div 2), JsStringValue(NewStringFromUnicode(Heap, Piece.Text)));
    Raws.Put(R, JsInteger(Index div 2), JsStringValue(NewStringFromUnicode(Heap, Piece.Name)));
    Inc(Index, 2);
  end;
  Raws.PreventExtensions(R);
  Raws.ObjectFlags := Raws.ObjectFlags or ObjectElementsFrozen or ObjectElementsSealed or ObjectLengthReadOnly;
  Strings.DefineData(R, R.Atom(anRaw), JsObjectValue(Raws), 0);
  Strings.PreventExtensions(R);
  Strings.ObjectFlags := Strings.ObjectFlags or ObjectElementsFrozen or ObjectElementsSealed or ObjectLengthReadOnly;
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Count := Template.Count div 2 + 1;
  Base := AllocateRegisters(2 + Count);
  Callee := Node.A;
  if Callee.Kind = nkMember then
  begin
    ExpressionInto(Callee.A, Base + 1);
    if (Callee.Flags and MemberFlagComputed) <> 0 then
      Emit(opGetIndex, Base, Base + 1, Expression(Callee.B, -1))
    else
      Emit(opGetNamed, Base, Base + 1, AtomConstant(Callee.Text), NewCache);
  end
  else
  begin
    ExpressionInto(Callee, Base);
    Emit(opLoadUndefined, Base + 1);
  end;
  Emit(opLoadConstant, Base + 2, ValueConstant(JsObjectValue(Strings)));
  Index := 1;
  while Index < Template.Count do
  begin
    ExpressionInto(Template.List[Index], Base + 2 + (Index + 1) div 2);
    Inc(Index, 2);
  end;
  NoteLine(Node);
  Emit(opCall, Target, Base, Count);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileArray(Node: TJsNode; Target: Integer): Integer;
var
  Index, Mark, Value: Integer;
  Element: TJsNode;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Emit(opNewArray, Target, Node.Count);
  for Index := 0 to Node.Count - 1 do
  begin
    Element := Node.List[Index];
    case Element.Kind of
      nkHole:
        Emit(opArrayHole, Target);
      nkSpread:
        begin
          Value := Expression(Element.A, -1);
          Emit(opArraySpread, Target, Value);
        end;
    else
      Value := Expression(Element, -1);
      Emit(opArrayPush, Target, Value);
    end;
    ReleaseTo(Mark);
  end;
end;

function TJsExpressionCompiler.CompileKey(Node: TJsNode; Computed: Boolean; Target: Integer): Integer;
begin
  if Computed then
  begin
    Result := Expression(Node, Target);
    if Target < 0 then
    begin
      Target := AllocateRegister;
      Emit(opToPropertyKey, Target, Result);
      Exit(Target);
    end;
    Emit(opToPropertyKey, Target, Target);
    Exit(Target);
  end;
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  case Node.Kind of
    nkNumber:
      if NumberIsIndex(Node.Number) then
        Emit(opLoadInteger, Target, Trunc(Node.Number))
      else
      begin
        Emit(opLoadConstant, Target, NumberConstant(Node.Number));
        Emit(opToPropertyKey, Target, Target);
      end;
    nkBigInt:
      begin
        CompileLiteral(Node, Target);
        Emit(opToPropertyKey, Target, Target);
      end;
    nkString:
      begin
        Emit(opLoadConstant, Target, StringConstant(Node.Text));
        Emit(opToPropertyKey, Target, Target);
      end;
  else
    Emit(opLoadConstant, Target, StringConstant(Node.Text));
  end;
end;

function TJsExpressionCompiler.CompileObject(Node: TJsNode; Target: Integer): Integer;
var
  Index, Mark, Value, Key: Integer;
  Property_: TJsNode;
  Name: UnicodeString;
  Flags: Integer;
  Computed: Boolean;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Emit(opNewObject, Target);
  for Index := 0 to Node.Count - 1 do
  begin
    Property_ := Node.List[Index];
    Flags := Property_.Flags;
    Computed := (Flags and PropertyFlagComputed) <> 0;
    if (Flags and PropertyFlagSpread) <> 0 then
    begin
      Value := Expression(Property_.A, -1);
      Emit(opCopyDataProperties, Target, Value, -1);
    end
    else if (Flags and (PropertyFlagMethod or PropertyFlagGetter or PropertyFlagSetter)) <> 0 then
    begin
      Key := CompileKey(Property_.A, Computed, -1);
      if Computed or not KeyIsName(Property_.A, Name) then
        Name := '';
      Value := CompileFunctionNode(Property_.B, -1, Name, not Computed);
      Emit(opSetHome, Value, Target);
      if Computed then
        Emit(opSetFunctionName, Value, Key, Ord((Flags and PropertyFlagGetter) <> 0) +
          2 * Ord((Flags and PropertyFlagSetter) <> 0));
      if (Flags and PropertyFlagGetter) <> 0 then
        Emit(opDefineGetter, Target, Key, Value, 1)
      else if (Flags and PropertyFlagSetter) <> 0 then
        Emit(opDefineSetter, Target, Key, Value, 1)
      else
        Emit(opDefineMethod, Target, Key, Value, 1);
    end
    else if (Flags and PropertyFlagProto) <> 0 then
    begin
      Value := Expression(Property_.B, -1);
      Emit(opSetPrototypeLiteral, Target, Value);
    end
    else if (not Computed) and KeyIsName(Property_.A, Name) then
    begin
      Value := NamedExpression(Property_.B, -1, Name);
      Emit(opDefineField, Target, AtomConstant(Name), Value, NewCache);
    end
    else
    begin
      Key := CompileKey(Property_.A, Computed, -1);
      if IsAnonymousDefinition(Property_.B) then
      begin
        Value := NamedExpression(Property_.B, -1, '');
        if Computed or (Property_.A.Kind <> nkString) then
          Emit(opSetFunctionName, Value, Key, 0);
      end
      else
        Value := Expression(Property_.B, -1);
      Emit(opDefineIndex, Target, Key, Value);
    end;
    ReleaseTo(Mark);
  end;
end;

function TJsExpressionCompiler.CompilePrivateName(Node: TJsNode; Target: Integer): Integer;
begin
  Result := LoadVariable(Node.Variable, Node.Text, Target, nil);
end;

function TJsExpressionCompiler.CompileMember(Node: TJsNode; Target: Integer): Integer;
var
  Mark, ObjectRegister, Key: Integer;
  Name: UnicodeString;
  KeyValue: Double;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  ObjectRegister := Expression(Node.A, -1);
  if (Node.Flags and MemberFlagOptional) <> 0 then
    OptionalExit(ObjectRegister);
  NoteLine(Node);
  if (Node.Flags and MemberFlagPrivate) <> 0 then
    Emit(opGetPrivate, Target, ObjectRegister, CompilePrivateName(Node.B, -1))
  else if (Node.Flags and MemberFlagComputed) = 0 then
  begin
    if Node.Text = 'length' then
      Emit(opGetLength, Target, ObjectRegister, NewCache)
    else
      Emit(opGetNamed, Target, ObjectRegister, AtomConstant(Node.Text), NewCache);
  end
  else if (Node.B.Kind = nkString) and KeyIsName(Node.B, Name) then
    Emit(opGetNamed, Target, ObjectRegister, AtomConstant(Name), NewCache)
  else
  begin
    if (Node.B.Kind = nkNumber) then
    begin
      KeyValue := Node.B.Number;
      Key := AllocateRegister;
      if NumberIsIndex(KeyValue) then
        Emit(opLoadInteger, Key, Trunc(KeyValue))
      else
        Emit(opLoadConstant, Key, NumberConstant(KeyValue));
    end
    else
      Key := Expression(Node.B, -1);
    Emit(opGetIndex, Target, ObjectRegister, Key);
  end;
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.LoadThis(Owner: TJsScope; Variable: TJsVariable; Target: Integer;
  Reference: TJsNode): Integer;
begin
  if Variable = nil then
  begin
    if (Target < 0) or (Target = -1) then
      Exit(-1);
    Emit(opMove, Target, -1);
    Exit(Target);
  end;
  Result := LoadVariable(Variable, 'this', Target, Reference);
end;

function TJsExpressionCompiler.CompileThis(Node: TJsNode; Target: Integer): Integer;
begin
  if Node.Variable = nil then
  begin
    if Target < 0 then
      Exit(-1);
    Emit(opMove, Target, -1);
    Exit(Target);
  end;
  { this in a derived constructor before super() is in its dead zone. }
  Result := LoadVariable(Node.Variable, 'this', Target, nil);
end;

function TJsExpressionCompiler.CompileSuperMember(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Key: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  if Node.A <> nil then
    Key := CompileKey(Node.A, True, -1)
  else
  begin
    Key := AllocateRegister;
    Emit(opLoadConstant, Key, AtomConstant(Node.Text));
  end;
  EmitGetSuper(Node, Target, Key);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.LoadHomeObject(Node: TJsNode): Integer;
begin
  if IsCurrentFunction(Node.Scope) then
  begin
    Result := AllocateRegister;
    Emit(opLoadHome, Result);
  end
  else
    Result := LoadVariable(Node.Scope.Func.HomeVariable, '%home', -1, nil);
end;

procedure TJsExpressionCompiler.EmitGetSuper(Node: TJsNode; Target, Key: Integer);
var
  Mark, Receiver, Home: Integer;
begin
  Mark := FNextRegister;
  Receiver := LoadThis(Node.Scope, Node.Variable, -1, nil);
  Home := LoadHomeObject(Node);
  Emit(opGetSuper, Target, Receiver, Key, Home);
  ReleaseTo(Mark);
end;

procedure TJsExpressionCompiler.CompileArguments(Node: TJsNode; Base: Integer; out Count: Integer;
  out SpreadArray: Integer);
var
  Index, Mark, Value: Integer;
  HasSpread: Boolean;
  Argument: TJsNode;
begin
  HasSpread := False;
  for Index := 0 to Node.Count - 1 do
    if Node.List[Index].Kind = nkSpread then
      HasSpread := True;
  Count := Node.Count;
  SpreadArray := -1;
  if HasSpread then
  begin
    SpreadArray := AllocateRegister;
    Emit(opNewArray, SpreadArray, Node.Count);
    Mark := FNextRegister;
    for Index := 0 to Node.Count - 1 do
    begin
      Argument := Node.List[Index];
      if Argument.Kind = nkSpread then
        Emit(opArraySpread, SpreadArray, Expression(Argument.A, -1))
      else
      begin
        Value := Expression(Argument, -1);
        Emit(opArrayPush, SpreadArray, Value);
      end;
      ReleaseTo(Mark);
    end;
    Exit;
  end;
  AllocateRegisters(Node.Count);
  for Index := 0 to Node.Count - 1 do
  begin
    Mark := FNextRegister;
    ExpressionInto(Node.List[Index], Base + Index);
    ReleaseTo(Mark);
  end;
end;

function TJsExpressionCompiler.CompileCall(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Base, Count, SpreadArray, Key: Integer;
  Callee: TJsNode;
  Name: UnicodeString;
  IsMethod: Boolean;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Base := AllocateRegisters(2);
  Callee := Node.A;
  IsMethod := True;
  if Callee.Kind = nkMember then
  begin
    ExpressionInto(Callee.A, Base + 1);
    if (Callee.Flags and MemberFlagOptional) <> 0 then
      OptionalExit(Base + 1);
    NoteLine(Callee);
    if (Callee.Flags and MemberFlagPrivate) <> 0 then
      Emit(opGetPrivate, Base, Base + 1, CompilePrivateName(Callee.B, -1))
    else if (Callee.Flags and MemberFlagComputed) = 0 then
      Emit(opGetNamed, Base, Base + 1, AtomConstant(Callee.Text), NewCache)
    else if KeyIsName(Callee.B, Name) and (Callee.B.Kind = nkString) then
      Emit(opGetNamed, Base, Base + 1, AtomConstant(Name), NewCache)
    else
    begin
      Key := Expression(Callee.B, -1);
      Emit(opGetIndex, Base, Base + 1, Key);
    end;
    ReleaseTo(Base + 2);
  end
  else if Callee.Kind = nkSuperMember then
  begin
    if Callee.A <> nil then
      Key := CompileKey(Callee.A, True, -1)
    else
    begin
      Key := AllocateRegister;
      Emit(opLoadConstant, Key, AtomConstant(Callee.Text));
    end;
    LoadThis(Callee.Scope, Callee.Variable, Base + 1, nil);
    EmitGetSuper(Callee, Base, Key);
    ReleaseTo(Base + 2);
  end
  else
  begin
    IsMethod := False;
    ExpressionInto(Callee, Base);
    Emit(opLoadUndefined, Base + 1);
    ReleaseTo(Base + 2);
  end;
  if (Node.Flags and MemberFlagOptional) <> 0 then
    OptionalExit(Base);
  CompileArguments(Node, Base + 2, Count, SpreadArray);
  NoteLine(Node);
  if SpreadArray >= 0 then
    Emit(opCallSpread, Target, Base, SpreadArray)
  else if IsMethod then
    Emit(opCallMethod, Target, Base, Count)
  else
    Emit(opCall, Target, Base, Count);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileNew(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Base, Count, SpreadArray: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Base := AllocateRegisters(2);
  ExpressionInto(Node.A, Base);
  ReleaseTo(Base + 2);
  CompileArguments(Node, Base + 2, Count, SpreadArray);
  NoteLine(Node);
  if SpreadArray >= 0 then
    Emit(opNewSpread, Target, Base, SpreadArray)
  else
    Emit(opNew, Target, Base, Count);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileSuperCall(Node: TJsNode; Target: Integer): Integer;
var
  Mark, FunctionRegister, NewTargetRegister, Base, Count, SpreadArray, Current: Integer;
  Info: TJsFunctionInfo;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Info := Node.Scope.Func;
  FunctionRegister := AllocateRegister;
  NewTargetRegister := AllocateRegister;
  if IsCurrentFunction(Node.Scope) then
  begin
    Emit(opLoadCallee, FunctionRegister);
    Emit(opLoadNewTarget, NewTargetRegister);
  end
  else
  begin
    LoadVariable(Info.FunctionVariable, '%function', FunctionRegister, nil);
    LoadVariable(Info.NewTargetVariable, '%newtarget', NewTargetRegister, nil);
  end;
  Base := FNextRegister;
  CompileArguments(Node, Base, Count, SpreadArray);
  NoteLine(Node);
  if SpreadArray >= 0 then
    Emit(opSuperCallSpread, Target, FunctionRegister, NewTargetRegister, SpreadArray)
  else
    Emit(opSuperCall, Target, FunctionRegister, NewTargetRegister, Base, Count);
  { this is bound once. }
  Current := AllocateRegister;
  if Node.Variable.Captured then
    Emit(opGetEnvironment, Current, EnvironmentHops(Node.Variable.Scope), Node.Variable.Index)
  else
    Emit(opMove, Current, Node.Variable.Index);
  Emit(opThrowIfNotHole, Current);
  StoreVariable(Node.Variable, '%this', Target, True);
  Emit(opRunClassFields, Target, FunctionRegister);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileUnary(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Value, ObjectRegister, Key: Integer;
  Operand: TJsNode;
  Name: UnicodeString;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Operand := Node.A;
  case Node.Op of
    tkTypeof:
      if (Operand.Kind = nkIdentifier) and (Operand.Variable = nil) then
        Emit(opTypeofGlobal, Target, AtomConstant(Operand.Text))
      else
        Emit(opTypeof, Target, Expression(Operand, -1));
    tkDelete:
      case Operand.Kind of
        nkIdentifier:
          if Operand.Variable = nil then
            Emit(opDeleteGlobal, Target, AtomConstant(Operand.Text))
          else
            Emit(opLoadFalse, Target);
        nkMember:
          begin
            ObjectRegister := Expression(Operand.A, -1);
            if (Operand.Flags and MemberFlagOptional) <> 0 then
              OptionalExit(ObjectRegister);
            if (Operand.Flags and MemberFlagComputed) = 0 then
              Emit(opDeleteNamed, Target, ObjectRegister, AtomConstant(Operand.Text))
            else if (Operand.B.Kind = nkString) and KeyIsName(Operand.B, Name) then
              Emit(opDeleteNamed, Target, ObjectRegister, AtomConstant(Name))
            else
            begin
              Key := Expression(Operand.B, -1);
              Emit(opDeleteIndex, Target, ObjectRegister, Key);
            end;
          end;
        nkSuperMember:
          begin
            Emit(opThrowReference, AtomConstant('Unsupported reference to ''super'''));
            Emit(opLoadTrue, Target);
          end;
        nkOptionalChain:
          begin
            { delete a?.b: true when a is nullish. }
            SetLength(FOptionalExits, FOptionalDepth + 1);
            FOptionalExits[FOptionalDepth] := nil;
            Inc(FOptionalDepth);
            Operand := Operand.A;
            ObjectRegister := Expression(Operand.A, -1);
            if (Operand.Flags and MemberFlagOptional) <> 0 then
              OptionalExit(ObjectRegister);
            if (Operand.Flags and MemberFlagComputed) = 0 then
              Emit(opDeleteNamed, Target, ObjectRegister, AtomConstant(Operand.Text))
            else
              Emit(opDeleteIndex, Target, ObjectRegister, Expression(Operand.B, -1));
            Dec(FOptionalDepth);
            Value := EmitJump;
            PatchAll(FOptionalExits[FOptionalDepth], Here);
            Emit(opLoadTrue, Target);
            PatchHere(Value);
          end;
      else
        ExpressionDiscard(Operand);
        Emit(opLoadTrue, Target);
      end;
    tkVoid:
      begin
        ExpressionDiscard(Operand);
        Emit(opLoadUndefined, Target);
      end;
    tkBang:
      Emit(opNot, Target, Expression(Operand, -1));
    tkMinus:
      if (Operand.Kind = nkNumber) then
      begin
        Operand.Number := -Operand.Number;
        CompileLiteral(Operand, Target);
        Operand.Number := -Operand.Number;
      end
      else
        Emit(opNegate, Target, Expression(Operand, -1));
    tkPlus:
      Emit(opPlus, Target, Expression(Operand, -1));
    tkTilde:
      Emit(opBitNot, Target, Expression(Operand, -1));
  end;
  ReleaseTo(Mark);
end;

{ Stores Value to a member target whose object (and key) are already in
  registers. }
procedure TJsExpressionCompiler.StoreToMember(Member: TJsNode; ObjectRegister, KeyRegister, Value: Integer);
var
  Name: UnicodeString;
begin
  NoteLine(Member);
  if Member.Kind = nkSuperMember then
  begin
    Emit(opSetSuper, LoadThis(Member.Scope, Member.Variable, -1, nil), KeyRegister, Value, LoadHomeObject(Member));
    Exit;
  end;
  if (Member.Flags and MemberFlagPrivate) <> 0 then
    Emit(opSetPrivate, ObjectRegister, KeyRegister, Value)
  else if (Member.Flags and MemberFlagComputed) = 0 then
    Emit(opSetNamed, ObjectRegister, AtomConstant(Member.Text), Value, NewCache)
  else if (Member.B.Kind = nkString) and KeyIsName(Member.B, Name) then
    Emit(opSetNamed, ObjectRegister, AtomConstant(Name), Value, NewCache)
  else
    Emit(opSetIndex, ObjectRegister, KeyRegister, Value);
end;

function TJsExpressionCompiler.CompileUpdate(Node: TJsNode; Target: Integer; Discard: Boolean): Integer;
var
  Mark, Old, NewValue, ObjectRegister, Key: Integer;
  Operand: TJsNode;
  Opcode: TJsOpcode;
  Prefix: Boolean;
  Name: UnicodeString;
begin
  Operand := Node.A;
  if Node.Op = tkPlusPlus then
    Opcode := opIncrement
  else
    Opcode := opDecrement;
  Prefix := (Node.Flags and UpdateFlagPrefix) <> 0;
  if (Operand.Kind = nkIdentifier) and (Operand.Variable <> nil) and not Operand.Variable.Captured and not Operand.Variable.IsGlobal and
    not DeclarationIsConstant(Operand.Variable) and not NeedsTdzCheck(Operand.Variable, Operand) and
    (Operand.Variable.Kind <> dkImplicit) then
  begin
    { A local in a register: in place. }
    if Discard then
    begin
      Emit(Opcode, Operand.Variable.Index, Operand.Variable.Index);
      Exit(-1);
    end;
    if Target < 0 then
      Target := AllocateRegister;
    if Prefix then
    begin
      Emit(Opcode, Operand.Variable.Index, Operand.Variable.Index);
      Emit(opMove, Target, Operand.Variable.Index);
    end
    else
    begin
      Emit(opToNumeric, Target, Operand.Variable.Index);
      Emit(Opcode, Operand.Variable.Index, Target);
    end;
    Exit(Target);
  end;
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  NewValue := AllocateRegister;
  ObjectRegister := -1;
  Key := -1;
  case Operand.Kind of
    nkIdentifier:
      Old := LoadVariable(Operand.Variable, Operand.Text, -1, Operand);
    nkMember:
      begin
        ObjectRegister := Expression(Operand.A, -1);
        if (Operand.Flags and MemberFlagPrivate) <> 0 then
        begin
          Key := CompilePrivateName(Operand.B, -1);
          Old := AllocateRegister;
          Emit(opGetPrivate, Old, ObjectRegister, Key);
        end
        else if ((Operand.Flags and MemberFlagComputed) = 0) or ((Operand.B.Kind = nkString) and
          KeyIsName(Operand.B, Name)) then
        begin
          if (Operand.Flags and MemberFlagComputed) = 0 then
            Name := Operand.Text;
          Old := AllocateRegister;
          Emit(opGetNamed, Old, ObjectRegister, AtomConstant(Name), NewCache);
        end
        else
        begin
          Key := AllocateRegister;
          ExpressionInto(Operand.B, Key);
          Emit(opToPropertyKey, Key, Key);
          Old := AllocateRegister;
          Emit(opGetIndex, Old, ObjectRegister, Key);
        end;
      end;
    nkSuperMember:
      begin
        if Operand.A <> nil then
          Key := CompileKey(Operand.A, True, -1)
        else
        begin
          Key := AllocateRegister;
          Emit(opLoadConstant, Key, AtomConstant(Operand.Text));
        end;
        Old := AllocateRegister;
        EmitGetSuper(Operand, Old, Key);
      end;
  else
    raise EJsSyntaxError.CreateAt('Invalid left-hand side expression', Node.Line, Node.Column);
  end;
  Emit(opToNumeric, Target, Old);
  Emit(Opcode, NewValue, Target);
  if Operand.Kind = nkIdentifier then
    StoreVariable(Operand.Variable, Operand.Text, NewValue, False, Operand)
  else
    StoreToMember(Operand, ObjectRegister, Key, NewValue);
  if Prefix then
    Emit(opMove, Target, NewValue);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.BinaryOpcode(Kind: TJsTokenKind): TJsOpcode;
begin
  case Kind of
    tkPlus, tkPlusAssign: Result := opAdd;
    tkMinus, tkMinusAssign: Result := opSubtract;
    tkStar, tkStarAssign: Result := opMultiply;
    tkSlash, tkSlashAssign: Result := opDivide;
    tkPercent, tkPercentAssign: Result := opModulo;
    tkStarStar, tkStarStarAssign: Result := opExponent;
    tkAmpersand, tkAmpersandAssign: Result := opBitAnd;
    tkBar, tkBarAssign: Result := opBitOr;
    tkCaret, tkCaretAssign: Result := opBitXor;
    tkShiftLeft, tkShiftLeftAssign: Result := opShiftLeft;
    tkShiftRight, tkShiftRightAssign: Result := opShiftRight;
    tkShiftRightUnsigned, tkShiftRightUnsignedAssign: Result := opShiftRightUnsigned;
    tkEqual: Result := opEqual;
    tkNotEqual: Result := opNotEqual;
    tkStrictEqual: Result := opStrictEqual;
    tkStrictNotEqual: Result := opStrictNotEqual;
    tkLess: Result := opLess;
    tkLessEqual: Result := opLessEqual;
    tkGreater: Result := opGreater;
    tkGreaterEqual: Result := opGreaterEqual;
    tkInstanceof: Result := opInstanceof;
    tkIn: Result := opIn;
  else
    Result := opNop;
  end;
end;

function TJsExpressionCompiler.CompileBinary(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Left, Right, Copy: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Left := Expression(Node.A, -1);
  if IsLocalRegister(Left) and not IsSimple(Node.B) then
  begin
    { The right side might assign the variable. }
    Copy := AllocateRegister;
    Emit(opMove, Copy, Left);
    Left := Copy;
  end;
  Right := Expression(Node.B, -1);
  NoteLine(Node);
  Emit(BinaryOpcode(Node.Op), Target, Left, Right);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileLogical(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Skip: Integer;
begin
  if (Target < 0) or IsLocalRegister(Target) then
    Result := AllocateRegister
  else
    Result := Target;
  Mark := FNextRegister;
  ExpressionInto(Node.A, Result);
  case Node.Op of
    tkAndAnd: Skip := EmitJumpIf(opJumpIfFalse, Result);
    tkOrOr: Skip := EmitJumpIf(opJumpIfTrue, Result);
  else
    Skip := EmitJumpIf(opJumpIfNotNullish, Result);
  end;
  ExpressionInto(Node.B, Result);
  PatchHere(Skip);
  ReleaseTo(Mark);
  if (Target >= 0) and (Target <> Result) then
  begin
    Emit(opMove, Target, Result);
    Result := Target;
  end;
end;

function TJsExpressionCompiler.CompileConditional(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Skip: Integer;
  ElsePatches: TJsPatchList;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  ElsePatches := nil;
  Branch(Node.A, False, ElsePatches);
  ReleaseTo(Mark);
  ExpressionInto(Node.B, Target);
  ReleaseTo(Mark);
  Skip := EmitJump;
  PatchAll(ElsePatches, Here);
  ExpressionInto(Node.C, Target);
  PatchHere(Skip);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileSequence(Node: TJsNode; Target: Integer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to Node.Count - 2 do
    ExpressionDiscard(Node.List[Index]);
  if Target = -1 then
    Result := Expression(Node.List[Node.Count - 1], -1)
  else
  begin
    ExpressionInto(Node.List[Node.Count - 1], Target);
    Result := Target;
  end;
end;

function TJsExpressionCompiler.CompileOptionalChain(Node: TJsNode; Target: Integer): Integer;
var
  Skip, Mark: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  if FOptionalDepth >= Length(FOptionalExits) then
    SetLength(FOptionalExits, FOptionalDepth + 4);
  FOptionalExits[FOptionalDepth] := nil;
  Inc(FOptionalDepth);
  ExpressionInto(Node.A, Target);
  Dec(FOptionalDepth);
  Skip := EmitJump;
  PatchAll(FOptionalExits[FOptionalDepth], Here);
  Emit(opLoadUndefined, Target);
  PatchHere(Skip);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileYield(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Value, Iterator: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  if (Node.Flags and YieldFlagDelegate) <> 0 then
  begin
    Iterator := AllocateRegisters(2);
    Value := Expression(Node.A, -1);
    Emit(opGetIterator, Iterator, Value, Ord(FInfo.IsAsync));
    Emit(opLoadUndefined, Target);
    Emit(opYieldDelegate, Target, Iterator);
    ReleaseTo(Mark);
    Exit;
  end;
  if Node.A <> nil then
    Value := Expression(Node.A, -1)
  else
  begin
    Value := AllocateRegister;
    Emit(opLoadUndefined, Value);
  end;
  if FInfo.IsAsync then
    Emit(opAsyncGeneratorYield, Target, Value)
  else
    Emit(opYield, Target, Value);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileAwait(Node: TJsNode; Target: Integer): Integer;
var
  Mark, Value: Integer;
begin
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  Value := Expression(Node.A, -1);
  NoteLine(Node);
  Emit(opAwait, Target, Value);
  ReleaseTo(Mark);
end;

function TJsExpressionCompiler.CompileAssign(Node: TJsNode; Target: Integer; Discard: Boolean): Integer;
var
  Mark, Value, ObjectRegister, Key, Current, Skip: Integer;
  Left: TJsNode;
  Variable: TJsVariable;
  Name: UnicodeString;
  Logical: Boolean;
  JumpOpcode: TJsOpcode;
begin
  Left := Node.A;
  Mark := FNextRegister;
  { Plain assignment to a local register: straight into it. }
  if (Node.Op = tkAssign) and (Left.Kind = nkIdentifier) then
  begin
    Variable := Left.Variable;
    if (Variable <> nil) and not Variable.Captured and not Variable.IsGlobal and not DeclarationIsConstant(Variable) and
      not NeedsTdzCheck(Variable, Left) and (Variable.Kind <> dkImplicit) and WritesTargetLast(Node.B) then
    begin
      Value := NamedExpression(Node.B, Variable.Index, Left.Text);
      if Value <> Variable.Index then
        Emit(opMove, Variable.Index, Value);
      ReleaseTo(Mark);
      if Discard then
        Exit(-1);
      if Target < 0 then
        Exit(Variable.Index);
      Emit(opMove, Target, Variable.Index);
      Exit(Target);
    end;
    if Target < 0 then
      Target := AllocateRegister;
    Mark := FNextRegister;
    Value := NamedExpression(Node.B, Target, Left.Text);
    if Value <> Target then
      Emit(opMove, Target, Value);
    StoreVariable(Variable, Left.Text, Target, False, Left);
    ReleaseTo(Mark);
    Exit(Target);
  end;
  if Target < 0 then
    Target := AllocateRegister;
  Result := Target;
  Mark := FNextRegister;
  if Left.Kind in [nkArrayPattern, nkObjectPattern] then
  begin
    ExpressionInto(Node.B, Target);
    BindPattern(Left, Target, bmAssign);
    ReleaseTo(Mark);
    Exit;
  end;
  Logical := Node.Op in [tkAndAndAssign, tkOrOrAssign, tkQuestionQuestionAssign];
  ObjectRegister := -1;
  Key := -1;
  Current := -1;
  { The reference: object and key first. }
  case Left.Kind of
    nkIdentifier:
      if Node.Op <> tkAssign then
        Current := LoadVariable(Left.Variable, Left.Text, -1, Left);
    nkMember:
      begin
        ObjectRegister := Expression(Left.A, -1);
        if IsLocalRegister(ObjectRegister) then
        begin
          Value := AllocateRegister;
          Emit(opMove, Value, ObjectRegister);
          ObjectRegister := Value;
        end;
        if (Left.Flags and MemberFlagPrivate) <> 0 then
          Key := CompilePrivateName(Left.B, -1)
        else if ((Left.Flags and MemberFlagComputed) <> 0) and not ((Left.B.Kind = nkString) and
          KeyIsName(Left.B, Name)) then
        begin
          Key := AllocateRegister;
          ExpressionInto(Left.B, Key);
          if Node.Op <> tkAssign then
            Emit(opToPropertyKey, Key, Key);
        end;
        if Node.Op <> tkAssign then
        begin
          Current := AllocateRegister;
          if (Left.Flags and MemberFlagPrivate) <> 0 then
            Emit(opGetPrivate, Current, ObjectRegister, Key)
          else if Key >= 0 then
            Emit(opGetIndex, Current, ObjectRegister, Key)
          else
          begin
            if (Left.Flags and MemberFlagComputed) = 0 then
              Name := Left.Text;
            Emit(opGetNamed, Current, ObjectRegister, AtomConstant(Name), NewCache);
          end;
        end;
      end;
    nkSuperMember:
      begin
        if Left.A <> nil then
          Key := CompileKey(Left.A, True, -1)
        else
        begin
          Key := AllocateRegister;
          Emit(opLoadConstant, Key, AtomConstant(Left.Text));
        end;
        if Node.Op <> tkAssign then
        begin
          Current := AllocateRegister;
          EmitGetSuper(Left, Current, Key);
        end;
      end;
    nkCall:
      begin
        ExpressionDiscard(Left);
        Emit(opThrowReference, AtomConstant('Invalid left-hand side in assignment'));
        ReleaseTo(Mark);
        Exit;
      end;
  else
    raise EJsSyntaxError.CreateAt('Invalid left-hand side in assignment', Node.Line, Node.Column);
  end;
  Skip := -1;
  if Logical then
  begin
    Emit(opMove, Target, Current);
    case Node.Op of
      tkAndAndAssign: JumpOpcode := opJumpIfFalse;
      tkOrOrAssign: JumpOpcode := opJumpIfTrue;
    else
      JumpOpcode := opJumpIfNotNullish;
    end;
    Skip := EmitJumpIf(JumpOpcode, Target);
    if Left.Kind = nkIdentifier then
      Value := NamedExpression(Node.B, Target, Left.Text)
    else
      Value := Expression(Node.B, Target);
    if Value <> Target then
      Emit(opMove, Target, Value);
  end
  else if Node.Op = tkAssign then
  begin
    Value := Expression(Node.B, Target);
    if Value <> Target then
      Emit(opMove, Target, Value);
  end
  else
  begin
    if IsLocalRegister(Current) and not IsSimple(Node.B) then
    begin
      Value := AllocateRegister;
      Emit(opMove, Value, Current);
      Current := Value;
    end;
    Value := Expression(Node.B, -1);
    NoteLine(Node);
    Emit(BinaryOpcode(Node.Op), Target, Current, Value);
  end;
  if Left.Kind = nkIdentifier then
    StoreVariable(Left.Variable, Left.Text, Target, False, Left)
  else
    StoreToMember(Left, ObjectRegister, Key, Target);
  if Skip >= 0 then
    PatchHere(Skip);
  ReleaseTo(Mark);
end;

{ Conditions }

procedure TJsExpressionCompiler.Branch(Node: TJsNode; WhenTrue: Boolean; var Patches: TJsPatchList);
var
  Local: TJsPatchList;
  Mark, Left, Right, Value, Copy: Integer;
  Opcode: TJsOpcode;
begin
  Mark := FNextRegister;
  case Node.Kind of
    nkTrue:
      begin
        if WhenTrue then
          AddPatch(Patches, EmitJump);
        Exit;
      end;
    nkFalse, nkNull:
      begin
        if not WhenTrue then
          AddPatch(Patches, EmitJump);
        Exit;
      end;
    nkUnary:
      if Node.Op = tkBang then
      begin
        Branch(Node.A, not WhenTrue, Patches);
        Exit;
      end;
    nkLogical:
      if Node.Op = tkAndAnd then
      begin
        if WhenTrue then
        begin
          Local := nil;
          Branch(Node.A, False, Local);
          Branch(Node.B, True, Patches);
          PatchAll(Local, Here);
        end
        else
        begin
          Branch(Node.A, False, Patches);
          Branch(Node.B, False, Patches);
        end;
        Exit;
      end
      else if Node.Op = tkOrOr then
      begin
        if WhenTrue then
        begin
          Branch(Node.A, True, Patches);
          Branch(Node.B, True, Patches);
        end
        else
        begin
          Local := nil;
          Branch(Node.A, True, Local);
          Branch(Node.B, False, Patches);
          PatchAll(Local, Here);
        end;
        Exit;
      end;
    nkBinary:
      if (not WhenTrue) and (Node.Op in [tkLess, tkLessEqual, tkGreater, tkGreaterEqual, tkStrictEqual,
        tkStrictNotEqual]) then
      begin
        case Node.Op of
          tkLess: Opcode := opJumpIfLessFalse;
          tkLessEqual: Opcode := opJumpIfLessEqualFalse;
          tkGreater: Opcode := opJumpIfGreaterFalse;
          tkGreaterEqual: Opcode := opJumpIfGreaterEqualFalse;
          tkStrictEqual: Opcode := opJumpIfStrictEqualFalse;
        else
          Opcode := opJumpIfStrictNotEqualFalse;
        end;
        Left := Expression(Node.A, -1);
        if IsLocalRegister(Left) and not IsSimple(Node.B) then
        begin
          Copy := AllocateRegister;
          Emit(opMove, Copy, Left);
          Left := Copy;
        end;
        Right := Expression(Node.B, -1);
        NoteLine(Node);
        Emit(Opcode, Left, Right, 0);
        AddPatch(Patches, LastOperand);
        ReleaseTo(Mark);
        Exit;
      end;
  end;
  Value := Expression(Node, -1);
  if WhenTrue then
    AddPatch(Patches, EmitJumpIf(opJumpIfTrue, Value))
  else
    AddPatch(Patches, EmitJumpIf(opJumpIfFalse, Value));
  ReleaseTo(Mark);
end;

{ Patterns }

procedure TJsExpressionCompiler.BindPattern(Pattern: TJsNode; Value: Integer; Mode: TJsBindMode);
var
  Mark, Temporary, Skip, Iterator, Index, ObjectRegister, Key, Excluded: Integer;
  Element, Property_, Target: TJsNode;
  Name: UnicodeString;
  HasRest: Boolean;
  Computed: Boolean;
  StartPC, HandlerSkip, HandlerPC, Caught: Integer;
begin
  Mark := FNextRegister;
  case Pattern.Kind of
    nkIdentifier:
      StoreVariable(Pattern.Variable, Pattern.Text, Value, Mode = bmInitialize, Pattern);
    nkMember, nkSuperMember:
      begin
        ObjectRegister := -1;
        Key := -1;
        if Pattern.Kind = nkMember then
        begin
          ObjectRegister := Expression(Pattern.A, -1);
          if (Pattern.Flags and MemberFlagPrivate) <> 0 then
            Key := CompilePrivateName(Pattern.B, -1)
          else if ((Pattern.Flags and MemberFlagComputed) <> 0) and not ((Pattern.B.Kind = nkString) and
            KeyIsName(Pattern.B, Name)) then
            Key := Expression(Pattern.B, -1);
        end
        else if Pattern.A <> nil then
          Key := CompileKey(Pattern.A, True, -1)
        else
        begin
          Key := AllocateRegister;
          Emit(opLoadConstant, Key, AtomConstant(Pattern.Text));
        end;
        StoreToMember(Pattern, ObjectRegister, Key, Value);
      end;
    nkAssignPattern:
      begin
        Temporary := AllocateRegister;
        Emit(opMove, Temporary, Value);
        Skip := EmitJumpIf(opJumpIfNotUndefined, Temporary);
        if Pattern.A.Kind = nkIdentifier then
          NamedExpression(Pattern.B, Temporary, Pattern.A.Text)
        else
          ExpressionInto(Pattern.B, Temporary);
        PatchHere(Skip);
        BindPattern(Pattern.A, Temporary, Mode);
      end;
    nkArrayPattern:
      begin
        Iterator := AllocateRegisters(2);
        NoteLine(Pattern);
        Emit(opGetIterator, Iterator, Value, 0);
        { An exception while binding closes the iterator. }
        StartPC := Here;
        for Index := 0 to Pattern.Count - 1 do
        begin
          Element := Pattern.List[Index];
          Temporary := AllocateRegister;
          if Element.Kind = nkRest then
          begin
            Emit(opIteratorRest, Temporary, Iterator);
            BindPattern(Element.A, Temporary, Mode);
          end
          else
          begin
            Emit(opIteratorNext, Temporary, Iterator, 0);
            Patch(LastOperand, Here);
            if Element.Kind <> nkHole then
              BindPattern(Element, Temporary, Mode);
          end;
          ReleaseTo(Iterator + 2);
        end;
        HandlerSkip := Here;
        Emit(opIteratorClose, Iterator);
        Skip := EmitJump;
        HandlerPC := Here;
        Caught := AllocateRegister;
        Emit(opIteratorCloseQuiet, Iterator);
        Emit(opRethrowCompletion, Caught);
        PatchHere(Skip);
        AddHandler(StartPC, HandlerSkip, HandlerPC, Caught, FEnvironmentDepth, True, []);
      end;
    nkObjectPattern:
      begin
        Emit(opThrowIfNullish, Value, 1);
        HasRest := (Pattern.Count > 0) and (Pattern.List[Pattern.Count - 1].Kind = nkRest);
        Excluded := -1;
        if HasRest then
        begin
          Excluded := AllocateRegister;
          Emit(opNewArray, Excluded, Pattern.Count);
        end;
        for Index := 0 to Pattern.Count - 1 do
        begin
          Property_ := Pattern.List[Index];
          if Property_.Kind = nkRest then
          begin
            Temporary := AllocateRegister;
            Emit(opNewObject, Temporary);
            Emit(opCopyDataProperties, Temporary, Value, Excluded);
            BindPattern(Property_.A, Temporary, Mode);
            Continue;
          end;
          Temporary := AllocateRegister;
          Target := Property_.B;
          Computed := (Property_.Flags and PropertyFlagComputed) <> 0;
          if (not Computed) and KeyIsName(Property_.A, Name) then
          begin
            Emit(opGetNamed, Temporary, Value, AtomConstant(Name), NewCache);
            if HasRest then
            begin
              Key := AllocateRegister;
              Emit(opLoadConstant, Key, AtomConstant(Name));
              Emit(opArrayPush, Excluded, Key);
            end;
          end
          else
          begin
            Key := CompileKey(Property_.A, Computed, -1);
            Emit(opGetIndex, Temporary, Value, Key);
            if HasRest then
              Emit(opArrayPush, Excluded, Key);
          end;
          BindPattern(Target, Temporary, Mode);
          ReleaseTo(Temporary);
        end;
      end;
    nkHole:
      ;
  else
    raise EJsSyntaxError.CreateAt('Invalid destructuring target', Pattern.Line, Pattern.Column);
  end;
  ReleaseTo(Mark);
end;

end.
