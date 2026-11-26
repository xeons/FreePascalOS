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

  - The object caches of the JS API (exported functions, Memory, Table
    and Global objects): one JavaScript object per store object, so
    identity is stable (instance.exports.f === instance.exports.f, a
    memory exported twice is one Memory object). Store objects live as
    long as the store, and so do their objects.
  - The current ArrayBuffer of each memory that has one; a memory's
    growth (TWasmMemory.OnGrow, also from memory.grow inside
    WebAssembly) detaches a fixed length one, and the next `buffer`
    makes a new one over the memory's new data; a resizable one
    (toResizableBuffer) follows the memory instead, and its resize()
    grows the memory by whole pages (ResizeBuffer).
  - Per window (realm): the prototypes and error constructors its
    platform script registered, for objects and errors the engine makes.

  The agent is a root provider of the heap: it marks those objects, the
  externrefs the store holds (Store.EnumerateReferences: tables,
  globals, element segments, the live slots of suspended frames) and
  the JavaScript functions behind host functions (EnumerateHostData).
  An externref is the JavaScript value's own 64 bits (JS null is the
  null reference), and a host function's data is the callable's value.

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
  Wasm.Runtime,
  Web.IdMaps,
  Web.Bindings.Context;

type
  { The objects a window's platform script registers. }
  TWasmPrototypeKind = (wpModule, wpMemory, wpTable, wpGlobal);
  TWasmErrorKind = (weCompileError, weLinkError, weRuntimeError);

  TWasmRealmData = class
  public
    Prototypes: array[TWasmPrototypeKind] of TJsObject;
    ErrorConstructors: array[TWasmErrorKind] of TJsObject;
  end;

  TWasmAgent = class(TWasmStore)
  private
    FContext: TBindingContext;
    FHeap: TJsHeap;
    FWrappers: TIdMap;
    FBuffers: TIdMap;
    FRealms: TIdMap;
    FTracer: TJsTracer;
    procedure MarkRoots(Tracer: TJsTracer);
    procedure MarkReference(Reference: Pointer);
    procedure MarkObjects(Map: TIdMap);
    function InterruptWanted(Store: TWasmStore): Boolean;
  public
    constructor CreateFor(TopContext: TBindingContext);
    destructor Destroy; override;
    { The JavaScript object made for a store object (a TWasmFunction,
      TWasmMemory, TWasmTable or TWasmGlobal), or nil. }
    function WrapperOf(StoreObject: TObject): TJsObject;
    procedure SetWrapper(StoreObject: TObject; Wrapper: TJsObject);
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
    { What Context's platform script registered (made empty if not). }
    function RealmData(Context: TBindingContext): TWasmRealmData;
    procedure ForgetRealm(Context: TBindingContext);
    property Context: TBindingContext read FContext;
  end;

{ The agent of Context's runtime, made if it has none. }
function AgentOf(Context: TBindingContext): TWasmAgent;
{ The agent of a store object's store. }
function AgentOfStore(Store: TWasmStore): TWasmAgent; inline;

implementation

uses
  Js.Runtime,
  Wasm.Types;

var
  { One per top-level context. }
  Agents: array of TWasmAgent;

function AgentOfStore(Store: TWasmStore): TWasmAgent;
begin
  Result := TWasmAgent(Store);
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

{ A context going: a top-level one takes its agent along (its engine,
  freed next, then releases what its objects held), a frame its
  registered objects. }
procedure ContextGoing(Context: TBindingContext);
var
  Index: Integer;
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
      Agent.ForgetRealm(Context);
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
  OnInterrupt := @InterruptWanted;
  FHeap.AddRootProvider(@MarkRoots);
end;

destructor TWasmAgent.Destroy;
var
  Data: TObjectArray;
  Index: Integer;
begin
  FHeap.RemoveRootProvider(@MarkRoots);
  { The buffers' memory goes with the store: they must not see it. }
  Data := FBuffers.Values;
  for Index := 0 to High(Data) do
  begin
    TJsArrayBuffer(Data[Index]).HostDetachOnly := False;
    TJsArrayBuffer(Data[Index]).Detach;
  end;
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
  FTracer.MarkValue(TJsValue(PtrUInt(Reference)));
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

procedure TWasmAgent.MarkRoots(Tracer: TJsTracer);
var
  Data: TObjectArray;
  Index: Integer;
  Kind: TWasmPrototypeKind;
  ErrorKind: TWasmErrorKind;
  Realm: TWasmRealmData;
begin
  FTracer := Tracer;
  try
    MarkObjects(FWrappers);
    MarkObjects(FBuffers);
    Data := FRealms.Values;
    for Index := 0 to High(Data) do
    begin
      Realm := TWasmRealmData(Data[Index]);
      for Kind := Low(Kind) to High(Kind) do
        if Realm.Prototypes[Kind] <> nil then
          Tracer.MarkCell(Realm.Prototypes[Kind]);
      for ErrorKind := Low(ErrorKind) to High(ErrorKind) do
        if Realm.ErrorConstructors[ErrorKind] <> nil then
          Tracer.MarkCell(Realm.ErrorConstructors[ErrorKind]);
    end;
    EnumerateReferences(@MarkReference);
    EnumerateHostData(@MarkReference);
  finally
    FTracer := nil;
  end;
end;

function TWasmAgent.WrapperOf(StoreObject: TObject): TJsObject;
var
  Found: TObject;
begin
  if FWrappers.TryGetValue(QWord(PtrUInt(StoreObject)), Found) then
    Result := TJsObject(Found)
  else
    Result := nil;
end;

procedure TWasmAgent.SetWrapper(StoreObject: TObject; Wrapper: TJsObject);
begin
  FWrappers.Add(QWord(PtrUInt(StoreObject)), Wrapper);
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

function TWasmAgent.RealmData(Context: TBindingContext): TWasmRealmData;
var
  Found: TObject;
begin
  if FRealms.TryGetValue(QWord(PtrUInt(Context)), Found) then
    Exit(TWasmRealmData(Found));
  Result := TWasmRealmData.Create;
  FRealms.Add(QWord(PtrUInt(Context)), Result);
end;

procedure TWasmAgent.ForgetRealm(Context: TBindingContext);
var
  Found: TObject;
begin
  if not FRealms.TryGetValue(QWord(PtrUInt(Context)), Found) then
    Exit;
  FRealms.Remove(QWord(PtrUInt(Context)));
  Found.Free;
end;

initialization
  AddContextGoingHook(@ContextGoing);
end.
