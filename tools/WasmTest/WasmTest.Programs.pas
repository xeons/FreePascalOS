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
  WasmTest: whole programs. A module built by a real toolchain, when one
  is given on the command line (decoded, validated and instantiated with
  stub imports; skipped when absent: such samples are not committed),
  and the interpreter's speed on recursive calls and on tight loops,
  printed as "perf" lines.
}
unit WasmTest.Programs;

{$mode objfpc}
{$H+}

interface

{ SamplePath: a .wasm file to instantiate, or ''. }
procedure RunProgramTests(const SamplePath: AnsiString);

implementation

uses
  SysUtils,
  Classes,
  DateUtils,
  TestChecks,
  Wasm.Types,
  Wasm.Errors,
  Wasm.Module,
  Wasm.Runtime,
  Wasm.Api,
  WasmTest.Support;

type
  TStubs = class
    Calls: Integer;
    procedure Stub(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
  end;

procedure TStubs.Stub(Func: TWasmFunction; const Arguments: TWasmValueArray; var Results: TWasmValueArray);
begin
  Inc(Calls);
end;

function ReadLeb(const Bytes: TBytes; var Position: SizeInt): QWord;
var
  Shift: Integer;
  Value: Byte;
begin
  Result := 0;
  Shift := 0;
  repeat
    if Position >= Length(Bytes) then
      Exit(High(QWord));
    Value := Bytes[Position];
    Inc(Position);
    Result := Result or (QWord(Value and $7F) shl Shift);
    Inc(Shift, 7);
  until (Value and $80 = 0) or (Shift > 63);
end;

procedure AppendLeb(var Bytes: TBytes; Value: QWord);
var
  Value_: Byte;
begin
  repeat
    Value_ := Value and $7F;
    Value := Value shr 7;
    if Value <> 0 then
      Value_ := Value_ or $80;
    SetLength(Bytes, Length(Bytes) + 1);
    Bytes[High(Bytes)] := Value_;
  until Value = 0;
end;

procedure AppendBytes(var Bytes: TBytes; const Source: TBytes; Start, Count: SizeInt);
var
  Base: SizeInt;
begin
  if Count <= 0 then
    Exit;
  Base := Length(Bytes);
  SetLength(Bytes, Base + Count);
  Move(Source[Start], Bytes[Base], Count);
end;

{ A sample cut short inside its code section (a partial download): the
  sections before it, and a code section with the function bodies that
  are whole and "unreachable" for the rest; nil if the sample is whole. }
function SalvageTruncated(const Bytes: TBytes; out Whole, Total: Integer): TBytes;
var
  Position, SectionStart, BodyStart: SizeInt;
  Id: Byte;
  Size, Count, BodySize: QWord;
  Code: TBytes;
  Index: Integer;
begin
  Result := nil;
  Whole := 0;
  Total := 0;
  Position := 8;
  while Position < Length(Bytes) do
  begin
    SectionStart := Position;
    Id := Bytes[Position];
    Inc(Position);
    Size := ReadLeb(Bytes, Position);
    if (Id = 10) and (Position + Int64(Size) > Length(Bytes)) then
    begin
      Result := Copy(Bytes, 0, SectionStart);
      Count := ReadLeb(Bytes, Position);
      Total := Count;
      Code := nil;
      AppendLeb(Code, Count);
      for Index := 0 to Integer(Count) - 1 do
      begin
        BodyStart := Position;
        BodySize := ReadLeb(Bytes, Position);
        if (BodySize <> High(QWord)) and (Position + Int64(BodySize) <= Length(Bytes)) then
        begin
          AppendBytes(Code, Bytes, BodyStart, Position + Int64(BodySize) - BodyStart);
          Inc(Position, BodySize);
          Inc(Whole);
        end
        else
        begin
          Position := Length(Bytes);
          AppendBytes(Code, TBytes.Create(3, 0, 0, $0B), 0, 4);
        end;
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := 10;
      AppendLeb(Result, Length(Code));
      AppendBytes(Result, Code, 0, Length(Code));
      Exit;
    end;
    if Position + Int64(Size) > Length(Bytes) then
      Exit;
    Inc(Position, Size);
  end;
end;

procedure TestSample(const SamplePath: AnsiString);
var
  Stream: TFileStream;
  Bytes: TBytes;
  Module: TWasmModule;
  Store: TWasmStore;
  Stubs: TStubs;
  Descriptors: TWasmImportDescriptorArray;
  Imports: TWasmExternalArray;
  Index, Functions: Integer;
  Instance: TWasmModuleInstance;
  Started: TDateTime;
  Salvaged: TBytes;
  Whole, Total: Integer;
  Message: AnsiString;
begin
  if (SamplePath = '') or not FileExists(SamplePath) then
  begin
    WriteLn('info no WebAssembly sample given: skipped');
    Exit;
  end;
  Stream := TFileStream.Create(SamplePath, fmOpenRead or fmShareDenyNone);
  try
    Bytes := nil;
    SetLength(Bytes, Stream.Size);
    if Length(Bytes) > 0 then
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Salvaged := SalvageTruncated(Bytes, Whole, Total);
  if Salvaged <> nil then
  begin
    Check(CompileFailure(Bytes, Message) = 'EWasmMalformed', 'a truncated sample is malformed (' + Message + ')');
    WriteLn(Format('info sample is truncated: %d of %d function bodies whole; the rest replaced by unreachable',
      [Whole, Total]));
    Bytes := Salvaged;
  end;
  Started := Now;
  try
    Module := WasmCompile(Bytes);
  except
    on E: Exception do
    begin
      Check(False, 'sample compiles: ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  Check(True, 'sample decodes and validates');
  Store := TWasmStore.Create;
  Stubs := TStubs.Create;
  try
    Descriptors := WasmModuleImports(Module);
    Imports := nil;
    SetLength(Imports, Length(Descriptors));
    Functions := 0;
    for Index := 0 to High(Descriptors) do
    begin
      FillChar(Imports[Index], SizeOf(TWasmExternal), 0);
      Imports[Index].Kind := Descriptors[Index].Kind;
      case Descriptors[Index].Kind of
        ekFunction:
          begin
            Imports[Index].Func := WasmNewHostFunction(Store, Descriptors[Index].FunctionType, @Stubs.Stub);
            Inc(Functions);
          end;
        ekTable: Imports[Index].Table := WasmNewTable(Store, Descriptors[Index].TableType, nil);
        ekMemory: Imports[Index].Memory := WasmNewMemory(Store, Descriptors[Index].MemoryType);
        ekGlobal: Imports[Index].Global := WasmNewGlobal(Store, Descriptors[Index].GlobalType,
          WasmDefaultValue(Descriptors[Index].GlobalType.ValueType));
      end;
    end;
    try
      Instance := WasmInstantiate(Store, Module, Imports);
      Check(Instance <> nil, 'sample instantiates with stub imports');
      WriteLn(Format('info sample: %d bytes, %d functions, %d imports (%d functions), %d exports, compiled and ' +
        'instantiated in %d ms', [Length(Bytes), Module.FunctionCount, Length(Descriptors), Functions,
        Length(Module.ExportList), MilliSecondsBetween(Now, Started)]));
    except
      on E: Exception do
        Check(False, 'sample instantiates: ' + E.ClassName + ': ' + E.Message);
    end;
  finally
    Stubs.Free;
    Store.Free;
    Module.Release;
  end;
end;

procedure TestPerformance;
var
  Test: TTestModule;
  Started: TDateTime;
  Milliseconds: Int64;
  Iterations: Int64;
begin
  Test := TTestModule.Create(
    '(module (memory 1)' +
    '  (func $fib (export "fib") (param i32) (result i32)' +
    '    (if (result i32) (i32.lt_u (local.get 0) (i32.const 2)) (then (local.get 0))' +
    '      (else (i32.add (call $fib (i32.sub (local.get 0) (i32.const 1))) (call $fib (i32.sub (local.get 0) (i32.const 2)))))))' +
    '  (func (export "mix") (param $n i32) (result i32) (local $a i32) (local $b i32) (local $i i32)' +
    '    (loop' +
    '      (local.set $a (i32.add (i32.rotl (local.get $a) (i32.const 5)) (i32.xor (local.get $b) (local.get $i))))' +
    '      (local.set $b (i32.add (local.get $b) (i32.shr_u (local.get $a) (i32.const 3))))' +
    '      (local.set $i (i32.add (local.get $i) (i32.const 1)))' +
    '      (br_if 0 (i32.lt_u (local.get $i) (local.get $n))))' +
    '    (local.get $a))' +
    '  (func (export "sum") (param $n i32) (result i32) (local $p i32) (local $s i32)' +
    '    (loop' +
    '      (local.set $s (i32.add (local.get $s) (i32.load8_u (local.get $p))))' +
    '      (br_if 0 (i32.lt_u (local.tee $p (i32.add (local.get $p) (i32.const 1))) (local.get $n))))' +
    '    (local.get $s))' +
    ')');
  try
    Started := Now;
    Check(Test.CallI32('fib', [WasmI32(30)]) = 832040, 'fib(30)');
    Milliseconds := MilliSecondsBetween(Now, Started);
    if Milliseconds = 0 then
      Milliseconds := 1;
    { fib(30) makes 2,692,537 calls of 9 or 15 instructions. }
    WriteLn(Format('perf fib(30): %d ms, %.1f million calls per second', [Milliseconds, 2692537 / Milliseconds / 1000]));
    Iterations := 20000000;
    Started := Now;
    Test.CallI32('mix', [WasmI32(Iterations)]);
    Milliseconds := MilliSecondsBetween(Now, Started);
    if Milliseconds = 0 then
      Milliseconds := 1;
    WriteLn(Format('perf mixing loop: %d million WebAssembly instructions in %d ms, %.0f million per second',
      [Iterations * 22 div 1000000, Milliseconds, Iterations * 22 / Milliseconds / 1000]));
    Iterations := 65536;
    Started := Now;
    for Milliseconds := 1 to 300 do
      Test.CallI32('sum', [WasmI32(Iterations)]);
    Milliseconds := MilliSecondsBetween(Now, Started);
    if Milliseconds = 0 then
      Milliseconds := 1;
    WriteLn(Format('perf memory loop: %d million WebAssembly instructions in %d ms, %.0f million per second',
      [300 * Iterations * 13 div 1000000, Milliseconds, 300 * Iterations * 13 / Milliseconds / 1000]));
  finally
    Test.Free;
  end;
end;

procedure RunProgramTests(const SamplePath: AnsiString);
begin
  TestSample(SamplePath);
  TestPerformance;
end;

end.
