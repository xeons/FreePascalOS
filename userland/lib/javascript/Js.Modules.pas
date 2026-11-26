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
  ES modules: loading a module graph through the host, linking and
  evaluating it (top-level await included), import() and import.meta.

  The host provides two hooks. The resolver turns a specifier and the
  referrer's key into a module key (a URL for the browser, a path for
  the js shell); the default resolves "./" and "../" against the
  referrer's directory. The fetcher gets a TJsModuleFetch for a key and
  calls Succeed with the source or Fail with a message, at once or
  later (an asynchronous fetch). The module map keeps one module per
  key and type, fetched once; JSON modules (with type "json") are
  parsed into a default export.

  Loading follows the specification's LoadRequestedModules (a count of
  the requests still outstanding per graph), then a job links
  (InnerModuleLinking: the strongly connected components of the graph)
  and evaluates (InnerModuleEvaluation, with the asynchronous module
  steps: modules that await, and those waiting for them, finish in the
  order they started). Link runs each module's initializer, which makes
  its hoisted functions, so a cycle's modules can call each other's
  functions before their bodies run.
}
unit Js.Modules;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.ModuleRecords,
  Js.Promises,
  Js.Interpreter;

type
  TJsModuleLoader = class;

  { A module the host is asked to fetch. Succeed or Fail is called once
    (during the fetcher call or later); the object is freed then. }
  TJsModuleFetch = class
  private
    FLoader: TJsModuleLoader;
    FEntry: TObject;
  public
    { The resolved key and whether JSON is asked for. }
    Key: string;
    Json: Boolean;
    { UTF-8 source text. }
    procedure Succeed(const Source: string);
    procedure Fail(const Message: string);
  end;

  TJsModuleResolver = function(const Specifier, ReferrerKey: string; out Key: string): Boolean of object;
  TJsModuleFetcher = procedure(Fetch: TJsModuleFetch) of object;
  { Adds what the host wants to import.meta (url and resolve are set). }
  TJsModuleMetaHook = procedure(const Key: string; Meta: TJsObject) of object;

  TJsModuleLoader = class
  private
    FRealm: TJsInterpreterRealm;
    FEntries: array of TObject;
    FLoads: array of TObject;
    { Graphs that finished (failed, or handed to the job that links
      them) but are not freed yet: a module map entry may still have
      them waiting, or a caller up the stack may still look at them. }
    FFinishedLoads: array of TObject;
    { Entry points of the loader running (Import, EvaluateSource, a
      fetch finishing); finished graphs are freed when it is 0. }
    FDepth: Integer;
    FFetches: array of TJsModuleFetch;
    FAsyncCounter: Int64;
    procedure MarkRoots(Tracer: TJsTracer);
    function FindEntry(const Key: string; Json: Boolean; MakeIfMissing: Boolean): TObject;
    procedure RemoveLoad(Load: TObject);
    procedure Enter;
    procedure Leave;
    procedure RemoveFetch(Fetch: TJsModuleFetch);
    function NewModule(const Key: string; Json: Boolean): TJsModule;
    procedure RequestModule(Load: TObject; Referrer: TJsModule; Index: Integer; const Key: string; Json: Boolean);
    procedure DeliverModule(Load: TObject; Referrer: TJsModule; Index: Integer; Module: TJsModule);
    procedure FailLoad(Load: TObject; Error: TJsValue);
    procedure InnerModuleLoading(Load: TObject; Module: TJsModule);
    procedure FinishEntry(Entry: TObject);
    function Resolve(const Specifier, ReferrerKey: string; out Key: string; out Error: TJsValue): Boolean;
  public
    Resolver: TJsModuleResolver;
    Fetcher: TJsModuleFetcher;
    MetaHook: TJsModuleMetaHook;
    constructor Create(R: TJsInterpreterRealm);
    destructor Destroy; override;
    { Loads, links and evaluates a module from source; a promise
      settled when it has run (JsException: a syntax error thrown). }
    function EvaluateSource(const Source, Key: string): TJsValue;
    { import(Specifier) from ReferrerKey: a promise for the namespace. }
    function Import(const Specifier, ReferrerKey: string; Json: Boolean): TJsValue;
    { The module loaded for Key (nil: none). }
    function ModuleFor(const Key: string): TJsModule;
    function Link(Module: TJsModule): Boolean;
    function Evaluate(Module: TJsModule): TJsPromise;
    procedure AsyncModuleFulfilled(Module: TJsModule);
    procedure AsyncModuleRejected(Module: TJsModule; Error: TJsValue);
    property Realm: TJsInterpreterRealm read FRealm;
  end;

function ModuleLoaderOf(R: TJsRealm): TJsModuleLoader;
{ "./a.js" against "dir/b.js": "dir/a.js" (paths, "/" separated); other
  specifiers as they are. }
function ResolveRelativePath(const Specifier, ReferrerKey: string): string;
procedure InstallModules(R: TJsInterpreterRealm);

implementation

uses
  Js.Atoms,
  Js.Shapes,
  Js.Conversions,
  Js.Operations,
  Js.Lexer,
  Js.Compiler,
  Js.Builtins.Json;

type
  TLoadWaiter = record
    Load: TObject;
    Referrer: TJsModule;
    Index: Integer;
  end;

  TModuleMapEntry = class
  public
    Key: string;
    Json: Boolean;
    Module: TJsModule;
    Fetching: Boolean;
    Failed: Boolean;
    Error: TJsValue;
    Waiters: array of TLoadWaiter;
  end;

  { One LoadRequestedModules: the graph under one root. }
  TGraphLoad = class
  public
    Root: TJsModule;
    Pending: Integer;
    Failed: Boolean;
    Visited: TJsModuleList;
    Promise: TJsPromise;
    { import(): the promise gets the namespace; else undefined. }
    ForImport: Boolean;
    { Module map entries it waits in. }
    Waiting: Integer;
    function HasVisited(Module: TJsModule): Boolean;
  end;

