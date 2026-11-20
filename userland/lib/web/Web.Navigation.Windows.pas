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
  The window of a document (HTML Standard section 7.2): the global the
  bindings will wrap, here an event target (load, pageshow, pagehide,
  beforeunload, unload, hashchange, popstate fire at it; other events
  bubble to it from the document) with what belongs to a global: its
  timers (setTimeout and setInterval) and its animation frame callbacks.

  Each window takes part in the event loop's rendering opportunities:
  "update the rendering" runs its animation frame callbacks (with a
  microtask checkpoint after each) and then OnUpdateRendering, which the
  web view sets to lay out and paint. RequestAnimationFrame asks the
  loop for a frame. Its tasks are grouped under the window: freeing it
  drops them.
}
unit Web.Navigation.Windows;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Dom.Events,
  Web.Dom,
  Web.EventLoop,
  Web.EventLoop.Timers,
  Web.EventLoop.AnimationFrames;

type
  TWebWindow = class;

  TWindowRenderingEvent = procedure(Window: TWebWindow; Now: Double) of object;

  TWindowRenderingClient = class(TRenderingClient)
  private
    FWindow: TWebWindow;
  public
    constructor Create(Window: TWebWindow);
    procedure UpdateRendering(Loop: TEventLoop; Now: Double); override;
  end;

  TWebWindow = class(TEventTarget)
  private
    FListeners: TEventListenerList;
    FLoop: TEventLoop;
    FDocument: TDocument;
    FTimers: TTimerList;
    FAnimationFrames: TAnimationFrameList;
    FRenderingClient: TWindowRenderingClient;
    FNavigable: TObject;
    FOnUpdateRendering: TWindowRenderingEvent;
    FTimeOrigin: Double;
  protected
    function GetListenerList(CreateIfMissing: Boolean): TEventListenerList; override;
  public
    { The window of Document (which it holds a reference to). }
    constructor Create(Loop: TEventLoop; Document: TDocument);
    destructor Destroy; override;
    function RequestAnimationFrame(Callback: TAnimationFrameCallback): LongInt;
    procedure CancelAnimationFrame(Id: LongInt);
    { The document is unloaded: timers and callbacks stop. }
    procedure StopActivity;
    { performance.now(): milliseconds since the window was made. }
    function PerformanceNow: Double;
    property Loop: TEventLoop read FLoop;
    property Document: TDocument read FDocument;
    property Timers: TTimerList read FTimers;
    property AnimationFrames: TAnimationFrameList read FAnimationFrames;
    { The navigable (Web.Navigation.Navigables) showing it. }
    property Navigable: TObject read FNavigable write FNavigable;
    property OnUpdateRendering: TWindowRenderingEvent read FOnUpdateRendering write FOnUpdateRendering;
  end;

implementation

constructor TWindowRenderingClient.Create(Window: TWebWindow);
begin
  inherited Create;
  FWindow := Window;
end;

procedure TWindowRenderingClient.UpdateRendering(Loop: TEventLoop; Now: Double);
begin
  FWindow.FAnimationFrames.Run(Now - FWindow.FTimeOrigin, @Loop.PerformMicrotaskCheckpoint);
  if Assigned(FWindow.FOnUpdateRendering) then
    FWindow.FOnUpdateRendering(FWindow, Now);
end;

constructor TWebWindow.Create(Loop: TEventLoop; Document: TDocument);
begin
  inherited Create;
  FLoop := Loop;
  FDocument := Document;
  FDocument.Retain;
  FDocument.DefaultView := Self;
  FTimers := TTimerList.Create(Loop, Self);
  FAnimationFrames := TAnimationFrameList.Create;
  FRenderingClient := TWindowRenderingClient.Create(Self);
  FLoop.AddRenderingClient(FRenderingClient);
  FTimeOrigin := Loop.Now;
end;

destructor TWebWindow.Destroy;
begin
  FLoop.RemoveRenderingClient(FRenderingClient);
  FTimers.Free;
  FLoop.DiscardTasks(Self);
  FAnimationFrames.Free;
  FRenderingClient.Free;
  FListeners.Free;
  if FDocument.DefaultView = Self then
    FDocument.DefaultView := nil;
  FDocument.Release;
  inherited Destroy;
end;

function TWebWindow.GetListenerList(CreateIfMissing: Boolean): TEventListenerList;
begin
  if (FListeners = nil) and CreateIfMissing then
    FListeners := TEventListenerList.Create;
  Result := FListeners;
end;

function TWebWindow.RequestAnimationFrame(Callback: TAnimationFrameCallback): LongInt;
begin
  Result := FAnimationFrames.Request(Callback);
  FLoop.RequestRendering;
end;

procedure TWebWindow.CancelAnimationFrame(Id: LongInt);
begin
  FAnimationFrames.Cancel(Id);
end;

procedure TWebWindow.StopActivity;
begin
  FTimers.ClearAll;
  FAnimationFrames.Clear;
  FLoop.DiscardTasks(Self);
end;

function TWebWindow.PerformanceNow: Double;
begin
  Result := FLoop.Now - FTimeOrigin;
end;

end.
