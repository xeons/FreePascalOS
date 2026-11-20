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
  Compiled code and the callable objects.

  TJsCode is one compiled function: its instructions, constants, nested
  functions, inline caches, exception handlers and line table. It is a
  cell: closures and the constants keep it alive.

  TJsEnvironment holds the captured variables of one scope instance;
  closures keep the environment they were made in.

  The callable objects: TJsClosure (bytecode with its environment),
  TJsNativeFunction (a Pascal callback, with a magic number and data
  for callbacks shared by several built-ins, and a method pointer for
  hosts), TJsBoundFunction (Function.prototype.bind).

  TJsSuspension is a frame put aside: a generator between next() calls,
  an async function waiting for a promise.
}
unit Js.Functions;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Shapes,
  Js.Runtime,
  Js.Objects;

const
  CodeStrict = 1;
  CodeArrow = 2;
  CodeGenerator = 4;
  CodeAsync = 8;
  CodeClassConstructor = 16;
  CodeDerivedConstructor = 32;
  CodeMethod = 64;
  CodeScript = 128;
  { new is allowed (ordinary functions and class constructors). }
  CodeConstructor = 256;
  CodeHasRest = 512;
  CodeNeedsArguments = 1024;
  CodeMappedArguments = 2048;
  CodeGetter = 4096;
  CodeSetter = 8192;