const
  ReactionNamespace = 0;
  ReactionUndefined = 1;
  ReactionReject = 2;
  ReactionAsyncFulfilled = 3;
  ReactionAsyncRejected = 4;

function TGraphLoad.HasVisited(Module: TJsModule): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Visited) do
    if Visited[Index] = Module then
      Exit(True);
  Result := False;
end;

function ModuleLoaderOf(R: TJsRealm): TJsModuleLoader;
var
  Realm: TJsInterpreterRealm;
begin
  Realm := TJsInterpreterRealm(R);
  if Realm.ModuleLoader = nil then
    Realm.ModuleLoader := TJsModuleLoader.Create(Realm);
  Result := TJsModuleLoader(Realm.ModuleLoader);
end;

function ResolveRelativePath(const Specifier, ReferrerKey: string): string;
var
  Directory: string;
  Parts: array of string;
  Part, Joined: string;
  Index, Start: Integer;
  Absolute: Boolean;
begin
  if not ((Copy(Specifier, 1, 2) = './') or (Copy(Specifier, 1, 3) = '../')) then
    Exit(Specifier);
  Directory := '';
  Index := Length(ReferrerKey);
  while (Index > 0) and (ReferrerKey[Index] <> '/') do
    Dec(Index);
  if Index > 0 then
    Directory := Copy(ReferrerKey, 1, Index);
  Joined := Directory + Specifier;
  Absolute := (Joined <> '') and (Joined[1] = '/');
  Parts := nil;
  Start := 1;
  for Index := 1 to Length(Joined) + 1 do
    if (Index > Length(Joined)) or (Joined[Index] = '/') then
    begin
      Part := Copy(Joined, Start, Index - Start);
      Start := Index + 1;
      if (Part = '') or (Part = '.') then
        Continue;
      if (Part = '..') and (Length(Parts) > 0) and (Parts[High(Parts)] <> '..') then
      begin
        SetLength(Parts, Length(Parts) - 1);
        Continue;
      end;
      if (Part = '..') and Absolute then
        Continue;
      SetLength(Parts, Length(Parts) + 1);
      Parts[High(Parts)] := Part;
    end;
  Result := '';
  for Index := 0 to High(Parts) do
  begin
    if Index > 0 then
      Result := Result + '/';
    Result := Result + Parts[Index];
  end;
  if Absolute then
    Result := '/' + Result;
end;

{ TJsModuleFetch }

procedure TJsModuleFetch.Succeed(const Source: string);
var
  Loader: TJsModuleLoader;
  Entry: TModuleMapEntry;
  Module: TJsModule;
  Text: TJsValue;
  Mark: Integer;
begin
  Loader := FLoader;
  Entry := TModuleMapEntry(FEntry);
  if (Loader <> nil) and not Loader.Realm.CanEnter then
  begin
    { The realm was detached: nothing more loads in it. }
    Loader.RemoveFetch(Self);
    Loader := nil;
  end;
  if Loader <> nil then
  begin
    Loader.RemoveFetch(Self);
    Module := Loader.NewModule(Key, Json);
    Mark := Loader.Realm.Runtime.PushRoot(JsObjectValue(Module));
    try
      if Json then
      begin
        Text := Loader.Realm.NewString(Source);
        Module.JsonValue := ParseJsonText(Loader.Realm, Text);
        if Module.JsonValue = JsException then
        begin
          Module.JsonValue := JsUndefined;
          Entry.Failed := True;
          Entry.Error := Loader.Realm.Runtime.TakeException;
        end
        else
        begin
          SetLength(Module.LocalExports, 1);
          Module.LocalExports[0].ExportName := 'default';
          Module.LocalExports[0].Slot := 0;
          Module.Environment := NewEnvironment(Loader.Realm.Heap, nil, 1);
        end;
      end
      else
        try
          CompileModule(Loader.Realm, UTF8Decode(Source), Key, Module);
        except
          on Error: EJsSyntaxError do
          begin
            Entry.Failed := True;
            Entry.Error := JsObjectValue(Loader.Realm.NewError(ekSyntax, Error.Message + ' (' + Key + ':' +
              IntToStr(Error.Line) + ':' + IntToStr(Error.Column) + ')'));
          end;
        end;
      if not Entry.Failed then
        Entry.Module := Module;
      Entry.Fetching := False;
      Loader.FinishEntry(Entry);
    finally
      Loader.Realm.Runtime.PopRoots(Mark);
    end;
  end;
  Free;
end;

procedure TJsModuleFetch.Fail(const Message: string);
var
  Loader: TJsModuleLoader;
  Entry: TModuleMapEntry;
begin
  Loader := FLoader;
  Entry := TModuleMapEntry(FEntry);
  if (Loader <> nil) and not Loader.Realm.CanEnter then
  begin
    Loader.RemoveFetch(Self);
    Loader := nil;
  end;
  if Loader <> nil then
  begin
    Loader.RemoveFetch(Self);
    Entry.Fetching := False;
    Entry.Failed := True;
    Entry.Error := JsObjectValue(Loader.Realm.NewError(ekType, Message));
    Loader.FinishEntry(Entry);
  end;
  Free;
end;

{ Promise reactions }

function ModuleReaction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Loader: TJsModuleLoader;
  Promise: TJsPromise;
