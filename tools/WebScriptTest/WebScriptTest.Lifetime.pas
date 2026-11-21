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
  Wrapper lifetime from the Pascal side: unreachable wrappers are
  collected and their nodes freed, expandos and listeners live as long
  as their node is in the document, detached cycles go in one
  collection, a document outlives its context safely; events made by
  native code reach script listeners; the environment serves external
  scripts. Reports the bytes per wrapper.
}
unit WebScriptTest.Lifetime;

{$mode objfpc}
{$H+}

interface

procedure RunLifetimeTests;

implementation

uses
  SysUtils,
  TestChecks,
  Js.Values,
  Js.Engine,
  Web.Atoms,
  Web.Dom,
  Web.Dom.Events,
  Web.Dom.UiEvents,
  Web.Bindings.Context,
  Web.Script.Context,
  Web.Navigation.Events,
  WebScriptTest.Harness;

procedure Collect(Bed: TTestBed);
begin
  Bed.Context.Engine.CollectGarbage;
  Web.Dom.CollectGarbage;
end;

procedure TestUnreachableWrappers;
var
  Bed: TTestBed;
  NodesBefore: Int64;
  WrappersBefore: Integer;
begin
  Bed := TTestBed.Create('lifetime');
  try
    Collect(Bed);
    NodesBefore := LiveNodeCount;
    WrappersBefore := Bed.Context.NodeWrapperCount;
    Bed.Run('var list = []; (function () { for (var i = 0; i < 1000; i++) { var d = document.createElement("div");' +
      ' d.expando = i; d.appendChild(document.createTextNode("x")); list.push(d); } })();');
    Check(LiveNodeCount >= NodesBefore + 2000, 'lifetime: detached nodes made from script exist');
    Check(Bed.Context.NodeWrapperCount >= WrappersBefore + 1000, 'lifetime: they have wrappers');
    Bed.Run('list = null;');
    Collect(Bed);
    Check(LiveNodeCount <= NodesBefore, 'lifetime: unreachable wrappers are collected and their nodes freed (' +
      IntToStr(LiveNodeCount) + ' nodes, ' + IntToStr(NodesBefore) + ' before)');
    Check(Bed.Context.NodeWrapperCount <= WrappersBefore, 'lifetime: the wrappers are gone');

    Bed.Run('var keep = document.createElement("p"); keep.id = "kept"; keep.note = "remembered";' +
      ' keep.addEventListener("ping", function (e) { window.pinged = (window.pinged || 0) + 1; });' +
      ' document.body.appendChild(keep); keep = null;');
    Collect(Bed);
    Collect(Bed);
    Check(Bed.Evaluate('document.getElementById("kept").note') = 'remembered',
      'lifetime: an expando lives while its node is in the document');
    Bed.Run('document.getElementById("kept").dispatchEvent(new Event("ping"));');
    Check(Bed.Evaluate('String(window.pinged)') = '1', 'lifetime: so does a listener');

    NodesBefore := LiveNodeCount;
    WrappersBefore := Bed.Context.NodeWrapperCount;
    Bed.Run('(function () { var a = document.createElement("div"), b = document.createElement("span");' +
      ' a.appendChild(b); a.other = b; b.other = a; b.addEventListener("click", function () { return a; });' +
      ' a.self = a; })();');
    Collect(Bed);
    Check(LiveNodeCount <= NodesBefore, 'lifetime: a detached cycle of wrappers, expandos and listeners is freed');
    Check(Bed.Context.NodeWrapperCount <= WrappersBefore, 'lifetime: its wrappers are collected');

    Bed.Run('var gone = document.getElementById("kept"); gone.remove(); gone = null;');
    Collect(Bed);
    Check(Bed.Evaluate('String(document.getElementById("kept"))') = 'null', 'lifetime: a removed node is not found');
    Check(LiveNodeCount < NodesBefore, 'lifetime: a removed node nothing refers to is freed');
  finally
    Bed.Free;
  end;
end;

procedure TestWrapperBytes;
var
  Bare: TJsEngine;
  Bed: TTestBed;
  Container: TElement;
  Index, Count: Integer;
  Before, After: Int64;
  Values: array of TJsValue;
