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
  A new realm's intrinsic objects and its global object.

  The prototypes are made first and linked (Function.prototype is a
  function, Array.prototype an array, String.prototype a String object
  of ""), then each built-in unit installs its constructors and
  methods. The order matters only where one unit uses another's objects.
}
unit Js.Intrinsics;

{$mode objfpc}{$H+}

interface

uses
  Js.Values,
  Js.Atoms,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Interpreter;

procedure CreateIntrinsics(R: TJsInterpreterRealm);

implementation

uses
  Js.Builtins.Objects,
  Js.Builtins.Functions,
  Js.Builtins.Error,
  Js.Builtins.Global,
  Js.Builtins.Symbol,
  Js.Builtins.Arrays,
  Js.Builtins.Iterators,
  Js.Builtins.Strings,
  Js.Builtins.Number,
  Js.Builtins.Math,
  Js.Builtins.Json,
  Js.Builtins.Collections,
  Js.Builtins.Promise,
  Js.Builtins.Generators,
  Js.Builtins.Reflect,
  Js.Builtins.BigInt,
  Js.Builtins.Date,
  Js.Builtins.RegExp,
  Js.Builtins.ArrayBuffer,
  Js.Builtins.TypedArrays,
  Js.Builtins.Atomics,
  Js.Builtins.Base64,
  Js.Modules,
  Js.DirectEval,
  Js.Builtins.AnnexB,
  Js.Builtins.Intl,
  Js.Builtins.SelfHosted;

procedure CreateIntrinsics(R: TJsInterpreterRealm);
var
  ObjectPrototype, FunctionPrototype, IteratorPrototype, ErrorPrototype, AsyncIteratorPrototype: TJsObject;
  PrototypeFunction: TJsNativeFunction;
  ArrayPrototype: TJsArray;
  Wrapper: TJsPrimitiveObject;
  Intrinsic: TJsIntrinsic;

  function Plain(Prototype: TJsObject): TJsObject;
  begin
    Result := R.NewObject(Prototype);
    R.NoteIsPrototype(Result);
  end;

  function Wrapped(Value: TJsValue; AClass: TJsObjectClass): TJsObject;
  begin
    Wrapper := TJsPrimitiveObject(R.NewObjectOfClass(TJsPrimitiveObject, ObjectPrototype, AClass));
    Wrapper.PrimitiveValue := Value;
    R.NoteIsPrototype(Wrapper);
    Result := Wrapper;
  end;

begin
  ObjectPrototype := R.NewObject(nil);
  R.NoteIsPrototype(ObjectPrototype);
  R.Intrinsics[inObjectPrototype] := ObjectPrototype;
  PrototypeFunction := TJsNativeFunction(R.NewObjectOfClass(TJsNativeFunction, ObjectPrototype, ocFunction));
  PrototypeFunction.ObjectFlags := PrototypeFunction.ObjectFlags or ObjectCallable;
  PrototypeFunction.Callback := @FunctionPrototypeItself;
  PrototypeFunction.Data := JsUndefined;
  PrototypeFunction.Data2 := JsUndefined;
  R.NoteIsPrototype(PrototypeFunction);
  FunctionPrototype := PrototypeFunction;
  R.Intrinsics[inFunctionPrototype] := FunctionPrototype;
  ArrayPrototype := TJsArray(R.NewObjectOfClass(TJsArray, ObjectPrototype, ocArray));
  R.NoteIsPrototype(ArrayPrototype);
  R.Intrinsics[inArrayPrototype] := ArrayPrototype;
  R.Intrinsics[inStringPrototype] := Wrapped(R.Atom(anEmpty), ocString);
  R.Intrinsics[inStringPrototype].ObjectFlags := R.Intrinsics[inStringPrototype].ObjectFlags or ObjectExotic;
  R.Intrinsics[inNumberPrototype] := Wrapped(JsInteger(0), ocNumber);
  R.Intrinsics[inBooleanPrototype] := Wrapped(JsFalse, ocBoolean);
  R.Intrinsics[inSymbolPrototype] := Plain(ObjectPrototype);
  R.Intrinsics[inBigIntPrototype] := Plain(ObjectPrototype);
  ErrorPrototype := Plain(ObjectPrototype);
  R.Intrinsics[inErrorPrototype] := ErrorPrototype;
  for Intrinsic := inEvalErrorPrototype to inInternalErrorPrototype do
    R.Intrinsics[Intrinsic] := Plain(ErrorPrototype);
  IteratorPrototype := Plain(ObjectPrototype);
  R.Intrinsics[inIteratorPrototype] := IteratorPrototype;
  for Intrinsic := inArrayIteratorPrototype to inGeneratorPrototype do
    R.Intrinsics[Intrinsic] := Plain(IteratorPrototype);
  R.Intrinsics[inGeneratorFunctionPrototype] := Plain(FunctionPrototype);
  R.Intrinsics[inAsyncFunctionPrototype] := Plain(FunctionPrototype);
  AsyncIteratorPrototype := Plain(ObjectPrototype);
  R.Intrinsics[inAsyncIteratorPrototype] := AsyncIteratorPrototype;
  R.Intrinsics[inAsyncGeneratorPrototype] := Plain(AsyncIteratorPrototype);
  R.Intrinsics[inAsyncGeneratorFunctionPrototype] := Plain(FunctionPrototype);
  R.Intrinsics[inAsyncFromSyncIteratorPrototype] := Plain(AsyncIteratorPrototype);
  for Intrinsic := inPromisePrototype to inDataViewPrototype do
    if Intrinsic in [inPromisePrototype, inMapPrototype, inSetPrototype, inWeakMapPrototype, inWeakSetPrototype,
      inWeakRefPrototype, inFinalizationRegistryPrototype, inRegExpPrototype, inDatePrototype,
      inArrayBufferPrototype, inDataViewPrototype] then
      R.Intrinsics[Intrinsic] := Plain(ObjectPrototype);
  R.Intrinsics[inTypedArrayPrototype] := Plain(ObjectPrototype);
  R.GlobalObject := R.NewObject(ObjectPrototype);

  InstallObject(R);
  InstallFunction(R);
  InstallErrors(R);
  InstallGlobal(R);
  InstallSymbol(R);
  InstallIterators(R);
  InstallArray(R);
  InstallString(R);
  InstallNumber(R);
  InstallMath(R);
  InstallJson(R);
  InstallCollections(R);
  InstallPromise(R);
  InstallGenerators(R);
  InstallReflect(R);
  InstallBigInt(R);
  InstallDate(R);
  InstallRegExp(R);
  InstallArrayBuffer(R);
  InstallTypedArrays(R);
  InstallAtomics(R);
  InstallBase64(R);
  RecordTypedArrayShapes(R);
  InstallModules(R);
  InstallDirectEval(R);
  InstallAnnexB(R);
  InstallIntl(R);
  InstallSelfHosted(R);
end;

end.