begin
  Result := JsUndefined;
  Loader := ModuleLoaderOf(R);
  case Callee.Magic of
    ReactionNamespace:
      begin
        Promise := TJsPromise(JsAsObject(Callee.Data));
        ResolvePromise(R, Promise, JsObjectValue(GetModuleNamespace(R, TJsModule(JsAsObject(Callee.Data2)))));
      end;
    ReactionUndefined:
      ResolvePromise(R, TJsPromise(JsAsObject(Callee.Data)), JsUndefined);
    ReactionReject:
      RejectPromise(R, TJsPromise(JsAsObject(Callee.Data)), Arg(Args, ArgCount, 0));
    ReactionAsyncFulfilled:
      Loader.AsyncModuleFulfilled(TJsModule(JsAsObject(Callee.Data)));
    ReactionAsyncRejected:
      Loader.AsyncModuleRejected(TJsModule(JsAsObject(Callee.Data)), Arg(Args, ArgCount, 0));
  end;
end;

function NewReaction(R: TJsRealm; Magic: Integer; Data, Data2: TJsValue): TJsValue;
var
  Reaction: TJsNativeFunction;
begin
  Reaction := NewNativeFunction(R, '', @ModuleReaction, 1, Magic);
  Reaction.Data := Data;
  Reaction.Data2 := Data2;
  Result := JsObjectValue(Reaction);
end;

{ TJsModuleLoader }

constructor TJsModuleLoader.Create(R: TJsInterpreterRealm);
begin
  inherited Create;
  FRealm := R;
  R.Heap.AddRootProvider(@MarkRoots);
end;

destructor TJsModuleLoader.Destroy;
var
  Index: Integer;
