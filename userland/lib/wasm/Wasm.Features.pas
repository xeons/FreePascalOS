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
  The features of WebAssembly 3.0 beyond 2.0, which a module is decoded
  and validated with. Everything is on by default; an embedder can turn
  features off (a browser's flags), and the 2.0 spec tests run with none
  of them, since 3.0 makes some modules valid that 2.0 rejects (a second
  memory, a memory index in place of the zero byte, global.get of a
  module's own global in a constant expression).

  Legacy exception handling (try, catch, delegate, rethrow) is what
  Emscripten still emits and browsers still ship; it is not part of 3.0
  but on by default here.
}
unit Wasm.Features;

{$mode objfpc}

interface

type
  TWasmFeature = (
    wfMultipleMemories,
    wfMemory64,
    wfExceptionHandling,
    wfLegacyExceptions,
    wfTailCalls,
    wfFunctionReferences,
    wfGarbageCollection,
    wfRelaxedSimd,
    wfExtendedConstants
  );
  TWasmFeatures = set of TWasmFeature;

const
  WasmFeatures20: TWasmFeatures = [];
  WasmFeaturesAll: TWasmFeatures = [Low(TWasmFeature)..High(TWasmFeature)];

implementation

end.