begin
  Count := 10000;
  Bare := TJsEngine.Create;
  try
    Bare.CollectGarbage;
    WriteLn('perf ', Bare.HeapBytes, ' bytes of script heap for libjavascript''s realm alone');
  finally
    Bare.Free;
  end;
  Bed := TTestBed.Create('bytes');
  try
    Collect(Bed);
    WriteLn('perf ', Bed.Context.Engine.HeapBytes, ' bytes of script heap for a new window (interfaces are made when first used)');
    Container := Bed.Document.CreateElement('div');
    Bed.Document.Body.AppendChild(Container);
    for Index := 1 to Count do
      Container.AppendChild(Bed.Document.CreateElement('span'));
    Collect(Bed);
    Before := Bed.Context.Engine.HeapBytes;
    SetLength(Values, Count);
    Index := 0;
    while Index < Count do
    begin
      Values[Index] := Bed.Context.WrapNode(Container.ChildAt(Index));
      Inc(Index);
    end;
    After := Bed.Context.Engine.HeapBytes;
    WriteLn('perf ', (After - Before) div Count, ' bytes of heap per node wrapper (', TBindingWrapper.InstanceSize,
      ' byte instances)');
    Check((After - Before) div Count < 512, 'bytes: a wrapper costs less than 512 bytes');
    Collect(Bed);
    Check(Bed.Context.NodeWrapperCount >= Count, 'bytes: wrappers of connected nodes stay');
  finally
    Bed.Free;
  end;
end;

procedure TestNativeEvents;
var
  Bed: TTestBed;
  Target: TElement;
  Event: TMouseEvent;
begin
  Bed := TTestBed.Create('native events', '<!DOCTYPE html><body><button id=b>go</button></body>');
  try
    Bed.Run('var seen = []; var b = document.getElementById("b");' +
      ' b.addEventListener("click", function (e) { seen.push(e.type + ":" + e.clientX + ":" + e.isTrusted +' +
      ' ":" + (e.target === b) + ":" + (e instanceof MouseEvent)); });' +
      ' window.addEventListener("click", function (e) { seen.push("window"); });');
    Target := Bed.Document.GetElementById('b');
    Event := TMouseEvent.Create('click', True, True);
    try
      Event.ClientX := 12;
      Target.DispatchEvent(Event);
    finally
      Event.Release;
    end;
    Check(Bed.Evaluate('seen.join(",")') = 'click:12:false:true:true,window',
      'native events: a native MouseEvent reaches the listeners and bubbles to the window (' +
      Bed.Evaluate('seen.join(",")') + ')');
  finally
    Bed.Free;
  end;
end;

{ The engine's own events (readystatechange, those FireEvent makes:
  change, load ...) kept by a listener: the wrapper holds a reference,
  so the event outlives its dispatch and a collection (the browser
  crashed on DuckDuckGo when the collector read such an event freed). }
procedure TestKeptEvents;
var
  Bed: TTestBed;
begin
  Bed := TTestBed.Create('kept events', '<!DOCTYPE html><body><input id=i></body>');
  try
    Bed.Run('var kept = []; document.addEventListener("readystatechange", function (e) { kept.push(e); });' +
      ' document.getElementById("i").addEventListener("change", function (e) { kept.push(e); });');
    Bed.Document.ReadyState := ReadyStateInteractive;
    Bed.Document.ReadyState := ReadyStateComplete;
    FireEvent(Bed.Document.GetElementById('i'), 'change', True);
    Collect(Bed);
    Bed.Evaluate('for (var n = 0; n < 2000; n++) kept.push({ n: n, s: "x" + n }); kept.length = 3;');
    Collect(Bed);
    Check(Bed.Evaluate('kept.map(function (e) { return e.type + ":" + e.isTrusted; }).join(",")') =
      'readystatechange:true,readystatechange:true,change:true',
      'kept events: events the engine fired outlive their dispatch in a listener''s hands (' +
      Bed.Evaluate('kept.map(function (e) { return e.type + ":" + e.isTrusted; }).join(",")') + ')');
    { An event of a target that is not a node keeps the target's wrapper;
      freeing the heap whole (the bed going) frees them in any order. }
    Bed.Run('var target = new EventTarget(); target.addEventListener("ping", function (e) { window.pinged = e; });' +
      ' target.dispatchEvent(new Event("ping")); target = null;');
    Collect(Bed);
    Bed.Evaluate('for (var n = 0; n < 2000; n++) kept.push({ n: n }); kept.length = 3;');
    Collect(Bed);
    Check(Bed.Evaluate('(pinged.target instanceof EventTarget) + ":" + pinged.type') = 'true:ping',
      'kept events: an event keeps a target that is not a node');
  finally
    Bed.Free;
  end;
end;

