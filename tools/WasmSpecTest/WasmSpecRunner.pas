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
  Runs the commands of one .wast script (WasmScript) against libwasm:
  modules are compiled and instantiated in a store of the script's own,
  with the spec tests' "spectest" host module and the modules the
  script registers available as imports; every assertion counts as a
  pass or a failure, and failures are kept with their line and reason.

  The assertions check the kind of failure (malformed, invalid,
  unlinkable, trap, exhaustion, exception), not the exact message.

  Host references: (ref.extern n) is the even pointer (n + 1) * 2, which
  the engine never looks at; (ref.host n) is the same value internalized
  into the any hierarchy (any.convert_extern), so results compare by
  externalizing them. Module definitions are compiled and kept by name
  for (module instance ...). The store caps memories at 1 GiB and the
  heap at 512 MiB, so that no test can take the host's memory.
}
unit WasmSpecRunner;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Wasm.Features,
  WasmScript;

type
  TScriptOutcome = record
    Passed: Integer;
    Failed: Integer;
    Failures: TStringList;
  end;

var
  { What modules are compiled with (WebAssembly 2.0 for its own suite). }
  SpecFeatures: TWasmFeatures;
  { Collect at every allocation (to find references the collector
    misses). }
  SpecGcStress: Boolean;

{ Runs a parsed script; Outcome.Failures must be a list to fill. }
procedure RunScript(Commands: TScriptCommandList; var Outcome: TScriptOutcome);

implementation

uses
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Exceptions,
  Wasm.Api;

