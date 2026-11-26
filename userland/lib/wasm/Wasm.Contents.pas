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
  The contents of libwasm.so, the WebAssembly engine: the binary
  decoder, the validator, the compiler to slot code, the interpreter,
  the store and instantiation, and the embedder's interface (Wasm.Api).
  Compiling this unit compiles all of them.
}
unit Wasm.Contents;

{$mode objfpc}

interface

uses
  Wasm.Types,
  Wasm.Errors,
  Wasm.Limits,
  Wasm.Opcodes,
  Wasm.Reader,
  Wasm.Instructions,
  Wasm.Module,
  Wasm.Decoder,
  Wasm.CodeValidator,
  Wasm.Validator,
  Wasm.Code,
  Wasm.CodeEmitter,
  Wasm.Compiler,
  Wasm.Numerics,
  Wasm.Simd,
  Wasm.Runtime,
  Wasm.Interpreter,
  Wasm.Instantiation,
  Wasm.Api;

implementation

end.
