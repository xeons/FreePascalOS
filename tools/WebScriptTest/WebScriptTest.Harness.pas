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
  The test bed: a script context over a document, with a test
  environment (timers fired by runTimers(), external scripts served from
  a table, navigation recorded) and the natives the test scripts use:

    check(name, condition)   one check
    gc()                     the engine's collection, then the DOM's
    liveNodes()              how many node objects exist
    wrapperCount()           how many node wrappers exist
    consoleText()            what went to the console so far
    clearConsole()
    runTimers()              fires the due timers in order, returns how
                             many ran
    lastNavigation()         the URL the last navigation asked for

  A script file may define after(): it is called once the script, its
  microtasks and the timers it left (each a task of its own) have run.
}
unit WebScriptTest.Harness;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Objects,
  Js.Functions,
  Js.Engine,
  Web.Dom,
  Web.Html.Parser,
  Web.ScriptEnvironment,
  Web.Script.Context;

type
  TTestTimer = record
    Id: Integer;
    Due: Int64;
    Interval: Integer;
    Repeating: Boolean;
    Active: Boolean;
  end;

  TTestEnvironment = class(TScriptEnvironment)
  public
    Timers: array of TTestTimer;
    Clock: Int64;
    Scripts: TStringList;
    Navigations: TStringList;
    constructor Create;
    destructor Destroy; override;
    function SupportsTimers: Boolean; override;
    procedure StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean); override;
    procedure StopTimer(Context: TObject; TimerId: Integer); override;
    procedure FetchClassicScript(Context: TObject; Element: TElement; const Url, Charset: string;
      Mode: TScriptFetchMode); override;
    procedure Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    function ViewportWidth: Integer; override;
    function ViewportHeight: Integer; override;
    { Fires the earliest due timer; False when none is left. }
    function RunNextTimer(Context: TScriptContext): Boolean;
  end;

  TTestBed = class
  private
    FConsole: TStringList;
    procedure ConsoleMessage(const Level, Text: string);
  public
    Document: TDocument;
    Environment: TTestEnvironment;
    Context: TScriptContext;
    Name: string;
    constructor Create(const AName: string; const Html: string = ''; const Url: string = 'https://example.test/dir/page.html');
    destructor Destroy; override;
    { Runs Source as a classic script, then after() if it was defined. }
    procedure Run(const Source: string);
    function ConsoleText: string;
    function Evaluate(const Source: string): string;
  end;

const
  DefaultHtml = '<!DOCTYPE html><html><head><title>test</title></head><body></body></html>';

var
  { The bed the natives report to. }
  CurrentBed: TTestBed;

function ReadTextFile(const Path: string): string;

implementation

uses
  TestChecks,
  Web.Bindings.Strings;

function ReadTextFile(const Path: string): string;
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

{ TTestEnvironment }

constructor TTestEnvironment.Create;
begin
  inherited Create;
  Scripts := TStringList.Create;
  Navigations := TStringList.Create;
end;

destructor TTestEnvironment.Destroy;
begin
  Scripts.Free;
  Navigations.Free;
  inherited Destroy;
end;

function TTestEnvironment.SupportsTimers: Boolean;
begin
  Result := True;
end;

procedure TTestEnvironment.StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean);
var
  Timer: TTestTimer;
begin
  Timer.Id := TimerId;
  Timer.Due := Clock + Milliseconds;
  Timer.Interval := Milliseconds;
  Timer.Repeating := Repeating;
  Timer.Active := True;
  SetLength(Timers, Length(Timers) + 1);
  Timers[High(Timers)] := Timer;
end;

