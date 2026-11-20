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
  The bytecode: a register machine.

  An instruction is an opcode word followed by its operand words (all
  LongInt). Operands are registers (indices relative to the frame's
  base: -2 is the callee, -1 the this value, 0.. the parameters, the
  locals and the temporaries), constant indices, immediates, absolute
  jump targets, and inline cache indices. OperandCounts says how many
  words follow each opcode.

  A call takes its callee in register F, the this value in F + 1 and
  the arguments in F + 2...; the callee's frame starts at F + 2, so the
  arguments are already where its parameters live.
}
unit Js.Bytecode;

{$mode objfpc}{$H+}

interface

type
  TJsOpcode = (
    opNop,
    { Loads: dst }
    opLoadUndefined, opLoadNull, opLoadTrue, opLoadFalse, opLoadHole,
    opLoadInteger,        { dst, value }
    opLoadConstant,       { dst, constant }
    opMove,               { dst, src }
    { Variables }
    opGetEnvironment,     { dst, hops, slot }
    opGetEnvironmentChecked, { dst, hops, slot, name constant }
    opSetEnvironment,     { hops, slot, src }
    opSetEnvironmentChecked, { hops, slot, src, name constant: the binding must be initialised }
    opCheckInitialized,   { register, name constant }
    opGetGlobal,          { dst, name constant, cache }
    opTypeofGlobal,       { dst, name constant }
    opSetGlobal,          { src, name constant, cache, strict }
    opDeclareGlobalVar,   { name constant, function value register or -1 }
    opDeclareGlobalLexical, { name constant, is const }
    opInitializeGlobalLexical, { name constant, src }
    opDeleteGlobal,       { dst, name constant }
    opPushScope,          { size }
    opPopScope,
    opCopyScope,          { per iteration copy of the current scope }
    opThrowConstAssign,   { name constant }
    opThrowReference,     { name constant }
    { Functions }
    opClosure,            { dst, function index }
    opLoadHome,           { dst }
    opLoadNewTarget,      { dst }
    opLoadCallee,         { dst }
    { Objects and properties }
    opNewObject,          { dst }
    opNewArray,           { dst, capacity }
    opGetNamed,           { dst, object, name constant, cache }
    opSetNamed,           { object, name constant, src, cache }
    opGetIndex,           { dst, object, key }
    opSetIndex,           { object, key, src }
    opGetLength,          { dst, object, cache }
    opDeleteNamed,        { dst, object, name constant }
    opDeleteIndex,        { dst, object, key }
    opDefineField,        { object, name constant, src, cache: CreateDataProperty }
    opDefineIndex,        { object, key, src }
    opDefineMethod,       { object, key, function, flags (1 enumerable) }
    opDefineGetter,       { object, key, function, flags }
    opDefineSetter,       { object, key, function, flags }
    opSetPrototypeLiteral,{ object, value: __proto__: in a literal }
    opCopyDataProperties, { target, source, excluded keys array register or -1 }
    opArrayPush,          { array, src }
    opArrayHole,          { array }
    opArraySpread,        { array, iterable }
    opGetSuper,           { dst, receiver, key, home object }
    opSetSuper,           { receiver, key, src, home object }
    opGetPrivate,         { dst, object, private name }
    opSetPrivate,         { object, private name, src }
    opDefinePrivate,      { object, private name, src }
    opDefinePrivateAccessor, { object, private name, getter, setter }
    opPrivateIn,          { dst, private name, object }
    opNewPrivateName,     { dst, description constant }
    opMakeClass,          { dst (constructor; dst + 1 gets the prototype), constructor function, heritage or -1 }
    opSetClassFields,     { constructor, initializer function }
    opRunClassFields,     { this value, function: runs the function's field initializer }
    opSetClassSlot,       { initializer function, index, src }
    opGetClassSlot,       { dst, index (of the callee's class slots) }
    opSetHome,            { function, home object }
    opSetFunctionName,    { function, key, prefix (0 none, 1 get, 2 set) }
    { Operators }
    opAdd, opSubtract, opMultiply, opDivide, opModulo, opExponent,
    opBitAnd, opBitOr, opBitXor, opShiftLeft, opShiftRight, opShiftRightUnsigned,
    opEqual, opNotEqual, opStrictEqual, opStrictNotEqual, opLess, opLessEqual,
    opGreater, opGreaterEqual, opInstanceof, opIn,
                          { all: dst, a, b }
    opNegate, opPlus, opBitNot, opNot, opIncrement, opDecrement, opToNumeric,
    opTypeof, opToPropertyKey, opToString, opVoid,
                          { all: dst, src }
    opTemplateAppend,     { dst, src: dst := dst + ToString(src) }
    opGetTemplateObject,  { dst, constant (template site) }
    { Control }
    opJump,               { target }
    opJumpIfTrue,         { src, target }
    opJumpIfFalse,        { src, target }
    opJumpIfNullish,      { src, target }
    opJumpIfNotNullish,   { src, target }
    opJumpIfUndefined,    { src, target }
    opJumpIfNotUndefined, { src, target }
    opJumpIfLessFalse,    { a, b, target: if not (a < b) }
    opJumpIfLessEqualFalse, { a, b, target }
    opJumpIfGreaterFalse, { a, b, target }
    opJumpIfGreaterEqualFalse, { a, b, target }
    opJumpIfStrictEqualFalse, { a, b, target }
    opJumpIfStrictNotEqualFalse, { a, b, target }
    opCall,               { dst, f, argument count }
    opCallMethod,         { dst, f, argument count (same as call, marks a method call for messages) }
    opCallSpread,         { dst, f, arguments array }
    opNew,                { dst, f, argument count }
    opNewSpread,          { dst, f, arguments array }
    opSuperCall,          { dst, function, new target, first argument, argument count }
    opSuperCallSpread,    { dst, function, new target, arguments array }
    opThrowIfNotHole,     { src: super() called twice }
    opReturn,             { src }
    opReturnUndefined,
    opThrow,              { src }
    opThrowIfNullish,     { src, message kind }
    opThrowIfNotObject,   { src, message kind }
    { Iteration }
    opGetIterator,        { dst (two registers: iterator, next), src, async }
    opIteratorNext,       { dst, iterator (two registers), done target }
    opIteratorClose,      { iterator (two registers) }
    opIteratorCloseQuiet, { iterator: closing on a throw, errors ignored }
    opForInStart,         { dst, object }
    opForInNext,          { dst, iterator, done target }
    opIteratorRest,       { dst, iterator (rest of the iterator as an array) }
    { Generators and async functions }
    opInitialYield,
    opYield,              { dst, src (dst gets the value sent in) }
    opYieldDelegate,      { dst, iterable }
    opAwait,              { dst, src }
    opAsyncGeneratorYield,{ dst, src }
    opResumeKind,         { dst (the kind of the last resumption: 0 next, 1 throw, 2 return) }
    { Exceptions }
    opRethrowCompletion,  { src (a caught completion: rethrow, or carry on a return) }
    opReturnCompletion,   { src }
    { Misc }
    opDebugger,
    opCreateRestFromArguments, { dst, start }
    opGetArgumentsObject, { dst }
    opRegExp,             { dst, body constant, flags constant }
    opEnterWith,          { (not supported: throws) }
    opLast);

var
  { Operand words after each opcode. }
  OperandCounts: array[TJsOpcode] of Byte;

function OpcodeName(Opcode: TJsOpcode): string;

implementation

uses
  TypInfo;

function OperandCount(Opcode: TJsOpcode): Integer;
begin
  case Opcode of
    opNop, opPopScope, opCopyScope, opReturnUndefined, opInitialYield, opDebugger, opEnterWith, opLast:
      Result := 0;
    opLoadUndefined, opLoadNull, opLoadTrue, opLoadFalse, opLoadHole, opPushScope, opThrowConstAssign,
    opThrowReference, opLoadHome, opLoadNewTarget, opLoadCallee, opNewObject, opArrayHole, opJump,
    opReturn, opThrow, opIteratorClose, opIteratorCloseQuiet, opResumeKind, opRethrowCompletion,
    opReturnCompletion, opGetArgumentsObject, opThrowIfNotHole:
      Result := 1;
    opLoadInteger, opLoadConstant, opMove, opCheckInitialized, opTypeofGlobal, opDeclareGlobalVar,
    opDeclareGlobalLexical, opInitializeGlobalLexical, opDeleteGlobal, opClosure, opNewArray,
    opSetPrototypeLiteral, opArrayPush, opArraySpread, opNewPrivateName,
    opSetClassFields, opSetHome, opNegate, opPlus, opBitNot, opNot, opIncrement, opDecrement,
    opToNumeric, opTypeof, opToPropertyKey, opToString, opVoid, opTemplateAppend, opGetTemplateObject,
    opJumpIfTrue, opJumpIfFalse, opJumpIfNullish, opJumpIfNotNullish, opJumpIfUndefined,
    opJumpIfNotUndefined, opThrowIfNullish, opThrowIfNotObject, opForInStart,
    opIteratorRest, opYield, opYieldDelegate, opAwait, opAsyncGeneratorYield,
    opCreateRestFromArguments, opRunClassFields, opGetClassSlot:
      Result := 2;
    opGetEnvironment, opSetEnvironment, opGetGlobal, opGetIndex, opSetIndex, opGetLength,
    opDeleteNamed, opDeleteIndex, opDefineIndex, opCopyDataProperties, opGetPrivate, opSetPrivate,
    opDefinePrivate, opPrivateIn, opMakeClass, opSetFunctionName, opAdd, opSubtract, opMultiply,
    opDivide, opModulo, opExponent, opBitAnd, opBitOr, opBitXor, opShiftLeft, opShiftRight,
    opShiftRightUnsigned, opEqual, opNotEqual, opStrictEqual, opStrictNotEqual, opLess, opLessEqual,
    opGreater, opGreaterEqual, opInstanceof, opIn, opJumpIfLessFalse, opJumpIfLessEqualFalse,
    opJumpIfGreaterFalse, opJumpIfGreaterEqualFalse, opJumpIfStrictEqualFalse,
    opJumpIfStrictNotEqualFalse, opCall, opCallMethod, opCallSpread, opNew, opNewSpread,
    opGetIterator, opIteratorNext, opForInNext, opRegExp, opSetClassSlot:
      Result := 3;
    opGetEnvironmentChecked, opSetEnvironmentChecked, opSetGlobal, opGetNamed, opSetNamed,
    opDefineField, opDefineMethod, opDefineGetter, opDefineSetter, opDefinePrivateAccessor,
    opSuperCallSpread, opGetSuper, opSetSuper:
      Result := 4;
    opSuperCall:
      Result := 5;
  else
    Result := 0;
  end;
end;

procedure FillOperandCounts;
var
  Opcode: TJsOpcode;
begin
  for Opcode := Low(TJsOpcode) to High(TJsOpcode) do
    OperandCounts[Opcode] := OperandCount(Opcode);
end;

function OpcodeName(Opcode: TJsOpcode): string;
begin
  Result := GetEnumName(TypeInfo(TJsOpcode), Ord(Opcode));
  if Copy(Result, 1, 2) = 'op' then
    Delete(Result, 1, 2);
end;

initialization
  FillOperandCounts;
end.
