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
  The natives of exception handling's JS API (WebAssembly.Tag,
  WebAssembly.Exception, WebAssembly.JSTag), called by
  platform/58-webassembly-exceptions.js with its arguments checked:

    wasmNewTag(parameters, proto)    a Tag of a new tag whose parameters
                                     are the value type names given
    wasmJSTag()                      the agent's JavaScript tag's Tag
    wasmNewException(tag, payload, proto)
                                     a WebAssembly.Exception of a new
                                     exception (payload: an array, one
                                     value per tag parameter)
    wasmExceptionGetArg(exception, index)
    wasmExceptionIs(exception, tag)

  A Tag is a host object whose native data is the store's tag; tags live
  with the store and their Tag objects are cached by it, like memories'.
}
unit Web.Script.NativeWasmExceptions;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Web.Bindings.Context;

function NativeNewTag(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeJsTag(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeNewException(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
function NativeExceptionGetArg(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
function NativeExceptionIs(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

implementation

uses
  SysUtils,
  Js.Conversions,
  Wasm.Types,
  Wasm.Runtime,
  Wasm.Api,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmValues,
  Web.Script.WasmReferences,
  Web.Script.WasmNativeArguments;

{ The elements of an array argument. }
function ArrayItems(R: TJsRealm; List: TJsValue; out Items: TJsValueList): Boolean;
var
  Index: Integer;
begin
  Items := nil;
  if not JsIsObject(List) or not (JsAsObject(List) is TJsArray) then
  begin
    R.ThrowTypeError('WebAssembly: a sequence is required');
    Exit(False);
  end;
  SetLength(Items, TJsArray(JsAsObject(List)).ArrayLength);
  for Index := 0 to High(Items) do
  begin
    Items[Index] := JsAsObject(List).Get(R, JsInteger(Index), List);
    if Items[Index] = JsException then
      Exit(False);
  end;
  Result := True;
end;

function NativeNewTag(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Names: TJsValueList;
  Params: TWasmValueTypeArray;
  Index: Integer;
  Tag: TWasmTag;
begin
  if not ArrayItems(R, Arg(Args, ArgCount, 0), Names) then
    Exit(JsException);
  Params := nil;
  SetLength(Params, Length(Names));
  for Index := 0 to High(Names) do
    if not ValueTypeFromName(ValueToText(R, Names[Index]), Params[Index]) then
      Exit(R.ThrowTypeError('WebAssembly.Tag: unknown value type ' + ValueToText(R, Names[Index])));
  Tag := WasmNewTag(AgentOf(Context), MakeFunctionType(Params, []));
  Result := NewStoreObject(R, woTag, Tag, ArgPrototype(Args, ArgCount, 1));
end;

function NativeJsTag(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := StoreObjectValue(R, woTag, AgentOf(Context).JsTag);
end;

function TagArgument(R: TJsRealm; Args: PJsValueArray; ArgCount, Index: Integer; out Tag: TWasmTag): Boolean;
begin
  Tag := TWasmTag(WasmObjectData(Arg(Args, ArgCount, Index), woTag));
  Result := Tag <> nil;
  if not Result then
    R.ThrowTypeError('WebAssembly: a WebAssembly.Tag is required');
end;

function NativeNewException(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Agent: TWasmAgent;
  Tag: TWasmTag;
  Items: TJsValueList;
  Params: TWasmValueTypeArray;
  Payload: TWasmValueArray;
  Index, Mark: Integer;
begin
  if not TagArgument(R, Args, ArgCount, 0, Tag) then
    Exit(JsException);
  Agent := AgentOf(Context);
  if Tag = Agent.JsTag then
    Exit(R.ThrowTypeError('WebAssembly.Exception: an exception of the JavaScript tag cannot be made'));
  if not ArrayItems(R, Arg(Args, ArgCount, 1), Items) then
    Exit(JsException);
  Params := WasmTagType(Tag).Params;
  if Length(Items) <> Length(Params) then
    Exit(R.ThrowTypeError(Format('WebAssembly.Exception: the tag has %d parameters, the payload %d values',
      [Length(Params), Length(Items)])));
  for Index := 0 to High(Params) do
    if IsOpaqueType(Agent, Params[Index]) then
      Exit(R.ThrowTypeError('WebAssembly.Exception: a v128 or exnref payload cannot be made from JavaScript'));
  SetLength(Items, Length(Items) + 1);
  Mark := R.Runtime.PushRoot(Arg(Args, ArgCount, 1));
  try
    if not ToWebAssemblyValues(R, @Items[0], Params, Payload) then
      Exit(JsException);
    Result := ExceptionObjectValue(R, Agent, WasmNewException(Agent, Tag, Payload),
      ArgPrototype(Args, ArgCount, 2));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ExceptionArgument(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer; out Reference: Pointer): Boolean;
begin
  Reference := ExceptionReferenceOf(Arg(Args, ArgCount, 0));
  Result := Reference <> nil;
  if not Result then
    R.ThrowTypeError('Illegal invocation: not a WebAssembly.Exception');
end;

function NativeExceptionGetArg(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray;
  ArgCount: Integer): TJsValue;
var
  Reference: Pointer;
  Payload: TWasmValueArray;
  Index: Double;
begin
  if not ExceptionArgument(R, Args, ArgCount, Reference) then
    Exit(JsException);
  Payload := WasmExceptionPayload(Reference);
  Index := ArgNumber(R, Args, ArgCount, 1);
  if Index >= Length(Payload) then
    Exit(R.ThrowRangeError('WebAssembly.Exception.getArg: index out of range'));
  if IsOpaqueType(AgentOf(Context), Payload[Trunc(Index)].ValueType) then
    Exit(R.ThrowTypeError('WebAssembly.Exception.getArg: a v128 or exnref value cannot be read from JavaScript'));
  Result := ToJSValue(R, Payload[Trunc(Index)]);
end;

function NativeExceptionIs(R: TJsRealm; Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Reference: Pointer;
  Tag: TWasmTag;
begin
  if not ExceptionArgument(R, Args, ArgCount, Reference) or not TagArgument(R, Args, ArgCount, 1, Tag) then
    Exit(JsException);
  Result := JsBoolean(WasmExceptionTag(Reference) = Tag);
end;

end.