begin
  { A realm of an engine that shared its parent's runtime may outlive
    that runtime's heap (the parent engine went first). }
  if not FRealm.HeapGone then
    FRealm.Heap.RemoveRootProvider(@MarkRoots);
  { Fetches the host still holds complete into nothing. }
  for Index := 0 to High(FFetches) do
    FFetches[Index].FLoader := nil;
  for Index := 0 to High(FEntries) do
    FEntries[Index].Free;
  for Index := 0 to High(FLoads) do
    FLoads[Index].Free;
  for Index := 0 to High(FFinishedLoads) do
    FFinishedLoads[Index].Free;
  inherited Destroy;
end;

procedure TJsModuleLoader.MarkRoots(Tracer: TJsTracer);
var
  Index, Inner: Integer;
  Entry: TModuleMapEntry;
  Load: TGraphLoad;
begin
  for Index := 0 to High(FEntries) do
  begin
    Entry := TModuleMapEntry(FEntries[Index]);
    Tracer.MarkCell(Entry.Module);
    Tracer.MarkValue(Entry.Error);
    for Inner := 0 to High(Entry.Waiters) do
      Tracer.MarkCell(Entry.Waiters[Inner].Referrer);
  end;
  for Index := 0 to High(FLoads) do
  begin
    Load := TGraphLoad(FLoads[Index]);
    Tracer.MarkCell(Load.Root);
    Tracer.MarkCell(Load.Promise);
    for Inner := 0 to High(Load.Visited) do
      Tracer.MarkCell(Load.Visited[Inner]);
  end;
end;

function TJsModuleLoader.FindEntry(const Key: string; Json: Boolean; MakeIfMissing: Boolean): TObject;
var
  Index: Integer;
  Entry: TModuleMapEntry;
begin
  for Index := 0 to High(FEntries) do
  begin
    Entry := TModuleMapEntry(FEntries[Index]);
    if (Entry.Key = Key) and (Entry.Json = Json) then
      Exit(Entry);
  end;
  Result := nil;
  if not MakeIfMissing then
    Exit;
  Entry := TModuleMapEntry.Create;
  Entry.Key := Key;
  Entry.Json := Json;
  Entry.Error := JsUndefined;
  SetLength(FEntries, Length(FEntries) + 1);
  FEntries[High(FEntries)] := Entry;
  Result := Entry;
end;

procedure TJsModuleLoader.RemoveLoad(Load: TObject);
var
  Index, Last: Integer;
begin
  Last := High(FLoads);
  for Index := 0 to Last do
    if FLoads[Index] = Load then
    begin
      FLoads[Index] := FLoads[Last];
      SetLength(FLoads, Last);
      Break;
    end;
  SetLength(FFinishedLoads, Length(FFinishedLoads) + 1);
  FFinishedLoads[High(FFinishedLoads)] := Load;
end;

procedure TJsModuleLoader.Enter;
begin
  Inc(FDepth);
end;

{ Frees the finished graphs nothing waits for any more. }
procedure TJsModuleLoader.Leave;
var
  Index, Kept: Integer;
begin
  Dec(FDepth);
  if FDepth > 0 then
    Exit;
  Kept := 0;
  for Index := 0 to High(FFinishedLoads) do
    if TGraphLoad(FFinishedLoads[Index]).Waiting > 0 then
    begin
      FFinishedLoads[Kept] := FFinishedLoads[Index];
      Inc(Kept);
    end
    else
      FFinishedLoads[Index].Free;
  SetLength(FFinishedLoads, Kept);
end;

procedure TJsModuleLoader.RemoveFetch(Fetch: TJsModuleFetch);
var
  Index, Last: Integer;
begin
  Last := High(FFetches);
  for Index := 0 to Last do
    if FFetches[Index] = Fetch then
    begin
      FFetches[Index] := FFetches[Last];
      SetLength(FFetches, Last);
      Exit;
    end;
end;

function TJsModuleLoader.NewModule(const Key: string; Json: Boolean): TJsModule;
begin
  Result := TJsModule(FRealm.NewObjectOfClass(TJsModule, nil, ocObject));
  Result.Key := Key;
  Result.Json := Json;
  Result.Status := msNew;
  Result.JsonValue := JsUndefined;
  Result.EvaluationError := JsUndefined;
  Result.TopLevelPromise := JsUndefined;
  Result.DfsIndex := -1;
  Result.DfsAncestorIndex := -1;
end;

function TJsModuleLoader.ModuleFor(const Key: string): TJsModule;
var
  Entry: TModuleMapEntry;
begin
  Entry := TModuleMapEntry(FindEntry(Key, False, False));
  if Entry = nil then
    Exit(nil);
  Result := Entry.Module;
end;

function TJsModuleLoader.Resolve(const Specifier, ReferrerKey: string; out Key: string; out Error: TJsValue): Boolean;
begin
  Error := JsUndefined;
  if Assigned(Resolver) then
    Result := Resolver(Specifier, ReferrerKey, Key)
  else
  begin
    Key := ResolveRelativePath(Specifier, ReferrerKey);
    Result := True;
  end;
  if not Result then
    Error := JsObjectValue(FRealm.NewError(ekType, 'Failed to resolve module specifier "' + Specifier + '"'));
end;

procedure TJsModuleLoader.FailLoad(Load: TObject; Error: TJsValue);
var
  Graph: TGraphLoad;
begin
  Graph := TGraphLoad(Load);
  if Graph.Failed then
    Exit;
  Graph.Failed := True;
  RejectPromise(FRealm, Graph.Promise, Error);
  RemoveLoad(Graph);
end;

{ The module a request of Referrer (nil: the graph's root) was loaded
  as. }
procedure TJsModuleLoader.DeliverModule(Load: TObject; Referrer: TJsModule; Index: Integer; Module: TJsModule);
begin
  if Referrer <> nil then
    Referrer.RequestedModules[Index] := Module;
  if TGraphLoad(Load).Failed then
    Exit;
  if Referrer = nil then
    TGraphLoad(Load).Root := Module;
  InnerModuleLoading(Load, Module);
end;

procedure TJsModuleLoader.FinishEntry(Entry: TObject);
var
  MapEntry: TModuleMapEntry;
  Waiters: array of TLoadWaiter;
  Index: Integer;
begin
  MapEntry := TModuleMapEntry(Entry);
  Waiters := MapEntry.Waiters;
  MapEntry.Waiters := nil;
  Enter;
  try
    for Index := 0 to High(Waiters) do
    begin
      Dec(TGraphLoad(Waiters[Index].Load).Waiting);
      if MapEntry.Failed then
        FailLoad(Waiters[Index].Load, MapEntry.Error)
      else
        DeliverModule(Waiters[Index].Load, Waiters[Index].Referrer, Waiters[Index].Index, MapEntry.Module);
    end;
  finally
    Leave;
  end;
end;

procedure TJsModuleLoader.RequestModule(Load: TObject; Referrer: TJsModule; Index: Integer; const Key: string;
  Json: Boolean);
var
  Entry: TModuleMapEntry;
  Waiter: TLoadWaiter;
  Fetch: TJsModuleFetch;
begin
  Entry := TModuleMapEntry(FindEntry(Key, Json, True));
  if Entry.Module <> nil then
  begin
    DeliverModule(Load, Referrer, Index, Entry.Module);
    Exit;
  end;
  if Entry.Failed then
  begin
    FailLoad(Load, Entry.Error);
    Exit;
  end;
  Waiter.Load := Load;
  Waiter.Referrer := Referrer;
  Waiter.Index := Index;
  SetLength(Entry.Waiters, Length(Entry.Waiters) + 1);
  Entry.Waiters[High(Entry.Waiters)] := Waiter;
  Inc(TGraphLoad(Load).Waiting);
  if Entry.Fetching then
    Exit;
  Entry.Fetching := True;
  Fetch := TJsModuleFetch.Create;
  Fetch.FLoader := Self;
  Fetch.FEntry := Entry;
  Fetch.Key := Key;
  Fetch.Json := Json;
  SetLength(FFetches, Length(FFetches) + 1);
  FFetches[High(FFetches)] := Fetch;
  if Assigned(Fetcher) then
    Fetcher(Fetch)
  else
    Fetch.Fail('Cannot load module "' + Key + '": no module loader');
end;

procedure ContinueGraphJob(R: TJsRealm; const Values: array of TJsValue); forward;

procedure TJsModuleLoader.InnerModuleLoading(Load: TObject; Module: TJsModule);
var
  Graph: TGraphLoad;
  Index: Integer;
  Key: string;
  Error: TJsValue;
begin
  Graph := TGraphLoad(Load);
  if (Module.Status = msNew) and not Graph.HasVisited(Module) then
  begin
    SetLength(Graph.Visited, Length(Graph.Visited) + 1);
    Graph.Visited[High(Graph.Visited)] := Module;
    Inc(Graph.Pending, Length(Module.Requests));
    for Index := 0 to High(Module.Requests) do
    begin
      if Graph.Failed then
        Exit;
      if Module.RequestedModules[Index] <> nil then
        InnerModuleLoading(Graph, Module.RequestedModules[Index])
      else if not Resolve(UTF8Encode(Module.Requests[Index].Specifier), Module.Key, Key, Error) then
      begin
        FailLoad(Graph, Error);
        Exit;
      end
      else
        RequestModule(Graph, Module, Index, Key, Module.Requests[Index].Json);
    end;
  end;
  if Graph.Failed then
    Exit;
  Dec(Graph.Pending);
  if Graph.Pending > 0 then
    Exit;
  for Index := 0 to High(Graph.Visited) do
    if Graph.Visited[Index].Status = msNew then
      Graph.Visited[Index].Status := msUnlinked;
  { Linking and evaluation run as a job, as after the specification's
    loading promise. }
  FRealm.EnqueueJob(@ContinueGraphJob, JsObjectValue(Graph.Promise), JsObjectValue(Graph.Root),
    JsBoolean(Graph.ForImport), JsUndefined);
  RemoveLoad(Graph);
end;

function TJsModuleLoader.EvaluateSource(const Source, Key: string): TJsValue;
var
  Entry: TModuleMapEntry;
  Module: TJsModule;
  Graph: TGraphLoad;
  Mark: Integer;
begin
  Module := NewModule(Key, False);
  Mark := FRealm.Runtime.PushRoot(JsObjectValue(Module));
  Enter;
  try
    try
      CompileModule(FRealm, UTF8Decode(Source), Key, Module);
    except
      on Error: EJsSyntaxError do
        Exit(FRealm.Throw(JsObjectValue(FRealm.NewError(ekSyntax, Error.Message + ' (' + Key + ':' +
          IntToStr(Error.Line) + ':' + IntToStr(Error.Column) + ')'))));
    end;
    Entry := TModuleMapEntry(FindEntry(Key, False, True));
    Entry.Module := Module;
    Entry.Failed := False;
    Graph := TGraphLoad.Create;
    Graph.Promise := NewPromise(FRealm);
    Graph.Root := Module;
    Graph.Pending := 1;
    SetLength(FLoads, Length(FLoads) + 1);
    FLoads[High(FLoads)] := Graph;
    Result := JsObjectValue(Graph.Promise);
    InnerModuleLoading(Graph, Module);
  finally
    Leave;
    FRealm.Runtime.PopRoots(Mark);
  end;
end;

function TJsModuleLoader.Import(const Specifier, ReferrerKey: string; Json: Boolean): TJsValue;
var
  Graph: TGraphLoad;
  Key: string;
  Error: TJsValue;
begin
  Enter;
  try
    Graph := TGraphLoad.Create;
    Graph.Promise := NewPromise(FRealm);
    Graph.ForImport := True;
    Graph.Pending := 1;
    SetLength(FLoads, Length(FLoads) + 1);
    FLoads[High(FLoads)] := Graph;
    Result := JsObjectValue(Graph.Promise);
    if not Resolve(Specifier, ReferrerKey, Key, Error) then
    begin
      FailLoad(Graph, Error);
      Exit;
    end;
    RequestModule(Graph, nil, -1, Key, Json);
  finally
    Leave;
  end;
end;

{ Linking }

function ImportName(const Name: UnicodeString): string;
begin
  Result := UTF8Encode(Name);
end;

function InitializeEnvironment(R: TJsInterpreterRealm; Module: TJsModule): Boolean;
var
  Index: Integer;
  Resolution: TJsResolvedExport;
  Target: TJsModule;
  Specifier: string;
  Closure: TJsClosure;
  Mark: Integer;
begin
  Result := False;
  for Index := 0 to High(Module.IndirectExports) do
  begin
    if Module.IndirectExports[Index].IsNamespace then
      Continue;
    Resolution := ResolveExport(Module, Module.IndirectExports[Index].ExportName);
    if not (Resolution.Kind in [rsBinding, rsNamespace]) then
    begin
      Specifier := ImportName(Module.Requests[Module.IndirectExports[Index].Request].Specifier);
      R.ThrowError(ekSyntax, 'The requested module ''' + Specifier + ''' does not provide an export named ''' +
        ImportName(Module.IndirectExports[Index].ImportName) + '''');
      Exit;
    end;
  end;
  for Index := 0 to High(Module.Imports) do
  begin
    Target := Module.Requested(Module.Imports[Index].Request);
    Specifier := ImportName(Module.Requests[Module.Imports[Index].Request].Specifier);
    if Module.Imports[Index].IsNamespace then
    begin
      Module.ImportBindings[Index].Environment := nil;
      Module.ImportBindings[Index].Value := JsObjectValue(GetModuleNamespace(R, Target));
      Continue;
    end;
    Resolution := ResolveExport(Target, Module.Imports[Index].ImportName);
    case Resolution.Kind of
      rsNotFound:
        begin
          R.ThrowError(ekSyntax, 'The requested module ''' + Specifier + ''' does not provide an export named ''' +
            ImportName(Module.Imports[Index].ImportName) + '''');
          Exit;
        end;
      rsAmbiguous:
        begin
          R.ThrowError(ekSyntax, 'The requested module ''' + Specifier +
            ''' contains conflicting star exports for name ''' + ImportName(Module.Imports[Index].ImportName) + '''');
          Exit;
        end;
      rsNamespace:
        begin
          Module.ImportBindings[Index].Environment := nil;
          Module.ImportBindings[Index].Value := JsObjectValue(GetModuleNamespace(R, Resolution.Module));
        end;
    else
      Module.ImportBindings[Index].Environment := Resolution.Module.Environment;
      Module.ImportBindings[Index].Slot := Resolution.Slot;
    end;
  end;
  if Module.Initializer <> nil then
  begin
    { The hoisted functions, made in the module's environment. }
    Closure := R.NewClosure(Module.Initializer, Module.Environment);
    Mark := R.Runtime.PushRoot(JsObjectValue(Closure));
    try
      if R.Call(JsObjectValue(Closure), JsUndefined, nil, 0) = JsException then
        Exit;
    finally
      R.Runtime.PopRoots(Mark);
    end;
  end;
  Result := True;
end;

function InnerModuleLinking(R: TJsInterpreterRealm; Module: TJsModule; var Stack: TJsModuleList;
  var Index: Integer): Boolean;
var
  Request: Integer;
  Required, Popped: TJsModule;
begin
  Result := True;
  if Module.Status in [msLinking, msLinked, msEvaluatingAsync, msEvaluated] then
    Exit;
  Module.Status := msLinking;
  Module.DfsIndex := Index;
  Module.DfsAncestorIndex := Index;
  Inc(Index);
  SetLength(Stack, Length(Stack) + 1);
  Stack[High(Stack)] := Module;
  for Request := 0 to High(Module.RequestedModules) do
  begin
    Required := Module.Requested(Request);
    if not InnerModuleLinking(R, Required, Stack, Index) then
      Exit(False);
    if (Required.Status = msLinking) and (Required.DfsAncestorIndex < Module.DfsAncestorIndex) then
      Module.DfsAncestorIndex := Required.DfsAncestorIndex;
  end;
  if not InitializeEnvironment(R, Module) then
    Exit(False);
  if Module.DfsAncestorIndex = Module.DfsIndex then
    repeat
      Popped := Stack[High(Stack)];
      SetLength(Stack, Length(Stack) - 1);
      Popped.Status := msLinked;
    until Popped = Module;
end;

function TJsModuleLoader.Link(Module: TJsModule): Boolean;
var
  Stack: TJsModuleList;
  Index: Integer;
begin
  Stack := nil;
  Index := 0;
  Result := InnerModuleLinking(FRealm, Module, Stack, Index);
  if not Result then
    for Index := 0 to High(Stack) do
      Stack[Index].Status := msUnlinked;
end;

{ Evaluation }

{ Runs a module's body (not one that awaits); False when it threw. }
function ExecuteModule(R: TJsInterpreterRealm; Module: TJsModule): Boolean;
var
  Closure: TJsClosure;
  Mark: Integer;
begin
  if Module.Json then
  begin
    Module.Environment.Slots^[0] := Module.JsonValue;
    Exit(True);
  end;
  Closure := R.NewClosure(Module.Body, Module.Environment);
  Mark := R.Runtime.PushRoot(JsObjectValue(Closure));
  try
    Result := R.Call(JsObjectValue(Closure), JsUndefined, nil, 0) <> JsException;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ A module that awaits: its body is an async function; its promise
  settles the module. }
procedure ExecuteAsyncModule(R: TJsInterpreterRealm; Module: TJsModule);
var
  Closure: TJsClosure;
  Mark: Integer;
  Outcome: TJsValue;
begin
  Closure := R.NewClosure(Module.Body, Module.Environment);
  Mark := R.Runtime.PushRoot(JsObjectValue(Closure));
  try
    Outcome := R.Call(JsObjectValue(Closure), JsUndefined, nil, 0);
    if Outcome = JsException then
    begin
      if R.Runtime.Terminating then
        Exit;
      ModuleLoaderOf(R).AsyncModuleRejected(Module, R.Runtime.TakeException);
      Exit;
    end;
    R.Runtime.PushRoot(Outcome);
    PerformPromiseThen(R, TJsPromise(JsAsObject(Outcome)),
      NewReaction(R, ReactionAsyncFulfilled, JsObjectValue(Module), JsUndefined),
      NewReaction(R, ReactionAsyncRejected, JsObjectValue(Module), JsUndefined), JsUndefined, JsUndefined,
      JsUndefined);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

procedure AppendModule(var List: TJsModuleList; Module: TJsModule);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)] := Module;
end;

function ListContains(const List: TJsModuleList; Module: TJsModule): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if List[Index] = Module then
      Exit(True);
  Result := False;
end;

function InnerModuleEvaluation(Loader: TJsModuleLoader; Module: TJsModule; var Stack: TJsModuleList;
  var Index: Integer): Boolean;
var
  R: TJsInterpreterRealm;
  Request: Integer;
  Required, Popped: TJsModule;
begin
  R := Loader.Realm;
  if Module.Status in [msEvaluatingAsync, msEvaluated] then
  begin
    if Module.HasEvaluationError then
    begin
      R.Throw(Module.EvaluationError);
      Exit(False);
    end;
    Exit(True);
  end;
  if Module.Status = msEvaluating then
    Exit(True);
  Module.Status := msEvaluating;
  Module.DfsIndex := Index;
  Module.DfsAncestorIndex := Index;
  Module.PendingAsyncDependencies := 0;
  Inc(Index);
  AppendModule(Stack, Module);
  for Request := 0 to High(Module.RequestedModules) do
  begin
    Required := Module.Requested(Request);
    if not InnerModuleEvaluation(Loader, Required, Stack, Index) then
      Exit(False);
    if Required.Status = msEvaluating then
    begin
      if Required.DfsAncestorIndex < Module.DfsAncestorIndex then
        Module.DfsAncestorIndex := Required.DfsAncestorIndex;
    end
    else
    begin
      Required := Required.CycleRoot;
      if Required.HasEvaluationError then
      begin
        R.Throw(Required.EvaluationError);
        Exit(False);
      end;
    end;
    if Required.AsyncEvaluation then
    begin
      Inc(Module.PendingAsyncDependencies);
      AppendModule(Required.AsyncParentModules, Module);
    end;
  end;
  if (Module.PendingAsyncDependencies > 0) or Module.HasTopLevelAwait then
  begin
    Module.AsyncEvaluation := True;
    Inc(Loader.FAsyncCounter);
    Module.AsyncEvaluationOrder := Loader.FAsyncCounter;
    if Module.PendingAsyncDependencies = 0 then
      ExecuteAsyncModule(R, Module);
  end
  else if not ExecuteModule(R, Module) then
    Exit(False);
  if Module.DfsAncestorIndex = Module.DfsIndex then
    repeat
      Popped := Stack[High(Stack)];
      SetLength(Stack, Length(Stack) - 1);
      if Popped.AsyncEvaluation then
        Popped.Status := msEvaluatingAsync
      else
        Popped.Status := msEvaluated;
      Popped.CycleRoot := Module;
    until Popped = Module;
  Result := True;
end;

function TJsModuleLoader.Evaluate(Module: TJsModule): TJsPromise;
var
  Stack: TJsModuleList;
  Index: Integer;
  Error: TJsValue;
begin
  if (Module.Status in [msEvaluatingAsync, msEvaluated]) and (Module.CycleRoot <> nil) then
    Module := Module.CycleRoot;
  if Module.TopLevelPromise <> JsUndefined then
    Exit(TJsPromise(JsAsObject(Module.TopLevelPromise)));
  Result := NewPromise(FRealm);
  Module.TopLevelPromise := JsObjectValue(Result);
  Stack := nil;
  Index := 0;
  if not InnerModuleEvaluation(Self, Module, Stack, Index) then
  begin
    if FRealm.Runtime.Terminating then
      Exit;
    Error := FRealm.Runtime.TakeException;
    for Index := 0 to High(Stack) do
    begin
      Stack[Index].Status := msEvaluated;
      Stack[Index].HasEvaluationError := True;
      Stack[Index].EvaluationError := Error;
    end;
    { The root may have finished before (an error of its own body). }
    if not Module.HasEvaluationError then
    begin
      Module.Status := msEvaluated;
      Module.HasEvaluationError := True;
      Module.EvaluationError := Error;
    end;
    RejectPromise(FRealm, Result, Error);
    Exit;
  end;
  if not Module.AsyncEvaluation then
    ResolvePromise(FRealm, Result, JsUndefined);
end;

procedure SortByAsyncOrder(var List: TJsModuleList);
var
  Index, Position: Integer;
  Module: TJsModule;
begin
  for Index := 1 to High(List) do
  begin
    Module := List[Index];
    Position := Index - 1;
    while (Position >= 0) and (List[Position].AsyncEvaluationOrder > Module.AsyncEvaluationOrder) do
    begin
      List[Position + 1] := List[Position];
      Dec(Position);
    end;
    List[Position + 1] := Module;
  end;
end;

procedure GatherAvailableAncestors(Module: TJsModule; var ExecList: TJsModuleList);
var
  Index: Integer;
  Parent: TJsModule;
begin
  for Index := 0 to High(Module.AsyncParentModules) do
  begin
    Parent := Module.AsyncParentModules[Index];
    if ListContains(ExecList, Parent) or Parent.CycleRoot.HasEvaluationError then
      Continue;
    Dec(Parent.PendingAsyncDependencies);
    if Parent.PendingAsyncDependencies = 0 then
    begin
      AppendModule(ExecList, Parent);
      if not Parent.HasTopLevelAwait then
        GatherAvailableAncestors(Parent, ExecList);
    end;
  end;
end;

procedure SettleTopLevel(R: TJsRealm; Module: TJsModule; Fulfilled: Boolean; Error: TJsValue);
begin
  if Module.TopLevelPromise = JsUndefined then
    Exit;
  if Fulfilled then
    ResolvePromise(R, TJsPromise(JsAsObject(Module.TopLevelPromise)), JsUndefined)
  else
    RejectPromise(R, TJsPromise(JsAsObject(Module.TopLevelPromise)), Error);
end;

procedure TJsModuleLoader.AsyncModuleFulfilled(Module: TJsModule);
var
  ExecList: TJsModuleList;
  Index: Integer;
  Waiting: TJsModule;
begin
  if Module.Status = msEvaluated then
    Exit;
  Module.AsyncEvaluation := False;
  Module.Status := msEvaluated;
  SettleTopLevel(FRealm, Module, True, JsUndefined);
  ExecList := nil;
  GatherAvailableAncestors(Module, ExecList);
  SortByAsyncOrder(ExecList);
  for Index := 0 to High(ExecList) do
  begin
    Waiting := ExecList[Index];
    if Waiting.Status = msEvaluated then
      Continue;
    if Waiting.HasTopLevelAwait then
      ExecuteAsyncModule(FRealm, Waiting)
    else if not ExecuteModule(FRealm, Waiting) then
    begin
      if FRealm.Runtime.Terminating then
        Exit;
      AsyncModuleRejected(Waiting, FRealm.Runtime.TakeException);
    end
    else
    begin
      Waiting.AsyncEvaluation := False;
      Waiting.Status := msEvaluated;
      SettleTopLevel(FRealm, Waiting, True, JsUndefined);
    end;
  end;
end;

procedure TJsModuleLoader.AsyncModuleRejected(Module: TJsModule; Error: TJsValue);
var
  Index: Integer;
begin
  if Module.Status = msEvaluated then
    Exit;
  Module.HasEvaluationError := True;
  Module.EvaluationError := Error;
  Module.Status := msEvaluated;
  Module.AsyncEvaluation := False;
  for Index := 0 to High(Module.AsyncParentModules) do
    AsyncModuleRejected(Module.AsyncParentModules[Index], Error);
  SettleTopLevel(FRealm, Module, False, Error);
end;

{ The job after a graph loaded: link, evaluate, settle the promise. }
procedure ContinueGraphJob(R: TJsRealm; const Values: array of TJsValue);
var
  Loader: TJsModuleLoader;
  Promise, Evaluation: TJsPromise;
  Module: TJsModule;
  Mark: Integer;
begin
  Loader := ModuleLoaderOf(R);
  Promise := TJsPromise(JsAsObject(Values[0]));
  Module := TJsModule(JsAsObject(Values[1]));
  Mark := R.Runtime.PushRoot(Values[0]);
  R.Runtime.PushRoot(Values[1]);
  try
    if not Loader.Link(Module) then
    begin
      if not R.Runtime.Terminating then
        RejectPromise(R, Promise, R.Runtime.TakeException);
      Exit;
    end;
    Evaluation := Loader.Evaluate(Module);
    if Evaluation = nil then
      Exit;
    if Values[2] = JsTrue then
      PerformPromiseThen(R, Evaluation, NewReaction(R, ReactionNamespace, Values[0], Values[1]),
        NewReaction(R, ReactionReject, Values[0], JsUndefined), JsUndefined, JsUndefined, JsUndefined)
    else
      PerformPromiseThen(R, Evaluation, NewReaction(R, ReactionUndefined, Values[0], JsUndefined),
        NewReaction(R, ReactionReject, Values[0], JsUndefined), JsUndefined, JsUndefined, JsUndefined);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ Hooks of the interpreter }

function ReferrerKeyOf(Referrer: TJsCode): string;
begin
  Result := '';
  if Referrer = nil then
    Exit;
  if Referrer.Module <> nil then
    Exit(TJsModule(Referrer.Module).Key);
  if Referrer.Source <> nil then
    Result := Referrer.Source.FileName;
end;

{ The with option of import(): True for type "json"; False (a TypeError
  thrown) when malformed. }
function ImportOptions(R: TJsRealm; Options: TJsValue; out Json: Boolean): Boolean;
var
  Attributes, Value: TJsValue;
  Keys: TJsValueList;
  Index: Integer;
  Desc: TJsPropertyDescriptor;
begin
  Json := False;
  if Options = JsUndefined then
    Exit(True);
  Result := False;
  if not JsIsObject(Options) then
  begin
    R.ThrowTypeError('The second argument of import() must be an object');
    Exit;
  end;
  Attributes := JsAsObject(Options).GetValue(R, R.Intern('with'));
  if Attributes = JsException then
    Exit;
  if Attributes = JsUndefined then
    Exit(True);
  if not JsIsObject(Attributes) then
  begin
    R.ThrowTypeError('The ''with'' option of import() must be an object');
    Exit;
  end;
  if not JsAsObject(Attributes).OwnPropertyKeys(R, KeysStrings, Keys) then
    Exit;
  for Index := 0 to High(Keys) do
  begin
    if JsAsObject(Attributes).GetOwnProperty(R, Keys[Index], Desc) < 0 then
      Exit;
    if (Desc.Flags and PropertyEnumerable) = 0 then
      Continue;
    Value := JsAsObject(Attributes).GetValue(R, Keys[Index]);
    if Value = JsException then
      Exit;
    if not JsIsString(Value) then
    begin
      R.ThrowTypeError('Import attribute values must be strings');
      Exit;
    end;
    if not (JsIsString(Keys[Index]) and StringEqualsAscii(JsAsString(Keys[Index]), 'type')) then
    begin
      R.ThrowTypeError('Unsupported import attribute ''' + KeyToPascal(R, Keys[Index]) + '''');
      Exit;
    end;
    if not StringEqualsAscii(JsAsString(Value), 'json') then
    begin
      R.ThrowTypeError('Unsupported module type ''' + StringToUtf8(R.Heap, JsAsString(Value)) + '''');
      Exit;
    end;
    Json := True;
  end;
  Result := True;
end;

function DynamicImport(R: TJsRealm; Referrer: TJsCode; Specifier, Options: TJsValue): TJsValue;
var
  Text: TJsString;
  Json: Boolean;
  Promise: TJsPromise;
begin
  Text := ToJsString(R, Specifier);
  if (Text = nil) or not ImportOptions(R, Options, Json) then
  begin
    if R.Runtime.Terminating then
      Exit(JsException);
    Promise := NewPromise(R);
    RejectPromise(R, Promise, R.Runtime.TakeException);
    Exit(JsObjectValue(Promise));
  end;
  Result := ModuleLoaderOf(R).Import(StringToUtf8(R.Heap, Text), ReferrerKeyOf(Referrer), Json);
end;

function MetaResolve(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Key: string;
  Error: TJsValue;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  if not ModuleLoaderOf(R).Resolve(StringToUtf8(R.Heap, Text), StringToUtf8(R.Heap, JsAsString(Callee.Data)), Key,
    Error) then
    Exit(R.Throw(Error));
  Result := R.NewString(Key);
end;

function ImportMeta(R: TJsRealm; Module: TJsModule): TJsObject;
var
  Resolve: TJsNativeFunction;
  Loader: TJsModuleLoader;
begin
  Result := R.NewObject(nil);
  Result.DefineData(R, R.Intern('url'), R.NewString(Module.Key));
  Resolve := NewNativeFunction(R, 'resolve', @MetaResolve, 1);
  Resolve.Data := R.NewString(Module.Key);
  Result.DefineData(R, R.Intern('resolve'), JsObjectValue(Resolve));
  Loader := ModuleLoaderOf(R);
  if Assigned(Loader.MetaHook) then
    Loader.MetaHook(Module.Key, Result);
end;

procedure InstallModules(R: TJsInterpreterRealm);
begin
  JsDynamicImportHook := @DynamicImport;
  JsImportMetaHook := @ImportMeta;
end;

end.
