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
  Promise: the constructor, then / catch / finally, and the static
  resolve, reject, all, allSettled, any, race, withResolvers, try.

  Capabilities of other constructors (subclasses) go through
  NewPromiseCapability; the intrinsic Promise takes the direct path.
}
unit Js.Builtins.Promise;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Promises,
  Js.Interpreter;

procedure InstallPromise(R: TJsInterpreterRealm);

implementation

type
  TJsCapability = record
    Promise: TJsValue;
    Resolve: TJsValue;
    Reject: TJsValue;
  end;

function CapabilityExecutor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Holder: TJsObject;
begin
  Holder := JsAsObject(Callee.Data);
  if (Holder.InlineSlots[0] <> JsUndefined) or (Holder.InlineSlots[1] <> JsUndefined) then
    Exit(R.ThrowTypeError('Promise executor has already been invoked with non-undefined arguments'));
  Holder.InlineSlots[0] := Arg(Args, ArgCount, 0);
  Holder.InlineSlots[1] := Arg(Args, ArgCount, 1);
  Result := JsUndefined;
end;

function NewPromiseCapability(R: TJsRealm; Constructor_: TJsValue; out Capability: TJsCapability): Boolean;
var
  Promise: TJsPromise;
  Holder: TJsObject;
  Executor: TJsNativeFunction;
  Argument, Made: TJsValue;
  Mark: Integer;
begin
  Capability.Promise := JsUndefined;
  Capability.Resolve := JsUndefined;
  Capability.Reject := JsUndefined;
  if Constructor_ = JsObjectValue(R.Intrinsics[inPromise]) then
  begin
    Promise := NewPromise(R);
    Capability.Promise := JsObjectValue(Promise);
    CreateResolvingFunctions(R, Promise, Capability.Resolve, Capability.Reject);
    Exit(True);
  end;
  if not JsIsConstructor(Constructor_) then
  begin
    R.ThrowTypeError('Promise resolve or reject function is not callable');
    Exit(False);
  end;
  Holder := R.NewObject(nil);
  Holder.InlineSlots[0] := JsUndefined;
  Holder.InlineSlots[1] := JsUndefined;
  Executor := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @CapabilityExecutor, 2);
  Executor.Data := JsObjectValue(Holder);
  Argument := JsObjectValue(Executor);
  Mark := R.Runtime.PushRoot(Argument);
  try
    Made := R.Construct(Constructor_, @Argument, 1, Constructor_);
    if Made = JsException then
      Exit(False);
    if not JsIsCallable(Holder.InlineSlots[0]) or not JsIsCallable(Holder.InlineSlots[1]) then
    begin
      R.ThrowTypeError('Promise resolve or reject function is not callable');
      Exit(False);
    end;
    Capability.Promise := Made;
    Capability.Resolve := Holder.InlineSlots[0];
    Capability.Reject := Holder.InlineSlots[1];
    Result := True;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function ThisPromise(R: TJsRealm; Value: TJsValue; out Promise: TJsPromise): Boolean;
begin
  Promise := nil;
  if not JsIsPromise(Value) then
  begin
    R.ThrowTypeError('Method Promise.prototype.then called on incompatible receiver ' + ValueToPascal(R, Value));
    Exit(False);
  end;
  Promise := TJsPromise(JsAsObject(Value));
  Result := True;
end;

function PromiseConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Executor, Reason: TJsValue;
  Promise: TJsPromise;
  Prototype: TJsObject;
  Pair: array[0..1] of TJsValue;
  Mark: Integer;
