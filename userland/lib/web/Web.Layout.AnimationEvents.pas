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
  Firing what CSS animations and transitions did (Web.Style.Animations
  collects it while styling): each event is a task of the page's event
  loop (in the document's group), dispatched at its element as an
  AnimationEvent or TransitionEvent that bubbles, if the element is
  still in the document. A web view and webbrowse queue a frame's
  events after its layout.
}
unit Web.Layout.AnimationEvents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Web.EventLoop, Web.Style.Animations;

procedure QueueAnimationEvents(Loop: TEventLoop; Document: TDocument; const Events: TPendingAnimationEventArray);

implementation

uses
  Web.EventLoop.Tasks, Web.Dom.UiEvents;

type
  TAnimationEventTask = class(TWebTask)
  private
    FEvent: TPendingAnimationEvent;
  public
    constructor Create(const Event: TPendingAnimationEvent);
    destructor Destroy; override;
    procedure Run; override;
  end;

constructor TAnimationEventTask.Create(const Event: TPendingAnimationEvent);
begin
  inherited Create;
  FEvent := Event;
  FEvent.Element.Retain;
end;

destructor TAnimationEventTask.Destroy;
begin
  FEvent.Element.Release;
  inherited Destroy;
end;

procedure TAnimationEventTask.Run;
var
  AnimationEvent: TAnimationEvent;
  TransitionEvent: TTransitionEvent;
begin
  if not FEvent.Element.IsConnected then
    Exit;
  if FEvent.Kind in [aeAnimationStart, aeAnimationEnd, aeAnimationIteration, aeAnimationCancel] then
  begin
    AnimationEvent := TAnimationEvent.Create(AnimationEventType(FEvent.Kind), True, False);
    try
      AnimationEvent.IsTrusted := True;
      AnimationEvent.AnimationName := FEvent.Name;
      AnimationEvent.ElapsedTime := FEvent.ElapsedTime;
      FEvent.Element.DispatchEvent(AnimationEvent);
    finally
      AnimationEvent.Release;
    end;
  end
  else
  begin
    TransitionEvent := TTransitionEvent.Create(AnimationEventType(FEvent.Kind), True, False);
    try
      TransitionEvent.IsTrusted := True;
      TransitionEvent.PropertyName := FEvent.Name;
      TransitionEvent.ElapsedTime := FEvent.ElapsedTime;
      FEvent.Element.DispatchEvent(TransitionEvent);
    finally
      TransitionEvent.Release;
    end;
  end;
end;

procedure QueueAnimationEvents(Loop: TEventLoop; Document: TDocument; const Events: TPendingAnimationEventArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Events) do
    if Events[Index].Element.IsConnected then
      Loop.QueueTask(TAnimationEventTask.Create(Events[Index]), TaskSourceDomManipulation, Document);
end;

end.
