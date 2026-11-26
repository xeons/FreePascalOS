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
  Work for a script context from elsewhere: another context's task (a
  message through a link, a service worker's event), a worker agent, a
  registry. PostToContext runs a procedure in a later task of the
  context's own event loop (its document's loop; posted, so that a loop
  driven by another GUI message is woken), only if the context is still
  alive then; the data object belongs to the task and is freed after it
  ran or when it never runs.

  Also the facts about a context the worker units need: its loop, its
  document's fetch client, origin and URL; and hooks run when a context
  goes.
}
unit Web.Script.ContextTasks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.EventLoop,
  Web.Fetch.Requests,
  Web.Bindings.Context;

type
  TContextTaskProcedure = procedure(Context: TBindingContext; Data: TObject);

{ False when the context has no loop (nothing will run; Data is freed). }
function PostToContext(Context: TBindingContext; Routine: TContextTaskProcedure; Data: TObject): Boolean;
{ The context exists and is open (neither going nor closed). }
function ContextIsLive(Context: TBindingContext): Boolean;
{ Starts tracking a context (PostToContext and the origin functions do). }
procedure KnowContext(Context: TBindingContext);
function ContextLoop(Context: TBindingContext): TEventLoop;
function ContextFetchClient(Context: TBindingContext): TFetchClient;
{ The serialization of the context's document's origin ('null' when
  opaque). }
function ContextOriginText(Context: TBindingContext): string;
{ The URL of the context's document. }
function ContextUrlText(Context: TBindingContext): string;
{ Called when a known context goes. }
procedure AddContextEndHook(Hook: TContextGoingHook);

implementation

uses
  Url.Origins,
  Web.EventLoop.Tasks,
  Web.Origins,
  Web.Loading.Contexts;

type
  TContextTask = class
  public
    Context: TBindingContext;
    Routine: TContextTaskProcedure;
    Data: TObject;
    destructor Destroy; override;
  end;

  TContextTaskRunner = class
  public
    procedure Run(Data: TObject);
  end;

var
  KnownContexts: TList;
  Runner: TContextTaskRunner;
  EndHooks: array of TContextGoingHook;

destructor TContextTask.Destroy;
begin
  Data.Free;
  inherited Destroy;
end;

procedure TContextTaskRunner.Run(Data: TObject);
var
  Task: TContextTask;
begin
  Task := TContextTask(Data);
  if ContextIsLive(Task.Context) then
    Task.Routine(Task.Context, Task.Data);
end;

procedure ContextGoing(Context: TBindingContext);
var
  Index: Integer;
begin
  if (KnownContexts = nil) or (KnownContexts.IndexOf(Context) < 0) then
    Exit;
  KnownContexts.Remove(Context);
  for Index := 0 to High(EndHooks) do
    EndHooks[Index](Context);
end;

procedure AddContextEndHook(Hook: TContextGoingHook);
begin
  SetLength(EndHooks, Length(EndHooks) + 1);
  EndHooks[High(EndHooks)] := Hook;
end;

procedure KnowContext(Context: TBindingContext);
begin
  if (Context <> nil) and not Context.Destroying and (KnownContexts.IndexOf(Context) < 0) then
    KnownContexts.Add(Context);
end;

function ContextIsLive(Context: TBindingContext): Boolean;
begin
  Result := (Context <> nil) and (KnownContexts.IndexOf(Context) >= 0) and not Context.Destroying and
    not Context.Closed;
end;

function LoaderOfContext(Context: TBindingContext): TLoadingContext;
var
  Found: TObject;
begin
  Result := nil;
  if (Context = nil) or (Context.Environment = nil) then
    Exit;
  Found := Context.Environment.LoadingContextOf(Context);
  if Found is TLoadingContext then
    Result := TLoadingContext(Found);
end;

function ContextLoop(Context: TBindingContext): TEventLoop;
var
  Loader: TLoadingContext;
begin
  Loader := LoaderOfContext(Context);
  if Loader = nil then
    Exit(nil);
  Result := Loader.Loop;
end;

function ContextFetchClient(Context: TBindingContext): TFetchClient;
var
  Loader: TLoadingContext;
begin
  Loader := LoaderOfContext(Context);
  if Loader = nil then
    Exit(nil);
  Result := Loader.Client;
end;

function ContextOriginText(Context: TBindingContext): string;
var
  Origin: TUrlOrigin;
begin
  KnowContext(Context);
  Origin := DocumentOrigin(Context.Document);
  if Origin.Opaque then
    Result := 'null'
  else
    Result := SerializeOrigin(Origin);
end;

function ContextUrlText(Context: TBindingContext): string;
begin
  Result := Context.Document.Url;
end;

function PostToContext(Context: TBindingContext; Routine: TContextTaskProcedure; Data: TObject): Boolean;
var
  Loop: TEventLoop;
  Task: TContextTask;
begin
  Loop := nil;
  if (Context <> nil) and not Context.Destroying and not Context.Closed then
    Loop := ContextLoop(Context);
  if Loop = nil then
  begin
    Data.Free;
    Exit(False);
  end;
  KnowContext(Context);
  Task := TContextTask.Create;
  Task.Context := Context;
  Task.Routine := Routine;
  Task.Data := Data;
  Loop.PostMethod(@Runner.Run, Task, TaskSourcePostedMessage, nil);
  Result := True;
end;

initialization
  KnownContexts := TList.Create;
  Runner := TContextTaskRunner.Create;
  AddContextGoingHook(@ContextGoing);
finalization
  FreeAndNil(KnownContexts);
  FreeAndNil(Runner);
end.
