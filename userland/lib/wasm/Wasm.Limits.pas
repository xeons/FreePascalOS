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
  Implementation limits: the ones the JS API spec makes every engine
  accept (section "Limits"), which also keep a hostile module from
  making the decoder allocate without bound; and the run time limits of
  a store (Wasm.Runtime) that keep deep recursion from exhausting the
  host thread.
}
unit Wasm.Limits;

{$mode objfpc}

interface

const
  MaximumModuleSize = 1024 * 1024 * 1024;
  MaximumTypes = 1000000;
  MaximumFunctions = 1000000;
  MaximumImports = 100000;
  MaximumExports = 100000;
  MaximumGlobals = 1000000;
  MaximumDataSegments = 100000;
  MaximumElementSegments = 10000000;
  MaximumTables = 100000;
  MaximumMemories = 100;
  MaximumTags = 1000000;
  MaximumStructFields = 10000;
  MaximumFixedArrayLength = 10000;
  MaximumSubtypeDepth = 63;
  MaximumTableElements = 10000000;
  MaximumMemoryPages = 65536;
  { A 64-bit memory's limits may name up to 2^48 pages (validation); how
    much is really allocated is a store's option. }
  MaximumMemory64Pages = QWord(1) shl 48;
  MaximumParams = 1000;
  MaximumResults = 1000;
  MaximumLocals = 50000;
  MaximumFunctionBodySize = 7654321;
  MaximumBranchTableLabels = 65520;
  MaximumStringLength = 100000;
  MaximumBlockDepth = 100000;

  { A store's defaults (Wasm.Runtime.TWasmStoreOptions). }
  DefaultMaximumCallDepth = 20000;
  DefaultMaximumStackSlots = 4 * 1024 * 1024;
  DefaultInitialStackSlots = 64 * 1024;
  DefaultMaximumHostNesting = 200;
  { Back edges and calls between two calls of the interrupt hook. }
  DefaultInterruptInterval = 1000000;
  { The bytes a memory may really take (its pages times 64 KiB). }
  DefaultMaximumMemoryBytes = QWord(4) * 1024 * 1024 * 1024;
  { The bytes of garbage collected objects a store may hold. }
  DefaultMaximumHeapBytes = QWord(1024) * 1024 * 1024;
  { Bytes allocated between two collections at the least. }
  DefaultCollectionThreshold = 4 * 1024 * 1024;

implementation

end.
