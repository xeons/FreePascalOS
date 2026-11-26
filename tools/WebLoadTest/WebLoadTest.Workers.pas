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
  Shared workers, BroadcastChannel, the Cache API and service workers
  through real loaders and the in-process site, several pages sharing
  one process as a content process's do:

  - a shared worker is one per URL and name for every page (connect
    events counted, a MessagePort sent to it and answered through, a
    blob: URL's script, error for a script that is not there) and goes
    with the last page;
  - a BroadcastChannel reaches another page of the origin, not one of
    another origin;
  - caches: put, match with Vary, ignoreSearch and ignoreMethod, keys,
    delete, addAll from the site, CacheStorage's match by cacheName,
    has, delete, and the caches kept through an origin data store;
  - service workers: register, install and activate with waitUntil,
    clients.claim and controllerchange, fetch events answered with a
    made response, a cached one, the network after all and a network
    error, messages both ways (a MessageChannel port to the worker),
    clients.matchAll, a navigation in the scope answered by the worker
    and controlled from its first script, an update check that finds
    the same script and one that finds a new one (updatefound, waiting,
    skipWaiting, activated), the max scope and Service-Worker-Allowed,
    a script of the wrong type, unregister, no service workers or
    caches on an insecure page, and a registration kept through the
    origin data store controlling a page after everything was
    forgotten (the worker started again from its stored script).
}
unit WebLoadTest.Workers;

{$mode objfpc}
{$H+}

interface

procedure RunWorkerTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Script.PageScripting,
  Web.Script.Context,
  Web.Storage.OriginData,
  Web.Storage.ResponseCaches,
  Web.Workers.Agents,
  Web.Workers.SharedWorkers,
  Web.Workers.ServiceWorkers,
  WebLoadTest.Server;

type
  { A page: a navigable with scripting on the environment's fetcher. }
  TWorkerPage = class
  public
    Navigable: TNavigable;
    Executor: TPageScriptExecutor;
    Console: string;
    constructor Create(Environment: TTestEnvironment; Sink: TResourceSink);
    destructor Destroy; override;
    procedure ConsoleMessage(const Level, Text: string);
    function Output: string;
    function Has(const Marker: string): Boolean;
  end;

  TWorkerConditions = class
  public
    Pages: array of TWorkerPage;
    Marker: string;
    function AllHaveMarker: Boolean;
    function FirstHasMarker: Boolean;
  end;

constructor TWorkerPage.Create(Environment: TTestEnvironment; Sink: TResourceSink);
begin
  inherited Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @ConsoleMessage;
  Navigable.Executor := Executor;
end;

destructor TWorkerPage.Destroy;
begin
  Navigable.Free;
  Executor.Free;
  inherited Destroy;
end;

procedure TWorkerPage.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

function TWorkerPage.Output: string;
var
  Element: TElement;
begin
  Result := '';
  if Navigable.ActiveDocument = nil then
    Exit;
  Element := Navigable.ActiveDocument.GetElementById('out');
  if Element <> nil then
    Result := Element.TextContent;
end;

function TWorkerPage.Has(const Marker: string): Boolean;
begin
  Result := Pos(Marker, Output) > 0;
end;

function TWorkerConditions.AllHaveMarker: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Pages) do
    if not Pages[Index].Has(Marker) then
      Exit(False);
  Result := True;
end;

function TWorkerConditions.FirstHasMarker: Boolean;
begin
  Result := Pages[0].Has(Marker);
end;

