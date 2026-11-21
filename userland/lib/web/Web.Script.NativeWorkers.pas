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
  The natives behind dedicated workers (platform/65-workers.js): a
  worker's global scope is a bare realm of the window's runtime (its
  own built-ins, no DOM), on the window's thread - its scripts run in
  tasks between the page's, its jobs at the window's microtask
  checkpoints (TBindingContext.WorkerEngines).

    natives.workerRealm()                  the new realm's global object
    natives.workerEvaluate(global, source, url)
                                           runs a script there: undefined,
                                           or the uncaught error's text
    natives.workerClose(global)            the realm stops (terminate())
}
unit Web.Script.NativeWorkers;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineWorkerNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Js.Values,
  Js.Functions,
  Js.Engine;

const
  { At most this many worker realms per window (each costs its built-ins). }
  MaximumWorkers = 32;
  WorkerStackCapacity = 64 * 1024;
  WorkerMaximumFrames = 2000;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function WorkerIndexOf(Context: TBindingContext; Global: TJsValue): Integer;
var
  Index: Integer;
begin
  if JsIsObject(Global) then
    for Index := 0 to High(Context.WorkerEngines) do
      if JsObjectValue(Context.WorkerEngines[Index].GlobalObject) = Global then
        Exit(Index);
  Result := -1;
end;

function NativeWorkerRealm(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Options: TJsEngineOptions;
  Engine: TJsEngine;
begin
  Context := ContextOfRealm(R);
  if Length(Context.WorkerEngines) >= MaximumWorkers then
    Exit(Context.ThrowDomException('QuotaExceededError', 'Too many workers'));
  Options := TJsEngine.DefaultOptions;
  Options.StackCapacity := WorkerStackCapacity;
  Options.MaximumFrames := WorkerMaximumFrames;
  Engine := TJsEngine.CreateSharing(Context.Engine, Options);
  SetLength(Context.WorkerEngines, Length(Context.WorkerEngines) + 1);
  Context.WorkerEngines[High(Context.WorkerEngines)] := Engine;
  Result := JsObjectValue(Engine.GlobalObject);
end;

function NativeWorkerEvaluate(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Index: Integer;
  Value: TJsValue;
  ErrorText: string;
begin
  Context := ContextOfRealm(R);
  Index := WorkerIndexOf(Context, Arg(Args, ArgCount, 0));
  if Index < 0 then
    Exit(Context.TextValue('not a worker'));
  if Context.WorkerEngines[Index].TryEvaluate(Context.Engine.ToText(Arg(Args, ArgCount, 1)),
     Context.Engine.ToText(Arg(Args, ArgCount, 2)), Value, ErrorText) then
    Result := JsUndefined
  else
    Result := Context.TextValue(ErrorText);
end;

function NativeWorkerClose(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Index: Integer;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  Index := WorkerIndexOf(Context, Arg(Args, ArgCount, 0));
  if Index < 0 then
    Exit;
  { Its roots stop; the engine goes with the window (what script kept of
    it still works). }
  Context.WorkerEngines[Index].Detach;
end;

procedure DefineWorkerNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'workerRealm', @NativeWorkerRealm, 0);
  Context.Engine.DefineFunction(Natives, 'workerEvaluate', @NativeWorkerEvaluate, 3);
  Context.Engine.DefineFunction(Natives, 'workerClose', @NativeWorkerClose, 1);
end;

end.
