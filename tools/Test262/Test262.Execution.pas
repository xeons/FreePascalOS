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
  Runs one test262 test as INTERPRETING.md says: in a fresh realm per
  variant (non-strict and strict, or the one its flags allow; a module
  once), the harness evaluated first (assert.js, sta.js,
  doneprintHandle.js for asynchronous tests, then the includes), then
  the test, then the job queue. A test passes when no exception escapes
  (an asynchronous one when it printed Test262:AsyncTestComplete), or,
  when negative, when the error expected is thrown at the phase
  expected: parse (the script or module does not compile), resolution
  (the module graph fails before the test module runs) or runtime.
}
unit Test262.Execution;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Test262.Frontmatter,
  Test262.Harness;

type
  TTestCase = record
    { Relative to test262's test/ directory, with "/". }
    RelativePath: string;
    FullPath: string;
    Source: string;
    Metadata: TTestMetadata;
  end;

  TTestOutcome = record
    Passed: Boolean;
    { The first failing variant and the first line of its error. }
    Message: string;
  end;

{ Runs every variant of Test; stops at the first that fails. The
  engine's heap may take HeapLimit bytes (it throws "Out of memory"
  beyond them). }
function ExecuteTest(const Test: TTestCase; Harness: THarnessLibrary; HeapLimit: Int64): TTestOutcome;

implementation

uses
  Classes,
  Js.Values,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Strings,
  Js.Conversions,
  Js.Operations,
  Js.Lexer,
  Js.Compiler,
  Js.Interpreter,
  Js.ModuleRecords,
  Js.Modules,
  Js.Promises,
  Js.Engine,
  Test262.Host;

const
  AsyncComplete = 'Test262:AsyncTestComplete';
  AsyncFailure = 'Test262:AsyncTestFailure:';
  StrictPrologue = '"use strict";'#10;

type
  TVariant = (vNonStrict, vStrict, vModule);

  { Where (if anywhere) running some code threw, and what. }
  TCodeOutcome = record
    Phase: TNegativePhase;
    ErrorType: string;
    ErrorText: string;
  end;

const
  VariantNames: array[TVariant] of string = ('non-strict', 'strict', 'module');

function FirstLine(const Text: string): string;
var
  BreakAt: Integer;
