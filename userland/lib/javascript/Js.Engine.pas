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
  The embedding API: an engine with one realm, for programs and
  libraries (libweb's DOM bindings).

    Engine := TJsEngine.Create;
    Engine.DefineFunction(Engine.GlobalObject, 'print', @Print, 1);
    Value := Engine.Evaluate('1 + 2', 'example.js');   // EJsError if it throws
    Engine.RunJobs;                                     // promise reactions

  Values handed to the host are only safe while no JavaScript runs:
  the collector may run at any call into the engine. A value kept
  longer is protected (Protect returns a handle for Unprotect).

  Host objects: DefineClass makes a constructor and prototype whose
  instances are TJsHostObject, carrying a Pascal object (NativeData)
  that the class's finalizer is given when the instance is collected,
  and a Trace callback through which the host keeps JavaScript values
  alive (event listeners of a DOM node).

  Native callbacks get the realm, this, the arguments and the function
  object; they return a value, or JsException after R.Throw* (never a
  Pascal exception).

  MemoryLimit (bytes, 0 for none) and Interrupt (from any thread) stop
  a script with an uncatchable InternalError.

  Binary data without copies: NewArrayBuffer makes a zeroed buffer the
  host fills through BufferSourceData (which also gives the bytes of a
  typed array or DataView); NewExternalArrayBuffer wraps memory the
  host owns, calling its free procedure when the buffer dies or is
  detached; DetachArrayBuffer takes a buffer's bytes away (transfer).
  A data pointer is valid until JavaScript next runs (a resizable
  buffer may move). The element kinds (taUint8...) are in
  Js.ArrayBuffers; native callbacks, which have only the realm, use its
  NewArrayBuffer and Js.Builtins.TypedArrays.NewTypedArray directly.
}
unit Js.Engine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
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
  Js.Inspect,
  Js.Interpreter,
  Js.ArrayBuffers,
  Js.ModuleRecords,
  Js.Modules,
  Js.Promises,
  Js.Intrinsics;

