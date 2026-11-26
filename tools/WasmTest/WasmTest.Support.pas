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
  What WasmTest's groups share: modules written in the text format
  (through the spec runner's encoder) compiled and instantiated in a
  store, calls to their exports by name, and checks that a call traps
  or a module fails to compile the expected way.
}
unit WasmTest.Support;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api;

type
  TTestModule = class
  public
    Store: TWasmStore;
    Module: TWasmModule;
    Instance: TWasmModuleInstance;
    OwnsStore: Boolean;
    { Compiles Text and instantiates it with Imports in Store (a new
      store of its own when nil). }
    constructor Create(const Text: AnsiString; AStore: TWasmStore = nil);
    constructor CreateWithImports(const Text: AnsiString; AStore: TWasmStore; const Imports: TWasmExternalArray);
    destructor Destroy; override;
    function Export_(const Name: AnsiString): TWasmExternal;
    function Call(const Name: AnsiString; const Arguments: array of TWasmValue): TWasmValueArray;
    function CallI32(const Name: AnsiString; const Arguments: array of TWasmValue): Int32;
    function CallI64(const Name: AnsiString; const Arguments: array of TWasmValue): Int64;
    { The kind of trap the call raises; tkHostError if it does not trap. }
    function TrapOf(const Name: AnsiString; const Arguments: array of TWasmValue): TWasmTrapKind;
  end;

function WatBytes(const Text: AnsiString): TBytes;
{ The class of exception compiling Text raises ('' if none), and its message. }
function CompileFailure(const Bytes: TBytes; out Message: AnsiString): AnsiString;
function FunctionExternal(Func: TWasmFunction): TWasmExternal;

implementation

uses
  WasmScript;

function WatBytes(const Text: AnsiString): TBytes;
begin
  Result := EncodeModuleText(Text);
end;

function CompileFailure(const Bytes: TBytes; out Message: AnsiString): AnsiString;
var
  Module: TWasmModule;
begin
  Message := '';
  try
    Module := WasmCompile(Bytes);
    Module.Release;
    Result := '';
  except
    on E: Exception do
    begin
      Result := E.ClassName;
      Message := E.Message;
    end;
  end;
end;

function FunctionExternal(Func: TWasmFunction): TWasmExternal;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := ekFunction;
  Result.Func := Func;
end;

constructor TTestModule.Create(const Text: AnsiString; AStore: TWasmStore);
begin
  CreateWithImports(Text, AStore, nil);
end;

constructor TTestModule.CreateWithImports(const Text: AnsiString; AStore: TWasmStore; const Imports: TWasmExternalArray);
begin
  inherited Create;
  OwnsStore := AStore = nil;
  if OwnsStore then
    Store := TWasmStore.Create
  else
    Store := AStore;
  Module := WasmCompile(WatBytes(Text));
  Instance := WasmInstantiate(Store, Module, Imports);
end;

destructor TTestModule.Destroy;
begin
  if OwnsStore then
    Store.Free;
  if Module <> nil then
    Module.Release;
  inherited Destroy;
end;

function TTestModule.Export_(const Name: AnsiString): TWasmExternal;
begin
  if not Instance.FindExport(Name, Result) then
    raise EWasmError.Create('no export ' + Name);
end;

function TTestModule.Call(const Name: AnsiString; const Arguments: array of TWasmValue): TWasmValueArray;
var
  Values: TWasmValueArray;
  Index: Integer;
begin
  Values := nil;
  SetLength(Values, Length(Arguments));
  for Index := 0 to High(Arguments) do
    Values[Index] := Arguments[Index];
  Result := WasmCall(Export_(Name).Func, Values);
end;

function TTestModule.CallI32(const Name: AnsiString; const Arguments: array of TWasmValue): Int32;
begin
  Result := Call(Name, Arguments)[0].I32;
end;

function TTestModule.CallI64(const Name: AnsiString; const Arguments: array of TWasmValue): Int64;
begin
  Result := Call(Name, Arguments)[0].I64;
end;

function TTestModule.TrapOf(const Name: AnsiString; const Arguments: array of TWasmValue): TWasmTrapKind;
begin
  Result := tkHostError;
  try
    Call(Name, Arguments);
  except
    on E: EWasmTrap do
      Result := E.Kind;
  end;
end;

end.
