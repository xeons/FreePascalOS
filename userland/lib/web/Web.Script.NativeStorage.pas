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
  The natives behind IndexedDB, the Cache API and navigator.storage
  (platform/80-*.js to 86-*.js):

    natives.idbAccess()            0 no storage service, 1 allowed,
                                   2 denied (an opaque origin)
    natives.idbExecute(bytes)      the service's reply (a Uint8Array) to
                                   a request (Web.IndexedDb.Wire), for
                                   the context's origin; null when there
                                   is no service
    natives.queueTask(id)          true: natives.onQueuedTask(id) runs in
                                   a task of its own soon (false: use a
                                   timer)
    natives.requestCheckpointCleanup()
                                   natives.onCheckpointCleanup() runs at
                                   the end of the next microtask
                                   checkpoint
    natives.reportedErrors()       how many uncaught exceptions the
                                   context reported so far (did an
                                   event's listeners throw)
    natives.setEventParent(target, parent)
                                   events at target go on to parent (both
                                   EventTargets made by platform scripts)

  The environment calls natives.onIndexedDbNotice(bytes) for a notice
  of the service (a versionchange for one of the context's connections).
}
unit Web.Script.NativeStorage;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineStorageNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Web.Dom.Events,
  Web.Bindings.Types,
  Web.Bindings.Listeners;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function NativeAccess(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  Result := JsInteger(Context.Environment.IndexedDbAccess(Context));
end;

function NativeExecute(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Data: PByte;
  Length_: SizeInt;
  Request, Reply: TBytes;
begin
  Context := ContextOfRealm(R);
  Request := nil;
  if Context.Engine.BufferSourceData(Arg(Args, ArgCount, 0), Data, Length_) and (Length_ > 0) then
  begin
    SetLength(Request, Length_);
    Move(Data^, Request[0], Length_);
  end;
  try
    if not Context.Environment.IndexedDbExecute(Context, Request, Reply) or (Length(Reply) = 0) then
      Exit(JsNull);
  except
    on Error: Exception do
      Exit(Context.ThrowFromException(Error));
  end;
  Result := Context.Engine.NewUint8Array(@Reply[0], Length(Reply));
end;

function NativeQueueTask(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  Result := JsBoolean(Context.Environment.QueueScriptTask(Context,
    Trunc(Context.Engine.ToNumber(Arg(Args, ArgCount, 0)))));
end;

function NativeRequestCleanup(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  ContextOfRealm(R).RequestCheckpointCleanup;
  Result := JsUndefined;
end;

function NativeSetEventParent(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Target, Parent: TObject;
begin
  Context := ContextOfRealm(R);
  Target := Context.Unwrap(Arg(Args, ArgCount, 0), InterfaceEventTarget);
  Parent := Context.Unwrap(Arg(Args, ArgCount, 1), InterfaceEventTarget);
  if (Target is TStandaloneEventTarget) and not (Target is TWindowTarget) and
    ((Parent = nil) or (Parent is TStandaloneEventTarget)) then
    TStandaloneEventTarget(Target).EventParent := TEventTarget(Parent);
  Result := JsUndefined;
end;

function NativeReportedErrors(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsInteger(ContextOfRealm(R).ReportedExceptions);
end;

procedure DefineStorageNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'reportedErrors', @NativeReportedErrors, 0, 0);
  Context.Engine.DefineFunction(Natives, 'idbAccess', @NativeAccess, 0, 0);
  Context.Engine.DefineFunction(Natives, 'idbExecute', @NativeExecute, 1, 0);
  Context.Engine.DefineFunction(Natives, 'queueTask', @NativeQueueTask, 1, 0);
  Context.Engine.DefineFunction(Natives, 'requestCheckpointCleanup', @NativeRequestCleanup, 0, 0);
  Context.Engine.DefineFunction(Natives, 'setEventParent', @NativeSetEventParent, 2, 0);
end;

end.
