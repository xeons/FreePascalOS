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
  Generator and async generator objects: next, return and throw.

  A generator resumes its suspended frame (Js.Interpreter) and wraps
  what it yields in an iterator result; inside yield* the inner
  iterator's results are handed on as they are.

  An async generator keeps a queue of requests, each with the promise
  its caller got. The driver resumes the frame for the request at the
  head; a yield settles that request and goes on with the next one, an
  await leaves the driver waiting until the awaited promise resumes the
  frame, and completion or an exception settles the rest of the queue.
}
unit Js.Builtins.Generators;

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

procedure InstallGenerators(R: TJsInterpreterRealm);

implementation

function ThisGenerator(R: TJsRealm; Value: TJsValue; AClass: TJsObjectClass; out Generator: TJsSuspension): Boolean;
begin
  Generator := nil;
  if not JsIsObject(Value) or (JsAsObject(Value).ObjectClass <> AClass) or
    not (JsAsObject(Value) is TJsSuspension) then
  begin
    R.ThrowTypeError('next method called on incompatible receiver ' + ValueToPascal(R, Value));
    Exit(False);
  end;
  Generator := TJsSuspension(JsAsObject(Value));
  Result := True;
end;

{ next (0), throw (1), return (2) }
function GeneratorResume(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Generator: TJsSuspension;
  Realm: TJsInterpreterRealm;
  Value, Outcome: TJsValue;
  Kind: Integer;
begin
  if not ThisGenerator(R, This, ocGenerator, Generator) then
    Exit(JsException);
  Realm := TJsInterpreterRealm(R);
  Kind := Callee.Magic;
  Value := Arg(Args, ArgCount, 0);
  case Generator.State of
    ssExecuting:
      Exit(R.ThrowTypeError('Generator is already running'));
    ssCompleted:
      case Kind of
        ResumeNext: Exit(CreateIterResult(R, JsUndefined, True));
        ResumeThrow: Exit(R.Throw(Value));
      else
        Exit(CreateIterResult(R, Value, True));
      end;
    ssSuspendedStart:
      if Kind <> ResumeNext then
      begin
        Generator.State := ssCompleted;
        if Kind = ResumeThrow then
          Exit(R.Throw(Value));
        Exit(CreateIterResult(R, Value, True));
      end;
  end;
  Outcome := Realm.ResumeSuspension(Generator, Kind, Value);
  if Outcome = JsException then
    Exit(JsException);
  if Realm.LastExitSuspended then
  begin
    if Generator.Delegating then
      Exit(Outcome);
    Exit(CreateIterResult(R, Outcome, False));
  end;
  Result := CreateIterResult(R, Outcome, True);
end;

{ Async generators }

const
  RequestKind = 0;
  RequestValue = 1;
  RequestPromise = 2;

procedure ResolveRequest(R: TJsRealm; Request: TJsObject; Value: TJsValue; Done: Boolean);
begin
  ResolvePromise(R, TJsPromise(JsAsObject(Request.Elements^[RequestPromise])), CreateIterResult(R, Value, Done));
end;

procedure RejectRequest(R: TJsRealm; Request: TJsObject; Reason: TJsValue);
begin
  RejectPromise(R, TJsPromise(JsAsObject(Request.Elements^[RequestPromise])), Reason);
end;

function QueueOf(Generator: TJsSuspension): TJsArray;
begin
  Result := TJsArray(JsAsObject(Generator.Queue));
end;

function Dequeue(Generator: TJsSuspension): TJsObject;
var
  Queue: TJsArray;
begin
  Queue := QueueOf(Generator);
  Result := JsAsObject(Queue.Elements^[0]);
  if Queue.ElementCount > 1 then
    Move(Queue.Elements^[1], Queue.Elements^[0], (Queue.ElementCount - 1) * SizeOf(TJsValue));
  Dec(Queue.ElementCount);
  Queue.ArrayLength := Queue.ElementCount;
end;

procedure DrainNext(R: TJsRealm; Generator: TJsSuspension); forward;

{ What the frame did after a resumption. }
procedure HandleOutcome(R: TJsRealm; Generator: TJsSuspension; Outcome: TJsValue);
var
  Realm: TJsInterpreterRealm;
  Request: TJsObject;
  Reason: TJsValue;
begin
  Realm := TJsInterpreterRealm(R);
  if QueueOf(Generator).ElementCount = 0 then
    Exit;
  if Outcome = JsException then
  begin
    if R.Runtime.Terminating then
      Exit;
    Reason := R.Runtime.TakeException;
    Generator.State := ssCompleted;
    Request := Dequeue(Generator);
    RejectRequest(R, Request, Reason);
    DrainNext(R, Generator);
    Exit;
  end;
  if Realm.LastExitSuspended then
  begin
    if Generator.Awaiting then
      Exit;
    Request := Dequeue(Generator);
    ResolveRequest(R, Request, Outcome, False);
    DrainNext(R, Generator);
    Exit;
  end;
  Generator.State := ssCompleted;
  Request := Dequeue(Generator);
  ResolveRequest(R, Request, Outcome, True);
  DrainNext(R, Generator);
end;

{ Serves queued requests while the generator is not running. }
procedure DrainNext(R: TJsRealm; Generator: TJsSuspension);
var
  Queue: TJsArray;
  Request: TJsObject;
  Kind: Integer;
  Value, Outcome: TJsValue;
  Mark: Integer;
begin
  Queue := QueueOf(Generator);
  while (Queue.ElementCount > 0) and (Generator.State <> ssExecuting) and not Generator.Awaiting do
  begin
    Request := JsAsObject(Queue.Elements^[0]);
    Kind := JsAsInteger(Request.Elements^[RequestKind]);
    Value := Request.Elements^[RequestValue];
    if (Generator.State = ssSuspendedStart) and (Kind <> ResumeNext) then
      Generator.State := ssCompleted;
    if Generator.State = ssCompleted then
    begin
      Dequeue(Generator);
      case Kind of
        ResumeNext: ResolveRequest(R, Request, JsUndefined, True);
        ResumeThrow: RejectRequest(R, Request, Value);
      else
        ResolveRequest(R, Request, Value, True);
      end;
      Continue;
    end;
    Mark := R.Runtime.PushRoot(JsObjectValue(Request));
    Outcome := TJsInterpreterRealm(R).ResumeSuspension(Generator, Kind, Value);
    R.Runtime.PopRoots(Mark);
    HandleOutcome(R, Generator, Outcome);
    Exit;
  end;
end;

{ next (0), throw (1), return (2): a promise of the result. }
function AsyncGeneratorEnqueue(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Generator: TJsSuspension;
  Promise: TJsPromise;
  Request: TJsArray;
  Queue: TJsArray;
  Reason: TJsValue;
begin
  Promise := NewPromise(R);
  Result := JsObjectValue(Promise);
  if not JsIsObject(This) or (JsAsObject(This).ObjectClass <> ocAsyncGenerator) then
  begin
    Reason := JsObjectValue(R.NewError(ekType, 'AsyncGenerator method called on incompatible receiver'));
    RejectPromise(R, Promise, Reason);
    Exit;
  end;
  Generator := TJsSuspension(JsAsObject(This));
  Request := R.NewArray(0);
  Request.CreateDataProperty(R, JsInteger(RequestKind), JsInteger(Callee.Magic));
  Request.CreateDataProperty(R, JsInteger(RequestValue), Arg(Args, ArgCount, 0));
  Request.CreateDataProperty(R, JsInteger(RequestPromise), Result);
  Queue := QueueOf(Generator);
  Queue.CreateDataProperty(R, JsInteger(Queue.ArrayLength), JsObjectValue(Request));
  if (Generator.State <> ssExecuting) and not Generator.Awaiting then
    DrainNext(R, Generator);
end;

{ An awaited promise settled (Magic: next or throw): resume. }
function AsyncGeneratorAwaitResume(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Generator: TJsSuspension;
  Outcome: TJsValue;
begin
  Generator := TJsSuspension(JsAsObject(This));
  Outcome := TJsInterpreterRealm(R).ResumeSuspension(Generator, Callee.Magic, Arg(Args, ArgCount, 0));
  HandleOutcome(R, Generator, Outcome);
  Result := JsUndefined;
end;

procedure SetUpAsyncGenerator(R: TJsRealm; Suspension: TJsSuspension);
begin
  Suspension.Queue := JsObjectValue(R.NewArray(0));
  Suspension.ResolveFunction := JsObjectValue(NewNativeFunctionWithKey(R, R.Atom(anEmpty),
    @AsyncGeneratorAwaitResume, 1, ResumeNext));
  Suspension.RejectFunction := JsObjectValue(NewNativeFunctionWithKey(R, R.Atom(anEmpty),
    @AsyncGeneratorAwaitResume, 1, ResumeThrow));
end;

procedure InstallGenerators(R: TJsInterpreterRealm);
var
  Prototype, FunctionPrototype: TJsObject;
begin
  Prototype := R.Intrinsics[inGeneratorPrototype];
  FunctionPrototype := R.Intrinsics[inGeneratorFunctionPrototype];
  DefineMethod(R, Prototype, 'next', @GeneratorResume, 1, ResumeNext);
  DefineMethod(R, Prototype, 'return', @GeneratorResume, 1, ResumeReturn);
  DefineMethod(R, Prototype, 'throw', @GeneratorResume, 1, ResumeThrow);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('Generator'), PropertyConfigurable);
  Prototype.DefineData(R, R.ConstructorKey, JsObjectValue(FunctionPrototype), PropertyConfigurable);
  FunctionPrototype.DefineData(R, R.PrototypeKey, JsObjectValue(Prototype), PropertyConfigurable);
  FunctionPrototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('GeneratorFunction'),
    PropertyConfigurable);

  Prototype := R.Intrinsics[inAsyncGeneratorPrototype];
  FunctionPrototype := R.Intrinsics[inAsyncGeneratorFunctionPrototype];
  DefineMethod(R, Prototype, 'next', @AsyncGeneratorEnqueue, 1, ResumeNext);
  DefineMethod(R, Prototype, 'return', @AsyncGeneratorEnqueue, 1, ResumeReturn);
  DefineMethod(R, Prototype, 'throw', @AsyncGeneratorEnqueue, 1, ResumeThrow);
  Prototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('AsyncGenerator'), PropertyConfigurable);
  Prototype.DefineData(R, R.ConstructorKey, JsObjectValue(FunctionPrototype), PropertyConfigurable);
  FunctionPrototype.DefineData(R, R.PrototypeKey, JsObjectValue(Prototype), PropertyConfigurable);
  FunctionPrototype.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('AsyncGeneratorFunction'),
    PropertyConfigurable);
  R.Intrinsics[inAsyncFunctionPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('AsyncFunction'), PropertyConfigurable);
  JsAsyncGeneratorCreated := @SetUpAsyncGenerator;
end;

end.
