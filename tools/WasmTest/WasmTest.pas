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
  Host side test of libwasm (make wasm-test): decoding and validation,
  each feature area, traps, host functions and the rest of the embedder
  interface, a real module when one is given, and the interpreter's
  speed. Modules are written in the text format and encoded by the spec
  test runner's encoder (tools/WasmSpecTest).

    WasmTest [SAMPLE.wasm]
}
program WasmTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  WasmTest.Features,
  WasmTest.Embedding,
  WasmTest.Programs;

begin
  RunFeatureTests;
  RunEmbeddingTests;
  RunProgramTests(ParamStr(1));
  FinishChecks('WASM TEST');
end.
