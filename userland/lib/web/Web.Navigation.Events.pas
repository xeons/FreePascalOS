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
  The events of loading and navigation (HTML Standard sections 7.4 and
  8): PageTransitionEvent (pageshow, pagehide; persisted),
  BeforeUnloadEvent (returnValue), HashChangeEvent (oldURL, newURL) and
  PopStateEvent (a slot for the state the bindings keep), and FireEvent,
  which fires a trusted event and frees it.
}
unit Web.Navigation.Events;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Dom.Events;

type
  TPageTransitionEvent = class(TEvent)
  public
    Persisted: Boolean;
  end;

  TBeforeUnloadEvent = class(TEvent)
  public
    { BeforeUnloadEvent.returnValue (a string, unlike Event.returnValue). }
    UnloadReturnValue: string;
  end;

  THashChangeEvent = class(TEvent)
  public
    OldUrl: string;
    NewUrl: string;
  end;

  TPopStateEvent = class(TEvent)
  public
    { The serialized state (the bindings' structured clone). }
    State: Pointer;
    HasUaVisualTransition: Boolean;
  end;

{ Fires a trusted event (freed afterwards); False if it was canceled. }
function FireEvent(Target: TEventTarget; const TypeName: string; Bubbles: Boolean = False;
  Cancelable: Boolean = False): Boolean;
function FireTrustedEvent(Target: TEventTarget; Event: TEvent): Boolean;

implementation

function FireTrustedEvent(Target: TEventTarget; Event: TEvent): Boolean;
begin
  try
    Event.IsTrusted := True;
    Result := Target.DispatchEvent(Event);
  finally
    Event.Free;
  end;
end;

function FireEvent(Target: TEventTarget; const TypeName: string; Bubbles: Boolean; Cancelable: Boolean): Boolean;
begin
  if Target = nil then
    Exit(True);
  Result := FireTrustedEvent(Target, TEvent.Create(TypeName, Bubbles, Cancelable));
end;

end.
