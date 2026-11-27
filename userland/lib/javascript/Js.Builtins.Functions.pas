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
  Function: the constructor (compiling source text) and
  Function.prototype: call, apply, bind, toString, Symbol.hasInstance.
}
unit Js.Builtins.Functions;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Lexer,
  Js.Compiler,
  Js.Interpreter;

procedure InstallFunction(R: TJsInterpreterRealm);
{ Function.prototype is itself a function: it takes anything and
  returns undefined. }
function FunctionPrototypeItself(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;

implementation

function FunctionPrototypeCall(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if not JsIsCallable(This) then
    Exit(R.ThrowTypeError('Function.prototype.call called on a non-function'));
  if ArgCount <= 1 then
    Result := R.Call(This, Arg(Args, ArgCount, 0), nil, 0)
  else
    Result := R.Call(This, Args^[0], @Args^[1], ArgCount - 1);
end;

const
  { apply copies a short dense array's elements to the stack. }
  LongestStackArguments = 16;

type
  TStackArguments = array[0..LongestStackArguments - 1] of TJsValue;

{ The elements of a short array without holes (whose length and
  elements are plain data: reading them runs nothing). }
function CopyShortArray(Source: TJsValue; out Buffer: TStackArguments; out Count: Integer): Boolean;
var
  Target: TJsObject;
  Index: Integer;
begin
  Count := 0;
  if not JsIsObject(Source) then
    Exit(False);
  Target := JsAsObject(Source);
  if not (Target is TJsArray) or ((Target.ObjectFlags and (ObjectExotic or ObjectIndexedByName)) <> 0) or
    (LongWord(Target.ElementCount) <> TJsArray(Target).ArrayLength) or
    (Target.ElementCount > LongestStackArguments) then
    Exit(False);
  for Index := 0 to Target.ElementCount - 1 do
  begin
    if Target.Elements^[Index] = JsHole then
      Exit(False);
    Buffer[Index] := Target.Elements^[Index];
  end;
  Count := Target.ElementCount;
  Result := True;
end;

function ApplyArrayLike(R: TJsRealm; F, This, Source: TJsValue): TJsValue;
var
  List: TJsValueList;
begin
  if not CreateListFromArrayLike(R, Source, List) then
    Exit(JsException);
  Result := R.Call(F, This, @List[0], Length(List));
end;

function FunctionPrototypeApply(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Buffer: TStackArguments;
  Count: Integer;
begin
  if not JsIsCallable(This) then
    Exit(R.ThrowTypeError('Function.prototype.apply was called on a non-function'));
  if CopyShortArray(Arg(Args, ArgCount, 1), Buffer, Count) then
    Result := R.Call(This, Arg(Args, ArgCount, 0), @Buffer[0], Count)
  else
    Result := ApplyArrayLike(R, This, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1));
end;

function FunctionPrototypeBind(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Bound: TJsBoundFunction;
  Index: Integer;
  LengthValue, NameValue: TJsValue;
  NewLength: Double;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
  Name: TJsString;
  Prototype: TJsObject;
begin
  if not JsIsCallable(This) then
    Exit(R.ThrowTypeError('Bind must be called on a function'));
  Target := JsAsObject(This);
  if not Target.GetPrototype(R, Prototype) then
    Exit(JsException);
  Bound := TJsBoundFunction(R.NewObjectOfClass(TJsBoundFunction, Prototype, ocFunction));
  Bound.ObjectFlags := Bound.ObjectFlags or ObjectCallable or (Target.ObjectFlags and ObjectConstructor);
  Bound.Target := This;
  Bound.BoundThis := Arg(Args, ArgCount, 0);
  if ArgCount > 1 then
  begin
    SetLength(Bound.BoundArguments, ArgCount - 1);
    for Index := 1 to ArgCount - 1 do
      Bound.BoundArguments[Index - 1] := Args^[Index];
  end;
  NewLength := 0;
  Found := Target.GetOwnProperty(R, R.LengthKey, Desc);
  if Found < 0 then
    Exit(JsException);
  if Found > 0 then
  begin
    LengthValue := Target.GetValue(R, R.LengthKey);
    if LengthValue = JsException then
      Exit(JsException);
    if JsIsNumber(LengthValue) then
    begin
      NewLength := JsNumberValue(LengthValue);
      if IsFiniteDouble(NewLength) then
        NewLength := Int(NewLength);
      NewLength := NewLength - (ArgCount - 1);
      if NewLength < 0 then
        NewLength := 0;
    end;
  end;
  Bound.DefineData(R, R.LengthKey, JsNumber(NewLength), PropertyConfigurable);
  NameValue := Target.GetValue(R, R.Atom(anName));
  if NameValue = JsException then
    Exit(JsException);
  if not JsIsString(NameValue) then
    NameValue := R.Atom(anEmpty);
  Name := ConcatStrings(R.Heap, NewStringFromUtf8(R.Heap, 'bound '), JsAsString(NameValue));
  Bound.DefineData(R, R.Atom(anName), JsStringValue(Name), PropertyConfigurable);
  Result := JsObjectValue(Bound);
end;

function FunctionPrototypeToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Code: TJsCode;
  NameValue: TJsValue;
  Name: string;
begin
  if not JsIsCallable(This) then
    Exit(R.ThrowTypeError('Function.prototype.toString requires that ''this'' be a Function'));
  Target := JsAsObject(This);
  if Target is TJsClosure then
  begin
    Code := TJsClosure(Target).Code;
    if (Code.Source <> nil) and not Code.Source.Builtin and (Code.SourceFinish > Code.SourceStart) then
      Exit(JsStringValue(NewStringFromUnicode(R.Heap, Copy(Code.Source.Text, Code.SourceStart,
        Code.SourceFinish - Code.SourceStart))));
  end;
  Name := '';
  NameValue := Target.GetValue(R, R.Atom(anName));
  if JsIsString(NameValue) then
    Name := StringToUtf8(R.Heap, JsAsString(NameValue));
  Result := R.NewString('function ' + Name + '() { [native code] }');
end;

function FunctionPrototypeHasInstance(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := OrdinaryHasInstance(R, This, Arg(Args, ArgCount, 0));
end;

function FunctionPrototypeItself(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsUndefined;
end;

function ThrowTypeErrorFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := R.ThrowTypeError('''caller'', ''callee'', and ''arguments'' properties may not be accessed on strict ' +
    'mode functions or the arguments objects for calls to them');
end;

{ new Function(p1, p2, ..., body); Magic: 0 normal, 1 generator, 2 async,
  3 async generator. }
function FunctionConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Parameters, Body: UnicodeString;
  Index: Integer;
  Text: TJsString;
  Code: TJsCode;
  Closure: TJsClosure;
  Prototype: TJsObject;
begin
  Parameters := '';
  Body := '';
  for Index := 0 to ArgCount - 2 do
  begin
    Text := ToJsString(R, Args^[Index]);
    if Text = nil then
      Exit(JsException);
    if Index > 0 then
      Parameters := Parameters + ',';
    Parameters := Parameters + StringToUnicode(R.Heap, Text);
  end;
  if ArgCount > 0 then
  begin
    Text := ToJsString(R, Args^[ArgCount - 1]);
    if Text = nil then
      Exit(JsException);
    Body := StringToUnicode(R.Heap, Text);
  end;
  if Assigned(R.CompileStringsCheck) and
     not R.MayCompileStrings('function anonymous(' + Parameters + #10') {'#10 + Body + #10'}') then
    Exit(JsException);
  try
    Code := CompileFunctionSource(R, Parameters, Body, Callee.Magic >= 2, Odd(Callee.Magic));
  except
    on Error: EJsSyntaxError do
      Exit(R.ThrowError(ekSyntax, Error.Message));
  end;
  Closure := TJsInterpreterRealm(R).NewClosure(Code, nil);
  if (NewTarget <> JsUndefined) and (NewTarget <> JsObjectValue(Callee)) then
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inFunctionPrototype);
    if Prototype = nil then
      Exit(JsException);
    Closure.Proto := Prototype;
  end;
  Result := JsObjectValue(Closure);
end;

procedure InstallFunction(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
  Thrower: TJsNativeFunction;
  Hidden: TJsObject;
begin
  Prototype := R.Intrinsics[inFunctionPrototype];
  Prototype.DefineData(R, R.LengthKey, JsInteger(0), PropertyConfigurable);
  Prototype.DefineData(R, R.Atom(anName), R.Atom(anEmpty), PropertyConfigurable);
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Function', @FunctionConstructor, 1, Prototype);
  R.Intrinsics[inFunction] := Constructor_;
  DefineMethod(R, Prototype, 'call', @FunctionPrototypeCall, 1);
  DefineMethod(R, Prototype, 'apply', @FunctionPrototypeApply, 2);
  DefineMethod(R, Prototype, 'bind', @FunctionPrototypeBind, 1);
  DefineMethod(R, Prototype, 'toString', @FunctionPrototypeToString, 0);
  DefineSymbolMethod(R, Prototype, wsHasInstance, '[Symbol.hasInstance]', @FunctionPrototypeHasInstance, 1, 0);
  Thrower := NewNativeFunction(R, '', @ThrowTypeErrorFunction, 0);
  Thrower.PreventExtensions(R);
  R.Intrinsics[inThrowTypeError] := Thrower;
  Prototype.DefineAccessor(R, R.Atom(anCaller), JsObjectValue(Thrower), JsObjectValue(Thrower), PropertyConfigurable);
  Prototype.DefineAccessor(R, R.Atom(anArguments), JsObjectValue(Thrower), JsObjectValue(Thrower),
    PropertyConfigurable);
  { The constructors of generator and async functions (not globals). }
  Hidden := R.Intrinsics[inGeneratorFunctionPrototype];
  Constructor_ := DefineConstructor(R, nil, 'GeneratorFunction', @FunctionConstructor, 1, Hidden);
  Constructor_.Magic := 1;
  Constructor_.Proto := R.Intrinsics[inFunction];
  Hidden := R.Intrinsics[inAsyncFunctionPrototype];
  Constructor_ := DefineConstructor(R, nil, 'AsyncFunction', @FunctionConstructor, 1, Hidden);
  Constructor_.Magic := 2;
  Constructor_.Proto := R.Intrinsics[inFunction];
  Hidden := R.Intrinsics[inAsyncGeneratorFunctionPrototype];
  Constructor_ := DefineConstructor(R, nil, 'AsyncGeneratorFunction', @FunctionConstructor, 1, Hidden);
  Constructor_.Magic := 3;
  Constructor_.Proto := R.Intrinsics[inFunction];
end;

end.
