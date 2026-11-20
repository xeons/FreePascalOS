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
  A page: what a browser tab or a web view control holds - an event
  loop, a fetcher over a network context (shared by the profile's
  pages), and the top-level navigable - with the calls a GUI thread
  drives it by:

    Page := TWebPage.Create(Network, Sink);
    Page.OnWake := ...           // any thread: post yourself a message
    Page.OnRenderingRequested := ...   // schedule a frame
    Page.Navigable.ObserverObject := ...   // address bar, title, ...
    Page.NavigateTo('https://example.com/');
    // on the message, on a timer after MillisecondsUntilNextTimer,
    // or idle:
    Page.ProcessPendingWork(8);
    // when it may paint (vsync, after an invalidation):
    Page.RenderingOpportunity;

  All of it runs on the thread that calls these (the page thread); only
  OnWake comes from other threads. A program without a GUI loop can
  call Run, which waits for work itself.
}
unit Web.Navigation.Pages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.EventLoop,
  Web.Fetch.Fetcher,
  Web.Fetch.NetworkContexts,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Loading.Scripts,
  Web.Navigation.Navigables;

type
  TPageCondition = function: Boolean of object;

  TWebPage = class
  private
    FLoop: TEventLoop;
    FFetcher: TFetcher;
    FNavigable: TNavigable;
    FOwnedSink: TResourceSink;
    function GetOnWake: TNotifyEvent;
    procedure SetOnWake(Value: TNotifyEvent);
    function GetOnRenderingRequested: TNotifyEvent;
    procedure SetOnRenderingRequested(Value: TNotifyEvent);
  public
    { Sink nil: a TNullResourceSink (nothing is rendered). Executor nil:
      scripting off. Clock: the event loop's (tests). }
    constructor Create(Network: TNetworkContext; Sink: TResourceSink = nil; Executor: TScriptExecutor = nil;
      Clock: TEventLoopClock = nil);
    destructor Destroy; override;
    function NavigateTo(const Text: string): Boolean;
    { Runs ready tasks for at most BudgetMilliseconds (0: until none is
      ready); the number run. }
    function ProcessPendingWork(BudgetMilliseconds: Double = 0): Integer;
    { -1 when no timer waits. }
    function MillisecondsUntilNextTimer: Double;
    procedure RenderingOpportunity;
    { Runs the loop, waiting for work, until Condition holds or
      TimeoutMilliseconds pass (negative: no limit); True if it held. }
    function Run(Condition: TPageCondition; TimeoutMilliseconds: Integer = -1): Boolean;
    property Loop: TEventLoop read FLoop;
    property Fetcher: TFetcher read FFetcher;
    property Navigable: TNavigable read FNavigable;
    property OnWake: TNotifyEvent read GetOnWake write SetOnWake;
    property OnRenderingRequested: TNotifyEvent read GetOnRenderingRequested write SetOnRenderingRequested;
  end;

implementation

constructor TWebPage.Create(Network: TNetworkContext; Sink: TResourceSink; Executor: TScriptExecutor;
  Clock: TEventLoopClock);
begin
  inherited Create;
  FLoop := TEventLoop.Create(Clock);
  FFetcher := TFetcher.Create(FLoop, Network);
  if Sink = nil then
  begin
    FOwnedSink := TNullResourceSink.Create;
    Sink := FOwnedSink;
  end;
  FNavigable := TNavigable.Create(FFetcher, Sink, DefaultLoadingSettings, Executor);
end;

destructor TWebPage.Destroy;
begin
  FNavigable.Free;
  FFetcher.Free;
  FLoop.Free;
  FOwnedSink.Free;
  inherited Destroy;
end;

function TWebPage.GetOnWake: TNotifyEvent;
begin
  Result := FLoop.OnWake;
end;

procedure TWebPage.SetOnWake(Value: TNotifyEvent);
begin
  FLoop.OnWake := Value;
end;

function TWebPage.GetOnRenderingRequested: TNotifyEvent;
begin
  Result := FLoop.OnRenderingRequested;
end;

procedure TWebPage.SetOnRenderingRequested(Value: TNotifyEvent);
begin
  FLoop.OnRenderingRequested := Value;
end;

function TWebPage.NavigateTo(const Text: string): Boolean;
begin
  Result := FNavigable.NavigateTo(Text, True);
end;

function TWebPage.ProcessPendingWork(BudgetMilliseconds: Double): Integer;
begin
  Result := FLoop.RunPendingTasks(0, BudgetMilliseconds);
end;

function TWebPage.MillisecondsUntilNextTimer: Double;
begin
  Result := FLoop.MillisecondsUntilNextTimer;
end;

procedure TWebPage.RenderingOpportunity;
begin
  FLoop.RenderingOpportunity;
end;

function TWebPage.Run(Condition: TPageCondition; TimeoutMilliseconds: Integer): Boolean;
var
  Started: QWord;
  Remaining: Integer;
begin
  Started := GetTickCount64;
  while True do
  begin
    FLoop.RunPendingTasks;
    if Assigned(Condition) and Condition() then
      Exit(True);
    if TimeoutMilliseconds >= 0 then
    begin
      Remaining := TimeoutMilliseconds - Integer(GetTickCount64 - Started);
      if Remaining <= 0 then
        Exit(False);
      FLoop.WaitForWork(Remaining);
    end
    else
      FLoop.WaitForWork(-1);
  end;
end;

end.
