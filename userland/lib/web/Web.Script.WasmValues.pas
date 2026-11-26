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
  interoperability").

  ToWebAssemblyValue: i32 by ToInt32, i64 by ToBigInt64 (a BigInt, or
  what converts to one), f32 and f64 by ToNumber (f32 rounded to single
  precision), funcref null or an Exported Function, externref any value
  (null being the null reference: the value's 64 bits are the
  reference); v128 is a TypeError. ToJSValue the other way (i64 as a
  BigInt, a funcref as its Exported Function).

  An Exported Function is a built-in function of the realm that first
  needed it (name: the function's index, length: its parameter count),
  cached per function by the agent so it is always the same object; it
  is not a constructor. Calling it converts the arguments (missing ones
  are undefined), runs the function and converts the results:
  undefined for none, the value for one, an array for several.

  A JavaScript callable imported as a function becomes a host function
  whose data is the callable (marked by the agent): calling it converts
  the arguments, calls with this undefined, and converts the result (an
  iterable of values for several results). A JavaScript exception
  unwinds the WebAssembly frames as EWasmScriptException and goes on,
  unchanged, from the Exported Function that called in; calls nest both
  ways as deep as the store and the interpreter allow.

  Values that only Pascal holds while JavaScript may run (converted
  externrefs, arguments made for a call) are pushed as temporary roots.
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
  Wasm.Runtime;

{ False when it threw. }
function ToWebAssemblyValue(R: TJsRealm; Value: TJsValue; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
{ JsException when it threw (v128). }
function ToJSValue(R: TJsRealm; const Value: TWasmValue): TJsValue;
{ The Exported Function of Func (made the first time). }
function ExportedFunctionValue(R: TJsRealm; Func: TWasmFunction): TJsValue;
{ The engine function of an Exported Function, else nil. }
function ExportedFunctionOf(Value: TJsValue): TWasmFunction;
{ A host function calling Callable, of the type. }
function NewImportedFunction(Store: TWasmStore; const FunctionType: TWasmFunctionType; Callable: TJsValue): TWasmFunction;
{ Whether a type has v128 parameters or results (not callable from JS). }
function HasVectorType(const FunctionType: TWasmFunctionType): Boolean;

implementation

uses
  Js.Runtime,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.BigIntegers,
  Js.Builtins.BigInt,
  Wasm.Api,
  Web.Bindings.Context,
  Web.Script.WasmAgents,
  Web.Script.WasmObjects;

type
  { The host functions' callback (a method is what libwasm takes); it
    keeps no state: the store and the callable come with the call. }
  TWasmImportCalls = class
  public
    procedure Call(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
  end;

var
  ImportCalls: TWasmImportCalls;

function HasVectorType(const FunctionType: TWasmFunctionType): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FunctionType.Params) do
    if FunctionType.Params[Index].Kind = vkV128 then
      Exit(True);
  for Index := 0 to High(FunctionType.Results) do
    if FunctionType.Results[Index].Kind = vkV128 then
      Exit(True);
  Result := False;
end;

function ToWebAssemblyValue(R: TJsRealm; Value: TJsValue; const ValueType: TWasmValueType;
  out Converted: TWasmValue): Boolean;
var
  Integer32: LongInt;
  Number: Double;
  Big: TJsValue;
  Func: TWasmFunction;
begin
  Converted := WasmDefaultValue(ValueType);
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
    vkV128:
      begin
        R.ThrowTypeError('WebAssembly: a v128 value cannot be passed from JavaScript');
        Exit;
      end;
  else
    if JsIsNull(Value) then
      Converted.Reference := nil
    else if ValueType.HeapType = HeapTypeExtern then
    begin
      { The value is the reference; +0.0's bits would read as null. }
      if Value = 0 then
        Value := JsInteger(0);
      Converted.Reference := Pointer(PtrUInt(Value));
    end
    else if ValueType.HeapType = HeapTypeFunc then
    begin
      Func := ExportedFunctionOf(Value);
      if Func = nil then
      begin
        R.ThrowTypeError('WebAssembly: a funcref must be null or an exported WebAssembly function');
        Exit;
      end;
      Converted.Reference := Func;
    end
    else
    begin
      R.ThrowTypeError('WebAssembly: values of type ' + ValueTypeToString(ValueType) +
        ' cannot be passed from JavaScript');
      Exit;
    end;
  end;
  Result := True;
end;

function ToJSValue(R: TJsRealm; const Value: TWasmValue): TJsValue;
begin
  case Value.ValueType.Kind of
    vkI32: Result := JsInteger(Value.I32);
    vkI64: Result := JsCellValue(JsBigIntBase, BigIntFromInt64(R.Heap, Value.I64));
    vkF32: Result := JsNumber(PSingle(@Value.F32Bits)^);
    vkF64: Result := JsNumber(PDouble(@Value.F64Bits)^);
    vkV128: Result := R.ThrowTypeError('WebAssembly: a v128 value cannot be passed to JavaScript');
  else
    if Value.Reference = nil then
      Result := JsNull
    else if Value.ValueType.HeapType = HeapTypeFunc then
      Result := ExportedFunctionValue(R, TWasmFunction(Value.Reference))
    else
      Result := TJsValue(PtrUInt(Value.Reference));
  end;
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
  if Agent.WrapperOf(Func) <> nil then
    Exit(JsObjectValue(Agent.WrapperOf(Func)));
  Made := NewNativeFunction(R, IntToStr(Func.FunctionIndex), @ExportedFunctionEntry,
    Length(Func.FunctionType.Params));
  Made.HostData := Func;
  Agent.SetWrapper(Func, Made);
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
  Arguments, Results: TWasmValueArray;
  Index, Mark: Integer;
  Argument: TJsValue;
begin
  Func := TWasmFunction(Callee.HostData);
  if HasVectorType(Func.FunctionType) then
    Exit(R.ThrowTypeError('WebAssembly: a function with v128 parameters or results cannot be called from ' +
      'JavaScript'));
  Arguments := nil;
  SetLength(Arguments, Length(Func.FunctionType.Params));
  Mark := R.Runtime.PushRoot(JsUndefined);
  try
    for Index := 0 to High(Arguments) do
    begin
      if Index < ArgCount then
        Argument := Args^[Index]
      else
        Argument := JsUndefined;
      if not ToWebAssemblyValue(R, Argument, Func.FunctionType.Params[Index], Arguments[Index]) then
        Exit(JsException);
      if Func.FunctionType.Params[Index].Kind = vkReference then
        R.Runtime.PushRoot(Argument);
    end;
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

function NewImportedFunction(Store: TWasmStore; const FunctionType: TWasmFunctionType; Callable: TJsValue): TWasmFunction;
begin
  Result := WasmNewHostFunction(Store, FunctionType, @ImportCalls.Call, Pointer(PtrUInt(Callable)));
end;

procedure TWasmImportCalls.Call(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
var
  R: TJsRealm;
  Callable, Outcome: TJsValue;
  Values, Items: TJsValueList;
  Index, Mark: Integer;
begin
  R := AgentOfStore(Func.Store).Context.Engine.Realm;
  Callable := TJsValue(PtrUInt(Func.HostData));
  Values := nil;
  SetLength(Values, Length(Arguments) + 1);
  Mark := R.Runtime.PushRoot(Callable);
  try
    for Index := 0 to High(Arguments) do
    begin
      Values[Index] := ToJSValue(R, Arguments[Index]);
      if Values[Index] = JsException then
        raise EWasmScriptException.Create('argument');
      R.Runtime.PushRoot(Values[Index]);
    end;
    Outcome := R.Call(Callable, JsUndefined, @Values[0], Length(Arguments));
    if Outcome = JsException then
      raise EWasmScriptException.Create('import threw');
    case Length(Results) of
      0: ;
      1:
        if not ToWebAssemblyValue(R, Outcome, Func.FunctionType.Results[0], Results[0]) then
          raise EWasmScriptException.Create('result');
    else
      R.Runtime.PushRoot(Outcome);
      if not IterableToList(R, Outcome, Items) then
        raise EWasmScriptException.Create('results');
      for Index := 0 to High(Items) do
        R.Runtime.PushRoot(Items[Index]);
      if Length(Items) <> Length(Results) then
      begin
        R.ThrowTypeError(Format('WebAssembly: the import returned %d values, %d expected',
          [Length(Items), Length(Results)]));
        raise EWasmScriptException.Create('results');
      end;
      for Index := 0 to High(Items) do
        if not ToWebAssemblyValue(R, Items[Index], Func.FunctionType.Results[Index], Results[Index]) then
          raise EWasmScriptException.Create('results');
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

initialization
  ImportCalls := TWasmImportCalls.Create;
end.
