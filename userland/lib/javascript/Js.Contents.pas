{
  The contents of libjavascript.so: the ECMAScript engine and its
  embedding API (Js.Engine). Compiling this unit compiles all of them.
}
unit Js.Contents;

{$mode objfpc}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.BigIntegers,
  Js.Objects,
  Js.Functions,
  Js.Lexer,
  Js.Ast,
  Js.Parser,
  Js.Scopes,
  Js.Bytecode,
  Js.CodeBuilder,
  Js.ExpressionCompiler,
  Js.StatementCompiler,
  Js.Compiler,
  Js.Conversions,
  Js.Operations,
  Js.Promises,
  Js.Interpreter,
  Js.Inspect,
  Js.Platform,
  Js.SystemClock,
  Js.RegExpCompiler,
  Js.RegExpMatcher,
  Js.Builtins.Objects,
  Js.Builtins.Functions,
  Js.Builtins.Error,
  Js.Builtins.Global,
  Js.Builtins.Symbol,
  Js.Builtins.Iterators,
  Js.Builtins.Arrays,
  Js.Builtins.Strings,
  Js.CaseMapping,
  Js.Builtins.Number,
  Js.Builtins.Math,
  Js.Builtins.BigInt,
  Js.Builtins.Json,
  Js.Builtins.Collections,
  Js.Builtins.Promise,
  Js.Builtins.Generators,
  Js.Builtins.Reflect,
  Js.Builtins.Date,
  Js.Builtins.RegExp,
  Js.ArrayBuffers,
  Js.Builtins.ArrayBuffer,
  Js.Builtins.TypedArrays,
  Js.Builtins.Atomics,
  Js.Builtins.Base64,
  Js.ModuleRecords,
  Js.Modules,
  Js.EvalScopes,
  Js.Arguments,
  Js.DirectEval,
  Js.Builtins.AnnexB,
  Js.Normalization,
  Js.Builtins.Intl,
  Js.Builtins.SelfHosted,
  Js.Intrinsics,
  Js.Engine;

implementation

end.