type
  TScriptRunner = class
  private
    FStore: TWasmStore;
    FModules: TList;
    FCurrent: TWasmModuleInstance;
    FNamed: TStringList;       { $name -> instance }
    FRegistered: TStringList;  { import module name -> instance }
    FDefinitions: TStringList; { $name -> module definition }
    FSpectest: TStringList;    { field -> TWasmExternal (boxed) }
    FOutcome: ^TScriptOutcome;
    FLine: Integer;
    procedure Pass;
    procedure Fail(const Reason: AnsiString);
    procedure HostPrint(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
    procedure AddSpectest(const Name: AnsiString; const Extern: TWasmExternal);
    procedure CreateSpectest;
    function Resolve(const Import: TWasmImportDescriptor; out Extern: TWasmExternal): Boolean;
    function Compile(const Module: TScriptModule): TWasmModule;
    function Instantiate(const Module: TScriptModule): TWasmModuleInstance;
    function FindInstance(const Name: AnsiString): TWasmModuleInstance;
    function PerformAction(const Action: TScriptAction): TWasmValueArray;
    function ToValue(const Value: TScriptValue): TWasmValue;
    function Matches(const Actual: TWasmValue; const Expected: TScriptValue): Boolean;
    function MatchesResult(Command: TScriptCommand; Index: Integer; const Actual: TWasmValue): Boolean;
    function HostReference(Number: QWord): Pointer;
    function Describe(const Value: TWasmValue): AnsiString;
    procedure RunCommand(Command: TScriptCommand);
  public
    constructor Create(var Outcome: TScriptOutcome);
    destructor Destroy; override;
    procedure Run(Commands: TScriptCommandList);
  end;

  TBoxedExternal = class
    Extern: TWasmExternal;
  end;

constructor TScriptRunner.Create(var Outcome: TScriptOutcome);
var
  Options: TWasmStoreOptions;
begin
  inherited Create;
  FOutcome := @Outcome;
  Options := TWasmStore.DefaultOptions;
  Options.MaximumMemoryBytes := QWord(1024) * 1024 * 1024;
  Options.MaximumHeapBytes := QWord(512) * 1024 * 1024;
  if SpecGcStress then
    Options.CollectionThreshold := 1;
  FStore := TWasmStore.Create(Options);
  FModules := TList.Create;
  FNamed := TStringList.Create;
  FRegistered := TStringList.Create;
  FDefinitions := TStringList.Create;
  FSpectest := TStringList.Create;
  FSpectest.OwnsObjects := True;
  CreateSpectest;
end;

destructor TScriptRunner.Destroy;
var
  Index: Integer;
begin
  FStore.Free;
  for Index := 0 to FModules.Count - 1 do
    TWasmModule(FModules[Index]).Release;
  FModules.Free;
  FNamed.Free;
  FRegistered.Free;
  FDefinitions.Free;
  FSpectest.Free;
  inherited Destroy;
end;

procedure TScriptRunner.Pass;
begin
  Inc(FOutcome^.Passed);
end;

procedure TScriptRunner.Fail(const Reason: AnsiString);
begin
  Inc(FOutcome^.Failed);
  FOutcome^.Failures.Add(Format('line %d: %s', [FLine, Reason]));
end;

procedure TScriptRunner.HostPrint(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
end;

procedure TScriptRunner.AddSpectest(const Name: AnsiString; const Extern: TWasmExternal);
var
  Box: TBoxedExternal;
begin
  Box := TBoxedExternal.Create;
  Box.Extern := Extern;
  FSpectest.AddObject(Name, Box);
end;

procedure TScriptRunner.CreateSpectest;
var
  Extern: TWasmExternal;
  GlobalType: TWasmGlobalType;
  TableType: TWasmTableType = (ElementType: (Kind: vkReference; Nullable: True; HeapType: HeapTypeFunc);
    Limits: (Minimum: 0; Maximum: 0; HasMaximum: False); AddressType: vkI32);
  MemoryType: TWasmMemoryType = (Limits: (Minimum: 0; Maximum: 0; HasMaximum: False); AddressType: vkI32);

  procedure AddPrint(const Name: AnsiString; const Params: array of TWasmValueType);
  begin
    FillChar(Extern, SizeOf(Extern), 0);
    Extern.Kind := ekFunction;
    Extern.Func := WasmNewHostFunction(FStore, MakeFunctionType(Params, []), @HostPrint);
    AddSpectest(Name, Extern);
  end;

  procedure AddGlobal(const Name: AnsiString; const Value: TWasmValue);
  begin
    FillChar(Extern, SizeOf(Extern), 0);
    Extern.Kind := ekGlobal;
    GlobalType.ValueType := Value.ValueType;
    GlobalType.Mutable := False;
    Extern.Global := WasmNewGlobal(FStore, GlobalType, Value);
    AddSpectest(Name, Extern);
  end;

begin
  AddPrint('print', []);
  AddPrint('print_i32', [WasmI32Type]);
  AddPrint('print_i64', [WasmI64Type]);
  AddPrint('print_f32', [WasmF32Type]);
  AddPrint('print_f64', [WasmF64Type]);
  AddPrint('print_i32_f32', [WasmI32Type, WasmF32Type]);
  AddPrint('print_f64_f64', [WasmF64Type, WasmF64Type]);
  AddGlobal('global_i32', WasmI32(666));
  AddGlobal('global_i64', WasmI64(666));
  AddGlobal('global_f32', WasmF32(666.6));
  AddGlobal('global_f64', WasmF64(666.6));
  FillChar(Extern, SizeOf(Extern), 0);
  Extern.Kind := ekTable;
  TableType.ElementType := WasmFuncRefType;
  TableType.Limits.Minimum := 10;
  TableType.Limits.Maximum := 20;
  TableType.Limits.HasMaximum := True;
  Extern.Table := WasmNewTable(FStore, TableType, nil);
  AddSpectest('table', Extern);
  FillChar(Extern, SizeOf(Extern), 0);
  Extern.Kind := ekTable;
  TableType.AddressType := vkI64;
  Extern.Table := WasmNewTable(FStore, TableType, nil);
  AddSpectest('table64', Extern);
  FillChar(Extern, SizeOf(Extern), 0);
  Extern.Kind := ekMemory;
  MemoryType.Limits.Minimum := 1;
  MemoryType.Limits.Maximum := 2;
  MemoryType.Limits.HasMaximum := True;
  Extern.Memory := WasmNewMemory(FStore, MemoryType);
  AddSpectest('memory', Extern);
end;

function TScriptRunner.Resolve(const Import: TWasmImportDescriptor; out Extern: TWasmExternal): Boolean;
var
  Position: Integer;
  Instance: TWasmModuleInstance;
begin
  FillChar(Extern, SizeOf(Extern), 0);
  if Import.ModuleName = 'spectest' then
  begin
    Position := FSpectest.IndexOf(Import.Name);
    Result := Position >= 0;
    if Result then
      Extern := TBoxedExternal(FSpectest.Objects[Position]).Extern;
    Exit;
  end;
  Position := FRegistered.IndexOf(Import.ModuleName);
  if Position < 0 then
    Exit(False);
  Instance := TWasmModuleInstance(FRegistered.Objects[Position]);
  Result := Instance.FindExport(Import.Name, Extern);
end;

function TScriptRunner.Compile(const Module: TScriptModule): TWasmModule;
begin
  if Module.EncodeError <> '' then
    raise EWasmError.Create('text did not encode: ' + Module.EncodeError);
  Result := WasmCompile(Module.Bytes, SpecFeatures);
  FModules.Add(Result);
end;

function TScriptRunner.HostReference(Number: QWord): Pointer;
begin
  Result := Pointer(PtrUInt((Number + 1) * 2));
end;

function TScriptRunner.Instantiate(const Module: TScriptModule): TWasmModuleInstance;
begin
  Result := WasmInstantiateWith(FStore, Compile(Module), @Resolve);
end;

function TScriptRunner.FindInstance(const Name: AnsiString): TWasmModuleInstance;
var
  Position: Integer;
begin
  if Name = '' then
    Result := FCurrent
  else
  begin
    Position := FNamed.IndexOf(Name);
    if Position < 0 then
      raise EWasmError.Create('unknown module ' + Name);
    Result := TWasmModuleInstance(FNamed.Objects[Position]);
  end;
  if Result = nil then
    raise EWasmError.Create('no module');
end;

function TScriptRunner.ToValue(const Value: TScriptValue): TWasmValue;
begin
  case Value.Kind of
    svI32: Result := WasmI32(Int32(DWord(Value.Bits[0])));
    svI64: Result := WasmI64(Int64(Value.Bits[0]));
    svF32: Result := WasmF32FromBits(DWord(Value.Bits[0]));
    svF64: Result := WasmF64FromBits(Value.Bits[0]);
    svV128:
      begin
        FillChar(Result, SizeOf(Result), 0);
        Result.ValueType := WasmV128Type;
        Result.V128.QWords[0] := Value.Bits[0];
        Result.V128.QWords[1] := Value.Bits[1];
      end;
    svRefNull:
      case Value.HeapKind of
        shFunc: Result := WasmFuncRef(nil);
        shNoFunc: Result := WasmReference(MakeReferenceType(HeapTypeNoFunc), nil);
        shExtern: Result := WasmExternRef(nil);
        shNoExtern: Result := WasmReference(MakeReferenceType(HeapTypeNoExtern), nil);
        shExn: Result := WasmReference(MakeReferenceType(HeapTypeExn), nil);
        shNoExn: Result := WasmReference(MakeReferenceType(HeapTypeNoExn), nil);
        shNone: Result := WasmReference(MakeReferenceType(HeapTypeNone), nil);
      else
        Result := WasmReference(MakeReferenceType(HeapTypeAny), nil);
      end;
    svRefExtern: Result := WasmExternRef(HostReference(Value.Bits[0]));
    svRefHost:
      Result := WasmReference(MakeReferenceType(HeapTypeAny, False),
        WasmInternalize(FStore, HostReference(Value.Bits[0])));
  else
    Result := WasmFuncRef(nil);
  end;
end;

function NanMatches(Pattern: TScriptNanPattern; Bits: QWord; Is64: Boolean): Boolean;
begin
  if Is64 then
  begin
    if Pattern = npCanonical then
      Result := Bits and QWord($7FFFFFFFFFFFFFFF) = QWord($7FF8000000000000)
    else
      Result := (Bits and QWord($7FF8000000000000)) = QWord($7FF8000000000000);
  end
  else
  begin
    Bits := Bits and $FFFFFFFF;
    if Pattern = npCanonical then
      Result := Bits and $7FFFFFFF = $7FC00000
    else
      Result := (Bits and $7FC00000) = $7FC00000;
  end;
end;

function TScriptRunner.Matches(const Actual: TWasmValue; const Expected: TScriptValue): Boolean;
var
  Lane: Integer;
begin
  case Expected.Kind of
    svI32: Result := (Actual.ValueType.Kind = vkI32) and (DWord(Actual.I32) = DWord(Expected.Bits[0]));
    svI64: Result := (Actual.ValueType.Kind = vkI64) and (Actual.F64Bits = Expected.Bits[0]);
    svF32:
      begin
        Result := Actual.ValueType.Kind = vkF32;
        if Result then
          if Expected.Nan <> npNone then
            Result := NanMatches(Expected.Nan, Actual.F32Bits, False)
          else
            Result := Actual.F32Bits = DWord(Expected.Bits[0]);
      end;
    svF64:
      begin
        Result := Actual.ValueType.Kind = vkF64;
        if Result then
          if Expected.Nan <> npNone then
            Result := NanMatches(Expected.Nan, Actual.F64Bits, True)
          else
            Result := Actual.F64Bits = Expected.Bits[0];
      end;
    svV128:
      begin
        Result := Actual.ValueType.Kind = vkV128;
        if not Result then
          Exit;
        case Expected.Shape of
          lsF32:
            for Lane := 0 to 3 do
              if Expected.LaneNan[Lane] <> npNone then
              begin
                if not NanMatches(Expected.LaneNan[Lane], Actual.V128.DWords[Lane], False) then
                  Exit(False);
              end
              else if Actual.V128.DWords[Lane] <> TWasmV128(Expected.Bits).DWords[Lane] then
                Exit(False);
          lsF64:
            for Lane := 0 to 1 do
              if Expected.LaneNan[Lane] <> npNone then
              begin
                if not NanMatches(Expected.LaneNan[Lane], Actual.V128.QWords[Lane], True) then
                  Exit(False);
              end
              else if Actual.V128.QWords[Lane] <> Expected.Bits[Lane] then
                Exit(False);
        else
          Result := (Actual.V128.QWords[0] = Expected.Bits[0]) and (Actual.V128.QWords[1] = Expected.Bits[1]);
        end;
      end;
    svRefNull:
      Result := (Actual.ValueType.Kind = vkReference) and (Actual.Reference = nil);
    svRefExtern, svRefHost:
      begin
        Result := (Actual.ValueType.Kind = vkReference) and (Actual.Reference <> nil);
        if Result and not Expected.AnyReference then
          Result := WasmExternalize(FStore, Actual.Reference) = HostReference(Expected.Bits[0]);
      end;
    svRefFunc, svRefAny, svRefExn:
      Result := (Actual.ValueType.Kind = vkReference) and (Actual.Reference <> nil);
    svRefI31:
      Result := (Actual.ValueType.Kind = vkReference) and
        (WasmClassifyReference(FStore, Actual.Reference, Actual.ValueType) = rkI31);
    svRefStruct:
      Result := (Actual.ValueType.Kind = vkReference) and
        (WasmClassifyReference(FStore, Actual.Reference, Actual.ValueType) = rkStruct);
    svRefArray:
      Result := (Actual.ValueType.Kind = vkReference) and
        (WasmClassifyReference(FStore, Actual.Reference, Actual.ValueType) = rkArray);
    svRefEq:
      Result := (Actual.ValueType.Kind = vkReference) and
        (WasmClassifyReference(FStore, Actual.Reference, Actual.ValueType) in [rkI31, rkStruct, rkArray]);
  else
    Result := False;
  end;
end;

function TScriptRunner.MatchesResult(Command: TScriptCommand; Index: Integer; const Actual: TWasmValue): Boolean;
var
  Alternative: Integer;
begin
  if Command.Expected[Index].Kind <> svEither then
    Exit(Matches(Actual, Command.Expected[Index]));
  for Alternative := 0 to High(Command.Alternatives[Index]) do
    if Matches(Actual, Command.Alternatives[Index][Alternative]) then
      Exit(True);
  Result := False;
end;

function TScriptRunner.Describe(const Value: TWasmValue): AnsiString;
begin
  case Value.ValueType.Kind of
    vkI32: Result := Format('i32:0x%x', [DWord(Value.I32)]);
    vkI64, vkF64: Result := Format('%s:0x%x', [ValueTypeToString(Value.ValueType), Value.F64Bits]);
    vkF32: Result := Format('f32:0x%x', [Value.F32Bits]);
    vkV128: Result := Format('v128:0x%.16x_%.16x', [Value.V128.QWords[1], Value.V128.QWords[0]]);
  else
    Result := Format('%s:%p', [ValueTypeToString(Value.ValueType), Value.Reference]);
  end;
end;

function TScriptRunner.PerformAction(const Action: TScriptAction): TWasmValueArray;
var
  Instance: TWasmModuleInstance;
  Extern: TWasmExternal;
  Arguments: TWasmValueArray;
  Index: Integer;
begin
  Instance := FindInstance(Action.ModuleName);
  if not Instance.FindExport(Action.FieldName, Extern) then
    raise EWasmError.Create('unknown export ' + Action.FieldName);
  if Action.Kind = saGet then
  begin
    if Extern.Kind <> ekGlobal then
      raise EWasmError.Create('not a global: ' + Action.FieldName);
    SetLength(Result, 1);
    Result[0] := WasmGlobalGet(Extern.Global);
    Exit;
  end;
  if Extern.Kind <> ekFunction then
    raise EWasmError.Create('not a function: ' + Action.FieldName);
  SetLength(Arguments, Length(Action.Arguments));
  for Index := 0 to High(Arguments) do
    Arguments[Index] := ToValue(Action.Arguments[Index]);
  Result := WasmCall(Extern.Func, Arguments);
end;

procedure TScriptRunner.RunCommand(Command: TScriptCommand);
var
  Instance: TWasmModuleInstance;
  Results: TWasmValueArray;
  Index: Integer;
  Text: AnsiString;
  Module: TWasmModule;
  Position: Integer;
begin
  FLine := Command.Line;
  WasmForgetExposed(FStore);
  case Command.Kind of
    scModule:
      if Command.Module.IsDefinition then
      try
        Module := Compile(Command.Module);
        if Command.Module.Name <> '' then
          FDefinitions.AddObject(Command.Module.Name, Module);
        Pass;
      except
        on E: Exception do
          Fail('module definition: ' + E.ClassName + ': ' + E.Message);
      end
      else
      try
        Instance := Instantiate(Command.Module);
        FCurrent := Instance;
        if Command.Module.Name <> '' then
          FNamed.AddObject(Command.Module.Name, Instance);
        Pass;
      except
        on E: Exception do
        begin
          FCurrent := nil;
          Fail('module: ' + E.ClassName + ': ' + E.Message);
        end;
      end;
    scModuleInstance:
      try
        Position := FDefinitions.IndexOf(Command.DefinitionName);
        if Position < 0 then
          raise EWasmError.Create('unknown module definition ' + Command.DefinitionName);
        Instance := WasmInstantiateWith(FStore, TWasmModule(FDefinitions.Objects[Position]), @Resolve);
        FCurrent := Instance;
        if Command.InstanceName <> '' then
          FNamed.AddObject(Command.InstanceName, Instance);
        Pass;
      except
        on E: Exception do
        begin
          FCurrent := nil;
          Fail('module instance: ' + E.ClassName + ': ' + E.Message);
        end;
      end;
    scAssertException:
      try
        PerformAction(Command.Action);
        Fail('expected an exception');
      except
        on E: EWasmException do
          Pass;
        on E: Exception do
          Fail('expected an exception, got ' + E.ClassName + ': ' + E.Message);
      end;
    scRegister:
      try
        FRegistered.AddObject(Command.RegisterAs, FindInstance(Command.RegisterModule));
      except
        on E: Exception do
          Fail('register: ' + E.Message);
      end;
    scAction:
      try
        PerformAction(Command.Action);
        Pass;
      except
        on E: Exception do
          Fail('action ' + Command.Action.FieldName + ': ' + E.ClassName + ': ' + E.Message);
      end;
    scAssertReturn:
      try
        Results := PerformAction(Command.Action);
        if Length(Results) <> Length(Command.Expected) then
          Fail(Format('%s: %d results, expected %d', [Command.Action.FieldName, Length(Results), Length(Command.Expected)]))
        else
        begin
          Text := '';
          for Index := 0 to High(Results) do
            if not MatchesResult(Command, Index, Results[Index]) then
              Text := Text + Format(' result %d is %s', [Index, Describe(Results[Index])]);
          if Text = '' then
            Pass
          else
            Fail(Command.Action.FieldName + ':' + Text);
        end;
      except
        on E: Exception do
          Fail('assert_return ' + Command.Action.FieldName + ': ' + E.ClassName + ': ' + E.Message);
      end;
    scAssertTrap, scAssertExhaustion, scAssertUninstantiable:
      try
        if Command.HasModule or (Command.Kind = scAssertUninstantiable) then
          Instantiate(Command.Module)
        else
          PerformAction(Command.Action);
        Fail('expected a trap: ' + Command.Message);
      except
        on E: EWasmTrap do
          if (Command.Kind = scAssertExhaustion) <> (E.Kind = tkCallStackExhausted) then
            Fail('wrong trap: ' + E.Message + ', expected ' + Command.Message)
          else
            Pass;
        on E: Exception do
          Fail('expected a trap (' + Command.Message + '), got ' + E.ClassName + ': ' + E.Message);
      end;
    scAssertInvalid, scAssertMalformed:
      begin
        if (Command.Kind = scAssertMalformed) and (Command.Module.EncodeError <> '') then
        begin
          Pass;
          Exit;
        end;
        if Command.Module.EncodeError <> '' then
        begin
          Fail('text did not encode: ' + Command.Module.EncodeError);
          Exit;
        end;
        try
          Module := WasmCompile(Command.Module.Bytes, SpecFeatures);
          Module.Release;
          Fail('expected ' + Command.Message);
        except
          on E: EWasmMalformed do
            if Command.Kind = scAssertMalformed then
              Pass
            else
              Fail('malformed (' + E.Message + '), expected invalid: ' + Command.Message);
          on E: EWasmInvalid do
            if Command.Kind = scAssertInvalid then
              Pass
            else
              Fail('invalid (' + E.Message + '), expected malformed: ' + Command.Message);
          on E: Exception do
            Fail(E.ClassName + ': ' + E.Message);
        end;
      end;
    scAssertUnlinkable:
      try
        Instantiate(Command.Module);
        Fail('expected unlinkable: ' + Command.Message);
      except
        on E: EWasmLinkError do
          Pass;
        on E: Exception do
          Fail('expected unlinkable (' + Command.Message + '), got ' + E.ClassName + ': ' + E.Message);
      end;
  end;
end;

procedure TScriptRunner.Run(Commands: TScriptCommandList);
var
  Index: Integer;
begin
  for Index := 0 to Commands.Count - 1 do
    RunCommand(Commands[Index]);
end;

procedure RunScript(Commands: TScriptCommandList; var Outcome: TScriptOutcome);
var
  Runner: TScriptRunner;
begin
  Runner := TScriptRunner.Create(Outcome);
  try
    Runner.Run(Commands);
  finally
    Runner.Free;
  end;
end;

initialization
  SpecFeatures := WasmFeaturesAll;
end.