procedure TTestEnvironment.StopTimer(Context: TObject; TimerId: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(Timers) do
    if Timers[Index].Id = TimerId then
      Timers[Index].Active := False;
end;

function TTestEnvironment.RunNextTimer(Context: TScriptContext): Boolean;
var
  Index, Best: Integer;
begin
  Best := -1;
  for Index := 0 to High(Timers) do
    if Timers[Index].Active and ((Best < 0) or (Timers[Index].Due < Timers[Best].Due)) then
      Best := Index;
  if Best < 0 then
    Exit(False);
  Clock := Timers[Best].Due;
  if Timers[Best].Repeating then
    Timers[Best].Due := Clock + Timers[Best].Interval + 1
  else
    Timers[Best].Active := False;
  Context.FireTimer(Timers[Best].Id);
  Result := True;
end;

procedure TTestEnvironment.FetchClassicScript(Context: TObject; Element: TElement; const Url, Charset: string;
  Mode: TScriptFetchMode);
var
  Index: Integer;
begin
  Index := Scripts.IndexOfName(Url);
  if Index < 0 then
  begin
    TScriptContext(Context).ScriptFetchFailed(Element);
    Exit;
  end;
  { Served at once (a parser-blocking one before the parser resumes). }
  TScriptContext(Context).ExecuteClassicScript(Scripts.ValueFromIndex[Index], Url, Element);
end;

procedure TTestEnvironment.Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  Navigations.Add(Url);
end;

procedure TTestEnvironment.HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  Navigations.Add('history ' + Url);
end;

function TTestEnvironment.ViewportWidth: Integer;
begin
  Result := 800;
end;

function TTestEnvironment.ViewportHeight: Integer;
begin
  Result := 600;
end;

{ The natives }

function TextArgument(R: TJsRealm; Args: PJsValueArray; ArgCount, Index: Integer): string;
begin
  if Index >= ArgCount then
    Exit('');
  Result := CurrentBed.Context.Engine.ToText(Args^[Index]);
end;

function NativeCheck(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Passed: Boolean;
begin
  Passed := (ArgCount >= 2) and (Args^[1] = JsTrue);
  Check(Passed, CurrentBed.Name + ': ' + TextArgument(R, Args, ArgCount, 0));
  Result := JsUndefined;
end;

function NativeGc(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  CurrentBed.Context.Engine.CollectGarbage;
  Web.Dom.CollectGarbage;
  Result := JsUndefined;
end;

function NativeLiveNodes(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsNumber(LiveNodeCount);
end;

function NativeWrapperCount(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsInteger(CurrentBed.Context.NodeWrapperCount);
end;

function NativeConsoleText(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := CurrentBed.Context.TextValue(CurrentBed.ConsoleText);
end;

function NativeClearConsole(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  CurrentBed.FConsole.Clear;
  Result := JsUndefined;
end;

function NativeRunTimers(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Count, Limit: Integer;
begin
  Count := 0;
  Limit := 1000;
  if ArgCount > 0 then
    Limit := Trunc(CurrentBed.Context.Engine.ToNumber(Args^[0]));
  while (Count < Limit) and CurrentBed.Environment.RunNextTimer(CurrentBed.Context) do
    Inc(Count);
  Result := JsInteger(Count);
end;

function NativeLastNavigation(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Navigations: TStringList;
begin
  Navigations := CurrentBed.Environment.Navigations;
  if Navigations.Count = 0 then
    Exit(JsNull);
  Result := CurrentBed.Context.TextValue(Navigations[Navigations.Count - 1]);
end;

{ TTestBed }

constructor TTestBed.Create(const AName: string; const Html: string; const Url: string);
var
  Engine: TJsEngine;
  Global: TJsObject;
begin
  inherited Create;
  Name := AName;
  FConsole := TStringList.Create;
  Environment := TTestEnvironment.Create;
  Document := TDocument.CreateDocument(True);
  Document.Url := Url;
  Context := TScriptContext.Create(Document, Environment);
  Context.OnConsoleMessage := @ConsoleMessage;
  CurrentBed := Self;
  Engine := Context.Engine;
  Global := Engine.GlobalObject;
  Engine.DefineFunction(Global, 'check', @NativeCheck, 2);
  Engine.DefineFunction(Global, 'gc', @NativeGc, 0);
  Engine.DefineFunction(Global, 'liveNodes', @NativeLiveNodes, 0);
  Engine.DefineFunction(Global, 'wrapperCount', @NativeWrapperCount, 0);
  Engine.DefineFunction(Global, 'consoleText', @NativeConsoleText, 0);
  Engine.DefineFunction(Global, 'clearConsole', @NativeClearConsole, 0);
  Engine.DefineFunction(Global, 'runTimers', @NativeRunTimers, 0);
  Engine.DefineFunction(Global, 'lastNavigation', @NativeLastNavigation, 0);
  if Html = '' then
    Context.ParseDocument(DefaultHtml)
  else
    Context.ParseDocument(Html);
end;

destructor TTestBed.Destroy;
begin
  Context.Free;
  Document.Release;
  Web.Dom.CollectGarbage;
  Environment.Free;
  FConsole.Free;
  if CurrentBed = Self then
    CurrentBed := nil;
  inherited Destroy;
end;

procedure TTestBed.ConsoleMessage(const Level, Text: string);
begin
  FConsole.Add(Level + ': ' + Text);
end;

function TTestBed.ConsoleText: string;
begin
  Result := FConsole.Text;
end;

procedure TTestBed.Run(const Source: string);
var
  After: TJsValue;
begin
  CurrentBed := Self;
  Context.ExecuteClassicScript(Source, Name, nil);
  { The event loop: the timers the script left, one task each. }
  while Environment.RunNextTimer(Context) do
    ;
  After := Context.Engine.GlobalObject.GetValue(Context.Engine.Realm, Context.Engine.Realm.Intern('after'));
  if JsIsCallable(After) then
  begin
    Context.CallFunction(After, JsUndefined, [], After, 'after');
    Context.PerformMicrotaskCheckpoint;
  end;
end;

function TTestBed.Evaluate(const Source: string): string;
var
  Value: TJsValue;
  ErrorText: string;
begin
  CurrentBed := Self;
  if Context.Engine.TryEvaluate(Source, Name, Value, ErrorText) then
    Result := Context.Engine.ToText(Value)
  else
    Result := 'error: ' + ErrorText;
end;

end.
