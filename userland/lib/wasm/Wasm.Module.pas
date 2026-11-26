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
  A decoded module (spec section 2.5): what the decoder (Wasm.Decoder)
  makes of the binary, what the validator checks and what instantiation
  (Wasm.Instantiation) builds instances from.

  The module keeps its own copy of the bytes; function bodies, constant
  expressions and data segments are ranges in it rather than copies.
  The index spaces are whole: Functions, Tables, Memories, Globals and
  Tags start with the imported ones, as the spec's index spaces do, with
  the counts of imports alongside. Compiled code (Wasm.Code) hangs off
  each defined function once the module is compiled.

  The type section is kept twice: TypeDefinitions has every defined type
  (function, struct or array, with its subtyping and rec group), Types
  the function types alone (empty for the others) as the rest of the
  engine reads them. Once validated, concrete heap types in every value
  type of the module are canonical indices (the first type equivalent to
  the one written), so equal types compare equal as records.
}
unit Wasm.Module;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Types,
  Wasm.Features,
  Wasm.TypeDefinitions;

type
  { A constant expression: the range of its instructions (the final end
    included) in the module's bytes. }
  TWasmConstantExpression = record
    Start: SizeInt;
    Limit: SizeInt;
  end;

  TWasmImport = record
    ModuleName: AnsiString;
    FieldName: AnsiString;
    Kind: TWasmExternalKind;
    TypeIndex: Cardinal;          { ekFunction }
    TableType: TWasmTableType;    { ekTable }
    MemoryType: TWasmMemoryType;  { ekMemory }
    GlobalType: TWasmGlobalType;  { ekGlobal }
    TagTypeIndex: Cardinal;       { ekTag }
  end;

  TWasmExport = record
    Name: AnsiString;
    Kind: TWasmExternalKind;
    Index: Cardinal;
  end;

  TWasmFunctionBody = record
    Locals: TWasmValueTypeArray;  { the declared locals, expanded }
    BodyStart: SizeInt;           { the first instruction }
    BodyLimit: SizeInt;           { past the final end }
    Compiled: TObject;            { its TCompiledFunction, once compiled }
  end;

  TWasmGlobalDefinition = record
    GlobalType: TWasmGlobalType;
    Initializer: TWasmConstantExpression;
  end;

  { A defined table's initial value (the 3.0 encoding with an
    expression; null without one). }
  TWasmTableDefinition = record
    HasInitializer: Boolean;
    Initializer: TWasmConstantExpression;
  end;

  TWasmSegmentMode = (smPassive, smActive, smDeclarative);

  TWasmElementSegment = record
    Mode: TWasmSegmentMode;
    TableIndex: Cardinal;
    Offset: TWasmConstantExpression;
    ElementType: TWasmValueType;
    { Either function indices (the encodings with an element kind) or
      one constant expression per element. }
    UsesExpressions: Boolean;
    FunctionIndices: array of Cardinal;
    Expressions: array of TWasmConstantExpression;
  end;

  TWasmDataSegment = record
    Mode: TWasmSegmentMode;
    MemoryIndex: Cardinal;
    Offset: TWasmConstantExpression;
    DataStart: SizeInt;
    DataLength: SizeInt;
  end;

  TWasmCustomSection = record
    Name: AnsiString;
    DataStart: SizeInt;
    DataLength: SizeInt;
  end;

  { A module is shared by whoever holds it (an embedder's handle, each
    instance made from it): it starts with one reference and frees
    itself when the last is released. }
  TWasmModule = class
  private
    FReferences: Integer;
  public
    Bytes: TBytes;
    Features: TWasmFeatures;
    Types: TWasmFunctionTypeArray;
    TypeDefinitions: TWasmTypeDefinitionArray;
    { The canonical index of every type index (filled by validation). }
    CanonicalTypes: array of Cardinal;
    Imports: array of TWasmImport;
    { The type index of every function, imported ones first. }
    FunctionTypes: array of Cardinal;
    Tables: array of TWasmTableType;
    Memories: array of TWasmMemoryType;
    Globals: array of TWasmGlobalType;
    { The type index of every tag, imported ones first. }
    TagTypes: array of Cardinal;
    ImportedFunctionCount: Cardinal;
    ImportedTableCount: Cardinal;
    ImportedMemoryCount: Cardinal;
    ImportedGlobalCount: Cardinal;
    ImportedTagCount: Cardinal;
    TableDefinitions: array of TWasmTableDefinition;  { the defined tables }
    Bodies: array of TWasmFunctionBody;         { the defined functions }
    GlobalDefinitions: array of TWasmGlobalDefinition;
    ExportList: array of TWasmExport;
    HasStart: Boolean;
    StartFunction: Cardinal;
    Elements: array of TWasmElementSegment;
    Data: array of TWasmDataSegment;
    HasDataCount: Boolean;
    DataCount: Cardinal;
    CustomSections: array of TWasmCustomSection;
    { From the name section: the module's name and function names
      (indexed by function index, '' where none was given). }
    Name: AnsiString;
    FunctionNames: array of AnsiString;
    constructor Create;
    destructor Destroy; override;
    procedure Retain;
    procedure Release;
    function FunctionCount: Cardinal; inline;
    function FunctionType(FunctionIndex: Cardinal): TWasmFunctionType; inline;
    function TagType(TagIndex: Cardinal): TWasmFunctionType; inline;
    function IsFunctionTypeIndex(TypeIndex: Cardinal): Boolean; inline;
    { The canonical index of a type index as an instruction names it. }
    function CanonicalType(TypeIndex: Cardinal): Int32; inline;
    function FunctionName(FunctionIndex: Cardinal): AnsiString;
    function FindExport(const ExportName: AnsiString; out Found: TWasmExport): Boolean;
  end;

