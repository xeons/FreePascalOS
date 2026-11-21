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
  The host test of libjavascript.

  JavaScriptTest SCRIPTS BENCHMARKS

  Runs every SCRIPTS/*.js (and every SCRIPTS/*.mjs as a module, its
  imports read from files relative to it) in a fresh engine, with its console output
  (and "Uncaught ..." for an exception that escapes, after the promise
  jobs have run) compared line by line with the block comment at the
  end of the file that starts with "/* expected". Then runs every
  BENCHMARKS/*.js and reports its time and the peak bytes: those of the
  engine's heap and those the whole process had allocated (a counting
  memory manager). The last line is the summary.

  The embedding API is checked too: host functions and classes with
  native data and finalizers, protected values across collections,
  calling JavaScript from Pascal, the memory limit and interrupts.
}
program JavaScriptTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Objects,
  Js.Functions,
  Js.Operations,
  Js.Interpreter,
  Js.ArrayBuffers,
  Js.Modules,
  Js.Promises,
  Js.Engine;

{ The counting memory manager }

var
  PreviousManager: TMemoryManager;
  CurrentBytes: Int64 = 0;
  PeakBytes: Int64 = 0;

function CountingGetMem(Size: PtrUInt): Pointer;
begin
  Result := PreviousManager.GetMem(Size);
  if Result <> nil then
  begin
    Inc(CurrentBytes, PreviousManager.MemSize(Result));
    if CurrentBytes > PeakBytes then
      PeakBytes := CurrentBytes;
  end;
end;

function CountingFreeMem(P: Pointer): PtrUInt;
begin
  if P <> nil then
    Dec(CurrentBytes, PreviousManager.MemSize(P));
  Result := PreviousManager.FreeMem(P);
end;

function CountingFreeMemSize(P: Pointer; Size: PtrUInt): PtrUInt;
begin
  if P <> nil then
    Dec(CurrentBytes, PreviousManager.MemSize(P));
  Result := PreviousManager.FreeMemSize(P, Size);
end;

function CountingAllocMem(Size: PtrUInt): Pointer;
begin
  Result := PreviousManager.AllocMem(Size);
  if Result <> nil then
  begin
    Inc(CurrentBytes, PreviousManager.MemSize(Result));
    if CurrentBytes > PeakBytes then
      PeakBytes := CurrentBytes;
  end;
end;

function CountingReAllocMem(var P: Pointer; Size: PtrUInt): Pointer;
begin
  if P <> nil then
    Dec(CurrentBytes, PreviousManager.MemSize(P));
  Result := PreviousManager.ReAllocMem(P, Size);
  if Result <> nil then
  begin
    Inc(CurrentBytes, PreviousManager.MemSize(Result));
    if CurrentBytes > PeakBytes then
      PeakBytes := CurrentBytes;
  end;
end;

procedure InstallCountingManager;
var
  Manager: TMemoryManager;
begin
  GetMemoryManager(PreviousManager);
  Manager := PreviousManager;
  Manager.GetMem := @CountingGetMem;
  Manager.FreeMem := @CountingFreeMem;
  Manager.FreeMemSize := @CountingFreeMemSize;
  Manager.AllocMem := @CountingAllocMem;
  Manager.ReAllocMem := @CountingReAllocMem;
  SetMemoryManager(Manager);
end;

function ReadText(const Path: string): string; forward;

{ Output capture }

type
  TCapture = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Write(const Text: string; IsError: Boolean);
    procedure Fetch(Request: TJsModuleFetch);
    { Scripts are named without their directory: their imports resolve
      against the scripts' directory. }
    function Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
  public
    Directory: string;
  end;

constructor TCapture.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TCapture.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

{ Modules are files: the key is the path. }
procedure TCapture.Fetch(Request: TJsModuleFetch);
var
  Text: string;
begin
  if not FileExists(Request.Key) then
  begin
    Request.Fail('Cannot find module ''' + ExtractFileName(Request.Key) + '''');
    Exit;
  end;
  Text := ReadText(Request.Key);
  Request.Succeed(Text);
end;

function TCapture.Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
begin
  if Pos('/', ReferrerKey) = 0 then
    Key := ResolveRelativePath(Specifier, Directory + ReferrerKey)
  else
    Key := ResolveRelativePath(Specifier, ReferrerKey);
  Result := True;
end;

procedure TCapture.Write(const Text: string; IsError: Boolean);
var
  Parts: TStringList;
  Index: Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := #10;
    Parts.DelimitedText := Text;
    for Index := 0 to Parts.Count - 1 do
      Lines.Add(Parts[Index]);
  finally
    Parts.Free;
  end;
end;

var
  Passed, Failed: Integer;

procedure Check(Condition: Boolean; const Name: string);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('PASS ', Name);
  end
  else
  begin
    Inc(Failed);
    WriteLn('FAIL ', Name);
  end;
  Flush(Output);
end;

function ReadText(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

{ The expected lines: the "/* expected" block comment at the end. }
function ExpectedOf(const Source: string; Lines: TStringList): Boolean;
var
  Start, Finish: Integer;
  Block: string;
begin
  Lines.Clear;
  Start := Pos('/* expected', Source);
  if Start = 0 then
    Exit(False);
  Start := Start + Length('/* expected');
  while (Start <= Length(Source)) and (Source[Start] <> #10) do
    Inc(Start);
  Inc(Start);
  Finish := Length(Source);
  while (Finish > Start) and (Copy(Source, Finish - 1, 2) <> '*/') do
    Dec(Finish);
  Block := Copy(Source, Start, Finish - 1 - Start);
  if (Block <> '') and (Block[Length(Block)] = #10) then
    Delete(Block, Length(Block), 1);
  Lines.StrictDelimiter := True;
  Lines.Delimiter := #10;
  if Block = '' then
    Lines.Clear
  else
    Lines.DelimitedText := Block;
  Result := True;
end;

procedure RunScript(const Path: string);
var
  Engine: TJsEngine;
  Capture: TCapture;
  Expected: TStringList;
  Source: string;
  Index: Integer;
  Same: Boolean;
  Options: TJsEngineOptions;
begin
  Source := ReadText(Path);
  Expected := TStringList.Create;
  Capture := TCapture.Create;
  { JS_GC_STRESS: collect every few kilobytes, to shake out roots the
    collector misses. }
  Options := TJsEngine.DefaultOptions;
  if GetEnvironmentVariable('JS_GC_STRESS') <> '' then
    Options.InitialHeapThreshold := 16 * 1024;
  Engine := TJsEngine.Create(Options);
  try
    if not ExpectedOf(Source, Expected) then
    begin
      Check(False, ExtractFileName(Path) + ' (no expected block)');
      Exit;
    end;
    Engine.Realm.ConsoleWriter := @Capture.Write;
    Engine.ModuleFetcher := @Capture.Fetch;
    Engine.ModuleResolver := @Capture.Resolve;
    Capture.Directory := ExtractFilePath(Path);
    try
      if ExtractFileExt(Path) = '.mjs' then
        Engine.EvaluateModule(Source, Path)
      else
        Engine.Evaluate(Source, ExtractFileName(Path));
      Engine.RunJobs;
    except
      on Error: EJsError do
      begin
        try
          Engine.RunJobs;
        except
          on EJsError do;
        end;
        Capture.Write('Uncaught ' + Error.Message, True);
      end;
    end;
    Same := Capture.Lines.Count = Expected.Count;
    if Same then
      for Index := 0 to Expected.Count - 1 do
        if Capture.Lines[Index] <> Expected[Index] then
        begin
          Same := False;
          Break;
        end;
    Check(Same, ExtractFileName(Path));
    if not Same then
    begin
      for Index := 0 to Expected.Count - 1 do
        if (Index >= Capture.Lines.Count) or (Capture.Lines[Index] <> Expected[Index]) then
        begin
          WriteLn('  line ', Index + 1, ' expected: ', Expected[Index]);
          if Index < Capture.Lines.Count then
            WriteLn('  line ', Index + 1, ' got:      ', Capture.Lines[Index])
          else
            WriteLn('  (output ended)');
          Break;
        end;
      if Capture.Lines.Count > Expected.Count then
        WriteLn('  extra output: ', Capture.Lines[Expected.Count]);
    end;
  finally
    Engine.Free;
    Capture.Free;
    Expected.Free;
  end;
end;

procedure RunBenchmark(const Path: string);
var
  Engine: TJsEngine;
  Capture: TCapture;
  Started: QWord;
  Elapsed: QWord;
  BaseBytes: Int64;
  Statistics: TJsCollectorStatistics;
begin
  Capture := TCapture.Create;
  BaseBytes := CurrentBytes;
  PeakBytes := CurrentBytes;
  Engine := TJsEngine.Create;
  try
    Engine.Realm.ConsoleWriter := @Capture.Write;
    Started := GetTickCount64;
    try
      Engine.Evaluate(ReadText(Path), ExtractFileName(Path));
      Engine.RunJobs;
      Elapsed := GetTickCount64 - Started;
      Statistics := Engine.CollectorStatistics;
      WriteLn(Format('BENCH %-27s %6d ms  heap peak %8d KiB  process peak %8d KiB  gc %3d, longest %4d ms',
        [ExtractFileName(Path), Elapsed, Engine.PeakHeapBytes div 1024, (PeakBytes - BaseBytes) div 1024,
        Statistics.Collections, Round(Statistics.LongestPause)]));
      Check(True, 'benchmark ' + ExtractFileName(Path));
    except
      on Error: EJsError do
      begin
        WriteLn('  ', Error.Message);
        Check(False, 'benchmark ' + ExtractFileName(Path));
      end;
    end;
  finally
    Engine.Free;
    Capture.Free;
  end;
end;

{ The embedding API }

type
  TPoint = class
  public
    X, Y: Double;
  end;

  TApiFixture = class
  public
    Finalized: Integer;
    Called: Integer;
    procedure Finalize(HostClass: TJsHostClass; NativeData: Pointer);
    function Add(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
      Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
  end;

var
  PointClass: TJsHostClass;
  ExternalFreed: Integer;

procedure FreeExternalBytes(Data: Pointer; ByteLength: SizeInt; Context: Pointer);
begin
  Inc(ExternalFreed);
  FreeMem(Data);
end;

type
  { A host whose fetches finish later. }
  TDeferredModules = class
  public
    Pending: array of TJsModuleFetch;
    procedure Fetch(Request: TJsModuleFetch);
  end;

procedure TDeferredModules.Fetch(Request: TJsModuleFetch);
begin
  SetLength(Pending, Length(Pending) + 1);
  Pending[High(Pending)] := Request;
end;

{ Modules fetched asynchronously by the host. }
procedure TestModuleLoading;
var
  Engine: TJsEngine;
  Host: TDeferredModules;
  Promise, Namespace, Second: TJsValue;
begin
  Host := TDeferredModules.Create;
  Engine := TJsEngine.Create;
  try
    Engine.ModuleFetcher := @Host.Fetch;
    Promise := Engine.EvaluateModule('import { v } from "./lib/dep.mjs"; globalThis.seen = v * 2;', 'app/main.mjs');
    Check((Length(Host.Pending) = 1) and (Host.Pending[0].Key = 'app/lib/dep.mjs') and
      (Engine.GetProperty(JsObjectValue(Engine.GlobalObject), 'seen') = JsUndefined), 'api: module fetch deferred');
    Host.Pending[0].Succeed('export const v = 21;');
    Host.Pending := nil;
    Engine.RunJobs;
    Check(Engine.ToNumber(Engine.GetProperty(JsObjectValue(Engine.GlobalObject), 'seen')) = 42,
      'api: module evaluated once its import arrived');
    Check(TJsPromise(JsAsObject(Promise)).State = psFulfilled, 'api: module evaluation promise');
    Namespace := Engine.ModuleNamespace('app/lib/dep.mjs');
    Check(Engine.ToNumber(Engine.GetProperty(Namespace, 'v')) = 21, 'api: module namespace');
    Promise := Engine.ImportModule('./lib/dep.mjs', 'app/main.mjs');
    Engine.RunJobs;
    Check((Length(Host.Pending) = 0) and (TJsPromise(JsAsObject(Promise)).Value = Namespace),
      'api: import of a loaded module');
    Promise := Engine.EvaluateModule('import "./gone.mjs";', 'app/other.mjs');
    Host.Pending[0].Fail('not found');
    Host.Pending := nil;
    Engine.RunJobs;
    Check(TJsPromise(JsAsObject(Promise)).State = psRejected, 'api: failed fetch rejects');
    { A graph waiting for two fetches fails at the first; the second
      arrives later (after another graph started) and must not reach
      the failed graph's memory (it was freed while the module map still
      had it waiting: www.github.com crashed hovering links). }
    Promise := Engine.EvaluateModule('import "./a.mjs"; import "./b.mjs";', 'app/failing.mjs');
    Check(Length(Host.Pending) = 2, 'api: a graph waits for two fetches');
    Host.Pending[0].Fail('not found');
    Second := Engine.EvaluateModule('import "./c.mjs"; globalThis.second = 1;', 'app/second.mjs');
    Host.Pending[1].Succeed('export const b = 1;');
    Check(Engine.GetProperty(JsObjectValue(Engine.GlobalObject), 'second') = JsUndefined,
      'api: a late fetch of a failed graph leaves the next graph waiting');
    Host.Pending[2].Succeed('export const c = 1;');
    Host.Pending := nil;
    Engine.RunJobs;
    Check((TJsPromise(JsAsObject(Promise)).State = psRejected) and (TJsPromise(JsAsObject(Second)).State = psFulfilled)
      and (Engine.ToNumber(Engine.GetProperty(JsObjectValue(Engine.GlobalObject), 'second')) = 1),
      'api: the failed graph rejects, the next one runs once its import arrived');
  finally
    Engine.Free;
    Host.Free;
  end;
end;

{ ArrayBuffers made and read from Pascal without copies. }
procedure TestBinaryData;
var
  Engine: TJsEngine;
  Buffer, View, Value: TJsValue;
  Data: PByte;
  Taken: Pointer;
  Length: SizeInt;
  Memory: PByte;
  Index: Integer;
begin
  ExternalFreed := 0;
  Engine := TJsEngine.Create;
  try
    Buffer := Engine.NewArrayBuffer(4);
    Check(Engine.BufferSourceData(Buffer, Data, Length) and (Length = 4), 'api: new ArrayBuffer');
    for Index := 0 to 3 do
      Data[Index] := Index + 10;
    Engine.SetProperty(JsObjectValue(Engine.GlobalObject), 'hostBuffer', Buffer);
    Value := Engine.Evaluate('new Uint8Array(hostBuffer).join()');
    Check(Engine.ToText(Value) = '10,11,12,13', 'api: script sees the host''s bytes');
    View := Engine.Evaluate('const v = new Uint8Array(8); v.set([1, 2, 3, 4, 5], 2); v.subarray(2, 5)');
    Check(Engine.IsTypedArray(View) and Engine.BufferSourceData(View, Data, Length) and (Length = 3) and
      (Data[0] = 1) and (Data[2] = 3), 'api: bytes of a typed array view');
    Memory := GetMem(3);
    Memory[0] := 7;
    Memory[1] := 8;
    Memory[2] := 9;
    Buffer := Engine.NewExternalArrayBuffer(Memory, 3, @FreeExternalBytes, nil);
    Engine.SetProperty(JsObjectValue(Engine.GlobalObject), 'external', Buffer);
    Value := Engine.Evaluate('new Uint8Array(external).reduce((a, b) => a + b) + external.byteLength');
    Check(Engine.ToNumber(Value) = 27, 'api: external ArrayBuffer');
    Engine.Evaluate('external.transfer(); external = null');
    Engine.CollectGarbage;
    Check(ExternalFreed = 1, 'api: external memory freed once when the buffer goes');
    View := Engine.NewUint8Array(Memory, 0);
    Check(Engine.IsTypedArray(View), 'api: empty Uint8Array');
    Buffer := Engine.Evaluate('globalThis.taken = new Uint8Array([4, 5, 6]).buffer; taken');
    Check(Engine.DetachArrayBuffer(Buffer, Taken, Length) and (Length = 3) and (PByte(Taken)[2] = 6),
      'api: detach takes the bytes');
    FreeMem(Taken);
    Value := Engine.Evaluate('taken.detached && taken.byteLength === 0');
    Check(Value = JsTrue, 'api: the detached buffer in the script');
    View := Engine.NewTypedArray(taInt16, Engine.NewArrayBuffer(8), 2, 2);
    Engine.SetProperty(JsObjectValue(Engine.GlobalObject), 'shorts', View);
    Value := Engine.Evaluate('shorts.length + shorts.byteOffset + (shorts instanceof Int16Array ? 100 : 0)');
    Check(Engine.ToNumber(Value) = 104, 'api: typed array on a host buffer');
  finally
    Engine.Free;
  end;
end;

procedure TApiFixture.Finalize(HostClass: TJsHostClass; NativeData: Pointer);
begin
  Inc(Finalized);
  TObject(NativeData).Free;
end;

function TApiFixture.Add(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Inc(Called);
  Result := JsNumber(JsNumberValue(Arg(Args, ArgCount, 0)) + JsNumberValue(Arg(Args, ArgCount, 1)));
end;

function PointConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Point: TPoint;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Point requires new'));
  Point := TPoint.Create;
  Point.X := JsNumberValue(Arg(Args, ArgCount, 0));
  Point.Y := JsNumberValue(Arg(Args, ArgCount, 1));
  Result := JsObjectValue(PointClass.CreateInstance(R, Point));
end;

function PointLength(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Point: TPoint;
begin
  Point := TPoint(PointClass.DataOf(This));
  if Point = nil then
    Exit(R.ThrowTypeError('not a Point'));
  Result := JsNumber(Sqrt(Point.X * Point.X + Point.Y * Point.Y));
end;

procedure TestEmbedding;
var
  Engine: TJsEngine;
  Fixture: TApiFixture;
  Value, Kept, Doubler: TJsValue;
  Handle: Integer;
  Options: TJsEngineOptions;
  Raised: Boolean;
  ErrorText: string;
begin
  Fixture := TApiFixture.Create;
  Engine := TJsEngine.Create;
  try
    Engine.DefineMethod(Engine.GlobalObject, 'add', @Fixture.Add, 2);
    Value := Engine.Evaluate('add(2, 3) * 2');
    Check((Engine.ToNumber(Value) = 10) and (Fixture.Called = 1), 'api: host function');
    PointClass := Engine.DefineClass('Point', @PointConstructor, 2);
    PointClass.Finalizer := @Fixture.Finalize;
    Engine.DefineFunction(PointClass.Prototype, 'length', @PointLength, 0);
    Value := Engine.Evaluate('new Point(3, 4).length()');
    Check(Engine.ToNumber(Value) = 5, 'api: host class with native data');
    Value := Engine.Evaluate('Object.prototype.toString.call(new Point(1, 1))');
    Check(Engine.ToText(Value) = '[object Point]', 'api: host class tag');
    Engine.Evaluate('for (let i = 0; i < 1000; i++) new Point(i, i);');
    Engine.CollectGarbage;
    Check(Fixture.Finalized >= 1000, 'api: finalizers run for collected host objects');
    Kept := Engine.Evaluate('({ text: "kept" + 1 })');
    Handle := Engine.Protect(Kept);
    Engine.Evaluate('let garbage = []; for (let i = 0; i < 20000; i++) garbage.push({ i }); garbage = null;');
    Engine.CollectGarbage;
    Check(Engine.ToText(Engine.GetProperty(Engine.Protected(Handle), 'text')) = 'kept1', 'api: protected value');
    Engine.Unprotect(Handle);
    Doubler := Engine.Evaluate('(x => x * 2)');
    Value := Engine.Call(Doubler, JsUndefined, [JsInteger(21)]);
    Check(Engine.ToNumber(Value) = 42, 'api: calling a function from Pascal');
    Raised := False;
    try
      Engine.Evaluate('throw new TypeError("from script")');
    except
      on Error: EJsError do
        Raised := (Error.ErrorName = 'TypeError') and (Pos('from script', Error.Message) > 0);
    end;
    Check(Raised, 'api: uncaught exception as EJsError');
    Check(not Engine.TryEvaluate('let = ;', 'bad.js', Value, ErrorText) and (Pos('SyntaxError', ErrorText) = 1),
      'api: syntax error');
    Value := Engine.Evaluate('let order = []; Promise.resolve().then(() => order.push("job")); order.push("sync"); order');
    Engine.RunJobs;
    Check(Engine.ToText(Value) = 'sync,job', 'api: job queue');
  finally
    Engine.Free;
  end;
  Check(Fixture.Finalized > 1000, 'api: engine shut down finalizes everything');
  Fixture.Free;

  Options := TJsEngine.DefaultOptions;
  Options.MemoryLimit := 8 * 1024 * 1024;
  Options.InitialHeapThreshold := 1024 * 1024;
  Engine := TJsEngine.Create(Options);
  try
    Raised := False;
    try
      Engine.Evaluate('let keep = []; while (true) keep.push(new Array(100).fill(1));');
    except
      on Error: EJsError do
        Raised := Pos('Out of memory', Error.Message) > 0;
    end;
    Check(Raised, 'api: memory limit stops the script');
    Value := Engine.Evaluate('1 + 1');
    Check(Engine.ToNumber(Value) = 2, 'api: the engine works after the limit');
  finally
    Engine.Free;
  end;

  Engine := TJsEngine.Create;
  try
    Raised := False;
    Engine.Interrupt;
    try
      Engine.Evaluate('try { while (true) {} } catch (e) { "caught" }');
    except
      on Error: EJsError do
        Raised := Pos('interrupted', Error.Message) > 0;
    end;
    Check(Raised, 'api: interrupt is not catchable');
  finally
    Engine.Free;
  end;
end;

var
  Search: TSearchRec;
  Files: TStringList;
  Index: Integer;
  ScriptDirectory, BenchmarkDirectory: string;

begin
  InstallCountingManager;
  if ParamCount < 2 then
  begin
    WriteLn('usage: JavaScriptTest SCRIPTS BENCHMARKS');
    Halt(2);
  end;
  ScriptDirectory := IncludeTrailingPathDelimiter(ParamStr(1));
  BenchmarkDirectory := IncludeTrailingPathDelimiter(ParamStr(2));
  Passed := 0;
  Failed := 0;
  Files := TStringList.Create;
  try
    if FindFirst(ScriptDirectory + '*.js', faAnyFile, Search) = 0 then
    begin
      repeat
        Files.Add(ScriptDirectory + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    if FindFirst(ScriptDirectory + '*.mjs', faAnyFile, Search) = 0 then
    begin
      repeat
        Files.Add(ScriptDirectory + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Files.Sort;
    for Index := 0 to Files.Count - 1 do
      RunScript(Files[Index]);
    TestEmbedding;
    TestBinaryData;
    TestModuleLoading;
    Files.Clear;
    if FindFirst(BenchmarkDirectory + '*.js', faAnyFile, Search) = 0 then
    begin
      repeat
        Files.Add(BenchmarkDirectory + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Files.Sort;
    for Index := 0 to Files.Count - 1 do
      RunBenchmark(Files[Index]);
  finally
    Files.Free;
  end;
  WriteLn(Format('JavaScript: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    Halt(1);
end.
