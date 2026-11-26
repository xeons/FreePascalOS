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
  The JavaScript objects of the WebAssembly API that carry engine
  objects, and the errors the engine's failures become.

  Module, Memory, Table and Global objects are host objects (one host
  class each, here, for the process) whose native data is the engine's
  object; their prototypes are the classes the platform script
  (platform/57-webassembly.js) defines, so the brand check is the host
  class, not the prototype chain (a subclass's instance passes, an
  object made with Object.create does not). A Module object holds a
  reference to its TWasmModule, released when it is collected; the
  other objects' engine objects belong to the store (Web.Script.
  WasmAgents), which also caches the objects so each engine object has
  one.

  A memory's buffer is an ArrayBuffer over the memory's own bytes (no
  copy), HostDetachOnly so script can neither transfer nor detach it;
  a growth detaches a fixed length one and the next buffer is a new
  one, while a resizable one (toResizableBuffer: its maximum is the
  memory's) follows the memory and grows it when resized.

  Errors (ThrowWasmError): a module that does not decode or validate is
  a WebAssembly.CompileError, a failed link a LinkError, a trap a
  RuntimeError with the WebAssembly frames in its stack, call stack
  exhaustion and running out of memory RangeErrors, the watchdog's
  interrupt the engine's uncatchable termination, and an exception a
  JavaScript import threw (EWasmScriptException) goes on unchanged.
}
unit Web.Script.WasmObjects;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Objects,
  Js.Engine,
  Wasm.Module,
  Wasm.Runtime,
  Web.Bindings.Context,
  Web.Script.WasmAgents;

type
  { A JavaScript exception is pending in the runtime: raised by a host
    function whose JavaScript threw, to unwind the WebAssembly frames
    to the boundary where it goes on in JavaScript. }
  EWasmScriptException = class(Exception);

  TWasmObjectKind = (woModule, woMemory, woTable, woGlobal);

{ The engine object of Value when it is a WebAssembly object of the
  kind, else nil. }