implementation

constructor TWasmModule.Create;
begin
  inherited Create;
  FReferences := 1;
  Features := WasmFeaturesAll;
end;

procedure TWasmModule.Retain;
begin
  Inc(FReferences);
end;

procedure TWasmModule.Release;
begin
  Dec(FReferences);
  if FReferences = 0 then
    Free;
end;

destructor TWasmModule.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Bodies) do
    Bodies[Index].Compiled.Free;
  inherited Destroy;
end;

function TWasmModule.FunctionCount: Cardinal;
begin
  Result := Length(FunctionTypes);
end;

function TWasmModule.FunctionType(FunctionIndex: Cardinal): TWasmFunctionType;
begin
  Result := Types[FunctionTypes[FunctionIndex]];
end;

function TWasmModule.TagType(TagIndex: Cardinal): TWasmFunctionType;
begin
  Result := Types[TagTypes[TagIndex]];
end;

function TWasmModule.IsFunctionTypeIndex(TypeIndex: Cardinal): Boolean;
begin
  Result := (TypeIndex < Cardinal(Length(TypeDefinitions))) and (TypeDefinitions[TypeIndex].Kind = ckFunction);
end;

function TWasmModule.CanonicalType(TypeIndex: Cardinal): Int32;
begin
  if TypeIndex < Cardinal(Length(CanonicalTypes)) then
    Result := CanonicalTypes[TypeIndex]
  else
    Result := TypeIndex;
end;

function TWasmModule.FunctionName(FunctionIndex: Cardinal): AnsiString;
begin
  if FunctionIndex < Cardinal(Length(FunctionNames)) then
    Result := FunctionNames[FunctionIndex]
  else
    Result := '';
end;

function TWasmModule.FindExport(const ExportName: AnsiString; out Found: TWasmExport): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(ExportList) do
    if ExportList[Index].Name = ExportName then
    begin
      Found := ExportList[Index];
      Exit(True);
    end;
  Result := False;
end;

end.
