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
  Promises: the objects and the machinery under Promise and async
  functions.

  A promise is pending, fulfilled or rejected, with its reactions (what
  then() registered) kept until it settles; settling queues one job per
  reaction. Resolving with a thenable queues a job that calls its then.
  The resolving functions (resolve, reject) share a flag so only the
  first call counts.

  Rejections nobody handles are noted (UnhandledRejections) for the host
  to report; a later then() takes the promise off the list.
}
unit Js.Promises;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations;

type
  TJsPromiseState = (psPending, psFulfilled, psRejected);

  TJsPromiseReaction = record
    OnFulfilled: TJsValue;
    OnRejected: TJsValue;
    { The derived promise's capability (undefined: none). }
    Promise: TJsValue;
    Resolve: TJsValue;
    Reject: TJsValue;
  end;

  TJsPromise = class(TJsObject)
  public
    State: TJsPromiseState;
    Value: TJsValue;
    Reactions: array of TJsPromiseReaction;
    ReactionCount: Integer;
    IsHandled: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  { The state the two resolving functions of one promise share. }
  TJsResolvingState = class(TJsCell)
  public
    Promise: TJsPromise;
    AlreadyResolved: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

function NewPromise(R: TJsRealm; Prototype: TJsObject = nil): TJsPromise;
procedure CreateResolvingFunctions(R: TJsRealm; Promise: TJsPromise; out Resolve, Reject: TJsValue);
{ The resolve function's work. }
procedure ResolvePromise(R: TJsRealm; Promise: TJsPromise; Resolution: TJsValue);
procedure FulfillPromise(R: TJsRealm; Promise: TJsPromise; Value: TJsValue);
procedure RejectPromise(R: TJsRealm; Promise: TJsPromise; Reason: TJsValue);
procedure PerformPromiseThen(R: TJsRealm; Promise: TJsPromise; OnFulfilled, OnRejected: TJsValue;
  ResultPromise, ResultResolve, ResultReject: TJsValue);
{ PromiseResolve(%Promise%, Value): Value itself when it is a promise
  made by %Promise%, else a new promise resolved with it. }
function PromiseResolveIntrinsic(R: TJsRealm; Value: TJsValue): TJsPromise;
function JsIsPromise(Value: TJsValue): Boolean; inline;

var
  { Called when a promise is rejected with no handler, and with Handled
    True when a handler comes later. }
  JsRejectionTracker: procedure(R: TJsRealm; Promise: TJsPromise; Handled: Boolean) = nil;

implementation

function JsIsPromise(Value: TJsValue): Boolean;
begin
  Result := JsIsObject(Value) and (JsAsObject(Value).ObjectClass = ocPromise);
end;

procedure TJsPromise.Trace(Tracer: TJsTracer);
var
  Index: Integer;
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Value);
  for Index := 0 to ReactionCount - 1 do
  begin
    Tracer.MarkValue(Reactions[Index].OnFulfilled);
    Tracer.MarkValue(Reactions[Index].OnRejected);
    Tracer.MarkValue(Reactions[Index].Promise);
    Tracer.MarkValue(Reactions[Index].Resolve);
    Tracer.MarkValue(Reactions[Index].Reject);
  end;
end;

procedure TJsResolvingState.Trace(Tracer: TJsTracer);
begin
  Tracer.MarkCell(Promise);
end;

function NewPromise(R: TJsRealm; Prototype: TJsObject): TJsPromise;
begin
  if Prototype = nil then
    Prototype := R.Intrinsics[inPromisePrototype];
  Result := TJsPromise(R.NewObjectOfClass(TJsPromise, Prototype, ocPromise));
  Result.Value := JsUndefined;
end;

function ResolveFunction(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  State: TJsResolvingState;
begin
  State := TJsResolvingState(JsAsCell(Callee.Data));
  Result := JsUndefined;
  if State.AlreadyResolved then
    Exit;
  State.AlreadyResolved := True;
  if Callee.Magic = 0 then
    ResolvePromise(R, State.Promise, Arg(Args, ArgCount, 0))
  else
    RejectPromise(R, State.Promise, Arg(Args, ArgCount, 0));
end;

procedure CreateResolvingFunctions(R: TJsRealm; Promise: TJsPromise; out Resolve, Reject: TJsValue);
var
  State: TJsResolvingState;
  Function_: TJsNativeFunction;
begin
  State := TJsResolvingState.Create;
  R.Heap.Register(State, ckOther);
  State.Promise := Promise;
  Function_ := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @ResolveFunction, 1, 0);
  Function_.Data := JsCellValue(JsObjectBase, State);
  Resolve := JsObjectValue(Function_);
  Function_ := NewNativeFunctionWithKey(R, R.Atom(anEmpty), @ResolveFunction, 1, 1);
  Function_.Data := JsCellValue(JsObjectBase, State);
  Reject := JsObjectValue(Function_);
end;

{ Jobs }

{ Values: handler, argument, promise capability (promise, resolve, reject
  packed: 2 = resolve, 3 = reject); the reaction kind travels in the
  handler slot as undefined for "pass the value on". }
procedure FulfillReactionJob(R: TJsRealm; const Values: array of TJsValue);
var
  Handler, Argument, Outcome: TJsValue;
begin
  Handler := Values[0];
  Argument := Values[1];
  if Handler = JsUndefined then
    Outcome := Argument
  else
    Outcome := R.Call(Handler, JsUndefined, @Argument, 1);
  if Outcome = JsException then
  begin
    Outcome := R.Runtime.TakeException;
    if Values[3] <> JsUndefined then
      R.Call(Values[3], JsUndefined, @Outcome, 1);
    Exit;
  end;
  if Values[2] <> JsUndefined then
    R.Call(Values[2], JsUndefined, @Outcome, 1);
end;

procedure RejectReactionJob(R: TJsRealm; const Values: array of TJsValue);
var
  Handler, Argument, Outcome: TJsValue;
begin
  Handler := Values[0];
  Argument := Values[1];
  if Handler = JsUndefined then
  begin
    if Values[3] <> JsUndefined then
      R.Call(Values[3], JsUndefined, @Argument, 1);
    Exit;
  end;
  Outcome := R.Call(Handler, JsUndefined, @Argument, 1);
  if Outcome = JsException then
  begin
    Outcome := R.Runtime.TakeException;
    if Values[3] <> JsUndefined then
      R.Call(Values[3], JsUndefined, @Outcome, 1);
    Exit;
  end;
  if Values[2] <> JsUndefined then
    R.Call(Values[2], JsUndefined, @Outcome, 1);
end;

{ Values: promise to resolve, thenable, then. }
procedure ResolveThenableJob(R: TJsRealm; const Values: array of TJsValue);
var
  Resolve, Reject, Outcome: TJsValue;
  Pair: array[0..1] of TJsValue;
  Mark: Integer;
begin
  CreateResolvingFunctions(R, TJsPromise(JsAsObject(Values[0])), Resolve, Reject);
  Mark := R.Runtime.PushRoot(Resolve);
  R.Runtime.PushRoot(Reject);
  Pair[0] := Resolve;
  Pair[1] := Reject;
  Outcome := R.Call(Values[2], Values[1], @Pair[0], 2);
  if Outcome = JsException then
  begin
    Outcome := R.Runtime.TakeException;
    R.Call(Reject, JsUndefined, @Outcome, 1);
  end;
  R.Runtime.PopRoots(Mark);
end;

procedure TriggerReactions(R: TJsRealm; Promise: TJsPromise);
var
  Index: Integer;
  Reaction: TJsPromiseReaction;
begin
  for Index := 0 to Promise.ReactionCount - 1 do
  begin
    Reaction := Promise.Reactions[Index];
    if Promise.State = psFulfilled then
      R.EnqueueJob(@FulfillReactionJob, Reaction.OnFulfilled, Promise.Value, Reaction.Resolve, Reaction.Reject)
    else
      R.EnqueueJob(@RejectReactionJob, Reaction.OnRejected, Promise.Value, Reaction.Resolve, Reaction.Reject);
  end;
  Promise.Reactions := nil;
  Promise.ReactionCount := 0;
end;

procedure FulfillPromise(R: TJsRealm; Promise: TJsPromise; Value: TJsValue);
begin
  if Promise.State <> psPending then
    Exit;
  Promise.State := psFulfilled;
  Promise.Value := Value;
  TriggerReactions(R, Promise);
end;

procedure RejectPromise(R: TJsRealm; Promise: TJsPromise; Reason: TJsValue);
begin
  if Promise.State <> psPending then
    Exit;
  Promise.State := psRejected;
  Promise.Value := Reason;
  if not Promise.IsHandled and Assigned(JsRejectionTracker) then
    JsRejectionTracker(R, Promise, False);
  TriggerReactions(R, Promise);
end;

procedure ResolvePromise(R: TJsRealm; Promise: TJsPromise; Resolution: TJsValue);
var
  Then_, Reason: TJsValue;
begin
  if Resolution = JsObjectValue(Promise) then
  begin
    RejectPromise(R, Promise, JsObjectValue(R.NewError(ekType, 'Chaining cycle detected for promise')));
    Exit;
  end;
  if not JsIsObject(Resolution) then
  begin
    FulfillPromise(R, Promise, Resolution);
    Exit;
  end;
  { A promise of ours with the original then: its state can be adopted
    through a reaction without calling into JavaScript. }
  Then_ := JsAsObject(Resolution).GetValue(R, R.Atom(anThen));
  if Then_ = JsException then
  begin
    Reason := R.Runtime.TakeException;
    RejectPromise(R, Promise, Reason);
    Exit;
  end;
  if not JsIsCallable(Then_) then
  begin
    FulfillPromise(R, Promise, Resolution);
    Exit;
  end;
  R.EnqueueJob(@ResolveThenableJob, JsObjectValue(Promise), Resolution, Then_, JsUndefined);
end;

procedure PerformPromiseThen(R: TJsRealm; Promise: TJsPromise; OnFulfilled, OnRejected: TJsValue;
  ResultPromise, ResultResolve, ResultReject: TJsValue);
var
  Reaction: TJsPromiseReaction;
begin
  if not JsIsCallable(OnFulfilled) then
    OnFulfilled := JsUndefined;
  if not JsIsCallable(OnRejected) then
    OnRejected := JsUndefined;
  Reaction.OnFulfilled := OnFulfilled;
  Reaction.OnRejected := OnRejected;
  Reaction.Promise := ResultPromise;
  Reaction.Resolve := ResultResolve;
  Reaction.Reject := ResultReject;
  case Promise.State of
    psPending:
      begin
        if Promise.ReactionCount >= Length(Promise.Reactions) then
          SetLength(Promise.Reactions, Length(Promise.Reactions) * 2 + 2);
        Promise.Reactions[Promise.ReactionCount] := Reaction;
        Inc(Promise.ReactionCount);
      end;
    psFulfilled:
      R.EnqueueJob(@FulfillReactionJob, OnFulfilled, Promise.Value, ResultResolve, ResultReject);
    psRejected:
      begin
        if not Promise.IsHandled and Assigned(JsRejectionTracker) then
          JsRejectionTracker(R, Promise, True);
        R.EnqueueJob(@RejectReactionJob, OnRejected, Promise.Value, ResultResolve, ResultReject);
      end;
  end;
  Promise.IsHandled := True;
end;

function PromiseResolveIntrinsic(R: TJsRealm; Value: TJsValue): TJsPromise;
var
  Constructor_: TJsValue;
begin
  if JsIsPromise(Value) then
  begin
    Constructor_ := JsAsObject(Value).GetValue(R, R.ConstructorKey);
    if Constructor_ = JsException then
      Exit(nil);
    if Constructor_ = JsObjectValue(R.Intrinsics[inPromise]) then
      Exit(TJsPromise(JsAsObject(Value)));
  end;
  Result := NewPromise(R);
  ResolvePromise(R, Result, Value);
end;

end.
