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
  The host test262 expects (INTERPRETING.md, "Host-Defined Functions"):
  print, which the runner reads the asynchronous tests' results from,
  and the $262 object: createRealm (another realm sharing the runtime),
  evalScript, detachArrayBuffer, gc, global and IsHTMLDDA (a function
  with [[IsHTMLDDA]] that returns null, as document.all does for no
  argument). $262.agent is left out: the engine has no shared-memory
  agents (the runner skips the tests that use it).

  Modules are files: a module's key is its path (the engine resolves
  "./x_FIXTURE.js" against the importing file's directory).

  One host per test; it lives in the process running that test.
}
unit Test262.Host;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Objects,
  Js.Functions,
  Js.Engine;

type
  TTestHost = class
  private
    FMainEngine: TJsEngine;
    FRealms: array of TJsEngine;
    FPrinted: TStringList;
    FOptions: TJsEngineOptions;
    procedure Install(Engine: TJsEngine);
    procedure FetchModule(Request: TJsModuleFetch);
  public
    constructor Create(const Options: TJsEngineOptions);
    destructor Destroy; override;
    { The engine whose realm a function was made in. }
    function EngineOf(R: TJsRealm): TJsEngine;
    function CreateRealm: TJsEngine;
    procedure AddPrinted(const Text: string);
    property MainEngine: TJsEngine read FMainEngine;
    { What print was given, one entry per call. }
    property Printed: TStringList read FPrinted;
  end;

{ Reads a whole file as bytes (UTF-8 text). }
function ReadFileText(const Path: string): string;

implementation

uses
  Js.Strings,
  Js.Conversions,
  Js.Operations,
  Js.Compiler,
  Js.Lexer,
  Js.Interpreter,
  Js.ArrayBuffers;

var
  { The host of the test running in this process. }
  ActiveHost: TTestHost = nil;

function ReadFileText(const Path: string): string;
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

{ print(value) }
function HostPrint(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
begin
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  ActiveHost.AddPrinted(StringToUtf8(R.Heap, Text));
  Result := JsUndefined;
end;

{ $262.createRealm() }
function HostCreateRealm(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Engine: TJsEngine;
begin
  Engine := ActiveHost.CreateRealm;
  Result := Engine.GetProperty(JsObjectValue(Engine.GlobalObject), '$262');
end;

{ $262.evalScript(source): ParseScript and ScriptEvaluation in the
  realm the function belongs to. }
function HostEvalScript(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Source: TJsString;
  Code: TJsCode;
begin
  Source := ToJsString(R, Arg(Args, ArgCount, 0));
  if Source = nil then
    Exit(JsException);
  try
    Code := CompileScript(R, StringToUnicode(R.Heap, Source), 'evalScript');
  except
    on Error: EJsSyntaxError do
      Exit(R.ThrowError(ekSyntax, Error.Message));
  end;
  Result := TJsInterpreterRealm(R).RunScript(Code);
end;

{ $262.detachArrayBuffer(buffer) }
function HostDetachArrayBuffer(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value: TJsValue;
begin
  Value := Arg(Args, ArgCount, 0);
  if not JsIsObject(Value) or not (JsAsObject(Value) is TJsArrayBuffer) or
    TJsArrayBuffer(JsAsObject(Value)).Shared then
    Exit(R.ThrowTypeError('detachArrayBuffer needs an ArrayBuffer'));
  TJsArrayBuffer(JsAsObject(Value)).Detach;
  Result := JsNull;
end;

{ $262.gc() }
function HostCollectGarbage(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  R.Heap.Collect;
  Result := JsUndefined;
end;

{ $262.IsHTMLDDA(): null for no argument or "" (its other calls are not
  tested). }
function HostHtmlDda(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsNull;
end;

{ TTestHost }

constructor TTestHost.Create(const Options: TJsEngineOptions);
begin
  inherited Create;
  ActiveHost := Self;
  FOptions := Options;
  FPrinted := TStringList.Create;
  FMainEngine := TJsEngine.Create(Options);
  Install(FMainEngine);
end;

destructor TTestHost.Destroy;
var
  Index: Integer;
begin
  for Index := High(FRealms) downto 0 do
    FRealms[Index].Free;
  FMainEngine.Free;
  FPrinted.Free;
  if ActiveHost = Self then
    ActiveHost := nil;
  inherited Destroy;
end;

procedure TTestHost.Install(Engine: TJsEngine);
var
  Host: TJsObject;
  HtmlDda: TJsNativeFunction;
begin
  Engine.ModuleFetcher := @FetchModule;
  Engine.DefineFunction(Engine.GlobalObject, 'print', @HostPrint, 1);
  Host := Engine.NewObject;
  Engine.DefineFunction(Host, 'createRealm', @HostCreateRealm, 0);
  Engine.DefineFunction(Host, 'evalScript', @HostEvalScript, 1);
  Engine.DefineFunction(Host, 'detachArrayBuffer', @HostDetachArrayBuffer, 1);
  Engine.DefineFunction(Host, 'gc', @HostCollectGarbage, 0);
  HtmlDda := Engine.DefineFunction(Host, 'IsHTMLDDA', @HostHtmlDda, 0);
  HtmlDda.ObjectFlags := HtmlDda.ObjectFlags or ObjectHtmlDda;
  Engine.DefineValue(Host, 'global', JsObjectValue(Engine.GlobalObject));
  Engine.DefineValue(Engine.GlobalObject, '$262', JsObjectValue(Host));
end;

procedure TTestHost.FetchModule(Request: TJsModuleFetch);
begin
  if not FileExists(Request.Key) then
    Request.Fail('Cannot find module ''' + ExtractFileName(Request.Key) + '''')
  else
    Request.Succeed(ReadFileText(Request.Key));
end;

function TTestHost.EngineOf(R: TJsRealm): TJsEngine;
var
  Index: Integer;
begin
  for Index := 0 to High(FRealms) do
    if FRealms[Index].Realm = R then
      Exit(FRealms[Index]);
  Result := FMainEngine;
end;

function TTestHost.CreateRealm: TJsEngine;
begin
  Result := TJsEngine.CreateSharing(FMainEngine, FOptions);
  SetLength(FRealms, Length(FRealms) + 1);
  FRealms[High(FRealms)] := Result;
  Install(Result);
end;

procedure TTestHost.AddPrinted(const Text: string);
begin
  FPrinted.Add(Text);
end;

end.
