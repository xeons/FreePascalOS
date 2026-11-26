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
  Values between JavaScript and WebAssembly, and calls both ways (JS API
  sections "Exported Functions", "Host functions" and "JavaScript
  interoperability", with the GC and exception handling additions).

  ToWebAssemblyValue: i32 by ToInt32, i64 by ToBigInt64 (a BigInt, or
  what converts to one), f32 and f64 by ToNumber (f32 rounded to single
  precision); v128 and exnref are TypeErrors. A reference:
    - null is the null reference (a TypeError for a non-nullable type);
    - func hierarchy: an Exported Function, of a type that matches;
    - any hierarchy: a Number that is an integer in the i31 range is an
      i31, an Exported GC Object its struct or array, any other value a
      host value (boxed by libwasm: WasmInternalize), and the result
      must match the type (an i31 is no structref, a host value only an
      anyref);
    - extern hierarchy: the same, externalized (an i31, a struct, or the
      value's host word, Web.Script.WasmHostValues).
  Mismatches are TypeErrors. ToJSValue the other way: i64 as a BigInt,
  an i31 as a Number, a struct or array as its Exported GC Object
  (Web.Script.WasmReferences), a funcref as its Exported Function, a
  host value as the value itself.

  Several values are converted in two passes (ToWebAssemblyValues):
  the numbers - whose conversions may run JavaScript - and the type
  checks of the references in order, then the references are made.
  Making one allocates (a box, a host box of libwasm's heap) and nothing
  marks it until WebAssembly holds it, so no JavaScript may run between
  making it and handing it over.

  An Exported Function is a built-in function of the realm that first
  needed it (name: the function's index, length: its parameter count),
  cached per function by the agent so it is always the same object; it
  is not a constructor. Calling it converts the arguments (missing ones
  are undefined), runs the function and converts the results:
  undefined for none, the value for one, an array for several. A type
  with v128 or exnref in it is a TypeError at each call.

  A JavaScript callable imported as a function becomes a host function
  whose data is the callable (marked by the agent): calling it converts
  the arguments, calls with this undefined, and converts the result (an
  iterable of values for several results). An exception thrown there
  (by the callable or by a conversion) goes into WebAssembly as a
  WebAssembly exception: a WebAssembly.Exception thrown is its own
  exception object again, any other value is wrapped in an exception of
  the JavaScript tag (WebAssembly.JSTag, payload the value as an
  externref), which catch_all and catch $JSTag see. Leaving WebAssembly
  (ThrowEscapedException) it becomes the value again, or the exception's
  WebAssembly.Exception (the same object each time); so a JavaScript
  exception crosses WebAssembly frames unchanged. Only the watchdog's
  termination unwinds them uncatchably (EWasmScriptException).

  Values that only Pascal holds while JavaScript may run are pushed as
  temporary roots.
}
unit Web.Script.WasmValues;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Objects,
  Wasm.Types,
  Wasm.Runtime,
  Wasm.Exceptions;

{ False when it threw. ValueType is a store type (concrete heap types
  are store type ids). }
function ToWebAssemblyValue(R: TJsRealm; Value: TJsValue; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
{ One value per type, in two passes (see above). }
function ToWebAssemblyValues(R: TJsRealm; Values: PJsValue; const Types: TWasmValueTypeArray;
  out Converted: TWasmValueArray): Boolean;
{ JsException when it threw (v128, exnref). }
function ToJSValue(R: TJsRealm; const Value: TWasmValue): TJsValue;
{ The Exported Function of Func (made the first time). }
function ExportedFunctionValue(R: TJsRealm; Func: TWasmFunction): TJsValue;
{ The engine function of an Exported Function, else nil. }
function ExportedFunctionOf(Value: TJsValue): TWasmFunction;
{ A host function calling Callable, of a module's type (TypeId: its
  store type id). }
function NewImportedFunction(Store: TWasmStore; TypeId: Integer; Callable: TJsValue): TWasmFunction;
{ Whether values of the (store) type cannot cross to or from JavaScript:
  v128 and the exn hierarchy. }
function IsOpaqueType(Store: TWasmStore; const ValueType: TWasmValueType): Boolean;
{ Whether a function type has such a parameter or result. }
function HasOpaqueType(Store: TWasmStore; const FunctionType: TWasmFunctionType): Boolean;
{ Throws what a WebAssembly exception leaving WebAssembly is in
  JavaScript; returns JsException. }
function ThrowEscapedException(R: TJsRealm; Error: EWasmException): TJsValue;

implementation

uses
  Js.Runtime,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.BigIntegers,
  Js.Builtins.BigInt,
  Wasm.Subtyping,
  Wasm.Api,
  Web.Bindings.Context,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects,
  Web.Script.WasmHostValues,
  Web.Script.WasmReferences;

type
  { The host functions' callback (a method is what libwasm takes); it
    keeps no state: the store and the callable come with the call. }
  TWasmImportCalls = class
  private
    function Run(R: TJsRealm; Func: TWasmFunction; const Arguments: TWasmValueArray;
      var Results: TWasmValueArray): Boolean;
  public
    procedure Call(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
  end;

var
  ImportCalls: TWasmImportCalls;

function AgentFor(R: TJsRealm): TWasmAgent;
begin
  Result := AgentOfRealm(R);
  if Result = nil then
    Result := AgentOf(ContextOfRealm(R));
end;

function HeapTop(Store: TWasmStore; const ValueType: TWasmValueType): Int32; inline;
begin
  Result := HeapTypeTop(Store.Registry, ValueType.HeapType);
end;

function IsOpaqueType(Store: TWasmStore; const ValueType: TWasmValueType): Boolean;
begin
  case ValueType.Kind of
    vkV128: Result := True;
    vkReference: Result := HeapTop(Store, ValueType) = HeapTypeExn;
  else
    Result := False;
  end;
end;

function HasOpaqueType(Store: TWasmStore; const FunctionType: TWasmFunctionType): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FunctionType.Params) do
    if IsOpaqueType(Store, FunctionType.Params[Index]) then
      Exit(True);
  for Index := 0 to High(FunctionType.Results) do
    if IsOpaqueType(Store, FunctionType.Results[Index]) then
      Exit(True);
  Result := False;
end;

function Matches(Agent: TWasmAgent; Reference: Pointer; const ValueType: TWasmValueType): Boolean; inline;
begin
  Result := WasmValueMatchesType(Agent, WasmReference(ValueType, Reference), ValueType);
end;

function RefuseType(R: TJsRealm; const ValueType: TWasmValueType): Boolean;
begin
  R.ThrowTypeError('WebAssembly: the value is not of type ' + ValueTypeToString(ValueType));
  Result := False;
end;

{ The type check of a reference (a TypeError when it fails), without
  allocating or running JavaScript. }
function CheckReference(R: TJsRealm; Agent: TWasmAgent; Value: TJsValue; const ValueType: TWasmValueType): Boolean;
var
  Func: TWasmFunction;
  Integer31: LongInt;
  Reference: Pointer;
begin
  if JsIsNull(Value) then
  begin
    if not ValueType.Nullable then
      Exit(RefuseType(R, ValueType));
    Exit(True);
  end;
  case HeapTop(Agent, ValueType) of
    HeapTypeFunc:
      begin
        Func := ExportedFunctionOf(Value);
        if Func = nil then
        begin
          R.ThrowTypeError('WebAssembly: a function reference must be null or an exported WebAssembly function');
          Exit(False);
        end;
        if not Matches(Agent, Func, ValueType) then
          Exit(RefuseType(R, ValueType));
      end;
    HeapTypeExtern:
      if ValueType.HeapType <> HeapTypeExtern then
        Exit(RefuseType(R, ValueType));
    HeapTypeAny:
      begin
        Reference := GcObjectReferenceOf(Value);
        if IsI31Number(Value, Integer31) then
          Reference := WasmMakeI31(Integer31);
        if Reference <> nil then
        begin
          if not Matches(Agent, Reference, ValueType) then
            Exit(RefuseType(R, ValueType));
        end
        else if ValueType.HeapType <> HeapTypeAny then
          Exit(RefuseType(R, ValueType));
      end;
  else
    Exit(RefuseType(R, ValueType));
  end;
  Result := True;
end;

{ The reference of a value that passed CheckReference. }
function MakeReference(R: TJsRealm; Agent: TWasmAgent; Value: TJsValue; const ValueType: TWasmValueType): Pointer;
var
  Integer31: LongInt;
  Top: Int32;
begin
  if JsIsNull(Value) then
    Exit(nil);
  Top := HeapTop(Agent, ValueType);
  if Top = HeapTypeFunc then
    Exit(ExportedFunctionOf(Value));
  if IsI31Number(Value, Integer31) then
    Exit(WasmMakeI31(Integer31));
  Result := GcObjectReferenceOf(Value);
  if Result <> nil then
    Exit;
  Result := HostWordOf(R, Value);
  if Top = HeapTypeAny then
    Result := WasmInternalize(Agent, Result);
end;

function ToNumericValue(R: TJsRealm; Value: TJsValue; const ValueType: TWasmValueType;
  var Converted: TWasmValue): Boolean;
var
  Integer32: LongInt;
  Number: Double;
  Big: TJsValue;
begin
  Result := False;
  case ValueType.Kind of
    vkI32:
      begin
        if not ToInt32(R, Value, Integer32) then
          Exit;
        Converted.I32 := Integer32;
      end;
    vkI64:
      begin
        Big := ToBigIntValue(R, Value);
        if Big = JsException then
          Exit;
        Converted.I64 := BigIntToInt64(TJsBigInt(JsAsCell(Big)));
      end;
    vkF32:
      begin
        if not ToDouble(R, Value, Number) then
          Exit;
        Converted := WasmF32(Single(Number));
      end;
    vkF64:
      begin
        if not ToDouble(R, Value, Number) then
          Exit;
        Converted := WasmF64(Number);
      end;
  else
    R.ThrowTypeError('WebAssembly: a v128 value cannot be passed from JavaScript');
    Exit;
  end;
  Result := True;
end;

function ToWebAssemblyValue(R: TJsRealm; Value: TJsValue; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
var
  Agent: TWasmAgent;
begin
  Converted := WasmDefaultValue(ValueType);
  if ValueType.Kind <> vkReference then
    Exit(ToNumericValue(R, Value, ValueType, Converted));
  Agent := AgentFor(R);
  if not CheckReference(R, Agent, Value, ValueType) then
    Exit(False);
  Converted.Reference := MakeReference(R, Agent, Value, ValueType);
  Result := True;
end;

function ToWebAssemblyValues(R: TJsRealm; Values: PJsValue; const Types: TWasmValueTypeArray;
  out Converted: TWasmValueArray): Boolean;
var
  Agent: TWasmAgent;
  Index: Integer;
begin
  Converted := nil;
  SetLength(Converted, Length(Types));
  Agent := AgentFor(R);
  for Index := 0 to High(Types) do
  begin
    Converted[Index] := WasmDefaultValue(Types[Index]);
    if Types[Index].Kind <> vkReference then
    begin
      if not ToNumericValue(R, Values[Index], Types[Index], Converted[Index]) then
        Exit(False);
    end
    else if not CheckReference(R, Agent, Values[Index], Types[Index]) then
      Exit(False);
  end;
  for Index := 0 to High(Types) do
    if Types[Index].Kind = vkReference then
      Converted[Index].Reference := MakeReference(R, Agent, Values[Index], Types[Index]);
  Result := True;
end;

function ToJSValue(R: TJsRealm; const Value: TWasmValue): TJsValue;
var
  Agent: TWasmAgent;
  Word: Pointer;
  Top: Int32;
begin
  case Value.ValueType.Kind of
    vkI32: Exit(JsInteger(Value.I32));
    vkI64: Exit(JsCellValue(JsBigIntBase, BigIntFromInt64(R.Heap, Value.I64)));
    vkF32: Exit(JsNumber(PSingle(@Value.F32Bits)^));
    vkF64: Exit(JsNumber(PDouble(@Value.F64Bits)^));
    vkV128: Exit(R.ThrowTypeError('WebAssembly: a v128 value cannot be passed to JavaScript'));
  end;
  if Value.Reference = nil then
    Exit(JsNull);
  Agent := AgentFor(R);
  Top := HeapTop(Agent, Value.ValueType);
  if Top = HeapTypeFunc then
    Exit(ExportedFunctionValue(R, TWasmFunction(Value.Reference)));
  if Top = HeapTypeExn then
    Exit(R.ThrowTypeError('WebAssembly: an exnref cannot be passed to JavaScript'));
  Word := Value.Reference;
  if Top = HeapTypeAny then
    Word := WasmExternalize(Agent, Word);
  if PtrUInt(Word) and 1 <> 0 then
    Result := JsInteger(WasmI31Value(Word))
  else if Agent.Heap.IsObject(Word) then
    Result := GcObjectValue(R, Agent, Word)
  else
    Result := HostValueOf(Word);
end;

function ThrowEscapedException(R: TJsRealm; Error: EWasmException): TJsValue;
var
  Agent: TWasmAgent;
  Payload: TWasmValueArray;
  Value: TJsValue;
begin
  Agent := AgentOfStore(Error.Store);
  if Error.Tag = Agent.JsTag then
  begin
    Payload := Error.Payload;
    Value := ToJSValue(R, Payload[0]);
  end
  else
    Value := ExceptionObjectValue(R, Agent, Error.Reference);
  if Value = JsException then
    Exit(JsException);
  Result := R.Throw(Value);
end;

{ Exported Functions }

function ExportedFunctionEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue; forward;

function ExportedFunctionOf(Value: TJsValue): TWasmFunction;
var
  Target: TJsObject;
begin
  Result := nil;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  if (Target is TJsNativeFunction) and (TJsNativeFunction(Target).Callback = @ExportedFunctionEntry) then
    Result := TWasmFunction(TJsNativeFunction(Target).HostData);
end;

function ExportedFunctionValue(R: TJsRealm; Func: TWasmFunction): TJsValue;
var
  Agent: TWasmAgent;
  Made: TJsNativeFunction;
begin
  Agent := AgentOfStore(Func.Store);
  if Agent.WrapperOf(R, Func) <> nil then
    Exit(JsObjectValue(Agent.WrapperOf(R, Func)));
  Made := NewNativeFunction(R, IntToStr(Func.FunctionIndex), @ExportedFunctionEntry,
    Length(Func.FunctionType.Params));
  Made.HostData := Func;
  Agent.SetWrapper(R, Func, Made);
  Result := JsObjectValue(Made);
end;

function ResultsToJS(R: TJsRealm; const Results: TWasmValueArray): TJsValue;
var
  Items: TJsValueList;
  Index, Mark: Integer;
  Made: TJsArray;
begin
  if Length(Results) = 0 then
    Exit(JsUndefined);
  if Length(Results) = 1 then
    Exit(ToJSValue(R, Results[0]));
  Items := nil;
  SetLength(Items, Length(Results));
  Mark := R.Runtime.PushRoot(JsUndefined);
  for Index := 0 to High(Results) do
  begin
    Items[Index] := ToJSValue(R, Results[Index]);
    R.Runtime.PushRoot(Items[Index]);
  end;
  Made := R.NewArrayFrom(@Items[0], Length(Items));
  R.Runtime.PopRoots(Mark);
  Result := JsObjectValue(Made);
end;

function ExportedFunctionEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Func: TWasmFunction;
  Values: TJsValueList;
  Arguments, Results: TWasmValueArray;
  Index, Mark: Integer;
begin
  Func := TWasmFunction(Callee.HostData);
  if HasOpaqueType(Func.Store, Func.FunctionType) then
    Exit(R.ThrowTypeError('WebAssembly: a function with v128 or exnref parameters or results cannot be called ' +
      'from JavaScript'));
  Values := nil;
  SetLength(Values, Length(Func.FunctionType.Params) + 1);
  Mark := R.Runtime.PushRoot(JsUndefined);
  try
    for Index := 0 to High(Func.FunctionType.Params) do
    begin
      if Index < ArgCount then
        Values[Index] := Args^[Index]
      else
        Values[Index] := JsUndefined;
      R.Runtime.PushRoot(Values[Index]);
    end;
    if not ToWebAssemblyValues(R, @Values[0], Func.FunctionType.Params, Arguments) then
      Exit(JsException);
    try
      Results := WasmCall(Func, Arguments);
    except
      on Error: Exception do
        Exit(ThrowWasmError(R, Error));
    end;
    Result := ResultsToJS(R, Results);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ Host functions }

function NewImportedFunction(Store: TWasmStore; TypeId: Integer; Callable: TJsValue): TWasmFunction;
begin
  Result := WasmNewHostFunctionOfType(Store, TypeId, @ImportCalls.Call, Pointer(PtrUInt(Callable)));
end;

{ The call: False when JavaScript threw (the exception pending). }
function TWasmImportCalls.Run(R: TJsRealm; Func: TWasmFunction; const Arguments: TWasmValueArray;
  var Results: TWasmValueArray): Boolean;
var
  Callable, Outcome: TJsValue;
  Values, Items: TJsValueList;
  Index: Integer;
begin
  Result := False;
  if HasOpaqueType(Func.Store, Func.FunctionType) then
  begin
    R.ThrowTypeError('WebAssembly: a function with v128 or exnref parameters or results cannot be called from ' +
      'WebAssembly into JavaScript');
    Exit;
  end;
  Callable := TJsValue(PtrUInt(Func.HostData));
  Values := nil;
  SetLength(Values, Length(Arguments) + 1);
  R.Runtime.PushRoot(Callable);
  for Index := 0 to High(Arguments) do
  begin
    Values[Index] := ToJSValue(R, Arguments[Index]);
    if Values[Index] = JsException then
      Exit;
    R.Runtime.PushRoot(Values[Index]);
  end;
  Outcome := R.Call(Callable, JsUndefined, @Values[0], Length(Arguments));
  if Outcome = JsException then
    Exit;
  case Length(Results) of
    0: ;
    1:
      if not ToWebAssemblyValue(R, Outcome, Func.FunctionType.Results[0], Results[0]) then
        Exit;
  else
    R.Runtime.PushRoot(Outcome);
    if not IterableToList(R, Outcome, Items) then
      Exit;
    for Index := 0 to High(Items) do
      R.Runtime.PushRoot(Items[Index]);
    if Length(Items) <> Length(Results) then
    begin
      R.ThrowTypeError(Format('WebAssembly: the import returned %d values, %d expected',
        [Length(Items), Length(Results)]));
      Exit;
    end;
    if not ToWebAssemblyValues(R, @Items[0], Func.FunctionType.Results, Results) then
      Exit;
  end;
  Result := True;
end;

procedure TWasmImportCalls.Call(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
var
  R: TJsRealm;
  Agent: TWasmAgent;
  Thrown: TJsValue;
  Reference: Pointer;
  Mark: Integer;
  Succeeded: Boolean;
begin
  Agent := AgentOfStore(Func.Store);
  R := Agent.Context.Engine.Realm;
  Mark := R.Runtime.PushRoot(JsUndefined);
  try
    Succeeded := Run(R, Func, Arguments, Results);
  finally
    R.Runtime.PopRoots(Mark);
  end;
  if Succeeded then
    Exit;
  { A termination stays one; anything else thrown is a WebAssembly
    exception now. }
  if R.Runtime.Terminating or not R.Runtime.HasException then
    raise EWasmScriptException.Create('import threw');
  Thrown := R.Runtime.TakeException;
  Reference := ExceptionReferenceOf(Thrown);
  if Reference <> nil then
    WasmThrowException(Agent, Reference);
  WasmThrow(Agent, Agent.JsTag, [WasmExternRef(MakeReference(R, Agent, Thrown, WasmExternRefType))]);
end;

initialization
  ImportCalls := TWasmImportCalls.Create;
end.
