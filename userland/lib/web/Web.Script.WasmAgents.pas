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
  The WebAssembly state of a JavaScript agent: libwasm's store (one per
  agent, as the JS API's "associated store") and what the JS API keeps
  beside it.

  An agent here is a top-level window's runtime: its frames and its
  dedicated workers are realms of the same runtime on the same thread,
  so they share the store; a shared or service worker's agent has a
  window (and so a store) of its own. TWasmAgent is the store itself (a
  subclass), made the first time a realm of the runtime uses
  WebAssembly and freed when the top-level context goes.

  What the agent keeps for the JS heap:

  - The object caches of the JS API (exported functions, Memory, Table,
    Global and Tag objects): one JavaScript object per store object, so
    identity is stable (instance.exports.f === instance.exports.f, a
    memory exported twice is one Memory object). Store objects live as
    long as the store, and so do their objects. A worker's realm, which
    is an agent of its own in a browser, has caches of its own (so
    WebAssembly.JSTag is a Tag of its realm there); the windows and
    frames share the agent's.
  - The current ArrayBuffer of each memory that has one; a memory's
    growth (TWasmMemory.OnGrow, also from memory.grow inside
    WebAssembly) detaches a fixed length one, and the next `buffer`
    makes a new one over the memory's new data; a resizable one
    (toResizableBuffer) follows the memory instead, and its resize()
    grows the memory by whole pages (ResizeBuffer).
  - Per realm that has a WebAssembly namespace (a window, a frame, a
    worker's global scope: platform/57-webassembly.js runs in each and
    registers it): the prototypes and error constructors of that realm,
    for the objects and errors the engine makes there. Natives find
    their agent through their realm (AgentOfRealm).

  - The objects of WebAssembly's collected heap that JavaScript holds:
    one Exported GC Object per struct or array and one
    WebAssembly.Exception per exception object (Web.Script.
    WasmReferences), kept weakly - an entry goes when its object is
    collected - so identity is stable while anything holds the object.
  - The JavaScript exception tag (WebAssembly.JSTag), made on first use.

  The two collectors trace through each other (libwasm's protocol b):
  the agent is a root provider of the heap, and at each collection it
  starts the store's host trace (Store.BeginHostTrace: the store's
  roots - tables, globals, element segments, the live slots of
  suspended frames, pinned objects - are marked and every host word
  found gives the JavaScript value it holds to the marking); a wrapper
  of a WebAssembly object, when the marking reaches it, traces on from
  its object (Store.TraceFromHost); when marking is done (the weak
  processors' last phase) the dead wrappers leave the caches and
  Store.EndHostTrace frees every WebAssembly object nothing reached. So
  a cycle through both heaps (a struct holding a JavaScript object that
  holds the struct's wrapper) is collected like any other garbage. The
  agent also marks the objects above and the JavaScript functions
  behind host functions (EnumerateHostData). Host words are
  Web.Script.WasmHostValues'; a host function's data is the callable's
  value.

  Long running code: the store's interrupt hook answers the runtime's
  InterruptRequested, which the slow script watchdog sets
  (Web.Script.Watchdog), so a module looping for ever is stopped the
  way a looping script is (an uncatchable termination at the boundary
  back into JavaScript).
}
unit Web.Script.WasmAgents;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Objects,
  Js.Heap,
  Js.ArrayBuffers,
  Wasm.Types,
  Wasm.Runtime,
  Web.IdMaps,
  Web.Bindings.Context;

type
  { The objects a realm's platform script registers. }
  TWasmPrototypeKind = (wpModule, wpMemory, wpTable, wpGlobal, wpTag, wpException);
  TWasmErrorKind = (weCompileError, weLinkError, weRuntimeError);

  TWasmRealmData = class
  public
    Prototypes: array[TWasmPrototypeKind] of TJsObject;
    ErrorConstructors: array[TWasmErrorKind] of TJsObject;
    { A worker's realm (an agent of its own in a browser): the objects
      made there for store objects, so they are of its realm; nil for a
      window's or a frame's realm, which use the agent's. }
    Wrappers: TIdMap;
    destructor Destroy; override;
  end;

  TWasmAgent = class(TWasmStore)
  private
    FContext: TBindingContext;
    FHeap: TJsHeap;
    FWrappers: TIdMap;
    FBuffers: TIdMap;
    FRealms: TIdMap;
    FReferenceObjects: TIdMap;
    FJsTag: TWasmTag;
    FTracer: TJsTracer;
    FHostTracing: Boolean;
    procedure MarkRoots(Tracer: TJsTracer);
    function FinishTrace(Tracer: TJsTracer; Phase: Integer): Boolean;
    procedure MarkReference(Reference: Pointer);
    procedure MarkObjects(Map: TIdMap);
    function InterruptWanted(Store: TWasmStore): Boolean;
  public
    constructor CreateFor(TopContext: TBindingContext);
    destructor Destroy; override;
    { The JavaScript object made in Realm's scope (a worker's realm, or
      the windows and frames) for a store object (a TWasmFunction,
      TWasmMemory, TWasmTable, TWasmGlobal or TWasmTag), or nil. }
    function WrapperOf(Realm: TJsRealm; StoreObject: TObject): TJsObject;
    procedure SetWrapper(Realm: TJsRealm; StoreObject: TObject; Wrapper: TJsObject);
    { A memory's current ArrayBuffer, or nil (none yet, or detached by a
      growth). }
    function BufferOf(Memory: TWasmMemory): TJsArrayBuffer;
    procedure SetBuffer(Memory: TWasmMemory; Buffer: TJsArrayBuffer);
    { Forgets the memory's buffer and detaches it. }
    procedure DropBuffer(Memory: TWasmMemory);
    { OnGrow of every memory with a buffer: a fixed length buffer is
      detached, a resizable one shows the new memory. }
    procedure MemoryGrown(Memory: TWasmMemory; OldData: Pointer; OldLength: QWord);
    { A resizable buffer's resize(): the memory grows to NewByteLength,
      a whole number of pages no smaller than now. }
    function ResizeBuffer(Buffer: TJsArrayBuffer; NewByteLength: SizeInt): Boolean;
    { What the realm's platform script registered (made empty if not). }
    function RealmData(Realm: TJsRealm): TWasmRealmData;
    procedure ForgetRealm(Realm: TJsRealm);
    { The JavaScript object of a GC heap object (an Exported GC Object or
      a WebAssembly.Exception), or nil; kept while the object lives. }
    function ReferenceObjectOf(Reference: Pointer): TJsObject;
    procedure SetReferenceObject(Reference: Pointer; Wrapper: TJsObject);
    { A wrapper reached by the marking: what its object reaches is kept. }
    procedure TraceReference(Reference: Pointer);
    { How many GC heap objects have a JavaScript object now. }
    function ReferenceObjectCount: Integer;
    { WebAssembly.JSTag's tag: (externref) -> (). }
    function JsTag: TWasmTag;
  public
    { The exports object of the wasm:js-string builtins (made by
      Web.Script.WasmStringBuiltins the first time), kept alive here. }
    StringBuiltins: TJsObject;
    property Context: TBindingContext read FContext;
  end;

{ The agent of Context's runtime, made if it has none. }
function AgentOf(Context: TBindingContext): TWasmAgent;
{ A realm of Context's runtime gets a WebAssembly namespace: its data. }
function RegisterRealm(Realm: TJsRealm; Context: TBindingContext): TWasmRealmData;
{ The agent of a registered realm (nil: none). }
function AgentOfRealm(Realm: TJsRealm): TWasmAgent;
{ The agent of a store object's store. }
function AgentOfStore(Store: TWasmStore): TWasmAgent; inline;
{ The agent whose host trace Tracer (a heap) is running, or nil. }
function TracingAgent(Tracer: TJsTracer): TWasmAgent;

implementation

uses
  Js.Runtime,
  Wasm.GcHeap,
  Wasm.Api,
  Web.Script.WasmHostValues;

var
  { One per top-level context. }
  Agents: array of TWasmAgent;
  { Realm to agent, for the realms with a WebAssembly namespace. }
  RealmAgents: TIdMap;

function AgentOfStore(Store: TWasmStore): TWasmAgent;
begin
  Result := TWasmAgent(Store);
end;

function TracingAgent(Tracer: TJsTracer): TWasmAgent;
var
  Index: Integer;
begin
  for Index := 0 to High(Agents) do
    if Agents[Index].FHostTracing and (TJsTracer(Agents[Index].FHeap) = Tracer) then
      Exit(Agents[Index]);
  Result := nil;
end;

function AgentOf(Context: TBindingContext): TWasmAgent;
var
  Top: TBindingContext;
  Index: Integer;
begin
  Top := Context.TopContext;
  for Index := 0 to High(Agents) do
    if Agents[Index].FContext = Top then
      Exit(Agents[Index]);
  Result := TWasmAgent.CreateFor(Top);
  SetLength(Agents, Length(Agents) + 1);
  Agents[High(Agents)] := Result;
end;

function RegisterRealm(Realm: TJsRealm; Context: TBindingContext): TWasmRealmData;
var
  Agent: TWasmAgent;
  Index: Integer;
begin
  Agent := AgentOf(Context);
  RealmAgents.Add(QWord(PtrUInt(Realm)), Agent);
  Result := Agent.RealmData(Realm);
  for Index := 0 to High(Context.WorkerEngines) do
    if (Context.WorkerEngines[Index].Realm = Realm) and (Result.Wrappers = nil) then
      Result.Wrappers := TIdMap.Create;
end;

destructor TWasmRealmData.Destroy;
begin
  Wrappers.Free;
  inherited Destroy;
end;

function AgentOfRealm(Realm: TJsRealm): TWasmAgent;
var
  Found: TObject;
begin
  if RealmAgents.TryGetValue(QWord(PtrUInt(Realm)), Found) then
    Result := TWasmAgent(Found)
  else
    Result := nil;
end;

{ A context going: a top-level one takes its agent along (its engine,
  freed next, then releases what its objects held), a frame its realm's
  and its workers' registered objects. }
procedure ContextGoing(Context: TBindingContext);
var
  Index, Worker: Integer;
  Agent: TWasmAgent;
begin
  for Index := 0 to High(Agents) do
  begin
    Agent := Agents[Index];
    if Agent.FContext = Context then
    begin
      Agents[Index] := Agents[High(Agents)];
      SetLength(Agents, High(Agents));
      Agent.Free;
      Exit;
    end;
    if Context.TopContext = Agent.FContext then
    begin
      Agent.ForgetRealm(Context.Engine.Realm);
      for Worker := 0 to High(Context.WorkerEngines) do
        Agent.ForgetRealm(Context.WorkerEngines[Worker].Realm);
    end;
  end;
end;

{ TWasmAgent }

constructor TWasmAgent.CreateFor(TopContext: TBindingContext);
begin
  inherited Create(TWasmStore.DefaultOptions);
  FContext := TopContext;
  FHeap := TopContext.Engine.Runtime.Heap;
  FWrappers := TIdMap.Create;
  FBuffers := TIdMap.Create;
  FRealms := TIdMap.Create;
  FReferenceObjects := TIdMap.Create;
  OnInterrupt := @InterruptWanted;
  FHeap.AddRootProvider(@MarkRoots);
  FHeap.AddWeakProcessor(@FinishTrace);
end;

destructor TWasmAgent.Destroy;
var
  Data: TObjectArray;
  Keys: TIdArray;
  Index: Integer;
begin
  FHeap.RemoveRootProvider(@MarkRoots);
  FHeap.RemoveWeakProcessor(@FinishTrace);
  FReferenceObjects.Free;
  { The buffers' memory goes with the store: they must not see it. }
  Data := FBuffers.Values;
  for Index := 0 to High(Data) do
  begin
    TJsArrayBuffer(Data[Index]).HostDetachOnly := False;
    TJsArrayBuffer(Data[Index]).Detach;
  end;
  Keys := FRealms.Keys;
  for Index := 0 to High(Keys) do
    RealmAgents.Remove(Keys[Index]);
  Data := FRealms.Values;
  for Index := 0 to High(Data) do
    Data[Index].Free;
  FRealms.Free;
  FBuffers.Free;
  FWrappers.Free;
  inherited Destroy;
end;

function TWasmAgent.InterruptWanted(Store: TWasmStore): Boolean;
begin
  { The watchdog's request stays set: the termination at the way back
    into JavaScript takes it. }
  Result := FContext.Engine.Runtime.InterruptRequested;
end;

procedure TWasmAgent.MarkReference(Reference: Pointer);
begin
  MarkHostWord(FTracer, Reference);
end;

procedure TWasmAgent.MarkObjects(Map: TIdMap);
var
  Data: TObjectArray;
  Index: Integer;
begin
  Data := Map.Values;
  for Index := 0 to High(Data) do
    FTracer.MarkCell(TJsCell(Data[Index]));
end;

{ The start of a collection: the host trace begins here and goes on as
  wrappers are reached (TraceReference) until FinishTrace. }
procedure TWasmAgent.MarkRoots(Tracer: TJsTracer);
var
  Data: TObjectArray;
  Index: Integer;
  Kind: TWasmPrototypeKind;
  ErrorKind: TWasmErrorKind;
  Realm: TWasmRealmData;
begin
  FTracer := Tracer;
  MarkObjects(FWrappers);
  MarkObjects(FBuffers);
  if StringBuiltins <> nil then
    Tracer.MarkCell(StringBuiltins);
  Data := FRealms.Values;
  for Index := 0 to High(Data) do
  begin
    Realm := TWasmRealmData(Data[Index]);
    if Realm.Wrappers <> nil then
      MarkObjects(Realm.Wrappers);
    for Kind := Low(Kind) to High(Kind) do
      if Realm.Prototypes[Kind] <> nil then
        Tracer.MarkCell(Realm.Prototypes[Kind]);
    for ErrorKind := Low(ErrorKind) to High(ErrorKind) do
      if Realm.ErrorConstructors[ErrorKind] <> nil then
        Tracer.MarkCell(Realm.ErrorConstructors[ErrorKind]);
  end;
  EnumerateHostData(@MarkReference);
  BeginHostTrace(@MarkReference);
  FHostTracing := True;
end;

procedure TWasmAgent.TraceReference(Reference: Pointer);
begin
  if FHostTracing then
    TraceFromHost(Reference, @MarkReference);
end;

{ Marking is complete: wrappers not marked are garbage (their entries
  go), and so is every WebAssembly object nothing reached. }
function TWasmAgent.FinishTrace(Tracer: TJsTracer; Phase: Integer): Boolean;
var
  Keys: TIdArray;
  Wrapper: TObject;
  Index: Integer;
begin
  Result := False;
  if (Phase <> 1) or not FHostTracing then
    Exit;
  Keys := FReferenceObjects.Keys;
  for Index := 0 to High(Keys) do
    if FReferenceObjects.TryGetValue(Keys[Index], Wrapper) and not TJsCell(Wrapper).Marked then
      FReferenceObjects.Remove(Keys[Index]);
  FHostTracing := False;
  FTracer := nil;
  EndHostTrace;
end;

function TWasmAgent.ReferenceObjectCount: Integer;
begin
  Result := FReferenceObjects.Count;
end;

function TWasmAgent.ReferenceObjectOf(Reference: Pointer): TJsObject;
var
  Found: TObject;
begin
  if FReferenceObjects.TryGetValue(QWord(PtrUInt(Reference)), Found) then
    Result := TJsObject(Found)
  else
    Result := nil;
end;

procedure TWasmAgent.SetReferenceObject(Reference: Pointer; Wrapper: TJsObject);
begin
  { The object stays exposed (alive) while the wrapper's tracing reaches
    it. }
  Heap.Expose(Reference);
  FReferenceObjects.Add(QWord(PtrUInt(Reference)), Wrapper);
end;

function TWasmAgent.JsTag: TWasmTag;
begin
  if FJsTag = nil then
    FJsTag := WasmNewTag(Self, MakeFunctionType([WasmExternRefType], []));
  Result := FJsTag;
end;

function TWasmAgent.WrapperOf(Realm: TJsRealm; StoreObject: TObject): TJsObject;
var
  Map: TIdMap;
  Found: TObject;
begin
  Map := RealmData(Realm).Wrappers;
  if Map = nil then
    Map := FWrappers;
  if Map.TryGetValue(QWord(PtrUInt(StoreObject)), Found) then
    Result := TJsObject(Found)
  else
    Result := nil;
end;

procedure TWasmAgent.SetWrapper(Realm: TJsRealm; StoreObject: TObject; Wrapper: TJsObject);
var
  Map: TIdMap;
begin
  Map := RealmData(Realm).Wrappers;
  if Map = nil then
    Map := FWrappers;
  Map.Add(QWord(PtrUInt(StoreObject)), Wrapper);
end;

function TWasmAgent.BufferOf(Memory: TWasmMemory): TJsArrayBuffer;
var
  Found: TObject;
begin
  if FBuffers.TryGetValue(QWord(PtrUInt(Memory)), Found) then
    Result := TJsArrayBuffer(Found)
  else
    Result := nil;
end;

procedure TWasmAgent.SetBuffer(Memory: TWasmMemory; Buffer: TJsArrayBuffer);
begin
  FBuffers.Add(QWord(PtrUInt(Memory)), Buffer);
  Memory.OnGrow := @MemoryGrown;
end;

procedure TWasmAgent.DropBuffer(Memory: TWasmMemory);
var
  Buffer: TJsArrayBuffer;
begin
  Buffer := BufferOf(Memory);
  if Buffer = nil then
    Exit;
  FBuffers.Remove(QWord(PtrUInt(Memory)));
  { An external buffer without a free procedure: detaching only lets go
    of the data, which the memory owns. }
  Buffer.HostDetachOnly := False;
  Buffer.Detach;
end;

procedure TWasmAgent.MemoryGrown(Memory: TWasmMemory; OldData: Pointer; OldLength: QWord);
var
  Buffer: TJsArrayBuffer;
begin
  Buffer := BufferOf(Memory);
  if Buffer = nil then
    Exit;
  if Buffer.Resizable then
  begin
    Buffer.Data := Memory.Data;
    Buffer.ByteLength := Memory.ByteLength;
  end
  else
    DropBuffer(Memory);
end;

function TWasmAgent.ResizeBuffer(Buffer: TJsArrayBuffer; NewByteLength: SizeInt): Boolean;
var
  Keys: TIdArray;
  Index: Integer;
  Memory: TWasmMemory;
begin
  Memory := nil;
  Keys := FBuffers.Keys;
  for Index := 0 to High(Keys) do
    if BufferOf(TWasmMemory(PtrUInt(Keys[Index]))) = Buffer then
      Memory := TWasmMemory(PtrUInt(Keys[Index]));
  if (Memory = nil) or (NewByteLength mod WasmPageSize <> 0) or (QWord(NewByteLength) < Memory.ByteLength) then
    Exit(False);
  Result := Memory.Grow((QWord(NewByteLength) - Memory.ByteLength) div WasmPageSize) >= 0;
end;

function TWasmAgent.RealmData(Realm: TJsRealm): TWasmRealmData;
var
  Found: TObject;
begin
  if FRealms.TryGetValue(QWord(PtrUInt(Realm)), Found) then
    Exit(TWasmRealmData(Found));
  Result := TWasmRealmData.Create;
  FRealms.Add(QWord(PtrUInt(Realm)), Result);
end;

procedure TWasmAgent.ForgetRealm(Realm: TJsRealm);
var
  Found: TObject;
begin
  RealmAgents.Remove(QWord(PtrUInt(Realm)));
  if not FRealms.TryGetValue(QWord(PtrUInt(Realm)), Found) then
    Exit;
  FRealms.Remove(QWord(PtrUInt(Realm)));
  Found.Free;
end;

initialization
  RealmAgents := TIdMap.Create;
  AddContextGoingHook(@ContextGoing);
end.