type
  TJsValue = Js.Values.TJsValue;
  TJsObject = Js.Objects.TJsObject;
  TJsRealm = Js.Objects.TJsRealm;
  TJsNativeCallback = Js.Functions.TJsNativeCallback;
  TJsNativeMethod = Js.Functions.TJsNativeMethod;
  TJsNativeFunction = Js.Functions.TJsNativeFunction;
  TJsTypedArrayKind = Js.ArrayBuffers.TJsTypedArrayKind;
  TJsBufferFreeProc = Js.ArrayBuffers.TJsBufferFreeProc;
  TJsModuleFetch = Js.Modules.TJsModuleFetch;
  TJsModuleResolver = Js.Modules.TJsModuleResolver;
  TJsModuleFetcher = Js.Modules.TJsModuleFetcher;
  TJsModuleMetaHook = Js.Modules.TJsModuleMetaHook;

  { An uncaught JavaScript exception (or a syntax error), as text. }
  EJsError = class(Exception)
  public
    { "TypeError", "SyntaxError"... ('' when a non-error was thrown). }
    ErrorName: string;
    { The stack trace (or the message). }
    StackText: string;
  end;

  TJsEngineOptions = record
    { Values in the register stack (8 bytes each). }
    StackCapacity: Integer;
    { The deepest call nesting. }
    MaximumFrames: Integer;
    { Bytes; 0: no limit. }
    MemoryLimit: Int64;
    { Collections start once this much is allocated. }
    InitialHeapThreshold: Int64;
  end;

  TJsHostClass = class;

  TJsHostFinalizer = procedure(HostClass: TJsHostClass; NativeData: Pointer) of object;
  TJsHostTracer = procedure(HostClass: TJsHostClass; NativeData: Pointer; Tracer: TJsTracer) of object;

  { An object of a host class. }
  TJsHostObject = class(TJsObject)
  public
    HostClass: TJsHostClass;
    NativeData: Pointer;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsHostClass = class
  public
    Name: string;
    Prototype: TJsObject;
    Constructor_: TJsNativeFunction;
    Finalizer: TJsHostFinalizer;
    Tracer: TJsHostTracer;
    { An instance with the class's prototype and the native data. }
    function CreateInstance(R: TJsRealm; NativeData: Pointer): TJsHostObject;
    { The native data of This when it is an instance of the class, else
      nil. }
    function DataOf(Value: TJsValue): Pointer;
  end;

  TJsEngine = class
  private
    FRuntime: TJsRuntime;
    FRealm: TJsInterpreterRealm;
    FRoots: TJsValueList;
    FFreeRoots: array of Integer;
    FHostClasses: array of TJsHostClass;
    procedure MarkRoots(Tracer: TJsTracer);
    procedure RaiseException;
    function GetMemoryLimit: Int64;
    procedure SetMemoryLimit(Value: Int64);
    procedure FinishCall;
    function GetModuleResolver: TJsModuleResolver;
    procedure SetModuleResolver(Value: TJsModuleResolver);
    function GetModuleFetcher: TJsModuleFetcher;
    procedure SetModuleFetcher(Value: TJsModuleFetcher);
    function GetModuleMetaHook: TJsModuleMetaHook;
    procedure SetModuleMetaHook(Value: TJsModuleMetaHook);
  public
    constructor Create;
    constructor Create(const Options: TJsEngineOptions);
    destructor Destroy; override;
    class function DefaultOptions: TJsEngineOptions;

    { Runs a script; raises EJsError when it throws. }
    function Evaluate(const Source: string; const FileName: string = '<eval>'): TJsValue;
    { False and the error's text when it throws or does not parse. }
    function TryEvaluate(const Source, FileName: string; out Value: TJsValue; out ErrorText: string): Boolean;
    function Call(F, This: TJsValue; const Args: array of TJsValue): TJsValue;
    function Construct(F: TJsValue; const Args: array of TJsValue): TJsValue;
    { Runs the job queue (promise reactions) until it is empty. }
    procedure RunJobs;
    function PendingJobs: Integer;

    function GlobalObject: TJsObject;
    function NewObject: TJsObject;
    function NewArray(const Values: array of TJsValue): TJsValue;
    function NewString(const Text: string): TJsValue;
    function NewNumber(Value: Double): TJsValue;
    function GetProperty(Target: TJsValue; const Name: string): TJsValue;
    procedure SetProperty(Target: TJsValue; const Name: string; Value: TJsValue);
    { ToString of the value, as UTF-8 (raises EJsError if that throws). }
    function ToText(Value: TJsValue): string;
    function ToNumber(Value: TJsValue): Double;
    { How the shell prints a value. }
    function Inspect(Value: TJsValue): string;
    { An uncaught exception's text: its stack, or what it converts to. }
    function ErrorText(Value: TJsValue): string;

    function DefineFunction(Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
      Length: Integer; Magic: Integer = 0): TJsNativeFunction;
    function DefineMethod(Target: TJsObject; const Name: string; Method: TJsNativeMethod;
      Length: Integer): TJsNativeFunction;
    procedure DefineValue(Target: TJsObject; const Name: string; Value: TJsValue);

    { Binary data. A zeroed ArrayBuffer of ByteLength bytes (EJsError
      RangeError when it cannot be had). }
    function NewArrayBuffer(ByteLength: SizeInt): TJsValue;
    { An ArrayBuffer holding a copy of the bytes. }
    function NewArrayBufferFrom(Data: Pointer; ByteLength: SizeInt): TJsValue;
    { An ArrayBuffer on the host's memory, no copy; FreeProc (nil: none)
      is called with Context when the buffer dies or is detached. }
    function NewExternalArrayBuffer(Data: Pointer; ByteLength: SizeInt; FreeProc: TJsBufferFreeProc;
      Context: Pointer): TJsValue;
    { A typed array viewing Buffer (Length < 0: to the end, tracking a
      resizable buffer); raises EJsError on bad offsets. }
    function NewTypedArray(Kind: TJsTypedArrayKind; Buffer: TJsValue; ByteOffset: SizeInt;
      Length: SizeInt = -1): TJsValue;
    { A new Uint8Array with a copy of the bytes. }
    function NewUint8Array(Data: Pointer; ByteLength: SizeInt): TJsValue;
    { The bytes of an ArrayBuffer, SharedArrayBuffer, typed array or
      DataView (views: their window); False for anything else or a
      detached one. }
    function BufferSourceData(Value: TJsValue; out Data: PByte; out ByteLength: SizeInt): Boolean;
    { Detaches an ArrayBuffer and gives the caller its bytes (free them
      with FreeMem); False when Value is not an attached ArrayBuffer. }
    function DetachArrayBuffer(Value: TJsValue; out Data: Pointer; out ByteLength: SizeInt): Boolean;
    function IsArrayBuffer(Value: TJsValue): Boolean;
    function IsTypedArray(Value: TJsValue): Boolean;

    { ES modules. Runs Source as the module Key: its imports are
      resolved and fetched through ModuleResolver and ModuleFetcher,
      then it is linked and evaluated in the job queue (run here).
      Returns the promise of its evaluation (still pending when a fetch
      or a top-level await has not finished); raises EJsError for a
      syntax error or when the evaluation failed already. }
    function EvaluateModule(const Source, Key: string): TJsValue;
    { import(Specifier) as from the module ReferrerKey: a promise for the
      namespace (settled by RunJobs once the graph is fetched). }
    function ImportModule(const Specifier: string; const ReferrerKey: string = ''): TJsValue;
    { The namespace of the module loaded as Key (undefined: none). }
    function ModuleNamespace(const Key: string): TJsValue;

    { A class: a constructor named Name on the global object (Callback
      handles new; nil makes it not constructible from scripts). }
    function DefineClass(const Name: string; Callback: TJsNativeCallback; Length: Integer;
      Parent: TJsHostClass = nil): TJsHostClass;

    { Keeps a value alive until Unprotect(Handle). }
    function Protect(Value: TJsValue): Integer;
    procedure Unprotect(Handle: Integer);
    function Protected(Handle: Integer): TJsValue;

    { Stops the running script at its next safe point (any thread). }
    procedure Interrupt;
    procedure CollectGarbage;
    function HeapBytes: Int64;
    function PeakHeapBytes: Int64;

    property Runtime: TJsRuntime read FRuntime;
    property Realm: TJsInterpreterRealm read FRealm;
    property MemoryLimit: Int64 read GetMemoryLimit write SetMemoryLimit;
    { Specifier and referrer key to module key (default: "./" and "../"
      against the referrer's directory, others as they are). }
    property ModuleResolver: TJsModuleResolver read GetModuleResolver write SetModuleResolver;
    { Fetches a module's source: calls Fetch.Succeed or Fetch.Fail, now
      or later. }
    property ModuleFetcher: TJsModuleFetcher read GetModuleFetcher write SetModuleFetcher;
    { Adds to import.meta (url and resolve are there already). }
    property ModuleMetaHook: TJsModuleMetaHook read GetModuleMetaHook write SetModuleMetaHook;
  end;

implementation

uses
  Math
  { On FreePascalOS (LINUX is undefined there) the kernel's clock and
    the time zone database; the host tests keep the runtime's. }
  {$ifndef LINUX}, Js.SystemClock{$endif};

{ TJsHostObject }

destructor TJsHostObject.Destroy;
begin
  if (HostClass <> nil) and Assigned(HostClass.Finalizer) then
    HostClass.Finalizer(HostClass, NativeData);
  inherited Destroy;
end;

procedure TJsHostObject.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  if (HostClass <> nil) and Assigned(HostClass.Tracer) then
    HostClass.Tracer(HostClass, NativeData, Tracer);
end;

{ TJsHostClass }

function TJsHostClass.CreateInstance(R: TJsRealm; NativeData: Pointer): TJsHostObject;
begin
  Result := TJsHostObject(R.NewObjectOfClass(TJsHostObject, Prototype, ocHost));
  Result.HostClass := Self;
  Result.NativeData := NativeData;
end;

function TJsHostClass.DataOf(Value: TJsValue): Pointer;
var
  Target: TJsObject;
  HostClass: TJsHostClass;
  Walk: TJsObject;
begin
  Result := nil;
  if not JsIsObject(Value) then
    Exit;
  Target := JsAsObject(Value);
  if not (Target is TJsHostObject) then
    Exit;
  HostClass := TJsHostObject(Target).HostClass;
  { An instance of a subclass is one of the class too. }
  Walk := HostClass.Prototype;
  while Walk <> nil do
  begin
    if Walk = Prototype then
      Exit(TJsHostObject(Target).NativeData);
    Walk := Walk.Proto;
  end;
end;

{ TJsEngine }

class function TJsEngine.DefaultOptions: TJsEngineOptions;
begin
  Result.StackCapacity := DefaultStackCapacity;
  Result.MaximumFrames := DefaultMaximumFrames;
  Result.MemoryLimit := 0;
  Result.InitialHeapThreshold := 4 * 1024 * 1024;
end;

constructor TJsEngine.Create;
begin
  Create(DefaultOptions);
end;

constructor TJsEngine.Create(const Options: TJsEngineOptions);
begin
  inherited Create;
  { JavaScript arithmetic gives NaN and infinities, never traps. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  FRuntime := TJsRuntime.Create;
  FRuntime.Heap.MinimumThreshold := Options.InitialHeapThreshold;
  FRuntime.Heap.Threshold := Options.InitialHeapThreshold;
  FRuntime.Heap.MemoryLimit := Options.MemoryLimit;
  FRealm := TJsInterpreterRealm.Create(FRuntime, Options.StackCapacity, Options.MaximumFrames);
  FRuntime.Heap.AddRootProvider(@MarkRoots);
  CreateIntrinsics(FRealm);
end;

destructor TJsEngine.Destroy;
var
  Index: Integer;
begin
  FRealm.Free;
  FRuntime.Free;
  for Index := 0 to High(FHostClasses) do
    FHostClasses[Index].Free;
  inherited Destroy;
end;

procedure TJsEngine.MarkRoots(Tracer: TJsTracer);
var
  Index: Integer;
begin
  Tracer.MarkValues(@FRoots[0], Length(FRoots));
  for Index := 0 to High(FHostClasses) do
  begin
    Tracer.MarkCell(FHostClasses[Index].Prototype);
    Tracer.MarkCell(FHostClasses[Index].Constructor_);
  end;
end;

function TJsEngine.ErrorText(Value: TJsValue): string;
var
  Stack, Converted: TJsValue;
begin
  if JsIsObject(Value) then
  begin
    Stack := JsAsObject(Value).GetValue(FRealm, FRealm.Atom(anStack));
    if Stack = JsException then
      FRuntime.TakeException
    else if JsIsString(Stack) then
      Exit(StringToUtf8(FRealm.Heap, JsAsString(Stack)));
  end;
  if JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocError) then
  begin
    Converted := ToStringValue(FRealm, Value);
    if Converted <> JsException then
      Exit(StringToUtf8(FRealm.Heap, JsAsString(Converted)));
    FRuntime.TakeException;
  end;
  Result := 'Uncaught ' + InspectNested(FRealm, Value);
end;

procedure TJsEngine.FinishCall;
begin
  FRuntime.Terminating := False;
end;

procedure TJsEngine.RaiseException;
var
  Thrown, Name: TJsValue;
  Error: EJsError;
  Text: string;
begin
  Thrown := FRuntime.TakeException;
  FinishCall;
  Text := ErrorText(Thrown);
  Error := EJsError.Create(Text);
  Error.StackText := Text;
  if JsIsObject(Thrown) then
  begin
    Name := JsAsObject(Thrown).GetValue(FRealm, FRealm.Atom(anName));
    if JsIsString(Name) then
      Error.ErrorName := StringToUtf8(FRealm.Heap, JsAsString(Name))
    else if Name = JsException then
      FRuntime.TakeException;
  end;
  raise Error;
end;

function TJsEngine.Evaluate(const Source: string; const FileName: string): TJsValue;
var
  Code: TJsCode;
  Error: EJsError;
begin
  try
    Code := CompileScript(FRealm, UTF8Decode(Source), FileName);
  except
    on Syntax: EJsSyntaxError do
    begin
      Error := EJsError.Create('SyntaxError: ' + Syntax.Message + ' (' + FileName + ':' + IntToStr(Syntax.Line) +
        ':' + IntToStr(Syntax.Column) + ')');
      Error.ErrorName := 'SyntaxError';
      Error.StackText := Error.Message;
      raise Error;
    end;
  end;
  Result := FRealm.RunScript(Code);
  if Result = JsException then
    RaiseException;
  FinishCall;
end;

function TJsEngine.TryEvaluate(const Source, FileName: string; out Value: TJsValue; out ErrorText: string): Boolean;
begin
  Value := JsUndefined;
  ErrorText := '';
  try
    Value := Evaluate(Source, FileName);
    Result := True;
  except
    on Error: EJsError do
    begin
      ErrorText := Error.Message;
      Result := False;
    end;
  end;
end;

function TJsEngine.Call(F, This: TJsValue; const Args: array of TJsValue): TJsValue;
begin
  if Length(Args) = 0 then
    Result := FRealm.Call(F, This, nil, 0)
  else
    Result := FRealm.Call(F, This, @Args[0], Length(Args));
  if Result = JsException then
    RaiseException;
  FinishCall;
end;

function TJsEngine.Construct(F: TJsValue; const Args: array of TJsValue): TJsValue;
begin
  if Length(Args) = 0 then
    Result := FRealm.Construct(F, nil, 0, F)
  else
    Result := FRealm.Construct(F, @Args[0], Length(Args), F);
  if Result = JsException then
    RaiseException;
  FinishCall;
end;

procedure TJsEngine.RunJobs;
begin
  if not FRealm.RunJobs then
    RaiseException;
  FinishCall;
end;

function TJsEngine.PendingJobs: Integer;
begin
  Result := FRealm.PendingJobCount;
end;

function TJsEngine.GlobalObject: TJsObject;
begin
  Result := FRealm.GlobalObject;
end;

function TJsEngine.NewObject: TJsObject;
begin
  Result := FRealm.NewPlainObject;
end;

function TJsEngine.NewArray(const Values: array of TJsValue): TJsValue;
begin
  if Length(Values) = 0 then
    Result := JsObjectValue(FRealm.NewArray(0))
  else
    Result := JsObjectValue(FRealm.NewArrayFrom(@Values[0], Length(Values)));
end;

function TJsEngine.NewString(const Text: string): TJsValue;
begin
  Result := FRealm.NewString(Text);
end;

function TJsEngine.NewNumber(Value: Double): TJsValue;
begin
  Result := JsNumber(Value);
end;

function TJsEngine.GetProperty(Target: TJsValue; const Name: string): TJsValue;
begin
  Result := Js.Operations.GetProperty(FRealm, Target, FRealm.Intern(Name));
  if Result = JsException then
    RaiseException;
end;

procedure TJsEngine.SetProperty(Target: TJsValue; const Name: string; Value: TJsValue);
begin
  if not Js.Operations.SetProperty(FRealm, Target, FRealm.Intern(Name), Value, True) then
    RaiseException;
end;

function TJsEngine.ToText(Value: TJsValue): string;
var
  Text: TJsString;
begin
  Text := ToJsString(FRealm, Value);
  if Text = nil then
    RaiseException;
  Result := StringToUtf8(FRealm.Heap, Text);
end;

function TJsEngine.ToNumber(Value: TJsValue): Double;
begin
  if not ToDouble(FRealm, Value, Result) then
    RaiseException;
end;

function TJsEngine.Inspect(Value: TJsValue): string;
begin
  Result := InspectNested(FRealm, Value);
end;

function TJsEngine.DefineFunction(Target: TJsObject; const Name: string; Callback: TJsNativeCallback;
  Length: Integer; Magic: Integer): TJsNativeFunction;
begin
  Result := NewNativeFunction(FRealm, Name, Callback, Length, Magic);
  Target.DefineData(FRealm, FRealm.Intern(Name), JsObjectValue(Result), PropertyHidden);
end;

function TJsEngine.DefineMethod(Target: TJsObject; const Name: string; Method: TJsNativeMethod;
  Length: Integer): TJsNativeFunction;
begin
  Result := NewNativeFunction(FRealm, Name, nil, Length);
  Result.Method := Method;
  Target.DefineData(FRealm, FRealm.Intern(Name), JsObjectValue(Result), PropertyHidden);
end;

procedure TJsEngine.DefineValue(Target: TJsObject; const Name: string; Value: TJsValue);
begin
  Target.DefineData(FRealm, FRealm.Intern(Name), Value, PropertyHidden);
end;

function TJsEngine.NewArrayBuffer(ByteLength: SizeInt): TJsValue;
var
  Buffer: TJsArrayBuffer;
begin
  Buffer := Js.ArrayBuffers.NewArrayBuffer(FRealm, FRealm.Intrinsics[inArrayBufferPrototype], ByteLength);
  if Buffer = nil then
    RaiseException;
  Result := JsObjectValue(Buffer);
end;

function TJsEngine.NewArrayBufferFrom(Data: Pointer; ByteLength: SizeInt): TJsValue;
var
  Bytes: PByte;
  Count: SizeInt;
begin
  Result := NewArrayBuffer(ByteLength);
  if (ByteLength > 0) and BufferSourceData(Result, Bytes, Count) then
    Move(Data^, Bytes^, ByteLength);
end;

function TJsEngine.NewExternalArrayBuffer(Data: Pointer; ByteLength: SizeInt; FreeProc: TJsBufferFreeProc;
  Context: Pointer): TJsValue;
begin
  Result := JsObjectValue(Js.ArrayBuffers.NewExternalArrayBuffer(FRealm, Data, ByteLength, FreeProc, Context));
end;

function TJsEngine.NewTypedArray(Kind: TJsTypedArrayKind; Buffer: TJsValue; ByteOffset: SizeInt;
  Length: SizeInt): TJsValue;
var
  Arguments: array[0..2] of TJsValue;
  Count: Integer;
begin
  Arguments[0] := Buffer;
  Arguments[1] := JsNumber(ByteOffset);
  Arguments[2] := JsNumber(Length);
  Count := 3;
  if Length < 0 then
    Count := 2;
  Result := Construct(JsObjectValue(FRealm.Intrinsics[TypedArrayConstructors[Kind]]), Arguments[0..Count - 1]);
end;

function TJsEngine.NewUint8Array(Data: Pointer; ByteLength: SizeInt): TJsValue;
var
  Buffer: TJsValue;
  Mark: Integer;
begin
  Buffer := NewArrayBufferFrom(Data, ByteLength);
  Mark := FRuntime.PushRoot(Buffer);
  try
    Result := NewTypedArray(taUint8, Buffer, 0, ByteLength);
  finally
    FRuntime.PopRoots(Mark);
  end;
end;

function TJsEngine.BufferSourceData(Value: TJsValue; out Data: PByte; out ByteLength: SizeInt): Boolean;
begin
  Result := BufferSourceBytes(Value, Data, ByteLength);
end;

function TJsEngine.DetachArrayBuffer(Value: TJsValue; out Data: Pointer; out ByteLength: SizeInt): Boolean;
begin
  Data := nil;
  ByteLength := 0;
  if not IsArrayBuffer(Value) or TJsArrayBuffer(JsAsObject(Value)).Shared then
    Exit(False);
  Result := TakeArrayBufferData(FRealm, TJsArrayBuffer(JsAsObject(Value)), Data, ByteLength);
end;

function TJsEngine.IsArrayBuffer(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and (JsAsObject(Value) is TJsArrayBuffer);
end;

function TJsEngine.IsTypedArray(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and (JsAsObject(Value) is TJsTypedArray);
end;

function TJsEngine.GetModuleResolver: TJsModuleResolver;
begin
  Result := ModuleLoaderOf(FRealm).Resolver;
end;

procedure TJsEngine.SetModuleResolver(Value: TJsModuleResolver);
begin
  ModuleLoaderOf(FRealm).Resolver := Value;
end;

function TJsEngine.GetModuleFetcher: TJsModuleFetcher;
begin
  Result := ModuleLoaderOf(FRealm).Fetcher;
end;

procedure TJsEngine.SetModuleFetcher(Value: TJsModuleFetcher);
begin
  ModuleLoaderOf(FRealm).Fetcher := Value;
end;

function TJsEngine.GetModuleMetaHook: TJsModuleMetaHook;
begin
  Result := ModuleLoaderOf(FRealm).MetaHook;
end;

procedure TJsEngine.SetModuleMetaHook(Value: TJsModuleMetaHook);
begin
  ModuleLoaderOf(FRealm).MetaHook := Value;
end;

function TJsEngine.EvaluateModule(const Source, Key: string): TJsValue;
var
  Handle: Integer;
  Promise: TJsPromise;
begin
  Result := ModuleLoaderOf(FRealm).EvaluateSource(Source, Key);
  if Result = JsException then
    RaiseException;
  Handle := Protect(Result);
  try
    RunJobs;
    Promise := TJsPromise(JsAsObject(Result));
    if Promise.State = psRejected then
    begin
      { Reported here, not as an unhandled rejection. }
      Promise.IsHandled := True;
      if Assigned(JsRejectionTracker) then
        JsRejectionTracker(FRealm, Promise, True);
      FRuntime.Exception := Promise.Value;
      FRuntime.HasException := True;
      RaiseException;
    end;
  finally
    Unprotect(Handle);
  end;
end;

function TJsEngine.ImportModule(const Specifier: string; const ReferrerKey: string): TJsValue;
begin
  Result := ModuleLoaderOf(FRealm).Import(Specifier, ReferrerKey, False);
end;

function TJsEngine.ModuleNamespace(const Key: string): TJsValue;
var
  Module: TJsModule;
begin
  Module := ModuleLoaderOf(FRealm).ModuleFor(Key);
  if (Module = nil) or (Module.Status in [msNew, msUnlinked, msLinking]) then
    Exit(JsUndefined);
  Result := JsObjectValue(GetModuleNamespace(FRealm, Module));
end;

function HostConstructorRefused(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := R.ThrowTypeError('Illegal constructor');
end;

function TJsEngine.DefineClass(const Name: string; Callback: TJsNativeCallback; Length: Integer;
  Parent: TJsHostClass): TJsHostClass;
var
  ParentPrototype: TJsObject;
begin
  Result := TJsHostClass.Create;
  Result.Name := Name;
  if Parent <> nil then
    ParentPrototype := Parent.Prototype
  else
    ParentPrototype := FRealm.Intrinsics[inObjectPrototype];
  Result.Prototype := FRealm.NewObject(ParentPrototype);
  FRealm.NoteIsPrototype(Result.Prototype);
  if not Assigned(Callback) then
    Callback := @HostConstructorRefused;
  Result.Constructor_ := DefineConstructor(FRealm, FRealm.GlobalObject, Name, Callback, Length, Result.Prototype);
  Result.Constructor_.HostData := Result;
  if Parent <> nil then
    Result.Constructor_.Proto := Parent.Constructor_;
  Result.Prototype.DefineData(FRealm, FRealm.Runtime.SymbolValue(wsToStringTag), FRealm.NewString(Name),
    PropertyConfigurable);
  SetLength(FHostClasses, System.Length(FHostClasses) + 1);
  FHostClasses[High(FHostClasses)] := Result;
end;

function TJsEngine.Protect(Value: TJsValue): Integer;
begin
  if System.Length(FFreeRoots) > 0 then
  begin
    Result := FFreeRoots[High(FFreeRoots)];
    SetLength(FFreeRoots, High(FFreeRoots));
  end
  else
  begin
    Result := System.Length(FRoots);
    SetLength(FRoots, Result + 1);
  end;
  FRoots[Result] := Value;
end;

procedure TJsEngine.Unprotect(Handle: Integer);
begin
  if (Handle < 0) or (Handle >= System.Length(FRoots)) then
    Exit;
  FRoots[Handle] := JsUndefined;
  SetLength(FFreeRoots, System.Length(FFreeRoots) + 1);
  FFreeRoots[High(FFreeRoots)] := Handle;
end;

function TJsEngine.Protected(Handle: Integer): TJsValue;
begin
  Result := FRoots[Handle];
end;

procedure TJsEngine.Interrupt;
begin
  FRuntime.InterruptRequested := True;
end;

procedure TJsEngine.CollectGarbage;
begin
  FRuntime.Heap.Collect;
end;

function TJsEngine.HeapBytes: Int64;
begin
  Result := FRuntime.Heap.BytesAllocated;
end;

function TJsEngine.PeakHeapBytes: Int64;
begin
  Result := FRuntime.Heap.PeakBytes;
end;

function TJsEngine.GetMemoryLimit: Int64;
begin
  Result := FRuntime.Heap.MemoryLimit;
end;

procedure TJsEngine.SetMemoryLimit(Value: Int64);
begin
  FRuntime.Heap.MemoryLimit := Value;
end;

end.