const
  { Every page logs to #out through this. }
  LogScript = '<p id="out"></p><script>const lines = []; function log(text) { lines.push(text); ' +
    'document.getElementById("out").textContent = lines.join("|"); }</script>';
  JavaScriptType = 'Content-Type: text/javascript';
  HtmlType = 'Content-Type: text/html';

var
  AgentConsoleText: string;

type
  TAgentConsoleSink = class
  public
    procedure Message(Agent: TWorkerAgent; const Level, Text: string);
  end;

procedure TAgentConsoleSink.Message(Agent: TWorkerAgent; const Level, Text: string);
begin
  AgentConsoleText := AgentConsoleText + Level + ': ' + Text + LineEnding;
end;

{ ---- shared workers ---- }

procedure CheckSharedWorkers;
var
  Finished: Boolean;
  Environment: TTestEnvironment;
  Sink: TNullResourceSink;
  First, Second, Missing: TWorkerPage;
  Conditions: TWorkerConditions;
begin
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Conditions := TWorkerConditions.Create;
  try
    Environment.Site.AddRoute('s.test/shared.js', 200, JavaScriptType,
      'let count = 0; onconnect = function (event) { count++; const port = event.ports[0]; ' +
      'port.onmessage = function (e) { if (e.data && e.data.reply) { e.data.reply.postMessage("via port " + count); ' +
      'return; } port.postMessage(e.data + ":" + count + ":" + self.name + ":" + (event.source === port)); }; };');
    Environment.Site.AddRoute('s.test/first.html', 200, HtmlType, LogScript +
      '<script>const worker = new SharedWorker("shared.js", "n"); worker.port.onmessage = function (e) { log(e.data); ' +
      'const channel = new MessageChannel(); channel.port1.onmessage = function (m) { log(m.data); ' +
      'const blobWorker = new SharedWorker(URL.createObjectURL(new Blob(["onconnect = e => ' +
      'e.ports[0].postMessage(typeof self.close)"], { type: "text/javascript" }))); ' +
      'blobWorker.port.onmessage = function (b) { log("blob " + b.data); log("done"); }; }; ' +
      'worker.port.postMessage({ reply: channel.port2 }, [channel.port2]); }; worker.port.postMessage("first");</script>');
    Environment.Site.AddRoute('s.test/second.html', 200, HtmlType, LogScript +
      '<script>const worker = new SharedWorker("shared.js", { name: "n" }); worker.port.onmessage = function (e) { ' +
      'log(e.data); log("done"); }; worker.port.postMessage("second");</script>');
    Environment.Site.AddRoute('s.test/missing.html', 200, HtmlType, LogScript +
      '<script>const worker = new SharedWorker("nothing.js"); worker.onerror = function () { log("error"); ' +
      'log("done"); };</script>');
    First := TWorkerPage.Create(Environment, Sink);
    Second := TWorkerPage.Create(Environment, Sink);
    Missing := TWorkerPage.Create(Environment, Sink);
    try
      SetLength(Conditions.Pages, 1);
      Conditions.Pages[0] := First;
      Conditions.Marker := 'done';
      First.Navigable.NavigateTo('https://s.test/first.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished, 'shared workers: the first page connects');
      Conditions.Pages[0] := Second;
      Second.Navigable.NavigateTo('https://s.test/second.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished, 'shared workers: the second page connects');
      Check(Pos('first:1:n:true', First.Output) > 0, 'shared workers: connect, name and source (' + First.Output + ')');
      Check(Pos('via port 1', First.Output) > 0, 'shared workers: a MessagePort sent to the worker answers');
      Check(Pos('blob function', First.Output) > 0, 'shared workers: a blob: URL''s script');
      Check(Pos('second:2:n:true', Second.Output) > 0,
        'shared workers: the second page reaches the same worker (' + Second.Output + ')');
      Check(SharedWorkerCount = 2, 'shared workers: one per URL and name (' + IntToStr(SharedWorkerCount) + ')');
      Conditions.Pages[0] := Missing;
      Missing.Navigable.NavigateTo('https://s.test/missing.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished and Missing.Has('error'),
        'shared workers: error for a script that is not there');
    finally
      First.Free;
      Second.Free;
      Missing.Free;
    end;
    Environment.RunFor(50);
    Check(SharedWorkerCount = 0, 'shared workers: they go with the last page (' + IntToStr(SharedWorkerCount) + ')');
    Check(LiveAgentCount = 0, 'shared workers: no agent is left (' + IntToStr(LiveAgentCount) + ')');
  finally
    Conditions.Free;
    Sink.Free;
    Environment.Free;
  end;
end;

{ ---- BroadcastChannel ---- }

procedure CheckBroadcastChannels;
var
  Finished: Boolean;
  Environment: TTestEnvironment;
  Sink: TNullResourceSink;
  Sender, Receiver, Stranger: TWorkerPage;
  Conditions: TWorkerConditions;
const
  Listener = LogScript + '<script>const channel = new BroadcastChannel("news"); channel.onmessage = function (e) { ' +
    'log(e.data.text + ":" + e.data.list.length + ":" + (e.data.when instanceof Date) + ":" + e.origin); }; ' +
    'log("listening");</script>';
begin
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Conditions := TWorkerConditions.Create;
  try
    Environment.Site.AddRoute('s.test/listen.html', 200, HtmlType, Listener);
    Environment.Site.AddRoute('other.test/listen.html', 200, HtmlType, Listener);
    Environment.Site.AddRoute('s.test/send.html', 200, HtmlType, LogScript +
      '<script>const channel = new BroadcastChannel("news"); channel.onmessage = function () { log("echo"); }; ' +
      'channel.postMessage({ text: "hello", list: [1, 2, 3], when: new Date(0) }); log("sent");</script>');
    Receiver := TWorkerPage.Create(Environment, Sink);
    Stranger := TWorkerPage.Create(Environment, Sink);
    Sender := TWorkerPage.Create(Environment, Sink);
    try
      SetLength(Conditions.Pages, 2);
      Conditions.Pages[0] := Receiver;
      Conditions.Pages[1] := Stranger;
      Conditions.Marker := 'listening';
      Receiver.Navigable.NavigateTo('https://s.test/listen.html');
      Stranger.Navigable.NavigateTo('https://other.test/listen.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished, 'broadcast: the listeners load');
      SetLength(Conditions.Pages, 1);
      Conditions.Pages[0] := Receiver;
      Conditions.Marker := 'hello';
      Sender.Navigable.NavigateTo('https://s.test/send.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished, 'broadcast: another page of the origin hears it');
      Environment.RunFor(50);
      Check(Pos('hello:3:true:https://s.test', Receiver.Output) > 0,
        'broadcast: the data and the origin (' + Receiver.Output + ')');
      Check(Pos('hello', Stranger.Output) = 0, 'broadcast: a page of another origin does not');
      Check(Pos('echo', Sender.Output) = 0, 'broadcast: the sender does not hear itself');
    finally
      Sender.Free;
      Receiver.Free;
      Stranger.Free;
    end;
  finally
    Conditions.Free;
    Sink.Free;
    Environment.Free;
  end;
end;

{ ---- caches ---- }

procedure CheckCaches;
var
  Finished: Boolean;
  Environment: TTestEnvironment;
  Sink: TNullResourceSink;
  Page, Later: TWorkerPage;
  Conditions: TWorkerConditions;
  Store: TMemoryOriginData;
begin
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Conditions := TWorkerConditions.Create;
  Store := TMemoryOriginData.Create;
  OriginDataBackend := Store;
  try
    Environment.Site.AddRoute('s.test/one.txt', 200, 'Content-Type: text/plain', 'one');
    Environment.Site.AddRoute('s.test/two.txt', 200, 'Content-Type: text/plain', 'two');
    Environment.Site.AddRoute('s.test/caches.html', 200, HtmlType, LogScript + '<script>(async function () { ' +
      'try { const cache = await caches.open("c1"); ' +
      'await cache.put("/a?x=1", new Response("A", { headers: { "Vary": "X-Lang" } })); ' +
      'await cache.put(new Request("/b", { headers: { "X-Lang": "en" } }), new Response("B-en", ' +
      '{ headers: { "Vary": "X-Lang" } })); ' +
      'log("plain " + await (await cache.match("/a?x=1")).text()); ' +
      'log("search " + ((await cache.match("/a")) === undefined) + " " + ' +
      '(await (await cache.match("/a", { ignoreSearch: true })).text())); ' +
      'log("vary " + ((await cache.match(new Request("/b", { headers: { "X-Lang": "fr" } }))) === undefined) + " " + ' +
      '(await (await cache.match(new Request("/b", { headers: { "X-Lang": "en" } }))).text()) + " " + ' +
      '(await (await cache.match("/b", { ignoreVary: true })).text())); ' +
      'log("method " + ((await cache.match(new Request("/b", { method: "POST" }))) === undefined) + " " + ' +
      '((await cache.match(new Request("/a?x=1", { method: "POST" }), { ignoreMethod: true })) !== undefined)); ' +
      'await cache.addAll(["/one.txt", "/two.txt"]); ' +
      'log("keys " + (await cache.keys()).map(r => new URL(r.url).pathname).join(",")); ' +
      'log("deleted " + (await cache.delete("/two.txt")) + " " + (await cache.delete("/two.txt"))); ' +
      'const other = await caches.open("c2"); await other.put("/one.txt", new Response("other one")); ' +
      'log("by name " + (await (await caches.match("/one.txt", { cacheName: "c2" })).text()) + " " + ' +
      '(await (await caches.match("/one.txt")).text())); ' +
      'log("names " + (await caches.keys()).join(",") + " " + (await caches.has("c2"))); ' +
      'log("storage delete " + (await caches.delete("c2")) + " " + (await caches.has("c2"))); ' +
      'let refused = "none"; try { await cache.put("/p", new Response("x", { status: 206 })); } ' +
      'catch (e) { refused = e.name; } log("partial " + refused); ' +
      'try { await cache.add("/nothing.txt"); } catch (e) { log("add failed " + e.name); } ' +
      '} catch (e) { log("fail " + e); } log("done"); })();</script>');
    Environment.Site.AddRoute('s.test/later.html', 200, HtmlType, LogScript + '<script>(async function () { ' +
      'const found = await caches.match("/one.txt"); log("kept " + (found ? await found.text() : "nothing")); ' +
      'log("done"); })();</script>');
    Page := TWorkerPage.Create(Environment, Sink);
    try
      SetLength(Conditions.Pages, 1);
      Conditions.Pages[0] := Page;
      Conditions.Marker := 'done';
      Page.Navigable.NavigateTo('https://s.test/caches.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished, 'caches: the page finishes (' + Page.Output + ')');
      Check(Pos('plain A', Page.Output) > 0, 'caches: put and match');
      Check(Pos('search true A', Page.Output) > 0, 'caches: the query counts unless ignoreSearch');
      Check(Pos('vary true B-en B-en', Page.Output) > 0, 'caches: Vary and ignoreVary');
      Check(Pos('method true true', Page.Output) > 0, 'caches: only GET unless ignoreMethod');
      Check(Pos('keys /a,/b,/one.txt,/two.txt', Page.Output) > 0, 'caches: addAll and keys in order (' +
        Page.Output + ')');
      Check(Pos('deleted true false', Page.Output) > 0, 'caches: delete');
      Check(Pos('by name other one one', Page.Output) > 0, 'caches: CacheStorage.match by cacheName and in order');
      Check(Pos('names c1,c2 true', Page.Output) > 0, 'caches: keys and has');
      Check(Pos('storage delete true false', Page.Output) > 0, 'caches: CacheStorage.delete');
      Check(Pos('partial TypeError', Page.Output) > 0, 'caches: a partial response is refused');
      Check(Pos('add failed TypeError', Page.Output) > 0, 'caches: add of a failed request rejects');
      Check(Pos('|fail ', Page.Output) = 0, 'caches: no failure (' + Trim(Page.Console) + ')');
    finally
      Page.Free;
    end;
    { Everything in memory goes; the store still has the caches. }
    ForgetAllCaches;
    Later := TWorkerPage.Create(Environment, Sink);
    try
      Conditions.Pages[0] := Later;
      Later.Navigable.NavigateTo('https://s.test/later.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished and Later.Has('kept one'),
        'caches: kept through the origin data store (' + Later.Output + ')');
    finally
      Later.Free;
    end;
  finally
    ForgetAllCaches;
    OriginDataBackend := nil;
    Store.Free;
    Conditions.Free;
    Sink.Free;
    Environment.Free;
  end;
end;

{ ---- service workers ---- }

const
  WorkerScript =
    'const version = "v1"; ' +
    'self.addEventListener("install", function (event) { event.waitUntil(caches.open("sw").then(function (cache) { ' +
    'return cache.put("/cached.txt", new Response("from the cache")); })); }); ' +
    'self.addEventListener("activate", function (event) { event.waitUntil(self.clients.claim()); }); ' +
    'self.addEventListener("fetch", function (event) { const path = new URL(event.request.url).pathname; ' +
    'if (path === "/made.txt") event.respondWith(new Response("made " + version + " " + event.request.method)); ' +
    'else if (path === "/cached.txt") event.respondWith(caches.match(event.request)); ' +
    'else if (path === "/broken.txt") event.respondWith(Promise.reject(new Error("no"))); ' +
    'else if (path === "/virtual.html") event.respondWith(new Response("<!DOCTYPE html><p id=out>virtual " + ' +
    '"<script>document.getElementById(\"out\").textContent += (navigator.serviceWorker.controller ? ' +
    '\" controlled\" : \" free\") + \" done\";</script>", { headers: { "Content-Type": "text/html" } })); }); ' +
    'self.addEventListener("message", function (event) { if (event.data === "skip") { self.skipWaiting(); return; } ' +
    'if (event.data && event.data.port) { self.clients.matchAll().then(function (list) { ' +
    'event.data.port.postMessage("clients " + list.length + " " + list[0].type + " " + version); }); return; } ' +
    'event.source.postMessage("echo " + event.data + " " + (event.source.id.length > 0)); });';

procedure CheckServiceWorkers;
var
  Finished: Boolean;
  Environment: TTestEnvironment;
  Sink: TNullResourceSink;
  Page, Virtual, Network, Plain, Restored: TWorkerPage;
  Conditions: TWorkerConditions;
  Store: TMemoryOriginData;
  Route: TTestRoute;
  ConsoleSink: TAgentConsoleSink;
  PageContext: TScriptContext;
begin
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Conditions := TWorkerConditions.Create;
  Store := TMemoryOriginData.Create;
  ConsoleSink := TAgentConsoleSink.Create;
  AgentConsoleText := '';
  AgentConsole := @ConsoleSink.Message;
  OriginDataBackend := Store;
  try
    Route := Environment.Site.AddRoute('s.test/sw.js', 200, JavaScriptType, WorkerScript);
    Environment.Site.AddRoute('s.test/net.txt', 200, 'Content-Type: text/plain', 'from the network');
    Environment.Site.AddRoute('s.test/net.html', 200, HtmlType, '<p id="out">network</p><script>' +
      'document.getElementById("out").textContent += (navigator.serviceWorker.controller ? " controlled" : " free") + ' +
      '" done";</script>');
    Environment.Site.AddRoute('s.test/sub/narrow.js', 200, JavaScriptType, '');
    Environment.Site.AddRoute('s.test/sub/wide.js', 200, JavaScriptType + '|Service-Worker-Allowed: /', '');
    Environment.Site.AddRoute('s.test/text.js', 200, 'Content-Type: text/plain', '');
    Environment.Site.AddRoute('plain.test/page.html', 200, HtmlType, LogScript + '<script>log(String(' +
      '"serviceWorker" in navigator) + " " + ("caches" in window)); log("done");</script>');
    Environment.Site.AddRoute('s.test/page.html', 200, HtmlType, LogScript + '<script>(async function () { try { ' +
      'navigator.serviceWorker.oncontrollerchange = function () { log("controllerchange"); }; ' +
      'navigator.serviceWorker.onmessage = function (e) { log(e.data); }; ' +
      'const registration = await navigator.serviceWorker.register("sw.js"); ' +
      'log("registered " + registration.scope + " " + registration.installing.state); ' +
      'const worker = registration.installing; const states = []; ' +
      'worker.onstatechange = function () { states.push(worker.state); }; ' +
      'const ready = await navigator.serviceWorker.ready; log("ready " + (ready === registration)); ' +
      'while (!navigator.serviceWorker.controller || states.indexOf("activated") < 0) ' +
      'await new Promise(r => setTimeout(r, 10)); ' +
      'log("states " + states.join(",")); ' +
      'log("controller " + new URL(navigator.serviceWorker.controller.scriptURL).pathname); ' +
      'log(await (await fetch("/made.txt")).text()); ' +
      'log(await (await fetch("/cached.txt")).text()); ' +
      'log(await (await fetch("/net.txt")).text()); ' +
      'log(await fetch("/broken.txt").then(() => "broken answered", () => "broken rejected")); ' +
      'navigator.serviceWorker.controller.postMessage("hi"); ' +
      'const channel = new MessageChannel(); ' +
      'const viaPort = new Promise(r => { channel.port1.onmessage = e => r(e.data); }); ' +
      'navigator.serviceWorker.controller.postMessage({ port: channel.port2 }, [channel.port2]); ' +
      'log(await viaPort); ' +
      'log("same update " + ((await registration.update()) === registration) + " " + (registration.waiting === null)); ' +
      'log("mark update"); ' +
      'await new Promise(r => { window.continueTest = r; }); ' +
      'const found = new Promise(r => { registration.onupdatefound = r; }); ' +
      'registration.update(); await found; log("updatefound"); ' +
      'const next = registration.installing; ' +
      'await new Promise(r => { next.onstatechange = () => { if (next.state === "installed") r(); }; }); ' +
      'log("waiting " + (registration.waiting === next)); ' +
      'const changed = new Promise(r => { navigator.serviceWorker.oncontrollerchange = r; }); ' +
      'next.postMessage("skip"); await changed; ' +
      'log("skipped " + next.state + " " + (navigator.serviceWorker.controller === next)); ' +
      'log(await (await fetch("/made.txt")).text()); ' +
      'let error = "none"; try { await navigator.serviceWorker.register("sub/narrow.js", { scope: "/" }); } ' +
      'catch (e) { error = e.name; } log("narrow " + error); ' +
      'const wide = await navigator.serviceWorker.register("sub/wide.js", { scope: "/elsewhere/" }); ' +
      'log("wide " + new URL(wide.scope).pathname); ' +
      'error = "none"; try { await navigator.serviceWorker.register("text.js", { scope: "/t/" }); } ' +
      'catch (e) { error = e.name; } log("type " + error); ' +
      'log("unregister " + (await wide.unregister()) + " " + (await navigator.serviceWorker.getRegistrations()).length); ' +
      '} catch (e) { log("fail " + e); } log("done"); })();</script>');
    Page := TWorkerPage.Create(Environment, Sink);
    Virtual := TWorkerPage.Create(Environment, Sink);
    Network := TWorkerPage.Create(Environment, Sink);
    Plain := TWorkerPage.Create(Environment, Sink);
    try
      SetLength(Conditions.Pages, 1);
      Conditions.Pages[0] := Page;
      Conditions.Marker := 'mark update';
      Page.Navigable.NavigateTo('https://s.test/page.html');
      Check(Environment.RunUntil(@Conditions.AllHaveMarker, 10000),
        'service workers: registered and running (' + Page.Output + ')');
      Check(Pos('registered https://s.test/ installing', Page.Output) > 0, 'service workers: register');
      Check(Pos('ready true', Page.Output) > 0, 'service workers: ready');
      Check(Pos('states installed,activating,activated', Page.Output) > 0, 'service workers: install and activate');
      Check(Pos('controllerchange', Page.Output) > 0, 'service workers: clients.claim and controllerchange');
      Check(Pos('controller /sw.js', Page.Output) > 0, 'service workers: the controller');
      Check(Pos('made v1 GET', Page.Output) > 0, 'service workers: a made response');
      Check(Pos('from the cache', Page.Output) > 0, 'service workers: a response from the Cache API');
      Check(Pos('from the network', Page.Output) > 0, 'service workers: the network when not answered');
      Check(Pos('broken rejected', Page.Output) > 0, 'service workers: a rejected respondWith is a network error');
      Check(Pos('echo hi true', Page.Output) > 0, 'service workers: messages both ways with the client as source');
      Check(Pos('clients 1 window v1', Page.Output) > 0, 'service workers: a port to the worker, clients.matchAll');
      Check(Pos('same update true true', Page.Output) > 0, 'service workers: an update finding the same script');

      Conditions.Pages[0] := Virtual;
      Conditions.Marker := 'done';
      Virtual.Navigable.NavigateTo('https://s.test/virtual.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished and Virtual.Has('controlled done'),
        'service workers: a navigation answered by the worker, controlled from its first script (' +
        Virtual.Output + ')');
      Conditions.Pages[0] := Network;
      Network.Navigable.NavigateTo('https://s.test/net.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished and Network.Has('network controlled'),
        'service workers: a navigation the worker leaves to the network is controlled (' + Network.Output + ')');
      Conditions.Pages[0] := Plain;
      Plain.Navigable.NavigateTo('http://plain.test/page.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker);
      Check(Finished and Plain.Has('false false'),
        'service workers: none and no caches on an insecure page (' + Plain.Output + ')');

      { A new script for the update check. }
      Route.Body := StringReplace(WorkerScript, '"v1"', '"v2"', []);
      PageContext := Page.Executor.ContextOf(Page.Navigable.ActiveDocument);
      PageContext.Engine.Evaluate('window.continueTest()', 'test');
      PageContext.PerformMicrotaskCheckpoint;
      Conditions.Pages[0] := Page;
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker, 10000);
      Check(Finished, 'service workers: the rest runs (' +
        Page.Output + ')');
      Check(Pos('updatefound', Page.Output) > 0, 'service workers: an update finding a new script');
      Check(Pos('waiting true', Page.Output) > 0, 'service workers: the new worker waits while clients are controlled');
      Check(Pos('skipped activating true', Page.Output) > 0,
        'service workers: skipWaiting activates it (controllerchange while activating)');
      Check(Pos('made v2 GET', Page.Output) > 0, 'service workers: the new worker answers');
      Check(Pos('narrow SecurityError', Page.Output) > 0, 'service workers: a scope above the max scope');
      Check(Pos('wide /elsewhere/', Page.Output) > 0, 'service workers: Service-Worker-Allowed widens it');
      Check(Pos('type SecurityError', Page.Output) > 0, 'service workers: a script of the wrong type');
      Check(Pos('unregister true 1', Page.Output) > 0, 'service workers: unregister');
      Check(Pos('|fail ', Page.Output) = 0, 'service workers: no failure (' + Trim(Page.Console) + ')');
      Check(RunningWorkerCount >= 1, 'service workers: the worker runs while used');
    finally
      Page.Free;
      Virtual.Free;
      Network.Free;
      Plain.Free;
    end;
    { Everything in memory goes; the store still has the registration. }
    ResetServiceWorkers;
    ForgetAllCaches;
    Check(LiveAgentCount = 0, 'service workers: no agent is left (' + IntToStr(LiveAgentCount) + ')');
    Restored := TWorkerPage.Create(Environment, Sink);
    try
      Conditions.Pages[0] := Restored;
      Restored.Navigable.NavigateTo('https://s.test/virtual.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker, 10000);
      Check(Finished and Restored.Has('controlled done'),
        'service workers: a kept registration answers after a restart (' + Restored.Output + ')');
    finally
      Restored.Free;
    end;
    Check((Pos('TypeError', AgentConsoleText) = 0) and (Pos('ReferenceError', AgentConsoleText) = 0) and
      (Pos('SyntaxError', AgentConsoleText) = 0), 'service workers: no script error in the workers (' +
      Trim(AgentConsoleText) + ')');
  finally
    ResetServiceWorkers;
    ForgetAllCaches;
    AgentConsole := nil;
    OriginDataBackend := nil;
    ConsoleSink.Free;
    Store.Free;
    Conditions.Free;
    Sink.Free;
    Environment.Free;
  end;
end;

function ReadFixture(const Path: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

{ The web-platform-tests subset (wpt-workers.html). }
procedure CheckPlatformTests;
var
  Environment: TTestEnvironment;
  Sink: TNullResourceSink;
  Page: TWorkerPage;
  Conditions: TWorkerConditions;
  Finished: Boolean;
begin
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Conditions := TWorkerConditions.Create;
  try
    Environment.Site.AddRoute('s.test/wpt.html', 200, HtmlType, ReadFixture('tools/WebLoadTest/wpt-workers.html'));
    Environment.Site.AddRoute('s.test/wpt-sw/narrow.js', 200, JavaScriptType, '');
    Environment.Site.AddRoute('s.test/wpt-sw/plain.js', 200, 'Content-Type: text/plain', '');
    Page := TWorkerPage.Create(Environment, Sink);
    try
      SetLength(Conditions.Pages, 1);
      Conditions.Pages[0] := Page;
      Conditions.Marker := 'done';
      Page.Navigable.NavigateTo('https://s.test/wpt.html');
      Finished := Environment.RunUntil(@Conditions.AllHaveMarker, 15000);
      Check(Finished and Page.Has('wpt PASSED'), 'web-platform-tests subset: ' + Page.Output + ' ' + Trim(Page.Console));
    finally
      Page.Free;
    end;
  finally
    ResetServiceWorkers;
    ForgetAllCaches;
    Conditions.Free;
    Sink.Free;
    Environment.Free;
  end;
end;

procedure RunWorkerTests;
begin
  CheckPlatformTests;
  CheckSharedWorkers;
  CheckBroadcastChannels;
  CheckCaches;
  CheckServiceWorkers;
end;

end.