begin
  if NewTarget = JsUndefined then
    Exit(R.ThrowTypeError('Promise constructor cannot be invoked without ''new'''));
  Executor := Arg(Args, ArgCount, 0);
  if not JsIsCallable(Executor) then
    Exit(R.ThrowTypeError('Promise resolver ' + ValueToPascal(R, Executor) + ' is not a function'));
  Prototype := PrototypeFromConstructor(R, NewTarget, inPromisePrototype);
  if Prototype = nil then
    Exit(JsException);
  Promise := NewPromise(R, Prototype);
  Result := JsObjectValue(Promise);
  CreateResolvingFunctions(R, Promise, Pair[0], Pair[1]);
  Mark := R.Runtime.PushRoot(Result);
  R.Runtime.PushRoot(Pair[0]);
  R.Runtime.PushRoot(Pair[1]);
  try
    if R.Call(Executor, JsUndefined, @Pair[0], 2) = JsException then
    begin
      if R.Runtime.Terminating then
        Exit(JsException);
      Reason := R.Runtime.TakeException;
      R.Call(Pair[1], JsUndefined, @Reason, 1);
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function PromiseThen(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Promise: TJsPromise;
  Constructor_: TJsValue;
  Capability: TJsCapability;
begin
  if not ThisPromise(R, This, Promise) then
    Exit(JsException);
  Constructor_ := SpeciesConstructor(R, Promise, JsObjectValue(R.Intrinsics[inPromise]));
  if Constructor_ = JsException then
    Exit(JsException);
  if not NewPromiseCapability(R, Constructor_, Capability) then
    Exit(JsException);
  PerformPromiseThen(R, Promise, Arg(Args, ArgCount, 0), Arg(Args, ArgCount, 1), Capability.Promise,
    Capability.Resolve, Capability.Reject);
  Result := Capability.Promise;
end;

function PromiseCatch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Pair: array[0..1] of TJsValue;
  Then_: TJsValue;
begin
  Pair[0] := JsUndefined;
  Pair[1] := Arg(Args, ArgCount, 0);
  Then_ := GetProperty(R, This, R.Atom(anThen));
  if Then_ = JsException then
    Exit(JsException);
  Result := R.Call(Then_, This, @Pair[0], 2);
end;

{ The functions finally passes to then: call onFinally, then pass the
  value on (Magic 0) or throw the reason again (Magic 1). }
function FinallyValueThunk(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if Callee.Magic = 0 then
    Result := Callee.Data
  else
    Result := R.Throw(Callee.Data);
end;

function FinallyReaction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Outcome: TJsValue;
  Promise: TJsPromise;
  Thunk: TJsNativeFunction;
  Then_, Argument: TJsValue;
begin
  Outcome := R.Call(Callee.Data, JsUndefined, nil, 0);
  if Outcome = JsException then
    Exit(JsException);
  Promise := PromiseResolveIntrinsic(R, Outcome);
  if Promise = nil then
    Exit(JsException);
  Thunk := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @FinallyValueThunk, 0, Callee.Magic);
  Thunk.Data := Arg(Args, ArgCount, 0);
  Then_ := Promise.GetValue(R, R.Atom(anThen));
  if Then_ = JsException then
    Exit(JsException);
  Argument := JsObjectValue(Thunk);
  Result := R.Call(Then_, JsObjectValue(Promise), @Argument, 1);
end;

function PromiseFinally(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  OnFinally, Then_: TJsValue;
  Pair: array[0..1] of TJsValue;
  Fulfilled, Rejected: TJsNativeFunction;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('Promise.prototype.finally called on non-object'));
  OnFinally := Arg(Args, ArgCount, 0);
  if JsIsCallable(OnFinally) then
  begin
    Fulfilled := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @FinallyReaction, 1, 0);
    Fulfilled.Data := OnFinally;
    Rejected := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @FinallyReaction, 1, 1);
    Rejected.Data := OnFinally;
    Pair[0] := JsObjectValue(Fulfilled);
    Pair[1] := JsObjectValue(Rejected);
  end
  else
  begin
    Pair[0] := OnFinally;
    Pair[1] := OnFinally;
  end;
  Then_ := JsAsObject(This).GetValue(R, R.Atom(anThen));
  if Then_ = JsException then
    Exit(JsException);
  Result := R.Call(Then_, This, @Pair[0], 2);
