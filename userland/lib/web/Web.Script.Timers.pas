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
  The window's map of active timers (HTML Standard 8.6): setTimeout and
  setInterval keep the handler (a function with its arguments, or a
  string compiled when the timer fires) under an id and ask the
  environment to call FireTimer after the timeout; clearTimeout and
  clearInterval forget it. Nested timers more than five deep wait at
  least 4 ms, as the standard says. The handlers are marked by a root
  provider while their timers are active.
}
unit Web.Script.Timers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Web.Bindings.Context;

type
  TScriptTimer = record
    Id: Integer;
    Handler: TJsValue;
    Arguments: TJsValueList;
    Timeout: Integer;
    Repeating: Boolean;
    NestingLevel: Integer;
  end;

  TScriptTimers = class
  private
    FContext: TBindingContext;
    FTimers: array of TScriptTimer;
    FNextId: Integer;
    FNestingLevel: Integer;
    procedure MarkRoots(Tracer: TJsTracer);
    function IndexOf(Id: Integer): Integer;
  public
    constructor Create(Context: TBindingContext);
    destructor Destroy; override;
    function Start(Handler: TJsValue; Timeout: Integer; const Arguments: TJsValueList; Repeating: Boolean): Integer;
    procedure Clear(Id: Integer);
    { The environment's call when a timer is due. }
    procedure Fire(Id: Integer);
    function ActiveCount: Integer;
  end;

function TimersOf(Context: TBindingContext): TScriptTimers;

implementation

uses
  Js.Objects,
  Web.Fetch.Requests,
  Web.Fetch.CspChecks,
  Js.Functions,
  Web.Bindings.UrlResolution;

function TimersOf(Context: TBindingContext): TScriptTimers;
begin
  if Context.Timers = nil then
    Context.Timers := TScriptTimers.Create(Context);
  Result := TScriptTimers(Context.Timers);
end;

constructor TScriptTimers.Create(Context: TBindingContext);
begin
  inherited Create;
  FContext := Context;
  FContext.Engine.Runtime.Heap.AddRootProvider(@MarkRoots);
end;

destructor TScriptTimers.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FTimers) do
    FContext.Environment.StopTimer(FContext, FTimers[Index].Id);
  if FContext.Engine <> nil then
    FContext.Engine.Runtime.Heap.RemoveRootProvider(@MarkRoots);
  inherited Destroy;
end;

procedure TScriptTimers.MarkRoots(Tracer: TJsTracer);
var
  Index: Integer;
begin
  for Index := 0 to High(FTimers) do
  begin
    Tracer.MarkValue(FTimers[Index].Handler);
    if Length(FTimers[Index].Arguments) > 0 then
      Tracer.MarkValues(@FTimers[Index].Arguments[0], Length(FTimers[Index].Arguments));
  end;
end;

function TScriptTimers.IndexOf(Id: Integer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FTimers) do
    if FTimers[Index].Id = Id then
      Exit(Index);
  Result := -1;
end;

function TScriptTimers.Start(Handler: TJsValue; Timeout: Integer; const Arguments: TJsValueList;
  Repeating: Boolean): Integer;
var
  Timer: TScriptTimer;
begin
  Inc(FNextId);
  if Timeout < 0 then
    Timeout := 0;
  if (FNestingLevel > 5) and (Timeout < 4) then
    Timeout := 4;
  Timer.Id := FNextId;
  Timer.Handler := Handler;
  Timer.Arguments := Copy(Arguments);
  Timer.Timeout := Timeout;
  Timer.Repeating := Repeating;
  Timer.NestingLevel := FNestingLevel + 1;
  SetLength(FTimers, Length(FTimers) + 1);
  FTimers[High(FTimers)] := Timer;
  FContext.Environment.StartTimer(FContext, Timer.Id, Timeout, Repeating);
  Result := Timer.Id;
end;

procedure TScriptTimers.Clear(Id: Integer);
var
  Index: Integer;
begin
  Index := IndexOf(Id);
  if Index < 0 then
    Exit;
  FContext.Environment.StopTimer(FContext, Id);
  FTimers[Index] := FTimers[High(FTimers)];
  SetLength(FTimers, High(FTimers));
end;

procedure TScriptTimers.Fire(Id: Integer);
var
  Index, Mark, Position: Integer;
  Timer: TScriptTimer;
  Ignored: TJsValue;
  Source, ErrorText: string;
  SavedNesting: Integer;
begin
  Index := IndexOf(Id);
  if Index < 0 then
    Exit;
  Timer := FTimers[Index];
  if not Timer.Repeating then
  begin
    FTimers[Index] := FTimers[High(FTimers)];
    SetLength(FTimers, High(FTimers));
  end;
  SavedNesting := FNestingLevel;
  FNestingLevel := Timer.NestingLevel;
  Mark := FContext.Engine.Runtime.PushRoot(Timer.Handler);
  try
    for Position := 0 to High(Timer.Arguments) do
      FContext.Engine.Runtime.PushRoot(Timer.Arguments[Position]);
    if JsIsCallable(Timer.Handler) then
      FContext.CallFunction(Timer.Handler, JsObjectValue(FContext.Engine.GlobalObject), Timer.Arguments, Ignored, 'timer')
    else
    begin
      Source := FContext.Engine.ToText(Timer.Handler);
      { A string handler is compiled only where CSP allows eval. }
      if CspBlocksEval(TFetchClient(FContext.Document.SecurityPolicy), Source) then
      begin
        FContext.Console('error', 'Refused to evaluate a string as JavaScript because ''unsafe-eval'' is not an ' +
          'allowed source of script in the Content Security Policy');
        Exit;
      end;
      FContext.EnterScript;
      try
        if not FContext.Engine.TryEvaluate(Source, DocumentUrlText(FContext.Document) + ' (timer)', Ignored,
          ErrorText) then
          FContext.Console('error', 'Uncaught ' + ErrorText);
      finally
        FContext.LeaveScript;
      end;
    end;
  finally
    FContext.Engine.Runtime.PopRoots(Mark);
    FNestingLevel := SavedNesting;
  end;
end;

function TScriptTimers.ActiveCount: Integer;
begin
  Result := Length(FTimers);
end;

end.