type
  TJsPropertyCache = record
    Shape: TJsShape;
    Generation: LongWord;
    Slot: Integer;
    { A property found on the prototype: where, and its shape then. }
    Holder: TJsObject;
    HolderShape: TJsShape;
    { An addition: the shape after it, and the prototype epoch then. }
    NewShape: TJsShape;
    Epoch: LongWord;
  end;
  PJsPropertyCache = ^TJsPropertyCache;

  TJsHandler = record
    StartPC: Integer;
    EndPC: Integer;
    HandlerPC: Integer;
    Register: Integer;
    EnvironmentDepth: Integer;
    IsFinally: Boolean;
  end;

  TJsLineEntry = record
    PC: Integer;
    Line: Integer;
    Column: Integer;
  end;

  { The text of a script, shared by its functions (toString). }
  TJsSource = class(TJsCell)
  public
    FileName: string;
    Text: UnicodeString;
    function MemorySize: SizeInt; override;
  end;

  TJsCode = class(TJsCell)
  public
    Instructions: array of LongInt;
    Constants: TJsValueList;
    Functions: array of TJsCode;
    Caches: array of TJsPropertyCache;
    Handlers: array of TJsHandler;
    Lines: array of TJsLineEntry;
    Name: TJsString;
    Source: TJsSource;
    SourceStart: Integer;
    SourceFinish: Integer;
    RegisterCount: Integer;
    ParameterCount: Integer;
    Length: Integer;
    Flags: LongWord;
    ArgumentsRegister: Integer;
    RestRegister: Integer;
    { Template objects made at each site (GetTemplateObject). }
    TemplateObjects: TJsValueList;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
    function LineAt(PC: Integer; out Column: Integer): Integer;
  end;

  TJsEnvironment = class(TJsCell)
  public
    Parent: TJsEnvironment;
    Count: Integer;
    Slots: PJsValueArray;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
  end;

  TJsClosure = class(TJsObject)
  public
    Code: TJsCode;
    Environment: TJsEnvironment;
    HomeObject: TJsObject;
    { Class constructors: the instance field initializer. }
    FieldInitializer: TJsValue;
    { Field initializers: computed keys and private methods, made when
      the class was defined. }
    ClassSlots: TJsValueList;
    procedure Trace(Tracer: TJsTracer); override;
    procedure MaterializeLazy(R: TJsRealm); override;
  end;

  TJsNativeFunction = class;

  TJsNativeCallback = function(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
    Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
  TJsNativeMethod = function(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
    Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue of object;

  TJsNativeFunction = class(TJsObject)
  public
    Callback: TJsNativeCallback;
    Method: TJsNativeMethod;
    Magic: Integer;
    Data: TJsValue;
    Data2: TJsValue;
    HostData: Pointer;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsBoundFunction = class(TJsObject)
  public
    Target: TJsValue;
    BoundThis: TJsValue;
    BoundArguments: TJsValueList;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsSuspensionState = (ssSuspendedStart, ssSuspendedYield, ssExecuting, ssCompleted);

  { A frame put aside, and what it is for: a generator object, or the
    state of an async function (the promise it settles). }
  TJsSuspension = class(TJsObject)
  public
    State: TJsSuspensionState;
    Code: TJsCode;
    Callee: TJsValue;
    ThisValue: TJsValue;
    NewTarget: TJsValue;
    Registers: TJsValueList;
    PC: Integer;
    Environment: TJsEnvironment;
    EnvironmentDepth: Integer;
    ArgumentCount: Integer;
    { The register a resumption's value goes to. }
    ResumeRegister: Integer;
    ResumeKind: Integer;
    { The suspending instruction, where a throw or return resumes. }
    SuspendPC: Integer;
    { Suspended in yield*: the next resumption goes to the inner iterator. }
    Delegating: Boolean;
    { Suspended in await (an async generator's driver waits for it). }
    Awaiting: Boolean;
    { Async functions: the promise and its resolving functions. }
    Promise: TJsValue;
    ResolveFunction: TJsValue;
    RejectFunction: TJsValue;
    { Async generators: the queue of requests (an array). }
    Queue: TJsValue;
    IsAsyncGenerator: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  { A frame's caught completion: an exception, or a return travelling
    through finally blocks (generator.return()). }
  TJsReturnCompletion = class(TJsCell)
  public
    Value: TJsValue;
    procedure Trace(Tracer: TJsTracer); override;
  end;

function NewEnvironment(Heap: TJsHeap; Parent: TJsEnvironment; Count: Integer): TJsEnvironment;
function ArgumentOrUndefined(Args: PJsValueArray; ArgCount, Index: Integer): TJsValue; inline;
function JsIsCallable(Value: TJsValue): Boolean; inline;
function JsIsConstructor(Value: TJsValue): Boolean;

implementation

function TJsSource.MemorySize: SizeInt;
begin
  Result := InstanceSize + System.Length(Text) * 2 + System.Length(FileName);
end;

{ TJsCode }

procedure TJsCode.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  Tracer.MarkValues(@Constants[0], System.Length(Constants));
  for Index := 0 to High(Functions) do
    Tracer.MarkCell(Functions[Index]);
  for Index := 0 to High(Caches) do
  begin
    Tracer.MarkCell(Caches[Index].Shape);
    Tracer.MarkCell(Caches[Index].Holder);
    Tracer.MarkCell(Caches[Index].HolderShape);
    Tracer.MarkCell(Caches[Index].NewShape);
  end;
  Tracer.MarkCell(Name);
  Tracer.MarkCell(Source);
  Tracer.MarkValues(@TemplateObjects[0], System.Length(TemplateObjects));
end;

function TJsCode.MemorySize: SizeInt;
begin
  Result := InstanceSize + System.Length(Instructions) * 4 + System.Length(Constants) * 8 +
    System.Length(Functions) * 8 + System.Length(Caches) * SizeOf(TJsPropertyCache) +
    System.Length(Handlers) * SizeOf(TJsHandler) + System.Length(Lines) * SizeOf(TJsLineEntry);
end;

function TJsCode.LineAt(PC: Integer; out Column: Integer): Integer;
var
  Low, High, Middle: Integer;
begin
  Result := 0;
  Column := 0;
  Low := 0;
  High := System.Length(Lines) - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Lines[Middle].PC <= PC then
    begin
      Result := Lines[Middle].Line;
      Column := Lines[Middle].Column;
      Low := Middle + 1;
    end
    else
      High := Middle - 1;
  end;
end;

{ TJsEnvironment }

function NewEnvironment(Heap: TJsHeap; Parent: TJsEnvironment; Count: Integer): TJsEnvironment;
var
  Index: Integer;
begin
  Result := TJsEnvironment.Create;
  Heap.Register(Result, ckEnvironment);
  Result.Parent := Parent;
  Result.Count := Count;
  if Count > 0 then
  begin
    Result.Slots := GetMem(Count * SizeOf(TJsValue));
    for Index := 0 to Count - 1 do
      Result.Slots^[Index] := JsUndefined;
    Heap.Account(Count * SizeOf(TJsValue));
  end;
end;

destructor TJsEnvironment.Destroy;
begin
  if Slots <> nil then
    FreeMem(Slots);
  inherited Destroy;
end;

procedure TJsEnvironment.Trace(Tracer: TJsTracer);
begin
  if Parent <> nil then
    Tracer.MarkCell(Parent);
  if Count > 0 then
    Tracer.MarkValues(PJsValue(Slots), Count);
end;

function TJsEnvironment.MemorySize: SizeInt;
begin
  Result := InstanceSize + Count * SizeOf(TJsValue);
end;

{ TJsClosure }

procedure TJsClosure.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Code);
  if Environment <> nil then
    Tracer.MarkCell(Environment);
  if HomeObject <> nil then
    Tracer.MarkCell(HomeObject);
  Tracer.MarkValue(FieldInitializer);
  Tracer.MarkValues(@ClassSlots[0], System.Length(ClassSlots));
end;

procedure TJsClosure.MaterializeLazy(R: TJsRealm);
var
  Prototype: TJsObject;
begin
  inherited MaterializeLazy(R);
  if (Code.Flags and CodeGenerator) <> 0 then
  begin
    if (Code.Flags and CodeAsync) <> 0 then
      Prototype := R.NewObject(R.Intrinsics[inAsyncGeneratorPrototype])
    else
      Prototype := R.NewObject(R.Intrinsics[inGeneratorPrototype]);
    DefineData(R, R.PrototypeKey, JsObjectValue(Prototype), PropertyWritable);
    Exit;
  end;
  Prototype := R.NewPlainObject;
  Prototype.DefineData(R, R.ConstructorKey, JsObjectValue(Self), PropertyHidden);
  DefineData(R, R.PrototypeKey, JsObjectValue(Prototype), PropertyWritable);
end;

{ TJsNativeFunction }

procedure TJsNativeFunction.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Data);
  Tracer.MarkValue(Data2);
end;

{ TJsBoundFunction }

procedure TJsBoundFunction.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Target);
  Tracer.MarkValue(BoundThis);
  Tracer.MarkValues(@BoundArguments[0], System.Length(BoundArguments));
end;

{ TJsSuspension }

procedure TJsSuspension.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Code);
  Tracer.MarkValue(Callee);
  Tracer.MarkValue(ThisValue);
  Tracer.MarkValue(NewTarget);
  Tracer.MarkValues(@Registers[0], System.Length(Registers));
  if Environment <> nil then
    Tracer.MarkCell(Environment);
  Tracer.MarkValue(Promise);
  Tracer.MarkValue(ResolveFunction);
  Tracer.MarkValue(RejectFunction);
  Tracer.MarkValue(Queue);
end;

procedure TJsReturnCompletion.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkValue(Value);
end;

function ArgumentOrUndefined(Args: PJsValueArray; ArgCount, Index: Integer): TJsValue;
begin
  if Index < ArgCount then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function JsIsCallable(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and ((JsAsObject(Value).ObjectFlags and ObjectCallable) <> 0);
end;

function JsIsConstructor(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and ((JsAsObject(Value).ObjectFlags and ObjectConstructor) <> 0);
end;

end.
