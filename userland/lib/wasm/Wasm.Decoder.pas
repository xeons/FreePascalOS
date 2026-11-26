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
  The binary format's decoder (spec chapter 5): bytes to a TWasmModule.

  Sections come in the spec's order (custom sections anywhere), each at
  most once, each exactly as long as its size says. Every function body
  is decoded instruction by instruction here too, so that everything the
  spec calls malformed (an unknown opcode, an immediate past the end, a
  block without its end, memory.init without a data count section) is
  found before validation, which then only sees well formed code.

  The name section is read for function names (stack traces) and the
  module's name; like any custom section, a damaged one is ignored.

  3.0 adds rec groups and struct, array and sub types to the type
  section, the tag section (between memory and global), tags as imports
  and exports, 64-bit limits (flag 4) for memories and tables, tables
  with an initializer expression (0x40 0x00) and value types of more
  than one byte. The module's features decide which of these decode.
}
unit Wasm.Decoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Features,
  Wasm.Module;

{ Decodes a module; raises EWasmMalformed. The module copies the bytes. }
function DecodeModule(const Bytes: TBytes): TWasmModule;
function DecodeModule(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;

implementation

uses
  Wasm.Types,
  Wasm.TypeDefinitions,
  Wasm.Errors,
  Wasm.Limits,
  Wasm.Reader,
  Wasm.Opcodes,
  Wasm.Instructions;

const
  SectionCustom = 0;
  SectionType = 1;
  SectionImport = 2;
  SectionFunction = 3;
  SectionTable = 4;
  SectionMemory = 5;
  SectionGlobal = 6;
  SectionExport = 7;
  SectionStart = 8;
  SectionElement = 9;
  SectionCode = 10;
  SectionData = 11;
  SectionDataCount = 12;
  SectionTag = 13;

{ Where each section id may come: data count between element and code,
  tags between memory and global. }
function SectionRank(Id: Byte): Integer;
begin
  case Id of
    SectionDataCount: Result := 21;
    SectionCode: Result := 23;
    SectionData: Result := 25;
    SectionTag: Result := 11;
  else
    Result := Id * 2;
  end;
end;

type
  TModuleDecoder = class
  private
    FModule: TWasmModule;
    FReader: TWasmReader;
    FFunctionCount: Cardinal;    { declared in the function section }
    FCodeCount: Cardinal;
    FSawCode: Boolean;
    FSawFunctions: Boolean;
    function ReadCount(Maximum: Cardinal; const What: AnsiString): Cardinal;
    function ReadValueType: TWasmValueType;
    function ReadReferenceType: TWasmValueType;
    procedure ReadLimits(out Limits: TWasmLimits; out AddressType: TWasmValueKind);
    procedure ReadFieldType(out Field: TWasmFieldType);
    procedure ReadCompositeType(Form: Byte; Index: Cardinal);
    procedure ReadSubType(Index, GroupStart, GroupSize: Cardinal);
    procedure ReadTableType(out TableType: TWasmTableType);
    procedure ReadMemoryType(out MemoryType: TWasmMemoryType);
    procedure ReadGlobalType(out GlobalType: TWasmGlobalType);
    procedure ReadConstantExpression(out Expression: TWasmConstantExpression);
    procedure DecodeTypes;
    procedure DecodeImports;
    procedure DecodeFunctions;
    procedure DecodeTables;
    procedure DecodeMemories;
    procedure DecodeGlobals;
    procedure DecodeExports;
    procedure DecodeStart;
    procedure DecodeElements;
    procedure DecodeCode;
    procedure DecodeFunctionBody(var Body: TWasmFunctionBody; Limit: SizeInt);
    procedure DecodeData;
    procedure DecodeDataCount;
    procedure DecodeTags;
    procedure DecodeCustom(Limit: SizeInt);
    procedure DecodeNames(Start, Limit: SizeInt);
  public
    function Decode(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;
  end;

function TModuleDecoder.ReadCount(Maximum: Cardinal; const What: AnsiString): Cardinal;
begin
  Result := FReader.ReadU32;
  if Result > Maximum then
    FReader.Fail('too many ' + What);
  { Each item takes a byte at least: a count past the end is malformed
    without allocating for it. }
  if Result > FReader.Remaining then
    FReader.Fail('length out of bounds');
end;

function TModuleDecoder.ReadValueType: TWasmValueType;
begin
  Result := FReader.ReadValueType;
end;

function TModuleDecoder.ReadReferenceType: TWasmValueType;
begin
  Result := FReader.ReadReferenceType;
end;

{ Flags: bit 0 a maximum follows, bit 2 the limits (and addresses) are
  64-bit (memory64, table64); bit 1, shared memory, is not supported. }
procedure TModuleDecoder.ReadLimits(out Limits: TWasmLimits; out AddressType: TWasmValueKind);
var
  Flags: Byte;
begin
  Flags := FReader.ReadByte;
  if (Flags > 1) and not ((wfMemory64 in FModule.Features) and (Flags in [4, 5])) then
    FReader.FailAt(FReader.Position - 1, 'integer too large');
  Limits.HasMaximum := Flags and 1 <> 0;
  if Flags and 4 <> 0 then
    AddressType := vkI64
  else
    AddressType := vkI32;
  { 3.0 reads limits as 64-bit numbers; i32 limits past 2^32 are then
    invalid rather than malformed. }
  if (Flags and 4 <> 0) or (wfMemory64 in FModule.Features) then
  begin
    Limits.Minimum := FReader.ReadU64;
    if Limits.HasMaximum then
      Limits.Maximum := FReader.ReadU64
    else
      Limits.Maximum := 0;
  end
  else
  begin
    Limits.Minimum := FReader.ReadU32;
    if Limits.HasMaximum then
      Limits.Maximum := FReader.ReadU32
    else
      Limits.Maximum := 0;
  end;
end;

procedure TModuleDecoder.ReadTableType(out TableType: TWasmTableType);
begin
  TableType.ElementType := ReadReferenceType;
  ReadLimits(TableType.Limits, TableType.AddressType);
end;

procedure TModuleDecoder.ReadMemoryType(out MemoryType: TWasmMemoryType);
begin
  ReadLimits(MemoryType.Limits, MemoryType.AddressType);
end;

procedure TModuleDecoder.ReadFieldType(out Field: TWasmFieldType);
var
  Mutability: Byte;
begin
  case FReader.PeekByte of
    $78:
      begin
        FReader.ReadByte;
        Field.Storage := skI8;
        Field.ValueType := WasmI32Type;
      end;
    $77:
      begin
        FReader.ReadByte;
        Field.Storage := skI16;
        Field.ValueType := WasmI32Type;
      end;
  else
    Field.Storage := skValue;
    Field.ValueType := ReadValueType;
  end;
  Mutability := FReader.ReadByte;
  if Mutability > 1 then
    FReader.FailAt(FReader.Position - 1, 'malformed mutability');
  Field.Mutable := Mutability = 1;
end;

procedure TModuleDecoder.ReadCompositeType(Form: Byte; Index: Cardinal);
var
  Count, Item: Cardinal;
begin
  with FModule.TypeDefinitions[Index] do
    case Form of
      $60:
        begin
          Kind := ckFunction;
          Count := ReadCount(MaximumParams, 'parameters');
          SetLength(FunctionType.Params, Count);
          if Count > 0 then
            for Item := 0 to Count - 1 do
              FunctionType.Params[Item] := ReadValueType;
          Count := ReadCount(MaximumResults, 'results');
          SetLength(FunctionType.Results, Count);
          if Count > 0 then
            for Item := 0 to Count - 1 do
              FunctionType.Results[Item] := ReadValueType;
          FModule.Types[Index] := FunctionType;
        end;
      $5F:
        begin
          Kind := ckStruct;
          Count := ReadCount(MaximumStructFields, 'fields');
          SetLength(Fields, Count);
          if Count > 0 then
            for Item := 0 to Count - 1 do
              ReadFieldType(Fields[Item]);
        end;
      $5E:
        begin
          Kind := ckArray;
          SetLength(Fields, 1);
          ReadFieldType(Fields[0]);
        end;
    else
      FReader.FailAt(FReader.Position - 1, 'malformed composite type');
    end;
end;

procedure TModuleDecoder.ReadSubType(Index, GroupStart, GroupSize: Cardinal);
var
  Form: Byte;
  Count: Cardinal;
  Definition: ^TWasmTypeDefinition;
begin
  Definition := @FModule.TypeDefinitions[Index];
  Definition^.Final := True;
  Definition^.HasSuperType := False;
  Definition^.SuperType := 0;
  Definition^.GroupStart := GroupStart;
  Definition^.GroupSize := GroupSize;
  Form := FReader.ReadByte;
  if ((Form = $50) or (Form = $4F)) and (wfGarbageCollection in FModule.Features) then
  begin
    Definition^.Final := Form = $4F;
    Count := FReader.ReadU32;
    if Count > 1 then
      FReader.Fail('too many supertypes');
    if Count = 1 then
    begin
      Definition^.HasSuperType := True;
      Definition^.SuperType := FReader.ReadU32;
    end;
    Form := FReader.ReadByte;
  end;
  if (Form <> $60) and not (wfGarbageCollection in FModule.Features) then
    FReader.FailAt(FReader.Position - 1, 'integer representation too long');
  ReadCompositeType(Form, Index);
end;

procedure TModuleDecoder.ReadGlobalType(out GlobalType: TWasmGlobalType);
var
  Mutability: Byte;
begin
  GlobalType.ValueType := ReadValueType;
  Mutability := FReader.ReadByte;
  if Mutability > 1 then
    FReader.FailAt(FReader.Position - 1, 'malformed mutability');
  GlobalType.Mutable := Mutability = 1;
end;

procedure TModuleDecoder.ReadConstantExpression(out Expression: TWasmConstantExpression);
var
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Depth: Integer;
begin
  Expression.Start := FReader.Position;
  Instructions.Initialize(FReader.Bytes, FReader.Position, FReader.Limit, FModule.Features);
  Depth := 0;
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpBlock, OpLoop, OpIf, OpTry, OpTryTable: Inc(Depth);
      OpEnd, OpDelegate: Dec(Depth);
    end;
  until Depth < 0;
  FReader.Position := Instructions.Reader.Position;
  Expression.Limit := FReader.Position;
end;

{ A rec group (0x4E and its subtypes) counts as one entry of the
  section but defines as many types as it has members. }
procedure TModuleDecoder.DecodeTypes;
var
  Count, Entry, GroupSize, Member, Index: Cardinal;
begin
  Count := ReadCount(MaximumTypes, 'types');
  Index := 0;
  Entry := 0;
  while Entry < Count do
  begin
    if (wfGarbageCollection in FModule.Features) and (FReader.PeekByte = $4E) then
    begin
      FReader.ReadByte;
      GroupSize := ReadCount(MaximumTypes, 'types');
    end
    else
      GroupSize := 1;
    if Index + GroupSize > MaximumTypes then
      FReader.Fail('too many types');
    SetLength(FModule.TypeDefinitions, Index + GroupSize);
    SetLength(FModule.Types, Index + GroupSize);
    Member := 0;
    while Member < GroupSize do
    begin
      ReadSubType(Index + Member, Index, GroupSize);
      Inc(Member);
    end;
    Inc(Index, GroupSize);
    Inc(Entry);
  end;
end;

procedure TModuleDecoder.DecodeImports;
var
  Count, Index: Cardinal;
  KindCode: Byte;
begin
  Count := ReadCount(MaximumImports, 'imports');
  SetLength(FModule.Imports, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    with FModule.Imports[Index] do
    begin
      ModuleName := FReader.ReadName;
      FieldName := FReader.ReadName;
      KindCode := FReader.ReadByte;
      case KindCode of
        0:
          begin
            FModule.Imports[Index].Kind := ekFunction;
            TypeIndex := FReader.ReadU32;
            SetLength(FModule.FunctionTypes, Length(FModule.FunctionTypes) + 1);
            FModule.FunctionTypes[High(FModule.FunctionTypes)] := TypeIndex;
            Inc(FModule.ImportedFunctionCount);
          end;
        1:
          begin
            FModule.Imports[Index].Kind := ekTable;
            ReadTableType(TableType);
            SetLength(FModule.Tables, Length(FModule.Tables) + 1);
            FModule.Tables[High(FModule.Tables)] := TableType;
            Inc(FModule.ImportedTableCount);
          end;
        2:
          begin
            FModule.Imports[Index].Kind := ekMemory;
            ReadMemoryType(MemoryType);
            SetLength(FModule.Memories, Length(FModule.Memories) + 1);
            FModule.Memories[High(FModule.Memories)] := MemoryType;
            Inc(FModule.ImportedMemoryCount);
          end;
        3:
          begin
            FModule.Imports[Index].Kind := ekGlobal;
            ReadGlobalType(GlobalType);
            SetLength(FModule.Globals, Length(FModule.Globals) + 1);
            FModule.Globals[High(FModule.Globals)] := GlobalType;
            Inc(FModule.ImportedGlobalCount);
          end;
        4:
          begin
            if FModule.Features * [wfExceptionHandling, wfLegacyExceptions] = [] then
              FReader.FailAt(FReader.Position - 1, 'malformed import kind');
            FModule.Imports[Index].Kind := ekTag;
            if FReader.ReadByte <> 0 then
              FReader.FailAt(FReader.Position - 1, 'malformed tag attribute');
            TagTypeIndex := FReader.ReadU32;
            SetLength(FModule.TagTypes, Length(FModule.TagTypes) + 1);
            FModule.TagTypes[High(FModule.TagTypes)] := TagTypeIndex;
            Inc(FModule.ImportedTagCount);
          end;
      else
        FReader.FailAt(FReader.Position - 1, 'malformed import kind');
      end;
    end;
end;

procedure TModuleDecoder.DecodeFunctions;
var
  Count, Index, Base: Cardinal;
begin
  Count := ReadCount(MaximumFunctions, 'functions');
  FFunctionCount := Count;
  FSawFunctions := True;
  Base := Length(FModule.FunctionTypes);
  SetLength(FModule.FunctionTypes, Base + Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    FModule.FunctionTypes[Base + Index] := FReader.ReadU32;
end;

procedure TModuleDecoder.DecodeTables;
var
  Count, Index, Base: Cardinal;
begin
  Count := ReadCount(MaximumTables, 'tables');
  Base := Length(FModule.Tables);
  SetLength(FModule.Tables, Base + Count);
  SetLength(FModule.TableDefinitions, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    FModule.TableDefinitions[Index].HasInitializer := False;
    if (wfFunctionReferences in FModule.Features) and (FReader.PeekByte = $40) then
    begin
      FReader.ReadByte;
      if FReader.ReadByte <> 0 then
        FReader.FailAt(FReader.Position - 1, 'malformed table');
      ReadTableType(FModule.Tables[Base + Index]);
      FModule.TableDefinitions[Index].HasInitializer := True;
      ReadConstantExpression(FModule.TableDefinitions[Index].Initializer);
    end
    else
      ReadTableType(FModule.Tables[Base + Index]);
  end;
end;

procedure TModuleDecoder.DecodeMemories;
var
  Count, Index, Base: Cardinal;
begin
  Count := ReadCount(MaximumTables, 'memories');
  Base := Length(FModule.Memories);
  SetLength(FModule.Memories, Base + Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    ReadMemoryType(FModule.Memories[Base + Index]);
end;

procedure TModuleDecoder.DecodeGlobals;
var
  Count, Index, Base: Cardinal;
begin
  Count := ReadCount(MaximumGlobals, 'globals');
  SetLength(FModule.GlobalDefinitions, Count);
  Base := Length(FModule.Globals);
  SetLength(FModule.Globals, Base + Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    ReadGlobalType(FModule.GlobalDefinitions[Index].GlobalType);
    ReadConstantExpression(FModule.GlobalDefinitions[Index].Initializer);
    FModule.Globals[Base + Index] := FModule.GlobalDefinitions[Index].GlobalType;
  end;
end;

procedure TModuleDecoder.DecodeTags;
var
  Count, Index, Base: Cardinal;
begin
  Count := ReadCount(MaximumTags, 'tags');
  Base := Length(FModule.TagTypes);
  SetLength(FModule.TagTypes, Base + Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    if FReader.ReadByte <> 0 then
      FReader.FailAt(FReader.Position - 1, 'malformed tag attribute');
    FModule.TagTypes[Base + Index] := FReader.ReadU32;
  end;
end;

procedure TModuleDecoder.DecodeExports;
var
  Count, Index: Cardinal;
  Kind: Byte;
begin
  Count := ReadCount(MaximumExports, 'exports');
  SetLength(FModule.ExportList, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    FModule.ExportList[Index].Name := FReader.ReadName;
    Kind := FReader.ReadByte;
    if (Kind > 4) or ((Kind = 4) and (FModule.Features * [wfExceptionHandling, wfLegacyExceptions] = [])) then
      FReader.FailAt(FReader.Position - 1, 'malformed export kind');
    FModule.ExportList[Index].Kind := TWasmExternalKind(Kind);
    FModule.ExportList[Index].Index := FReader.ReadU32;
  end;
end;

procedure TModuleDecoder.DecodeStart;
begin
  FModule.HasStart := True;
  FModule.StartFunction := FReader.ReadU32;
end;

procedure TModuleDecoder.DecodeElements;
var
  Count, Index, Flags, ItemCount, Item: Cardinal;
begin
  Count := ReadCount(MaximumElementSegments, 'element segments');
  SetLength(FModule.Elements, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    with FModule.Elements[Index] do
    begin
      Flags := FReader.ReadU32;
      if Flags > 7 then
        FReader.Fail('malformed elements segment kind');
      TableIndex := 0;
      ElementType := WasmFuncRefType;
      if Flags and 1 = 0 then
        Mode := smActive
      else if Flags and 2 = 0 then
        Mode := smPassive
      else
        Mode := smDeclarative;
      if Mode = smActive then
      begin
        if Flags and 2 <> 0 then
          TableIndex := FReader.ReadU32;
        ReadConstantExpression(Offset);
      end;
      UsesExpressions := Flags and 4 <> 0;
      { Function indices are references that cannot be null. }
      if not UsesExpressions and (wfFunctionReferences in FModule.Features) then
        ElementType := MakeReferenceType(HeapTypeFunc, False);
      { The encodings 1, 2, 3 (and 5, 6, 7) name the element kind or type. }
      if Flags and 3 <> 0 then
      begin
        if UsesExpressions then
          ElementType := ReadReferenceType
        else if FReader.ReadByte <> 0 then
          FReader.FailAt(FReader.Position - 1, 'malformed element kind');
      end;
      ItemCount := ReadCount(MaximumTableElements, 'elements');
      if UsesExpressions then
      begin
        SetLength(Expressions, ItemCount);
        if ItemCount > 0 then
          for Item := 0 to ItemCount - 1 do
            ReadConstantExpression(Expressions[Item]);
      end
      else
      begin
        SetLength(FunctionIndices, ItemCount);
        if ItemCount > 0 then
          for Item := 0 to ItemCount - 1 do
            FunctionIndices[Item] := FReader.ReadU32;
      end;
    end;
end;

procedure TModuleDecoder.DecodeCode;
var
  Count, Index, Size: Cardinal;
  Limit: SizeInt;
begin
  Count := ReadCount(MaximumFunctions, 'functions');
  FCodeCount := Count;
  FSawCode := True;
  if Count <> FFunctionCount then
    FReader.Fail('function and code section have inconsistent lengths');
  SetLength(FModule.Bodies, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    Size := FReader.ReadU32;
    if Size > FReader.Remaining then
      FReader.Fail('length out of bounds');
    if Size > MaximumFunctionBodySize then
      FReader.Fail('function body too large');
    Limit := FReader.Position + Size;
    DecodeFunctionBody(FModule.Bodies[Index], Limit);
    FReader.Position := Limit;
  end;
end;

procedure TModuleDecoder.DecodeFunctionBody(var Body: TWasmFunctionBody; Limit: SizeInt);
var
  Body_: TWasmReader;
  GroupCount, Group, RunLength, Item: Cardinal;
  Total: QWord;
  ValueType: TWasmValueType;
  Instructions: TWasmInstructionReader;
  Instruction: TWasmInstruction;
  Opener: array of Integer;
  Depth: Integer;
begin
  Body_.Initialize(FReader.Bytes, FReader.Position, Limit);
  Body_.Features := FModule.Features;
  GroupCount := Body_.ReadU32;
  if GroupCount > Body_.Remaining then
    Body_.Fail('too many locals');
  Total := 0;
  Body.Locals := nil;
  Group := 0;
  while Group < GroupCount do
  begin
    RunLength := Body_.ReadU32;
    Total := Total + RunLength;
    if Total > MaximumLocals then
      Body_.Fail('too many locals');
    ValueType := Body_.ReadValueType;
    SetLength(Body.Locals, Total);
    if RunLength > 0 then
      for Item := Total - RunLength to Total - 1 do
        Body.Locals[Item] := ValueType;
    Inc(Group);
  end;
  Body.BodyStart := Body_.Position;
  Body.BodyLimit := Limit;
  Body.Compiled := nil;
  { The structure: every block, loop, if, try and try_table ends (a try
    perhaps with delegate), else only in an if, catch and catch_all only
    in a try, and the body's own end is its last byte. }
  Instructions.Initialize(FReader.Bytes, Body_.Position, Limit, FModule.Features);
  SetLength(Opener, 16);
  Depth := 0;
  Opener[0] := OpBlock;
  while True do
  begin
    if Instructions.AtEnd then
      Instructions.Reader.Fail('END opcode expected');
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpBlock, OpLoop, OpIf, OpTry, OpTryTable:
        begin
          Inc(Depth);
          if Depth >= Length(Opener) then
            SetLength(Opener, Length(Opener) * 2);
          Opener[Depth] := Instruction.Opcode;
        end;
      OpElse:
        begin
          if (Depth = 0) or (Opener[Depth] <> OpIf) then
            Instructions.Reader.FailAt(Instruction.Offset, 'illegal opcode else');
          Opener[Depth] := OpElse;
        end;
      OpCatch, OpCatchAll:
        begin
          if (Depth = 0) or ((Opener[Depth] <> OpTry) and (Opener[Depth] <> OpCatch)) then
            Instructions.Reader.FailAt(Instruction.Offset, 'illegal opcode ' + WasmOpcodeName(Instruction.Opcode));
          Opener[Depth] := Instruction.Opcode;
        end;
      OpDelegate:
        begin
          if (Depth = 0) or (Opener[Depth] <> OpTry) then
            Instructions.Reader.FailAt(Instruction.Offset, 'illegal opcode delegate');
          Dec(Depth);
        end;
      OpEnd:
        begin
          if Depth = 0 then
            Break;
          Dec(Depth);
        end;
      OpMemoryInit, OpDataDrop, OpArrayNewData, OpArrayInitData:
        if not FModule.HasDataCount then
          Instructions.Reader.FailAt(Instruction.Offset, 'data count section required');
    end;
  end;
  if not Instructions.AtEnd then
    Instructions.Reader.Fail('section size mismatch');
end;

procedure TModuleDecoder.DecodeData;
var
  Count, Index, Flags, Size: Cardinal;
begin
  Count := ReadCount(MaximumDataSegments, 'data segments');
  if FModule.HasDataCount and (Count <> FModule.DataCount) then
    FReader.Fail('data count and data section have inconsistent lengths');
  SetLength(FModule.Data, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    with FModule.Data[Index] do
    begin
      Flags := FReader.ReadU32;
      MemoryIndex := 0;
      case Flags of
        0:
          begin
            Mode := smActive;
            ReadConstantExpression(Offset);
          end;
        1:
          Mode := smPassive;
        2:
          begin
            Mode := smActive;
            MemoryIndex := FReader.ReadU32;
            ReadConstantExpression(Offset);
          end;
      else
        FReader.Fail('malformed data segment kind');
      end;
      Size := FReader.ReadU32;
      if Size > FReader.Remaining then
        FReader.Fail('unexpected end of section or function');
      DataStart := FReader.Position;
      DataLength := Size;
      FReader.Skip(Size);
    end;
end;

procedure TModuleDecoder.DecodeDataCount;
begin
  FModule.HasDataCount := True;
  FModule.DataCount := FReader.ReadU32;
end;

procedure TModuleDecoder.DecodeCustom(Limit: SizeInt);
var
  Section: TWasmCustomSection;
begin
  Section.Name := FReader.ReadName;
  if FReader.Position > Limit then
    FReader.Fail('unexpected end');
  Section.DataStart := FReader.Position;
  Section.DataLength := Limit - FReader.Position;
  SetLength(FModule.CustomSections, Length(FModule.CustomSections) + 1);
  FModule.CustomSections[High(FModule.CustomSections)] := Section;
  if Section.Name = 'name' then
    try
      DecodeNames(Section.DataStart, Limit);
    except
      on EWasmMalformed do
      begin
        FModule.Name := '';
        FModule.FunctionNames := nil;
      end;
    end;
  FReader.Position := Limit;
end;

procedure TModuleDecoder.DecodeNames(Start, Limit: SizeInt);
var
  Names: TWasmReader;
  Kind: Byte;
  Size, Count, Item, FunctionIndex: Cardinal;
  SubsectionLimit: SizeInt;
  FunctionName: AnsiString;
begin
  Names.Initialize(FReader.Bytes, Start, Limit);
  while not Names.AtEnd do
  begin
    Kind := Names.ReadByte;
    Size := Names.ReadU32;
    if Size > Names.Remaining then
      Names.Fail('unexpected end');
    SubsectionLimit := Names.Position + Size;
    case Kind of
      0: FModule.Name := Names.ReadName;
      1:
        begin
          Count := Names.ReadU32;
          Item := 0;
          while Item < Count do
          begin
            FunctionIndex := Names.ReadU32;
            FunctionName := Names.ReadName;
            if FunctionIndex < MaximumFunctions then
            begin
              if FunctionIndex >= Cardinal(Length(FModule.FunctionNames)) then
                SetLength(FModule.FunctionNames, FunctionIndex + 1);
              FModule.FunctionNames[FunctionIndex] := FunctionName;
            end;
            Inc(Item);
          end;
        end;
    end;
    Names.Position := SubsectionLimit;
  end;
end;

function TModuleDecoder.Decode(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;
var
  Id: Byte;
  Size: Cardinal;
  SectionLimit: SizeInt;
  LastRank: Integer;
  Magic, Version: DWord;
begin
  FModule := TWasmModule.Create;
  try
    FModule.Features := Features;
    FModule.Bytes := Copy(Bytes);
    FReader.Initialize(PByte(FModule.Bytes), 0, Length(FModule.Bytes));
    FReader.Features := Features;
    if Length(FModule.Bytes) < 4 then
      FReader.Fail('unexpected end');
    FReader.ReadRaw(@Magic, 4);
    if LEtoN(Magic) <> $6D736100 then
      FReader.FailAt(0, 'magic header not detected');
    if FReader.Remaining < 4 then
      FReader.Fail('unexpected end');
    FReader.ReadRaw(@Version, 4);
    if LEtoN(Version) <> 1 then
      FReader.FailAt(4, 'unknown binary version');
    LastRank := 0;
    while not FReader.AtEnd do
    begin
      Id := FReader.ReadByte;
      if (Id > SectionTag) or ((Id = SectionTag) and
        (FModule.Features * [wfExceptionHandling, wfLegacyExceptions] = [])) then
        FReader.FailAt(FReader.Position - 1, 'malformed section id');
      Size := FReader.ReadU32;
      if Size > FReader.Remaining then
        FReader.Fail('length out of bounds');
      SectionLimit := FReader.Position + Size;
      if Id <> SectionCustom then
      begin
        if SectionRank(Id) <= LastRank then
          FReader.FailAt(FReader.Position, 'unexpected content after last section');
        LastRank := SectionRank(Id);
      end;
      FReader.Limit := SectionLimit;
      case Id of
        SectionCustom: DecodeCustom(SectionLimit);
        SectionType: DecodeTypes;
        SectionImport: DecodeImports;
        SectionFunction: DecodeFunctions;
        SectionTable: DecodeTables;
        SectionMemory: DecodeMemories;
        SectionGlobal: DecodeGlobals;
        SectionExport: DecodeExports;
        SectionStart: DecodeStart;
        SectionElement: DecodeElements;
        SectionCode: DecodeCode;
        SectionData: DecodeData;
        SectionDataCount: DecodeDataCount;
        SectionTag: DecodeTags;
      end;
      if FReader.Position <> SectionLimit then
        FReader.Fail('section size mismatch');
      FReader.Limit := Length(FModule.Bytes);
    end;
    if (FFunctionCount > 0) and not FSawCode then
      FReader.Fail('function and code section have inconsistent lengths');
    if FSawCode and not FSawFunctions and (FCodeCount > 0) then
      FReader.Fail('function and code section have inconsistent lengths');
    if FModule.HasDataCount and (Length(FModule.Data) <> FModule.DataCount) then
      FReader.Fail('data count and data section have inconsistent lengths');
    Result := FModule;
  except
    FModule.Free;
    FModule := nil;
    raise;
  end;
end;

function DecodeModule(const Bytes: TBytes): TWasmModule;
begin
  Result := DecodeModule(Bytes, WasmFeaturesAll);
end;

function DecodeModule(const Bytes: TBytes; Features: TWasmFeatures): TWasmModule;
var
  Decoder: TModuleDecoder;
begin
  if Length(Bytes) > MaximumModuleSize then
    raise EWasmMalformed.CreateAt(0, 'module too large');
  Decoder := TModuleDecoder.Create;
  try
    Result := Decoder.Decode(Bytes, Features);
  finally
    Decoder.Free;
  end;
end;

end.
