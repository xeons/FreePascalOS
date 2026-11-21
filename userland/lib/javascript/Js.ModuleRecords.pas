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
  Module records: what a compiled module is, how its exports resolve
  and its namespace object.

  A module's top-level bindings all live in its environment, made when
  the module is compiled (so that the modules of a cycle can bind to
  each other before any of them runs); its let, const and class slots
  start as holes (the temporal dead zone). An import is a binding of
  the importing module (ImportBindings, filled when linking) that
  points at the exporter's environment slot, so reads see the current
  value (live bindings), or holds a namespace object.

  ResolveExport, GetExportedNames and the namespace object follow the
  specification (Source Text Module Records, Module Namespace exotic
  objects). Loading, linking and evaluation are in Js.Modules.
}
unit Js.ModuleRecords;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions;

type
  TJsModuleStatus = (msNew, msUnlinked, msLinking, msLinked, msEvaluating, msEvaluatingAsync, msEvaluated);

  TJsModule = class;

  { An import binding: the exporter's environment and slot, or a value
    (a namespace object) when Environment is nil. }
  TJsImportBinding = record
    Environment: TJsEnvironment;
    Slot: Integer;
    Value: TJsValue;
  end;

  TJsModuleRequest = record
    Specifier: UnicodeString;
    Json: Boolean;
  end;

  TJsModuleImport = record
    Request: Integer;
    ImportName: UnicodeString;
    IsNamespace: Boolean;
  end;

  TJsModuleLocalExport = record
    ExportName: UnicodeString;
    Slot: Integer;
  end;

  TJsModuleIndirectExport = record
    ExportName: UnicodeString;
    Request: Integer;
    ImportName: UnicodeString;
    IsNamespace: Boolean;
  end;

  { ResolveExport's answer. }
  TJsResolution = (rsNotFound, rsAmbiguous, rsBinding, rsNamespace);
  TJsResolvedExport = record
    Kind: TJsResolution;
    Module: TJsModule;
    Slot: Integer;
  end;

  TJsModuleList = array of TJsModule;
  TJsNameList = array of UnicodeString;

  TJsModule = class(TJsObject)
  public
    { The module map's key (the resolved URL or path). }
    Key: string;
    Json: Boolean;
    { The top-level code (asynchronous when it awaits) and the code
      that makes the hoisted functions when the module is linked. }
    Body: TJsCode;
    Initializer: TJsCode;
    Environment: TJsEnvironment;
    { A JSON module's value (its default export). }
    JsonValue: TJsValue;
    Requests: array of TJsModuleRequest;
    RequestedModules: TJsModuleList;
    Imports: array of TJsModuleImport;
    ImportBindings: array of TJsImportBinding;
    LocalExports: array of TJsModuleLocalExport;
    IndirectExports: array of TJsModuleIndirectExport;
    StarExports: array of Integer;
    Status: TJsModuleStatus;
    HasEvaluationError: Boolean;
    EvaluationError: TJsValue;
    DfsIndex: Integer;
    DfsAncestorIndex: Integer;
    CycleRoot: TJsModule;
    HasTopLevelAwait: Boolean;
    AsyncEvaluation: Boolean;
    AsyncEvaluationOrder: Int64;
    { The promise Evaluate gives (undefined: none yet). }
    TopLevelPromise: TJsValue;
    AsyncParentModules: TJsModuleList;
    PendingAsyncDependencies: Integer;
    Namespace: TJsObject;
    Meta: TJsObject;
    procedure Trace(Tracer: TJsTracer); override;
    { The module a request was loaded as. }
    function Requested(Index: Integer): TJsModule; inline;
  end;

  { A Module Namespace exotic object. }
  TJsModuleNamespace = class(TJsObject)
  public
    Module: TJsModule;
    { The export names in code unit order, as atoms, with what each
      resolves to. }
    Names: TJsValueList;
    Bindings: array of TJsResolvedExport;
    procedure Trace(Tracer: TJsTracer); override;
    function FindName(Key: TJsValue): Integer;
    { The value of export Index (a ReferenceError before it is
      initialised). }
    function BindingValue(R: TJsRealm; Index: Integer): TJsValue;
    function GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer; override;
    function DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
      ThrowOnFailure: Boolean): Integer; override;
    function HasProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue; override;
    function SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer; override;
    function DeleteProperty(R: TJsRealm; Key: TJsValue): Integer; override;
    function OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean; override;
    function SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer; override;
    function PreventExtensions(R: TJsRealm): Integer; override;
    function IsExtensible(R: TJsRealm): Integer; override;
  end;

var
  { import(): a promise for the namespace (set by Js.Modules). Referrer
    is the code that called it (its module, or its script's name). }
  JsDynamicImportHook: function(R: TJsRealm; Referrer: TJsCode; Specifier, Options: TJsValue): TJsValue = nil;
  { import.meta's object for a module, made the first time. }
  JsImportMetaHook: function(R: TJsRealm; Module: TJsModule): TJsObject = nil;

function ResolveExport(Module: TJsModule; const ExportName: UnicodeString): TJsResolvedExport;
function GetExportedNames(Module: TJsModule): TJsNameList;
{ The module's namespace object (made the first time). }
function GetModuleNamespace(R: TJsRealm; Module: TJsModule): TJsModuleNamespace;

implementation

uses
  Js.Atoms,
  Js.Conversions;

type
  TResolveStep = record
    Module: TJsModule;
    ExportName: UnicodeString;
  end;
  TResolveSet = array of TResolveStep;

{ TJsModule }

procedure TJsModule.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Body);
  Tracer.MarkCell(Initializer);
  Tracer.MarkCell(Environment);
  Tracer.MarkValue(JsonValue);
  for Index := 0 to High(RequestedModules) do
    Tracer.MarkCell(RequestedModules[Index]);
  for Index := 0 to High(ImportBindings) do
  begin
    Tracer.MarkCell(ImportBindings[Index].Environment);
    Tracer.MarkValue(ImportBindings[Index].Value);
  end;
  Tracer.MarkValue(EvaluationError);
  Tracer.MarkCell(CycleRoot);
  Tracer.MarkValue(TopLevelPromise);
  for Index := 0 to High(AsyncParentModules) do
    Tracer.MarkCell(AsyncParentModules[Index]);
  Tracer.MarkCell(Namespace);
  Tracer.MarkCell(Meta);
end;

function TJsModule.Requested(Index: Integer): TJsModule;
begin
  Result := RequestedModules[Index];
end;

{ Export resolution }

function ResolveExportIn(Module: TJsModule; const ExportName: UnicodeString;
  var ResolveSet: TResolveSet): TJsResolvedExport;
var
  Index: Integer;
  Imported: TJsModule;
  Resolution, StarResolution: TJsResolvedExport;
begin
  Result := Default(TJsResolvedExport);
  Result.Kind := rsNotFound;
  for Index := 0 to High(ResolveSet) do
    if (ResolveSet[Index].Module = Module) and (ResolveSet[Index].ExportName = ExportName) then
      Exit;
  SetLength(ResolveSet, Length(ResolveSet) + 1);
  ResolveSet[High(ResolveSet)].Module := Module;
  ResolveSet[High(ResolveSet)].ExportName := ExportName;
  for Index := 0 to High(Module.LocalExports) do
    if Module.LocalExports[Index].ExportName = ExportName then
    begin
      Result.Kind := rsBinding;
      Result.Module := Module;
      Result.Slot := Module.LocalExports[Index].Slot;
      Exit;
    end;
  for Index := 0 to High(Module.IndirectExports) do
    if Module.IndirectExports[Index].ExportName = ExportName then
    begin
      Imported := Module.Requested(Module.IndirectExports[Index].Request);
      if Module.IndirectExports[Index].IsNamespace then
      begin
        Result.Kind := rsNamespace;
        Result.Module := Imported;
        Exit;
      end;
      Exit(ResolveExportIn(Imported, Module.IndirectExports[Index].ImportName, ResolveSet));
    end;
  if ExportName = 'default' then
    Exit;
  StarResolution := Default(TJsResolvedExport);
  StarResolution.Kind := rsNotFound;
  for Index := 0 to High(Module.StarExports) do
  begin
    Imported := Module.Requested(Module.StarExports[Index]);
    Resolution := ResolveExportIn(Imported, ExportName, ResolveSet);
    if Resolution.Kind = rsAmbiguous then
      Exit(Resolution);
    if Resolution.Kind = rsNotFound then
      Continue;
    if StarResolution.Kind = rsNotFound then
      StarResolution := Resolution
    else if (Resolution.Module <> StarResolution.Module) or (Resolution.Kind <> StarResolution.Kind) or
      ((Resolution.Kind = rsBinding) and (Resolution.Slot <> StarResolution.Slot)) then
    begin
      Result.Kind := rsAmbiguous;
      Exit;
    end;
  end;
  Result := StarResolution;
end;

function ResolveExport(Module: TJsModule; const ExportName: UnicodeString): TJsResolvedExport;
var
  ResolveSet: TResolveSet;
begin
  ResolveSet := nil;
  Result := ResolveExportIn(Module, ExportName, ResolveSet);
end;

procedure AddUnique(var Names: TJsNameList; const Name: UnicodeString);
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] = Name then
      Exit;
  SetLength(Names, Length(Names) + 1);
  Names[High(Names)] := Name;
end;

procedure ExportedNamesOf(Module: TJsModule; var StarSet: TJsModuleList; var Names: TJsNameList);
var
  Index, Inner: Integer;
  StarNames: TJsNameList;
begin
  for Index := 0 to High(StarSet) do
    if StarSet[Index] = Module then
      Exit;
  SetLength(StarSet, Length(StarSet) + 1);
  StarSet[High(StarSet)] := Module;
  for Index := 0 to High(Module.LocalExports) do
    AddUnique(Names, Module.LocalExports[Index].ExportName);
  for Index := 0 to High(Module.IndirectExports) do
    AddUnique(Names, Module.IndirectExports[Index].ExportName);
  for Index := 0 to High(Module.StarExports) do
  begin
    StarNames := nil;
    ExportedNamesOf(Module.Requested(Module.StarExports[Index]), StarSet, StarNames);
    for Inner := 0 to High(StarNames) do
      if StarNames[Inner] <> 'default' then
        AddUnique(Names, StarNames[Inner]);
  end;
end;

function GetExportedNames(Module: TJsModule): TJsNameList;
var
  StarSet: TJsModuleList;
begin
  Result := nil;
  StarSet := nil;
  ExportedNamesOf(Module, StarSet, Result);
end;

procedure SortNames(var Names: TJsNameList);
var
  Index, Position: Integer;
  Name: UnicodeString;
begin
  { Insertion sort by code units (export lists are short). }
  for Index := 1 to High(Names) do
  begin
    Name := Names[Index];
    Position := Index - 1;
    while (Position >= 0) and (Names[Position] > Name) do
    begin
      Names[Position + 1] := Names[Position];
      Dec(Position);
    end;
    Names[Position + 1] := Name;
  end;
end;

function GetModuleNamespace(R: TJsRealm; Module: TJsModule): TJsModuleNamespace;
var
  Exported: TJsNameList;
  Index, Count: Integer;
  Resolution: TJsResolvedExport;
begin
  if Module.Namespace <> nil then
    Exit(TJsModuleNamespace(Module.Namespace));
  Exported := GetExportedNames(Module);
  SortNames(Exported);
  Result := TJsModuleNamespace(R.NewObjectOfClass(TJsModuleNamespace, nil, ocObject));
  Result.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Module'), 0);
  Result.ObjectFlags := ObjectExotic;
  Result.Module := Module;
  SetLength(Result.Names, Length(Exported));
  SetLength(Result.Bindings, Length(Exported));
  Count := 0;
  for Index := 0 to High(Exported) do
  begin
    Resolution := ResolveExport(Module, Exported[Index]);
    if not (Resolution.Kind in [rsBinding, rsNamespace]) then
      Continue;
    Result.Names[Count] := ToPropertyKey(R, JsStringValue(NewStringFromUnicode(R.Heap, Exported[Index])));
    Result.Bindings[Count] := Resolution;
    Inc(Count);
  end;
  SetLength(Result.Names, Count);
  SetLength(Result.Bindings, Count);
  Module.Namespace := Result;
end;

{ TJsModuleNamespace }

procedure TJsModuleNamespace.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Module);
  if Length(Names) > 0 then
    Tracer.MarkValues(@Names[0], Length(Names));
  for Index := 0 to High(Bindings) do
    Tracer.MarkCell(Bindings[Index].Module);
end;

function TJsModuleNamespace.FindName(Key: TJsValue): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if Names[Index] = Key then
      Exit(Index);
  Result := -1;
end;

function TJsModuleNamespace.BindingValue(R: TJsRealm; Index: Integer): TJsValue;
var
  Binding: TJsResolvedExport;
begin
  Binding := Bindings[Index];
  if Binding.Kind = rsNamespace then
    Exit(JsObjectValue(GetModuleNamespace(R, Binding.Module)));
  Result := Binding.Module.Environment.Slots^[Binding.Slot];
  if Result = JsHole then
    Result := R.ThrowReferenceError('Cannot access ''' + KeyToPascal(R, Names[Index]) + ''' before initialization');
end;

function TJsModuleNamespace.GetOwnProperty(R: TJsRealm; Key: TJsValue; out Desc: TJsPropertyDescriptor): Integer;
var
  Index: Integer;
  Value: TJsValue;
begin
  if JsIsSymbol(Key) then
    Exit(inherited GetOwnProperty(R, Key, Desc));
  Index := FindName(Key);
  if Index < 0 then
    Exit(0);
  Value := BindingValue(R, Index);
  if Value = JsException then
    Exit(-1);
  Desc := DataDescriptor(Value, PropertyWritable or PropertyEnumerable);
  Result := 1;
end;

function TJsModuleNamespace.DefineOwnProperty(R: TJsRealm; Key: TJsValue; const Desc: TJsPropertyDescriptor;
  ThrowOnFailure: Boolean): Integer;
var
  Current: TJsPropertyDescriptor;
  Found: Integer;
  Refused: Boolean;
begin
  if JsIsSymbol(Key) then
    Exit(inherited DefineOwnProperty(R, Key, Desc, ThrowOnFailure));
  Found := GetOwnProperty(R, Key, Current);
  if Found < 0 then
    Exit(-1);
  Refused := (Found = 0) or
    (((Desc.Present and HasConfigurable) <> 0) and ((Desc.Flags and PropertyConfigurable) <> 0)) or
    (((Desc.Present and HasEnumerable) <> 0) and ((Desc.Flags and PropertyEnumerable) = 0)) or
    ((Desc.Present and (HasGetter or HasSetter)) <> 0) or
    (((Desc.Present and HasWritable) <> 0) and ((Desc.Flags and PropertyWritable) = 0)) or
    (((Desc.Present and HasValue) <> 0) and not SameValue(Desc.Value, Current.Value, R.Heap));
  if not Refused then
    Exit(1);
  if ThrowOnFailure then
  begin
    R.ThrowTypeError('Cannot redefine property: ' + KeyToPascal(R, Key));
    Exit(-1);
  end;
  Result := 0;
end;

function TJsModuleNamespace.HasProperty(R: TJsRealm; Key: TJsValue): Integer;
var
  Desc: TJsPropertyDescriptor;
begin
  if JsIsSymbol(Key) then
    Exit(inherited GetOwnProperty(R, Key, Desc));
  if FindName(Key) >= 0 then
    Result := 1
  else
    Result := 0;
end;

function TJsModuleNamespace.Get(R: TJsRealm; Key, Receiver: TJsValue): TJsValue;
var
  Index: Integer;
  Desc: TJsPropertyDescriptor;
begin
  if JsIsSymbol(Key) then
  begin
    if inherited GetOwnProperty(R, Key, Desc) > 0 then
      Exit(Desc.Value);
    Exit(JsUndefined);
  end;
  Index := FindName(Key);
  if Index < 0 then
    Exit(JsUndefined);
  Result := BindingValue(R, Index);
end;

function TJsModuleNamespace.SetValue(R: TJsRealm; Key, Value, Receiver: TJsValue): Integer;
begin
  Result := 0;
end;

function TJsModuleNamespace.DeleteProperty(R: TJsRealm; Key: TJsValue): Integer;
begin
  if JsIsSymbol(Key) then
    Exit(inherited DeleteProperty(R, Key));
  if FindName(Key) >= 0 then
    Result := 0
  else
    Result := 1;
end;

function TJsModuleNamespace.OwnPropertyKeys(R: TJsRealm; Filter: Integer; out Keys: TJsValueList): Boolean;
var
  Symbols: TJsValueList;
  Index, Count: Integer;
begin
  Keys := nil;
  Count := 0;
  if (Filter and KeysStrings) <> 0 then
  begin
    SetLength(Keys, Length(Names));
    for Index := 0 to High(Names) do
      Keys[Index] := Names[Index];
    Count := Length(Names);
  end;
  if (Filter and KeysSymbols) <> 0 then
  begin
    if not inherited OwnPropertyKeys(R, KeysSymbols, Symbols) then
      Exit(False);
    SetLength(Keys, Count + Length(Symbols));
    for Index := 0 to High(Symbols) do
      Keys[Count + Index] := Symbols[Index];
  end;
  Result := True;
end;

function TJsModuleNamespace.SetPrototype(R: TJsRealm; Prototype: TJsObject): Integer;
begin
  if Prototype = nil then
    Result := 1
  else
    Result := 0;
end;

function TJsModuleNamespace.PreventExtensions(R: TJsRealm): Integer;
begin
  Result := 1;
end;

function TJsModuleNamespace.IsExtensible(R: TJsRealm): Integer;
begin
  Result := 0;
end;

end.
