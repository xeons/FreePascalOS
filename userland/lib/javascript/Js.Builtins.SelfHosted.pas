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
  Built-ins written in JavaScript: those whose algorithm is mostly
  awaiting (Array.fromAsync). The source runs once when the realm is
  made, inside a function given the intrinsics it needs (taken before
  any script can replace them) and a few native helpers, and returns
  the built-in functions.
}
unit Js.Builtins.SelfHosted;

{$mode objfpc}{$H+}

interface

uses
  Js.Interpreter;

procedure InstallSelfHosted(R: TJsInterpreterRealm);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Compiler;

const
  Source =
    '(function (defineProperty, construct, apply, TypeError, asyncIteratorSymbol, iteratorSymbol, isConstructor,' +
    ' toLength, toObject, arrayCreate) {'#10 +
    '  "use strict";'#10 +
    '  async function fromAsync(asyncItems, mapfn = undefined, thisArg = undefined) {'#10 +
    '    const C = this;'#10 +
    '    const mapping = mapfn !== undefined;'#10 +
    '    if (mapping && typeof mapfn !== "function") throw new TypeError(String(mapfn) + " is not a function");'#10 +
    '    if (asyncItems === null || asyncItems === undefined)'#10 +
    '      throw new TypeError("Array.fromAsync requires an iterable or an array-like object");'#10 +
    '    const usingAsync = asyncItems[asyncIteratorSymbol];'#10 +
    '    const usingSync = usingAsync === undefined || usingAsync === null ? asyncItems[iteratorSymbol] : undefined;'#10 +
    '    if ((usingAsync !== undefined && usingAsync !== null) || (usingSync !== undefined && usingSync !== null)) {'#10 +
    '      const result = isConstructor(C) ? construct(C, []) : arrayCreate(0);'#10 +
    '      let k = 0;'#10 +
    '      for await (const value of asyncItems) {'#10 +
    '        const mapped = mapping ? await apply(mapfn, thisArg, [value, k]) : value;'#10 +
    '        defineProperty(result, k, { value: mapped, writable: true, enumerable: true, configurable: true });'#10 +
    '        k++;'#10 +
    '      }'#10 +
    '      result.length = k;'#10 +
    '      return result;'#10 +
    '    }'#10 +
    '    const arrayLike = toObject(asyncItems);'#10 +
    '    const length = toLength(arrayLike.length);'#10 +
    '    const result = isConstructor(C) ? construct(C, [length]) : arrayCreate(length);'#10 +
    '    for (let k = 0; k < length; k++) {'#10 +
    '      const value = await arrayLike[k];'#10 +
    '      const mapped = mapping ? await apply(mapfn, thisArg, [value, k]) : value;'#10 +
    '      defineProperty(result, k, { value: mapped, writable: true, enumerable: true, configurable: true });'#10 +
    '    }'#10 +
    '    result.length = length;'#10 +
    '    return result;'#10 +
    '  }'#10 +
    '  return { fromAsync };'#10 +
    '})';

function HelperIsConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsBoolean(JsIsConstructor(Arg(Args, ArgCount, 0)));
end;

function HelperToLength(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Length: Int64;
begin
  if not ToLength(R, Arg(Args, ArgCount, 0), Length) then
    Exit(JsException);
  Result := JsNumber(Length);
end;

function HelperToObject(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := ToObject(R, Arg(Args, ArgCount, 0));
end;

function HelperArrayCreate(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Created: TJsArray;
  Length: Double;
begin
  Created := R.NewArray(0);
  Length := JsNumberValue(Arg(Args, ArgCount, 0));
  if Length > 4294967295.0 then
    Exit(R.ThrowRangeError('Invalid array length'));
  Created.ArrayLength := Trunc(Length);
  Result := JsObjectValue(Created);
end;

procedure InstallSelfHosted(R: TJsInterpreterRealm);
var
  Code: TJsCode;
  Factory, Builtins, Value: TJsValue;
  Helpers: array[0..9] of TJsValue;
  Mark: Integer;
  ObjectConstructor, Reflect, SymbolConstructor: TJsObject;
begin
  Code := CompileScript(R, UnicodeString(Source), '<builtin>', True);
  Factory := R.RunScript(Code);
  if Factory = JsException then
  begin
    R.Runtime.TakeException;
    Exit;
  end;
  Mark := R.Runtime.PushRoot(Factory);
  try
    ObjectConstructor := JsAsObject(R.GlobalObject.GetValue(R, R.Intern('Object')));
    Reflect := JsAsObject(R.GlobalObject.GetValue(R, R.Intern('Reflect')));
    SymbolConstructor := JsAsObject(R.GlobalObject.GetValue(R, R.Intern('Symbol')));
    Helpers[0] := ObjectConstructor.GetValue(R, R.Intern('defineProperty'));
    Helpers[1] := Reflect.GetValue(R, R.Intern('construct'));
    Helpers[2] := Reflect.GetValue(R, R.Intern('apply'));
    Helpers[3] := R.GlobalObject.GetValue(R, R.Intern('TypeError'));
    Helpers[4] := SymbolConstructor.GetValue(R, R.Intern('asyncIterator'));
    Helpers[5] := SymbolConstructor.GetValue(R, R.Intern('iterator'));
    Helpers[6] := JsObjectValue(NewNativeFunction(R, 'isConstructor', @HelperIsConstructor, 1));
    Helpers[7] := JsObjectValue(NewNativeFunction(R, 'toLength', @HelperToLength, 1));
    Helpers[8] := JsObjectValue(NewNativeFunction(R, 'toObject', @HelperToObject, 1));
    Helpers[9] := JsObjectValue(NewNativeFunction(R, 'arrayCreate', @HelperArrayCreate, 1));
    for Value in Helpers do
      R.Runtime.PushRoot(Value);
    Builtins := R.Call(Factory, JsUndefined, @Helpers[0], Length(Helpers));
    if Builtins = JsException then
    begin
      R.Runtime.TakeException;
      Exit;
    end;
    R.Runtime.PushRoot(Builtins);
    Value := JsAsObject(Builtins).GetValue(R, R.Intern('fromAsync'));
    R.Intrinsics[inArray].DefineData(R, R.Intern('fromAsync'), Value, PropertyHidden);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

end.
