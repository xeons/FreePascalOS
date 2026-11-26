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
  The lifetime of WebAssembly's collected objects seen from JavaScript,
  counted on the Pascal side: structs only JavaScript holds are freed
  with their wrappers, a cycle through both heaps (a struct holding a
  JavaScript object holding the struct) goes in one collection, structs
  a WebAssembly global holds stay with what they hold, and exception
  objects keep their WebAssembly.Exception through collections.
}
unit WebScriptTest.WasmLifetime;

{$mode objfpc}
{$H+}

interface

procedure RunWasmLifetimeTests;

implementation

uses
  SysUtils,
  TestChecks,
  Wasm.GcHeap,
  Wasm.Api,
  Web.Script.WasmAgents,
  WebScriptTest.Harness;

const
  { A module: makeBox(externref) -> (ref $box), unbox, setStored(anyref),
    clearStored(); $box = struct (mut externref). }
  ModuleScript =
    'function vec(items) { var out = [items.length]; items.forEach(function (i) { out = out.concat(i); });' +
    ' return out; }' +
    'function sec(id, body) { return [id, body.length].concat(body); }' +
    'function code(c) { return [c.length + 2, 0].concat(c, [0x0b]); }' +
    'var bytes = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0].concat(' +
    ' sec(1, vec([[0x5f, 1, 0x6f, 1], [0x60, 1, 0x6f, 1, 0x64, 0], [0x60, 1, 0x63, 0, 1, 0x6f],' +
    '  [0x60, 1, 0x6e, 0], [0x60, 0, 0]])),' +
    ' sec(3, vec([[1], [2], [3], [4]])),' +
    ' sec(6, vec([[0x63, 0x6e, 1, 0xd0, 0x6e, 0x0b]])),' +
    ' sec(7, vec([[7].concat(Array.from("makeBox", function (c) { return c.charCodeAt(0); }), [0, 0]),' +
    '  [5].concat(Array.from("unbox", function (c) { return c.charCodeAt(0); }), [0, 1]),' +
    '  [9].concat(Array.from("setStored", function (c) { return c.charCodeAt(0); }), [0, 2]),' +
    '  [11].concat(Array.from("clearStored", function (c) { return c.charCodeAt(0); }), [0, 3])])),' +
    ' sec(10, vec([code([0x20, 0, 0xfb, 0x00, 0]), code([0x20, 0, 0xfb, 0x02, 0, 0]), code([0x20, 0, 0x24, 0]),' +
    '  code([0xd0, 0x6e, 0x24, 0])])));' +
    'var w = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(bytes))).exports;';

procedure Collect(Bed: TTestBed);
begin
  Bed.Context.Engine.CollectGarbage;
end;

procedure TestWasmObjectLifetime;
var
  Bed: TTestBed;
  Agent: TWasmAgent;
  ObjectsBefore, WrappersBefore: Integer;
begin
  Bed := TTestBed.Create('wasm-lifetime');
  try
    Bed.Run(ModuleScript);
    Agent := AgentOf(Bed.Context);
    Collect(Bed);
    ObjectsBefore := Agent.Heap.ObjectCount;
    WrappersBefore := Agent.ReferenceObjectCount;
    Bed.Run('var boxes = []; for (var i = 0; i < 1000; i++) boxes.push(w.makeBox({ index: i }));');
    Collect(Bed);
    Check(Agent.Heap.ObjectCount >= ObjectsBefore + 1000, 'wasm lifetime: structs JavaScript holds are kept (' +
      IntToStr(Agent.Heap.ObjectCount) + ' objects)');
    Check(Bed.Evaluate('String(w.unbox(boxes[999]).index)') = '999', 'wasm lifetime: with what they hold');
    WasmCollectGarbage(Agent);
    Check((Agent.Heap.ObjectCount >= ObjectsBefore + 1000) and
      (Bed.Evaluate('String(w.unbox(boxes[0]).index)') = '0'),
      'wasm lifetime: libwasm''s own collection keeps what JavaScript holds');
    Bed.Run('boxes = null;');
    Collect(Bed);
    Check(Agent.Heap.ObjectCount <= ObjectsBefore, 'wasm lifetime: unreachable structs are freed (' +
      IntToStr(Agent.Heap.ObjectCount) + ' objects, ' + IntToStr(ObjectsBefore) + ' before)');
    Check(Agent.ReferenceObjectCount <= WrappersBefore, 'wasm lifetime: and their wrappers leave the cache');

    Bed.Run('(function () { for (var i = 0; i < 500; i++) { var o = { index: i }; o.box = w.makeBox(o); } })();');
    Collect(Bed);
    Check(Agent.Heap.ObjectCount <= ObjectsBefore, 'wasm lifetime: cycles through both heaps are freed (' +
      IntToStr(Agent.Heap.ObjectCount) + ' objects)');
    Check(Agent.ReferenceObjectCount <= WrappersBefore, 'wasm lifetime: and their wrappers go');

    Bed.Run('(function () { var o = { note: "kept" }; o.box = w.makeBox(o); w.setStored(o.box); })();');
    Collect(Bed);
    Collect(Bed);
    Check(Agent.Heap.ObjectCount = ObjectsBefore + 1, 'wasm lifetime: a struct a global holds stays');
    Bed.Run('w.clearStored();');
    Collect(Bed);
    Check(Agent.Heap.ObjectCount <= ObjectsBefore, 'wasm lifetime: and goes with its cycle when the global lets go');

    Bed.Run('var tag = new WebAssembly.Tag({ parameters: ["externref"] }); var payload = { p: 1 };' +
      ' var exception = new WebAssembly.Exception(tag, [payload]); payload = null;');
    Collect(Bed);
    Check(Bed.Evaluate('String(exception.getArg(tag, 0).p)') = '1',
      'wasm lifetime: an exception keeps its payload through collections');
    Bed.Run('exception = null;');
    Collect(Bed);
    Check(Agent.Heap.ObjectCount <= ObjectsBefore, 'wasm lifetime: an exception nothing holds is freed');
  finally
    Bed.Free;
  end;
end;

procedure RunWasmLifetimeTests;
begin
  TestWasmObjectLifetime;
end;

end.
