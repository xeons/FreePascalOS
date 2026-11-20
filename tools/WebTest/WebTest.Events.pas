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
  DOM event dispatch: the capture, target and bubble order, phases,
  stopPropagation and stopImmediatePropagation, once and passive
  listeners, preventDefault, non-bubbling events, listeners added and
  removed during dispatch, duplicates, and exceptions in listeners.
}
unit WebTest.Events;

{$mode objfpc}
{$H+}

interface

procedure RunEventTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Dom,
  Web.Dom.Events,
  Web.Html.Parser;

type
  TEventAction = (ActionNone, ActionStopPropagation, ActionStopImmediate, ActionPreventDefault, ActionRaise,
    ActionRemoveOther, ActionAddOther);

  TLoggingListener = class(TEventListener)
  public
    Name: string;
    Action: TEventAction;
    Other: TEventListener;
    OtherTarget: TEventTarget;
    procedure HandleEvent(Event: TEvent); override;
  end;

var
  EventLog: string;

const
  PhaseNames: array[TEventPhase] of string = ('none', 'capture', 'target', 'bubble');

procedure TLoggingListener.HandleEvent(Event: TEvent);
begin
  EventLog := EventLog + Name + ':' + PhaseNames[Event.EventPhase] + ' ';
  case Action of
    ActionStopPropagation:
      Event.StopPropagation;
    ActionStopImmediate:
      Event.StopImmediatePropagation;
    ActionPreventDefault:
      Event.PreventDefault;
    ActionRaise:
      raise Exception.Create('listener failure');
    ActionRemoveOther:
      OtherTarget.RemoveEventListener('go', Other);
    ActionAddOther:
      OtherTarget.AddEventListener('go', Other);
  end;
end;

function Listener(const Name: string; Action: TEventAction = ActionNone): TLoggingListener;
begin
  Result := TLoggingListener.Create;
  Result.Name := Name;
  Result.Action := Action;
end;

function Dispatch(Target: TNode; Bubbles: Boolean = True; Cancelable: Boolean = False;
  const TypeName: string = 'go'): Boolean;
var
  Event: TEvent;
begin
  EventLog := '';
  Event := TEvent.Create(TypeName, Bubbles, Cancelable);
  try
    Result := Target.DispatchEvent(Event);
  finally
    Event.Free;
  end;
end;

procedure TestOrder;
var
  Document: TDocument;
  Outer, Inner, Target: TElement;
  Options: TEventListenerOptions;
begin
  Document := ParseHtmlText('<div><p><b>x</b></p></div>');
  try
    Outer := TElement(Document.Body.FirstChild);
    Inner := TElement(Outer.FirstChild);
    Target := TElement(Inner.FirstChild);
    Outer.AddEventListener('go', Listener('outer'));
    Outer.AddEventListener('go', Listener('outer'), True);
    Inner.AddEventListener('go', Listener('inner'));
    Inner.AddEventListener('go', Listener('inner'), True);
    Target.AddEventListener('go', Listener('target'));
    Target.AddEventListener('go', Listener('target'), True);
    Document.AddEventListener('go', Listener('document'), True);
    Dispatch(Target);
    Check(EventLog = 'document:capture outer:capture inner:capture target:target target:target inner:bubble ' +
      'outer:bubble ', 'capture, target and bubble order: ' + EventLog);
    Dispatch(Target, False);
    Check(EventLog = 'document:capture outer:capture inner:capture target:target target:target ',
      'a non-bubbling event: ' + EventLog);
    Inner.AddEventListener('go', Listener('stopper', ActionStopPropagation), True);
    Dispatch(Target);
    Check(EventLog = 'document:capture outer:capture inner:capture stopper:capture ',
      'stopPropagation in the capture phase: ' + EventLog);
    Options.Capture := False;
    Options.Once := True;
    Options.Passive := False;
    Check(Outer.AddEventListener('other', Listener('once'), Options), 'a once listener is added');
    Dispatch(Outer, True, False, 'other');
    Dispatch(Outer, True, False, 'other');
    Check(EventLog = '', 'a once listener runs once');
    Check(not Outer.HasEventListeners('other'), 'and is gone afterwards');
  finally
    Document.Release;
  end;
end;

procedure TestCancelAndStop;
var
  Document: TDocument;
  Target: TElement;
  Options: TEventListenerOptions;
  Shared, First, Helper: TLoggingListener;
  FirstCount: Integer;
begin
  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    First := Listener('first', ActionStopImmediate);
    Target.AddEventListener('go', First);
    Target.AddEventListener('go', Listener('second'));
    Dispatch(Target);
    Check(EventLog = 'first:target ', 'stopImmediatePropagation skips the other listeners: ' + EventLog);
    Check(Target.RemoveEventListener('go', First), 'remove by the same callback');
    Dispatch(Target);
    Check(EventLog = 'second:target ', 'the removed listener is gone: ' + EventLog);
  finally
    Document.Release;
  end;

  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    Target.AddEventListener('go', Listener('canceler', ActionPreventDefault));
    Check(not Dispatch(Target, True, True), 'preventDefault cancels a cancelable event');
    Check(Dispatch(Target, True, False), 'preventDefault does nothing to a non-cancelable event');
  finally
    Document.Release;
  end;

  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    Options.Capture := False;
    Options.Once := False;
    Options.Passive := True;
    Target.AddEventListener('go', Listener('passive', ActionPreventDefault), Options);
    Check(Dispatch(Target, True, True), 'a passive listener cannot cancel');
    Shared := Listener('shared');
    Check(Target.AddEventListener('go', Shared), 'adding a listener');
    Check(not Target.AddEventListener('go', Shared), 'adding the same listener again does nothing');
    Check(Target.AddEventListener('go', Shared, True), 'the same callback with capture is another listener');
    Dispatch(Target);
    Check(EventLog = 'shared:target passive:target shared:target ', 'both run: ' + EventLog);
  finally
    Document.Release;
  end;

  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    Shared := Listener('removed');
    Helper := Listener('remover', ActionRemoveOther);
    Helper.Other := Shared;
    Helper.OtherTarget := Target;
    Target.AddEventListener('go', Helper);
    Target.AddEventListener('go', Shared);
    Dispatch(Target);
    Check(EventLog = 'remover:target ', 'a listener removed during dispatch is not called: ' + EventLog);
  finally
    Document.Release;
  end;

  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    Shared := Listener('late');
    Helper := Listener('adder', ActionAddOther);
    Helper.Other := Shared;
    Helper.OtherTarget := Target;
    Target.AddEventListener('go', Helper);
    Dispatch(Target);
    Check(EventLog = 'adder:target ', 'a listener added during dispatch waits for the next: ' + EventLog);
    Helper.Action := ActionNone;
    Dispatch(Target);
    Check(EventLog = 'adder:target late:target ', 'then it runs: ' + EventLog);
  finally
    Document.Release;
  end;

  Document := ParseHtmlText('<p>x</p>');
  try
    Target := TElement(Document.Body.FirstChild);
    FirstCount := ListenerExceptionCount;
    Target.AddEventListener('go', Listener('thrower', ActionRaise));
    Target.AddEventListener('go', Listener('after'));
    Dispatch(Target);
    Check((EventLog = 'thrower:target after:target ') and (ListenerExceptionCount = FirstCount + 1),
      'an exception in a listener is reported and the others still run');
  finally
    Document.Release;
  end;
end;

procedure RunEventTests;
begin
  TestOrder;
  TestCancelAndStop;
end;

end.