begin
  Result := Text;
  BreakAt := Pos(#10, Result);
  if BreakAt > 0 then
    Result := Copy(Result, 1, BreakAt - 1);
  Result := TrimRight(Result);
end;

{ The constructor name and the text of a thrown value. }
procedure DescribeThrown(Engine: TJsEngine; Value: TJsValue; out TypeName, Text: string);
var
  R: TJsInterpreterRealm;
  Constructor_, Name: TJsValue;
  Converted: TJsString;
begin
  R := Engine.Realm;
  TypeName := '';
  if JsIsObject(Value) then
  begin
    Constructor_ := GetProperty(R, Value, R.Intern('constructor'));
    if Constructor_ = JsException then
      R.Runtime.TakeException
    else if JsIsObject(Constructor_) then
    begin
      Name := GetProperty(R, Constructor_, R.Intern('name'));
      if Name = JsException then
        R.Runtime.TakeException
      else if JsIsString(Name) then
        TypeName := StringToUtf8(R.Heap, JsAsString(Name));
    end;
  end;
  if JsIsSymbol(Value) then
    Converted := nil
  else
    Converted := ToJsString(R, Value);
  if Converted <> nil then
    Text := StringToUtf8(R.Heap, Converted)
  else
  begin
    if R.Runtime.HasException then
      R.Runtime.TakeException;
    Text := Engine.Inspect(Value);
  end;
  R.Runtime.Terminating := False;
end;

procedure NoteThrown(Engine: TJsEngine; Phase: TNegativePhase; Value: TJsValue; var Outcome: TCodeOutcome);
begin
  Outcome.Phase := Phase;
  DescribeThrown(Engine, Value, Outcome.ErrorType, Outcome.ErrorText);
end;

function RunScriptCode(Engine: TJsEngine; const Source, FileName: string): TCodeOutcome;
var
  Code: TJsCode;
  Completion: TJsValue;
begin
  Result := Default(TCodeOutcome);
  try
    Code := CompileScript(Engine.Realm, UTF8Decode(Source), FileName);
  except
    on Error: EJsSyntaxError do
    begin
      Result.Phase := npParse;
      Result.ErrorType := 'SyntaxError';
      Result.ErrorText := 'SyntaxError: ' + Error.Message + ' (line ' + IntToStr(Error.Line) + ')';
      Exit;
    end;
  end;
  Completion := Engine.Realm.RunScript(Code);
  if Completion = JsException then
    NoteThrown(Engine, npRuntime, Engine.Runtime.TakeException, Result);
end;

function RunModuleCode(Engine: TJsEngine; const Source, Key: string): TCodeOutcome;
var
  Loader: TJsModuleLoader;
  Evaluation: TJsValue;
  Promise: TJsPromise;
  Module: TJsModule;
  Handle: Integer;
begin
  Result := Default(TCodeOutcome);
  Loader := ModuleLoaderOf(Engine.Realm);
  Evaluation := Loader.EvaluateSource(Source, Key);
  if Evaluation = JsException then
  begin
    NoteThrown(Engine, npParse, Engine.Runtime.TakeException, Result);
    Exit;
  end;
  Handle := Engine.Protect(Evaluation);
  if not Engine.Realm.RunJobs then
    NoteThrown(Engine, npRuntime, Engine.Runtime.TakeException, Result)
  else
  begin
    Promise := TJsPromise(JsAsObject(Evaluation));
    if Promise.State = psRejected then
    begin
      Promise.IsHandled := True;
      Module := Loader.ModuleFor(Key);
      if (Module = nil) or (Module.Status in [msNew, msUnlinked, msLinking]) then
        NoteThrown(Engine, npResolution, Promise.Value, Result)
      else
        NoteThrown(Engine, npRuntime, Promise.Value, Result);
    end;
  end;
  Engine.Unprotect(Handle);
end;

{ Evaluates the harness files the test needs; '' or the failure. }
function LoadHarness(Engine: TJsEngine; const Test: TTestCase; Harness: THarnessLibrary): string;

  function LoadFile(const Name: string): string;
  var
    Source: string;
    Outcome: TCodeOutcome;
  begin
    Result := '';
    if not Harness.Find(Name, Source) then
      Exit('harness file ' + Name + ' is missing');
    Outcome := RunScriptCode(Engine, Source, Name);
    if Outcome.Phase <> npNone then
      Result := 'harness ' + Name + ': ' + FirstLine(Outcome.ErrorText);
  end;

var
  Index: Integer;
begin
  Result := LoadFile('assert.js');
  if Result = '' then
    Result := LoadFile('sta.js');
  if (Result = '') and (tfAsync in Test.Metadata.Flags) then
    Result := LoadFile('doneprintHandle.js');
  for Index := 0 to High(Test.Metadata.Includes) do
    if Result = '' then
      Result := LoadFile(Test.Metadata.Includes[Index]);
end;

const
  PhaseNames: array[TNegativePhase] of string = ('none', 'parse', 'resolution', 'runtime');

{ Whether the outcome is what the test expects; Message says why not. }
function Judge(const Test: TTestCase; const Outcome: TCodeOutcome; Host: TTestHost; out Message: string): Boolean;
var
  Index: Integer;
  Completed: Boolean;
  Line: string;
begin
  Message := '';
  if Test.Metadata.NegativePhase <> npNone then
  begin
    if Outcome.Phase = npNone then
      Message := 'expected ' + Test.Metadata.NegativeType + ' at ' + PhaseNames[Test.Metadata.NegativePhase] +
        ' but nothing was thrown'
    else if (Outcome.Phase <> Test.Metadata.NegativePhase) or (Outcome.ErrorType <> Test.Metadata.NegativeType) then
      Message := 'expected ' + Test.Metadata.NegativeType + ' at ' + PhaseNames[Test.Metadata.NegativePhase] +
        ', got ' + PhaseNames[Outcome.Phase] + ' ' + FirstLine(Outcome.ErrorText);
    Exit(Message = '');
  end;
  if Outcome.Phase <> npNone then
  begin
    Message := PhaseNames[Outcome.Phase] + ' ' + FirstLine(Outcome.ErrorText);
    Exit(False);
  end;
  if tfAsync in Test.Metadata.Flags then
  begin
    Completed := False;
    for Index := 0 to Host.Printed.Count - 1 do
    begin
      Line := Host.Printed[Index];
      if Pos(AsyncFailure, Line) = 1 then
      begin
        Message := 'async ' + FirstLine(Copy(Line, Length(AsyncFailure) + 1, Length(Line)));
        Exit(False);
      end;
      if Line = AsyncComplete then
        Completed := True;
    end;
    if not Completed then
    begin
      Message := 'async test did not complete';
      Exit(False);
    end;
  end;
  Result := True;
end;

function RunVariant(const Test: TTestCase; Variant: TVariant; Harness: THarnessLibrary; HeapLimit: Int64;
  out Message: string): Boolean;
var
  Options: TJsEngineOptions;
  Host: TTestHost;
  Engine: TJsEngine;
  Outcome: TCodeOutcome;
begin
  Options := TJsEngine.DefaultOptions;
  Options.MemoryLimit := HeapLimit;
  Host := TTestHost.Create(Options);
  Engine := Host.MainEngine;
  if not (tfRaw in Test.Metadata.Flags) then
  begin
    Message := LoadHarness(Engine, Test, Harness);
    if Message <> '' then
      Exit(False);
  end;
  case Variant of
    vNonStrict:
      Outcome := RunScriptCode(Engine, Test.Source, Test.FullPath);
    vStrict:
      Outcome := RunScriptCode(Engine, StrictPrologue + Test.Source, Test.FullPath);
    vModule:
      Outcome := RunModuleCode(Engine, Test.Source, Test.FullPath);
  end;
  if (Outcome.Phase = npNone) and not Engine.Realm.RunJobs then
    NoteThrown(Engine, npRuntime, Engine.Runtime.TakeException, Outcome);
  Result := Judge(Test, Outcome, Host, Message);
  { The process ends after the test: the host and its engines go with it
    (freeing them would only time the destructors). }
end;

function ExecuteTest(const Test: TTestCase; Harness: THarnessLibrary; HeapLimit: Int64): TTestOutcome;
var
  Variants: array of TVariant;
  Variant: TVariant;
  Message: string;
  Index: Integer;
begin
  Variants := nil;
  if tfModule in Test.Metadata.Flags then
    Variants := [vModule]
  else if tfOnlyStrict in Test.Metadata.Flags then
    Variants := [vStrict]
  else if tfNoStrict in Test.Metadata.Flags then
    Variants := [vNonStrict]
  else
    Variants := [vNonStrict, vStrict];
  Result.Passed := True;
  Result.Message := '';
  for Index := 0 to High(Variants) do
  begin
    Variant := Variants[Index];
    if not RunVariant(Test, Variant, Harness, HeapLimit, Message) then
    begin
      Result.Passed := False;
      Result.Message := '[' + VariantNames[Variant] + '] ' + Message;
      Exit;
    end;
  end;
end;

end.