procedure TestExternalScripts;
var
  Document: TDocument;
  Environment: TTestEnvironment;
  Context: TScriptContext;
  Value: TJsValue;
  ErrorText: string;
begin
  Document := TDocument.CreateDocument(True);
  Document.Url := 'https://example.test/dir/page.html';
  Environment := TTestEnvironment.Create;
  Environment.Scripts.Values['https://example.test/dir/a.js'] :=
    'document.write("<p id=fromA>a</p>"); var order = (window.order || "") + "a";';
  Environment.Scripts.Values['https://example.test/lib/b.js'] := 'var order = (window.order || "") + "b";';
  Context := TScriptContext.Create(Document, Environment);
  try
    Context.ParseDocument('<!DOCTYPE html><body><script src=a.js></script><script>order += "i";' +
      ' window.afterA = document.getElementById("fromA") !== null;</script>' +
      '<script src="../lib/b.js"></script><script src=missing.js onerror="window.failed = true"></script>' +
      '<script>order += "j"</script></body>');
    Check(Context.Engine.TryEvaluate('order', 'test', Value, ErrorText) and (Context.Engine.ToText(Value) = 'aibj'),
      'external scripts: parser-blocking scripts run in order with the inline ones');
    Check(Context.Engine.TryEvaluate('afterA', 'test', Value, ErrorText) and (Value = JsTrue),
      'external scripts: document.write from an external script inserts at the insertion point');
    Check(Context.Engine.TryEvaluate('window.failed', 'test', Value, ErrorText) and (Value = JsTrue),
      'external scripts: a script that cannot be fetched fires error');
    Context.Engine.Evaluate('var s = document.createElement("script"); s.src = "/lib/b.js";' +
      ' document.head.appendChild(s);');
    Check(Context.Engine.TryEvaluate('order', 'test', Value, ErrorText) and (Context.Engine.ToText(Value) = 'aibjb'),
      'external scripts: a script element inserted by script is fetched through the environment');
  finally
    Context.Free;
    Document.Release;
    Environment.Free;
    Web.Dom.CollectGarbage;
  end;
end;

procedure TestContextGoesFirst;
var
  Document: TDocument;
  Context: TScriptContext;
  Event: TEvent;
begin
  Document := TDocument.CreateDocument(True);
  Context := TScriptContext.Create(Document, nil);
  try
    Context.ParseDocument('<!DOCTYPE html><body><div id=d onclick="this.hit = 1">x</div></body>');
    Context.Engine.Evaluate('document.getElementById("d").addEventListener("click", function () {});');
  finally
    Context.Free;
  end;
  Event := TEvent.Create('click', True, True);
  try
    Document.GetElementById('d').DispatchEvent(Event);
  finally
    Event.Release;
  end;
  Check(Document.GetElementById('d') <> nil, 'context first: the document outlives its context, listeners inert');
  Document.Release;
  Web.Dom.CollectGarbage;
end;

procedure TestSpeed;
var
  Bed: TTestBed;
  Started: QWord;
begin
  Bed := TTestBed.Create('speed');
  try
    Started := GetTickCount64;
    Bed.Run('var root = document.createElement("div"); document.body.appendChild(root);' +
      ' for (var i = 0; i < 20000; i++) { var e = document.createElement("span"); e.className = "c" + (i % 10);' +
      ' e.textContent = "x"; root.appendChild(e); }');
    WriteLn('perf 20000 createElement, className, textContent and appendChild from script in ',
      GetTickCount64 - Started, ' ms');
    Started := GetTickCount64;
    Bed.Run('var n = 0; for (var i = 0; i < 200000; i++) { n += root.firstChild.nodeType; }');
    WriteLn('perf 200000 reads of node.firstChild.nodeType in ', GetTickCount64 - Started, ' ms');
    Started := GetTickCount64;
    Bed.Run('var found = 0; for (var i = 0; i < 100; i++) { found += document.querySelectorAll("span.c3").length; }');
    WriteLn('perf 100 querySelectorAll("span.c3") over 20000 elements in ', GetTickCount64 - Started, ' ms');
    Check(Bed.Evaluate('found') = '200000', 'speed: the queries found every match');
  finally
    Bed.Free;
  end;
end;

procedure RunLifetimeTests;
begin
  TestSpeed;
  TestUnreachableWrappers;
  TestWrapperBytes;
  TestNativeEvents;
  TestKeptEvents;
  TestExternalScripts;
  TestContextGoesFirst;
end;

end.
