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
}
unit Wasm.Decoder;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Wasm.Module;

{ Decodes a module; raises EWasmMalformed. The module copies the bytes. }
function DecodeModule(const Bytes: TBytes): TWasmModule;

implementation

uses
  Wasm.Types,
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

{ Where each section id may come, data count between element and code. }
function SectionRank(Id: Byte): Integer;
begin
  case Id of
    SectionDataCount: Result := 10;
    SectionCode: Result := 11;
    SectionData: Result := 12;
  else
    Result := Id;
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
    procedure ReadLimits(out Limits: TWasmLimits; Maximum64: Boolean);
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
    procedure DecodeCustom(Limit: SizeInt);
    procedure DecodeNames(Start, Limit: SizeInt);
  public
    function Decode(const Bytes: TBytes): TWasmModule;
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
var
  Code: Byte;
begin
  Code := FReader.ReadByte;
  if not DecodeValueType(Code, Result) then
    FReader.FailAt(FReader.Position - 1, 'malformed value type');
end;

function TModuleDecoder.ReadReferenceType: TWasmValueType;
var
  Code: Byte;
begin
  Code := FReader.ReadByte;
  if (not DecodeValueType(Code, Result)) or (Result.Kind <> vkReference) then
    FReader.FailAt(FReader.Position - 1, 'malformed reference type');
end;

procedure TModuleDecoder.ReadLimits(out Limits: TWasmLimits; Maximum64: Boolean);
var
  Flags: Byte;
begin
  Flags := FReader.ReadByte;
  if Flags > 1 then
    FReader.FailAt(FReader.Position - 1, 'integer too large');
  Limits.Minimum := FReader.ReadU32;
  Limits.HasMaximum := Flags = 1;
  if Limits.HasMaximum then
    Limits.Maximum := FReader.ReadU32
  else
    Limits.Maximum := 0;
end;

procedure TModuleDecoder.ReadTableType(out TableType: TWasmTableType);
begin
  TableType.ElementType := ReadReferenceType;
  ReadLimits(TableType.Limits, False);
end;

procedure TModuleDecoder.ReadMemoryType(out MemoryType: TWasmMemoryType);
begin
  ReadLimits(MemoryType.Limits, False);
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
  Instructions.Initialize(FReader.Bytes, FReader.Position, FReader.Limit);
  Depth := 0;
  repeat
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpBlock, OpLoop, OpIf: Inc(Depth);
      OpEnd: Dec(Depth);
    end;
  until Depth < 0;
  FReader.Position := Instructions.Reader.Position;
  Expression.Limit := FReader.Position;
end;

procedure TModuleDecoder.DecodeTypes;
var
  Count, Index, ParamCount, ResultCount, Item: Cardinal;
begin
  Count := ReadCount(MaximumTypes, 'types');
  SetLength(FModule.Types, Count);
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    if FReader.ReadByte <> $60 then
      FReader.FailAt(FReader.Position - 1, 'integer representation too long');
    ParamCount := ReadCount(MaximumParams, 'parameters');
    SetLength(FModule.Types[Index].Params, ParamCount);
    if ParamCount > 0 then
      for Item := 0 to ParamCount - 1 do
        FModule.Types[Index].Params[Item] := ReadValueType;
    ResultCount := ReadCount(MaximumResults, 'results');
    SetLength(FModule.Types[Index].Results, ResultCount);
    if ResultCount > 0 then
      for Item := 0 to ResultCount - 1 do
        FModule.Types[Index].Results[Item] := ReadValueType;
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
  if Count = 0 then
    Exit;
  for Index := 0 to Count - 1 do
    ReadTableType(FModule.Tables[Base + Index]);
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
    if Kind > 3 then
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
  IsIf: array of Boolean;
  Depth: Integer;
begin
  Body_.Initialize(FReader.Bytes, FReader.Position, Limit);
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
    if not DecodeValueType(Body_.ReadByte, ValueType) then
      Body_.FailAt(Body_.Position - 1, 'malformed value type');
    SetLength(Body.Locals, Total);
    if RunLength > 0 then
      for Item := Total - RunLength to Total - 1 do
        Body.Locals[Item] := ValueType;
    Inc(Group);
  end;
  Body.BodyStart := Body_.Position;
  Body.BodyLimit := Limit;
  Body.Compiled := nil;
  { The structure: every block, loop and if ends, else only in an if,
    and the body's own end is its last byte. }
  Instructions.Initialize(FReader.Bytes, Body_.Position, Limit);
  SetLength(IsIf, 16);
  Depth := 0;
  IsIf[0] := False;
  while True do
  begin
    if Instructions.AtEnd then
      Instructions.Reader.Fail('END opcode expected');
    Instructions.Next(Instruction);
    case Instruction.Opcode of
      OpBlock, OpLoop, OpIf:
        begin
          Inc(Depth);
          if Depth >= Length(IsIf) then
            SetLength(IsIf, Length(IsIf) * 2);
          IsIf[Depth] := Instruction.Opcode = OpIf;
        end;
      OpElse:
        begin
          if (Depth = 0) or not IsIf[Depth] then
            Instructions.Reader.FailAt(Instruction.Offset, 'illegal opcode else');
          IsIf[Depth] := False;
        end;
      OpEnd:
        begin
          if Depth = 0 then
            Break;
          Dec(Depth);
        end;
      OpMemoryInit, OpDataDrop:
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

function TModuleDecoder.Decode(const Bytes: TBytes): TWasmModule;
var
  Id: Byte;
  Size: Cardinal;
  SectionLimit: SizeInt;
  LastRank: Integer;
  Magic, Version: DWord;
begin
  FModule := TWasmModule.Create;
  try
    FModule.Bytes := Copy(Bytes);
    FReader.Initialize(PByte(FModule.Bytes), 0, Length(FModule.Bytes));
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
      if Id > SectionDataCount then
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
var
  Decoder: TModuleDecoder;
begin
  if Length(Bytes) > MaximumModuleSize then
    raise EWasmMalformed.CreateAt(0, 'module too large');
  Decoder := TModuleDecoder.Create;
  try
    Result := Decoder.Decode(Bytes);
  finally
    Decoder.Free;
  end;
end;

end.