function WasmObjectData(Value: TJsValue; Kind: TWasmObjectKind): Pointer;
{ A new Module object for Module (which it retains) with Prototype (nil:
  the realm's registered one). }
function NewModuleObject(R: TJsRealm; Module: TWasmModule; Prototype: TJsObject): TJsValue;
{ A new object of the kind for a store object, with Prototype (nil: the
  realm's registered one); it becomes the object's cached one. }
function NewStoreObject(R: TJsRealm; Kind: TWasmObjectKind; StoreObject: TObject; Prototype: TJsObject): TJsValue;
{ The cached object of a memory, table or global, made if needed. }
function StoreObjectValue(R: TJsRealm; Kind: TWasmObjectKind; StoreObject: TObject): TJsValue;
{ The memory's current buffer (a fixed length one made if it has none). }
function MemoryBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;
{ toFixedLengthBuffer and toResizableBuffer: the current buffer if it
  is of that kind, else a new one (the old one detached). }
function MemoryFixedBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;
function MemoryResizableBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;

{ The script error for an exception raised by the engine (or by a
  conversion): returns JsException with it thrown. }
function ThrowWasmError(R: TJsRealm; Error: Exception): TJsValue;
{ Throws a new WebAssembly error of the kind (the realm's class). }
function ThrowWasmErrorOfKind(R: TJsRealm; Kind: TWasmErrorKind; const Message: string): TJsValue;

implementation

uses
  Js.Runtime,
  Js.Shapes,
  Js.Functions,
  Js.Interpreter,
  Js.ArrayBuffers,
  Wasm.Types,
  Wasm.Limits,
  Wasm.Errors;

type
  TWasmHostClasses = class
  public
    Classes: array[TWasmObjectKind] of TJsHostClass;
    constructor Create;
    procedure FinalizeModule(HostClass: TJsHostClass; NativeData: Pointer);
  end;

var
  HostClasses: TWasmHostClasses;

constructor TWasmHostClasses.Create;
const
  Names: array[TWasmObjectKind] of string = ('WebAssembly.Module', 'WebAssembly.Memory', 'WebAssembly.Table',
    'WebAssembly.Global');
var
  Kind: TWasmObjectKind;
begin
  inherited Create;
  for Kind := Low(Kind) to High(Kind) do
  begin
    Classes[Kind] := TJsHostClass.Create;
    Classes[Kind].Name := Names[Kind];
  end;
  Classes[woModule].Finalizer := @FinalizeModule;
end;

procedure TWasmHostClasses.FinalizeModule(HostClass: TJsHostClass; NativeData: Pointer);
begin
  if NativeData <> nil then
    TWasmModule(NativeData).Release;
end;

function WasmObjectData(Value: TJsValue; Kind: TWasmObjectKind): Pointer;
var
  Target: TJsObject;
begin
  Result := nil;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  if (Target is TJsHostObject) and (TJsHostObject(Target).HostClass = HostClasses.Classes[Kind]) then
    Result := TJsHostObject(Target).NativeData;
end;

function RegisteredPrototype(R: TJsRealm; Kind: TWasmObjectKind): TJsObject;
const
  PrototypeKinds: array[TWasmObjectKind] of TWasmPrototypeKind = (wpModule, wpMemory, wpTable, wpGlobal);
begin
  Result := nil;
  if AgentOfRealm(R) <> nil then
    Result := AgentOfRealm(R).RealmData(R).Prototypes[PrototypeKinds[Kind]];
  if Result = nil then
    Result := R.Intrinsics[inObjectPrototype];
end;

function NewHostObject(R: TJsRealm; Kind: TWasmObjectKind; NativeData: Pointer; Prototype: TJsObject): TJsHostObject;
begin
  if Prototype = nil then
    Prototype := RegisteredPrototype(R, Kind);
  Result := TJsHostObject(R.NewObjectOfClass(TJsHostObject, Prototype, ocHost));
  Result.HostClass := HostClasses.Classes[Kind];
  Result.NativeData := NativeData;
end;

function NewModuleObject(R: TJsRealm; Module: TWasmModule; Prototype: TJsObject): TJsValue;
begin
  Module.Retain;
  Result := JsObjectValue(NewHostObject(R, woModule, Module, Prototype));
end;

function NewStoreObject(R: TJsRealm; Kind: TWasmObjectKind; StoreObject: TObject; Prototype: TJsObject): TJsValue;
var
  Made: TJsHostObject;
begin
  Made := NewHostObject(R, Kind, StoreObject, Prototype);
  AgentOfRealm(R).SetWrapper(StoreObject, Made);
  Result := JsObjectValue(Made);
end;

function StoreObjectValue(R: TJsRealm; Kind: TWasmObjectKind; StoreObject: TObject): TJsValue;
var
  Existing: TJsObject;
begin
  Existing := AgentOfRealm(R).WrapperOf(StoreObject);
  if Existing <> nil then
    Exit(JsObjectValue(Existing));
  Result := NewStoreObject(R, Kind, StoreObject, nil);
end;

function NewMemoryBuffer(R: TJsRealm; Agent: TWasmAgent; Memory: TWasmMemory; Resizable: Boolean): TJsValue;
var
  Buffer: TJsArrayBuffer;
  MaximumPages: QWord;
begin
  Buffer := NewExternalArrayBuffer(R, Memory.Data, Memory.ByteLength, nil, nil);
  Buffer.HostDetachOnly := True;
  if Resizable then
  begin
    MaximumPages := MaximumMemoryPages;
    if Memory.MemoryType.Limits.HasMaximum and (Memory.MemoryType.Limits.Maximum < MaximumPages) then
      MaximumPages := Memory.MemoryType.Limits.Maximum;
    Buffer.Resizable := True;
    Buffer.MaxByteLength := MaximumPages * WasmPageSize;
    Buffer.HostResize := @Agent.ResizeBuffer;
  end;
  Agent.SetBuffer(Memory, Buffer);
  Result := JsObjectValue(Buffer);
end;

function MemoryBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;
var
  Agent: TWasmAgent;
begin
  Agent := AgentOfRealm(R);
  if Agent.BufferOf(Memory) <> nil then
    Exit(JsObjectValue(Agent.BufferOf(Memory)));
  Result := NewMemoryBuffer(R, Agent, Memory, False);
end;

function MemoryBufferOfKind(R: TJsRealm; Memory: TWasmMemory; Resizable: Boolean): TJsValue;
var
  Agent: TWasmAgent;
begin
  Agent := AgentOfRealm(R);
  if Agent.BufferOf(Memory) <> nil then
  begin
    if Agent.BufferOf(Memory).Resizable = Resizable then
      Exit(JsObjectValue(Agent.BufferOf(Memory)));
    Agent.DropBuffer(Memory);
  end;
  Result := NewMemoryBuffer(R, Agent, Memory, Resizable);
end;

function MemoryFixedBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;
begin
  Result := MemoryBufferOfKind(R, Memory, False);
end;

function MemoryResizableBufferValue(R: TJsRealm; Memory: TWasmMemory): TJsValue;
begin
  Result := MemoryBufferOfKind(R, Memory, True);
end;

{ Errors }

function ThrowWasmErrorOfKind(R: TJsRealm; Kind: TWasmErrorKind; const Message: string): TJsValue;
var
  Constructor_: TJsObject;
  Argument, Made: TJsValue;
begin
  Constructor_ := nil;
  if AgentOfRealm(R) <> nil then
    Constructor_ := AgentOfRealm(R).RealmData(R).ErrorConstructors[Kind];
  if Constructor_ = nil then
    Exit(R.ThrowError(ekError, Message));
  Argument := R.NewString(Message);
  Made := R.Construct(JsObjectValue(Constructor_), @Argument, 1, JsObjectValue(Constructor_));
  if Made = JsException then
    Exit(JsException);
  Result := R.Throw(Made);
end;

{ A RuntimeError whose stack has the WebAssembly frames first. }
function ThrowTrap(R: TJsRealm; Trap: EWasmTrap): TJsValue;
var
  Value, Stack: TJsValue;
  Text, Header, Rest: string;
  LineEnd: Integer;
begin
  Result := ThrowWasmErrorOfKind(R, weRuntimeError, Trap.Message);
  if (Length(Trap.StackTrace) = 0) or not R.Runtime.HasException then
    Exit;
  Value := R.Runtime.Exception;
  if not JsIsObject(Value) then
    Exit;
  Stack := JsAsObject(Value).Get(R, R.Intern('stack'), Value);
  if not JsIsString(Stack) then
    Exit;
  Text := ValueToText(R, Stack);
  LineEnd := Pos(LineEnding, Text);
  if LineEnd = 0 then
  begin
    Header := Text;
    Rest := '';
  end
  else
  begin
    Header := Copy(Text, 1, LineEnd - 1);
    Rest := Copy(Text, LineEnd + Length(LineEnding), MaxInt);
  end;
  Text := Header + LineEnding + Trap.StackTraceText + Rest;
  JsAsObject(Value).DefineData(R, R.Intern('stack'), R.NewString(Text), PropertyHidden);
end;

{ The watchdog's interrupt: the uncatchable termination a looping script
  gets. }
function Terminate(R: TJsRealm): TJsValue;
begin
  R.Runtime.InterruptRequested := False;
  R.Runtime.Terminating := True;
  Result := R.Throw(JsObjectValue(R.NewError(ekInternal, 'Script interrupted')));
end;

function ThrowWasmError(R: TJsRealm; Error: Exception): TJsValue;
var
  Where: string;
begin
  if Error is EWasmScriptException then
  begin
    if R.Runtime.HasException then
      Exit(JsException);
    Exit(R.ThrowError(ekError, 'WebAssembly: an exception was lost'));
  end;
  if Error is EWasmTrap then
    case EWasmTrap(Error).Kind of
      tkCallStackExhausted: Exit(R.ThrowRangeError('Maximum call stack size exceeded'));
      tkInterrupted: Exit(Terminate(R));
    else
      Exit(ThrowTrap(R, EWasmTrap(Error)));
    end;
  if Error is EWasmMalformed then
  begin
    Where := Format(' @+%d', [EWasmMalformed(Error).Offset]);
    Exit(ThrowWasmErrorOfKind(R, weCompileError, 'WebAssembly module is malformed: ' + Error.Message + Where));
  end;
  if Error is EWasmInvalid then
  begin
    Where := Format(' @+%d', [EWasmInvalid(Error).Offset]);
    Exit(ThrowWasmErrorOfKind(R, weCompileError, 'WebAssembly module is invalid: ' + Error.Message + Where));
  end;
  if Error is EWasmLinkError then
    Exit(ThrowWasmErrorOfKind(R, weLinkError, 'WebAssembly link error: ' + Error.Message));
  if (Error is EWasmResourceError) or (Error is EOutOfMemory) then
    Exit(R.ThrowRangeError('WebAssembly: ' + Error.Message));
  if Error is EWasmError then
    Exit(R.ThrowTypeError('WebAssembly: ' + Error.Message));
  Result := R.ThrowError(ekError, Error.Message);
end;

initialization
  { Never freed: host objects of heaps still alive when the program
    ends refer to them. }
  HostClasses := TWasmHostClasses.Create;
end.