end;

function PromiseResolveStatic(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Value, Constructor_: TJsValue;
  Capability: TJsCapability;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('PromiseResolve called on non-object'));
  Value := Arg(Args, ArgCount, 0);
  if Callee.Magic = 0 then
  begin
    if JsIsPromise(Value) then
    begin
      Constructor_ := JsAsObject(Value).GetValue(R, R.ConstructorKey);
      if Constructor_ = JsException then
        Exit(JsException);
      if Constructor_ = This then
        Exit(Value);
    end;
    if not NewPromiseCapability(R, This, Capability) then
      Exit(JsException);
    if R.Call(Capability.Resolve, JsUndefined, @Value, 1) = JsException then
      Exit(JsException);
  end
  else
  begin
    if not NewPromiseCapability(R, This, Capability) then
      Exit(JsException);
    if R.Call(Capability.Reject, JsUndefined, @Value, 1) = JsException then
      Exit(JsException);
  end;
  Result := Capability.Promise;
end;

function PromiseWithResolvers(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Capability: TJsCapability;
  Outcome: TJsObject;
begin
  if not NewPromiseCapability(R, This, Capability) then
    Exit(JsException);
  Outcome := R.NewPlainObject;
  Outcome.CreateDataProperty(R, R.Intern('promise'), Capability.Promise);
  Outcome.CreateDataProperty(R, R.Intern('resolve'), Capability.Resolve);
  Outcome.CreateDataProperty(R, R.Intern('reject'), Capability.Reject);
  Result := JsObjectValue(Outcome);
end;

function PromiseTry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Capability: TJsCapability;
  Outcome: TJsValue;
begin
  if not NewPromiseCapability(R, This, Capability) then
    Exit(JsException);
  if ArgCount > 1 then
    Outcome := R.Call(Arg(Args, ArgCount, 0), JsUndefined, @Args^[1], ArgCount - 1)
  else
    Outcome := R.Call(Arg(Args, ArgCount, 0), JsUndefined, nil, 0);
  if Outcome = JsException then
  begin
    Outcome := R.Runtime.TakeException;
    if R.Call(Capability.Reject, JsUndefined, @Outcome, 1) = JsException then
      Exit(JsException);
  end
  else if R.Call(Capability.Resolve, JsUndefined, @Outcome, 1) = JsException then
    Exit(JsException);
  Result := Capability.Promise;
end;

{ Combinators: all (0), allSettled (1), any (2), race (3). The shared
  state lives in an array: [values, remaining count, resolve, reject]. }
const
  CombineAll = 0;
  CombineAllSettled = 1;
  CombineAny = 2;
  CombineRace = 3;

  StateValues = 0;
  StateRemaining = 1;
  StateResolve = 2;
  StateReject = 3;

function ElementFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  State: TJsObject;
  Values: TJsArray;
  Index, Remaining: Integer;
  Entry: TJsObject;
  Value, Error: TJsValue;
  Kind: Integer;
begin
  Result := JsUndefined;
  { Each element function settles once. }
  if Callee.HostData <> nil then
    Exit;
  Callee.HostData := Pointer(1);
  State := JsAsObject(Callee.Data);
  Values := TJsArray(JsAsObject(State.Elements^[StateValues]));
  Index := JsAsInteger(Callee.Data2);
  Kind := Callee.Magic;
  Value := Arg(Args, ArgCount, 0);
  case Kind of
    0: Values.CreateDataProperty(R, JsInteger(Index), Value);
    1, 2:
      begin
        Entry := R.NewPlainObject;
        if Kind = 1 then
        begin
          Entry.CreateDataProperty(R, R.Atom(anStatus), R.Atom(anFulfilled));
          Entry.CreateDataProperty(R, R.Atom(anValue), Value);
        end
        else
        begin
          Entry.CreateDataProperty(R, R.Atom(anStatus), R.Atom(anRejected));
          Entry.CreateDataProperty(R, R.Atom(anReason), Value);
        end;
        Values.CreateDataProperty(R, JsInteger(Index), JsObjectValue(Entry));
      end;
    3: Values.CreateDataProperty(R, JsInteger(Index), Value);
  end;
  Remaining := JsAsInteger(State.Elements^[StateRemaining]) - 1;
  State.Elements^[StateRemaining] := JsInteger(Remaining);
  if Remaining = 0 then
  begin
    if Kind = 3 then
    begin
      Error := JsObjectValue(R.NewError(ekAggregate, 'All promises were rejected'));
      JsAsObject(Error).DefineData(R, R.Atom(anErrors), JsObjectValue(Values), PropertyHidden);
      Exit(R.Call(State.Elements^[StateReject], JsUndefined, @Error, 1));
    end;
    Value := JsObjectValue(Values);
    Result := R.Call(State.Elements^[StateResolve], JsUndefined, @Value, 1);
  end;
end;

function PromiseCombinator(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Capability: TJsCapability;
  Resolver, Value, NextPromise, Then_, Reason: TJsValue;
  Iterator: TJsIteratorRecord;
  State: TJsArray;
  Values: TJsArray;
  Index, Mark, Kind: Integer;
  OnFulfilled, OnRejected: TJsValue;
  Element: TJsNativeFunction;
  Pair: array[0..1] of TJsValue;

  function Abrupt: TJsValue;
  begin
    if R.Runtime.Terminating then
      Exit(JsException);
    Reason := R.Runtime.TakeException;
    if R.Call(Capability.Reject, JsUndefined, @Reason, 1) = JsException then
      Exit(JsException);
    Result := Capability.Promise;
  end;

  function MakeElement(Magic: Integer): TJsValue;
  begin
    Element := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @ElementFunction, 1, Magic);
    Element.Data := JsObjectValue(State);
    Element.Data2 := JsInteger(Index);
    Result := JsObjectValue(Element);
  end;

begin
  Kind := Callee.Magic;
  if not NewPromiseCapability(R, This, Capability) then
    Exit(JsException);
  Mark := R.Runtime.PushRoot(Capability.Promise);
  R.Runtime.PushRoot(Capability.Resolve);
  R.Runtime.PushRoot(Capability.Reject);
  try
    Resolver := JsAsObject(This).GetValue(R, R.Intern('resolve'));
    if Resolver = JsException then
      Exit(Abrupt);
    if not JsIsCallable(Resolver) then
    begin
      R.ThrowTypeError('Promise resolve is not a function');
      Exit(Abrupt);
    end;
    if not GetIterator(R, Arg(Args, ArgCount, 0), False, Iterator) then
      Exit(Abrupt);
    R.Runtime.PushRoot(Iterator.Iterator);
    R.Runtime.PushRoot(Iterator.NextMethod);
    Values := R.NewArray(0);
    State := R.NewArray(0);
    State.CreateDataProperty(R, JsInteger(StateValues), JsObjectValue(Values));
    State.CreateDataProperty(R, JsInteger(StateRemaining), JsInteger(1));
    State.CreateDataProperty(R, JsInteger(StateResolve), Capability.Resolve);
    State.CreateDataProperty(R, JsInteger(StateReject), Capability.Reject);
    R.Runtime.PushRoot(JsObjectValue(State));
    Index := 0;
    while IteratorStep(R, Iterator, Value) do
    begin
      if Kind <> CombineRace then
        Values.CreateDataProperty(R, JsInteger(Index), JsUndefined);
      NextPromise := R.Call(Resolver, This, @Value, 1);
      if NextPromise = JsException then
      begin
        IteratorClose(R, Iterator.Iterator, True);
        Exit(Abrupt);
      end;
      case Kind of
        CombineAll:
          begin
            OnFulfilled := MakeElement(0);
            OnRejected := Capability.Reject;
          end;
        CombineAllSettled:
          begin
            OnFulfilled := MakeElement(1);
            OnRejected := MakeElement(2);
            TJsNativeFunction(JsAsObject(OnRejected)).Data2 := JsInteger(Index);
          end;
        CombineAny:
          begin
            OnFulfilled := Capability.Resolve;
            OnRejected := MakeElement(3);
          end;
      else
        OnFulfilled := Capability.Resolve;
        OnRejected := Capability.Reject;
      end;
      if Kind = CombineAllSettled then
      begin
        { The two functions of one element share "already called". }
        TJsNativeFunction(JsAsObject(OnRejected)).Data := JsObjectValue(State);
      end;
      if Kind <> CombineRace then
        State.Elements^[StateRemaining] := JsInteger(JsAsInteger(State.Elements^[StateRemaining]) + 1);
      Then_ := GetProperty(R, NextPromise, R.Atom(anThen));
      if Then_ = JsException then
      begin
        IteratorClose(R, Iterator.Iterator, True);
        Exit(Abrupt);
      end;
      Pair[0] := OnFulfilled;
      Pair[1] := OnRejected;
      if R.Call(Then_, NextPromise, @Pair[0], 2) = JsException then
      begin
        IteratorClose(R, Iterator.Iterator, True);
        Exit(Abrupt);
      end;
      Inc(Index);
    end;
    if R.HasException then
      Exit(Abrupt);
    if Kind <> CombineRace then
    begin
      State.Elements^[StateRemaining] := JsInteger(JsAsInteger(State.Elements^[StateRemaining]) - 1);
      if JsAsInteger(State.Elements^[StateRemaining]) = 0 then
      begin
        if Kind = CombineAny then
        begin
          Reason := JsObjectValue(R.NewError(ekAggregate, 'All promises were rejected'));
          JsAsObject(Reason).DefineData(R, R.Atom(anErrors), JsObjectValue(Values), PropertyHidden);
          if R.Call(Capability.Reject, JsUndefined, @Reason, 1) = JsException then
            Exit(JsException);
        end
        else
        begin
          Value := JsObjectValue(Values);
          if R.Call(Capability.Resolve, JsUndefined, @Value, 1) = JsException then
            Exit(JsException);
        end;
      end;
    end;
    Result := Capability.Promise;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function PromiseSpecies(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

procedure InstallPromise(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;
begin
  Prototype := R.Intrinsics[inPromisePrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'Promise', @PromiseConstructor, 1, Prototype);
  R.Intrinsics[inPromise] := Constructor_;
  DefineMethod(R, Constructor_, 'resolve', @PromiseResolveStatic, 1, 0);
  DefineMethod(R, Constructor_, 'reject', @PromiseResolveStatic, 1, 1);
  DefineMethod(R, Constructor_, 'all', @PromiseCombinator, 1, CombineAll);
  DefineMethod(R, Constructor_, 'allSettled', @PromiseCombinator, 1, CombineAllSettled);
  DefineMethod(R, Constructor_, 'any', @PromiseCombinator, 1, CombineAny);
  DefineMethod(R, Constructor_, 'race', @PromiseCombinator, 1, CombineRace);
  DefineMethod(R, Constructor_, 'withResolvers', @PromiseWithResolvers, 0);
  DefineMethod(R, Constructor_, 'try', @PromiseTry, 1);
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies),
    JsObjectValue(NewNativeFunction(R, 'get [Symbol.species]', @PromiseSpecies, 0)), JsUndefined, PropertyConfigurable);
  DefineMethod(R, Prototype, 'then', @PromiseThen, 2);
  DefineMethod(R, Prototype, 'catch', @PromiseCatch, 1);
  DefineMethod(R, Prototype, 'finally', @PromiseFinally, 1);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Promise'), PropertyConfigurable);
end;

end.
