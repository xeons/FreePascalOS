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
  The JavaScript objects of WebAssembly's collected heap: Exported GC
  Objects (a struct or an array seen from JavaScript) and
  WebAssembly.Exception objects (an exception, an exnref).

  An Exported GC Object (JS API "Garbage Collected Objects") is an
  exotic object with no properties: its prototype is null and cannot be
  set, it is not extensible and cannot be made so, reads give
  undefined, writes, definitions and deletions are refused (a TypeError
  for [[Set]] and [[Delete]]). typeof is "object" and it works as a Map
  or WeakMap key like any object. A WebAssembly.Exception is a host
  object of its class (the brand), with the realm's Exception prototype
  or the constructor's new.target's.

  Each holds its WebAssembly object's address and traces it for the
  agent's host trace (TWasmAgent.TraceReference), so the object lives
  while the wrapper does and what it holds (JavaScript values in its
  fields) lives with it. The agent caches one wrapper per object, weakly
  (JS API: the exported GC object cache and the Exception object
  cache), which keeps identity: a struct passed out twice is the same
  object, an exception rethrown through WebAssembly the same
  WebAssembly.Exception.
}
unit Web.Script.WasmReferences;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Js.Objects,
  Js.Engine,
  Web.Script.WasmAgents;

type
  TWasmGcObjectWrapper = class(TJsObject)
  public
    Reference: Pointer;
    procedure Trace(Tracer: TJsTracer); override;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
    function GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean; override;
    function SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer; override;
    function PreventExtensions(R: TJsRealm): Integer; override;
    function IsExtensible(R: TJsRealm): Integer; override;
  end;

  { NativeData is the exception object (the exnref). }
  TWasmExceptionObject = class(TJsHostObject)
  public
    procedure Trace(Tracer: TJsTracer); override;
  end;

{ The Exported GC Object of a struct or array (made the first time). }
function GcObjectValue(R: TJsRealm; Agent: TWasmAgent; Reference: Pointer): TJsValue;
{ The struct or array of an Exported GC Object, else nil. }
function GcObjectReferenceOf(Value: TJsValue): Pointer;
{ The WebAssembly.Exception of an exception object (made the first time,
  with Prototype, nil being the realm's registered one). }
function ExceptionObjectValue(R: TJsRealm; Agent: TWasmAgent; Reference: Pointer; Prototype: TJsObject = nil): TJsValue;
{ The exception object of a WebAssembly.Exception, else nil. }
function ExceptionReferenceOf(Value: TJsValue): Pointer;

implementation

uses
  Js.Runtime,
  Js.Shapes,
  Web.Script.WasmObjects;

{ TWasmGcObjectWrapper }

procedure TWasmGcObjectWrapper.Trace(Tracer: TJsTracer);
var
  Agent: TWasmAgent;
begin
  inherited Trace(Tracer);
  Agent := TracingAgent(Tracer);
  if Agent <> nil then
    Agent.TraceReference(Reference);
end;

function TWasmGcObjectWrapper.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
begin
  Desc := Default(TJsPropertyDescriptor);
  Result := 0;
end;

function TWasmGcObjectWrapper.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
begin
  if ThrowOnFailure then
  begin
    R.ThrowTypeError('Cannot define a property on a WebAssembly object');
    Exit(-1);
  end;
  Result := 0;
end;

function TWasmGcObjectWrapper.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
begin
  Result := 0;
end;

function TWasmGcObjectWrapper.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
begin
  Result := JsUndefined;
end;

function TWasmGcObjectWrapper.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
begin
  R.ThrowTypeError('Cannot set a property of a WebAssembly object');
  Result := -1;
end;

function TWasmGcObjectWrapper.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
begin
  R.ThrowTypeError('Cannot delete a property of a WebAssembly object');
  Result := -1;
end;

function TWasmGcObjectWrapper.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
begin
  Keys := nil;
  Result := True;
end;

function TWasmGcObjectWrapper.GetPrototype(R: TJsRealm; out Prototype: TJsObject): Boolean;
begin
  Prototype := nil;
  Result := True;
end;

function TWasmGcObjectWrapper.SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer;
begin
  Result := 0;
end;

function TWasmGcObjectWrapper.PreventExtensions(R: TJsRealm): Integer;
begin
  Result := 0;
end;

function TWasmGcObjectWrapper.IsExtensible(R: TJsRealm): Integer;
begin
  Result := 0;
end;

{ TWasmExceptionObject }

procedure TWasmExceptionObject.Trace(Tracer: TJsTracer);
var
  Agent: TWasmAgent;
begin
  inherited Trace(Tracer);
  Agent := TracingAgent(Tracer);
  if Agent <> nil then
    Agent.TraceReference(NativeData);
end;

function GcObjectValue(R: TJsRealm; Agent: TWasmAgent; Reference: Pointer): TJsValue;
var
  Made: TWasmGcObjectWrapper;
begin
  if Agent.ReferenceObjectOf(Reference) <> nil then
    Exit(JsObjectValue(Agent.ReferenceObjectOf(Reference)));
  Made := TWasmGcObjectWrapper(R.NewObjectOfClass(TWasmGcObjectWrapper, nil, ocObject));
  Made.ObjectFlags := ObjectExotic;
  Made.Reference := Reference;
  Agent.SetReferenceObject(Reference, Made);
  Result := JsObjectValue(Made);
end;

function GcObjectReferenceOf(Value: TJsValue): Pointer;
begin
  Result := nil;
  if JsIsObject(Value) and (JsAsObject(Value) is TWasmGcObjectWrapper) then
    Result := TWasmGcObjectWrapper(JsAsObject(Value)).Reference;
end;

function ExceptionObjectValue(R: TJsRealm; Agent: TWasmAgent; Reference: Pointer; Prototype: TJsObject): TJsValue;
var
  Made: TJsHostObject;
begin
  if Agent.ReferenceObjectOf(Reference) <> nil then
    Exit(JsObjectValue(Agent.ReferenceObjectOf(Reference)));
  if Prototype = nil then
    Prototype := RegisteredWasmPrototype(R, woException);
  Made := TJsHostObject(R.NewObjectOfClass(TWasmExceptionObject, Prototype, ocHost));
  Made.HostClass := WasmHostClass(woException);
  Made.NativeData := Reference;
  Agent.SetReferenceObject(Reference, Made);
  Result := JsObjectValue(Made);
end;

function ExceptionReferenceOf(Value: TJsValue): Pointer;
begin
  Result := WasmObjectData(Value, woException);
end;

end.
