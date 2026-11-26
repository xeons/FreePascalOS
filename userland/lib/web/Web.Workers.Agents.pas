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
  Worker agents: where a shared worker or a service worker runs. Such a
  worker belongs to no one page (several pages share it; it outlives
  the page that started it), so it gets a host of its own: an event
  loop, a fetcher over the starting page's network context and a
  window-less navigable whose document - empty, at the worker script's
  URL, so of the worker's origin - is scripted like a page's. The worker
  global scope is a realm in that window's runtime
  (platform/65-workers.js makes it, as for a dedicated worker), so its
  timers, fetch, crypto and messaging are the host window's.

  The agent's loop is a satellite (Web.EventLoop): whatever drives the
  process's pages drives it. An agent is never freed inside one of its
  own tasks: Retire hides it from everyone and the satellite reaper
  frees it before the next satellite task, and an agent whose network
  context goes is freed then.

  The console of every agent goes to AgentConsole (when set).
}
unit Web.Workers.Agents;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Web.EventLoop,
  Web.Fetch.Fetcher,
  Web.Fetch.NetworkContexts,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Bindings.Context,
  Web.IndexedDb.Service,
  Web.Script.PageScripting;

type
  TWorkerAgent = class;

  TAgentConsoleEvent = procedure(Agent: TWorkerAgent; const Level, Text: string) of object;
  { Told before an agent is freed (its context still exists). }
  TAgentRetiredEvent = procedure(Agent: TWorkerAgent) of object;

  TWorkerAgent = class
  private
    FLoop: TEventLoop;
    FFetcher: TFetcher;
    FSink: TNullResourceSink;
    FNavigable: TNavigable;
    FExecutor: TPageScriptExecutor;
    FNetwork: TNetworkContext;
    FScriptUrl: string;
    FRetired: Boolean;
    FOnRetired: TAgentRetiredEvent;
    procedure ConsoleMessage(const Level, Text: string);
  public
    { Tag: what the owner keeps with the agent (its worker record). }
    Tag: TObject;
    { StorageBackend: the starting page's storage service (its
      environment's SharedStorageBackend; nil: one of the agent's own). }
    constructor Create(Network: TNetworkContext; constref ScriptUrl: TUrlRecord; const UserAgent: string;
      StorageBackend: TObject);
    destructor Destroy; override;
    { The host window's context (nil once retired or if it failed). }
    function Context: TBindingContext;
    { The agent stops: no more tasks run; freed soon (above). }
    procedure Retire;
    property Loop: TEventLoop read FLoop;
    property Network: TNetworkContext read FNetwork;
    property ScriptUrl: string read FScriptUrl;
    property Retired: Boolean read FRetired;
    property OnRetired: TAgentRetiredEvent read FOnRetired write FOnRetired;
  end;

var
  { Where agents' console messages go (nil: nowhere). }
  AgentConsole: TAgentConsoleEvent;
  { Told when a network context goes, after its agents went (the
    service worker registry forgets it). }
  AfterNetworkGone: TNetworkContextGoingHook;

{ The live agents (tests check that none is left). }
function LiveAgentCount: Integer;
{ Frees every agent at once (a test's end, a process shutting down). }
procedure RetireAllAgents;

implementation

const
  AgentDocument = '<!DOCTYPE html><html><head><title>worker</title></head><body></body></html>';

var
  Agents: TList;
  Retiring: TList;
  Reaping: Boolean;

constructor TWorkerAgent.Create(Network: TNetworkContext; constref ScriptUrl: TUrlRecord; const UserAgent: string;
  StorageBackend: TObject);
begin
  inherited Create;
  FNetwork := Network;
  FScriptUrl := SerializeUrl(ScriptUrl);
  FLoop := TEventLoop.Create;
  FLoop.MakeSatellite;
  FFetcher := TFetcher.Create(FLoop, Network);
  FSink := TNullResourceSink.Create;
  FNavigable := TNavigable.Create(FFetcher, FSink, DefaultLoadingSettings);
  FExecutor := TPageScriptExecutor.Create(FNavigable);
  if UserAgent <> '' then
    FExecutor.Environment.UserAgentText := UserAgent;
  FExecutor.OnConsoleMessage := @ConsoleMessage;
  FExecutor.Environment.WorkerAgent := True;
  if StorageBackend is TIndexedDbBackend then
    FExecutor.Environment.IndexedDb := TIndexedDbBackend(StorageBackend);
  FNavigable.Executor := FExecutor;
  Agents.Add(Self);
  FNavigable.LoadHtml(AgentDocument, ScriptUrl);
end;

destructor TWorkerAgent.Destroy;
begin
  Agents.Remove(Self);
  Retiring.Remove(Self);
  if Assigned(FOnRetired) then
  begin
    FOnRetired(Self);
    FOnRetired := nil;
  end;
  FExecutor.Shutdown;
  FNavigable.Free;
  FExecutor.Free;
  FSink.Free;
  FFetcher.Free;
  FLoop.Free;
  inherited Destroy;
end;

procedure TWorkerAgent.ConsoleMessage(const Level, Text: string);
begin
  if Assigned(AgentConsole) then
    AgentConsole(Self, Level, Text);
end;

function TWorkerAgent.Context: TBindingContext;
begin
  if FRetired or (FNavigable.ActiveDocument = nil) then
    Exit(nil);
  Result := FExecutor.ContextOf(FNavigable.ActiveDocument);
end;

procedure TWorkerAgent.Retire;
begin
  if FRetired then
    Exit;
  if Assigned(FOnRetired) then
  begin
    FOnRetired(Self);
    FOnRetired := nil;
  end;
  FRetired := True;
  FExecutor.Shutdown;
  Retiring.Add(Self);
  { A primary takes the chance to free it. }
  FLoop.Wake;
end;

procedure ReapAgents;
begin
  if Reaping or (Retiring.Count = 0) then
    Exit;
  Reaping := True;
  try
    while Retiring.Count > 0 do
      TWorkerAgent(Retiring[0]).Free;
  finally
    Reaping := False;
  end;
end;

procedure NetworkGoing(Network: TNetworkContext);
var
  Index: Integer;
begin
  ReapAgents;
  for Index := Agents.Count - 1 downto 0 do
    if (Index < Agents.Count) and (TWorkerAgent(Agents[Index]).Network = Network) then
      TWorkerAgent(Agents[Index]).Free;
  if Assigned(AfterNetworkGone) then
    AfterNetworkGone(Network);
end;

function LiveAgentCount: Integer;
begin
  Result := Agents.Count - Retiring.Count;
end;

procedure RetireAllAgents;
begin
  while Agents.Count > 0 do
    TWorkerAgent(Agents[Agents.Count - 1]).Free;
end;

initialization
  Agents := TList.Create;
  Retiring := TList.Create;
  SatelliteReaper := @ReapAgents;
  NetworkContextGoingHook := @NetworkGoing;
finalization
  RetireAllAgents;
  FreeAndNil(Agents);
  FreeAndNil(Retiring);
end.
