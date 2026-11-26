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
  The event kinds beyond Event: CustomEvent (its detail is a script
  value, kept by the event's wrapper) and the UI Events ones the input
  code and scripts make: UIEvent, MouseEvent, KeyboardEvent, FocusEvent,
  InputEvent.
}
unit Web.Dom.UiEvents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom.Events;

type
  TModifierKey = (ModifierControl, ModifierShift, ModifierAlt, ModifierMeta);
  TModifierKeys = set of TModifierKey;

  TCustomEvent = class(TEvent);

  TUiEvent = class(TEvent)
  public
    { Whether view is the window (the only view there is). }
    HasView: Boolean;
    Detail: LongInt;
    Modifiers: TModifierKeys;
    { getModifierState for "Control", "Shift", "Alt" and "Meta". }
    function ModifierState(const KeyName: string): Boolean;
  end;

  TMouseEvent = class(TUiEvent)
  public
    ScreenX, ScreenY: LongInt;
    ClientX, ClientY: LongInt;
    { Offsets in the target's padding box (layout fills them). }
    OffsetX, OffsetY: LongInt;
    { The viewport's scroll offset at the event (pageX = clientX + it). }
    ScrollX, ScrollY: LongInt;
    Button: SmallInt;
    Buttons: Word;
    { Pointer Lock: the motion since the last mousemove (CSS px). }
    MovementX, MovementY: Double;
  end;

  { Pointer Events 3: a mouse event with the pointer's identity and
    shape (a mouse is pointer 1, primary, one pixel, half pressure while
    a button is held). }
  TPointerEvent = class(TMouseEvent)
  public
    PointerId: LongInt;
    Width, Height: Double;
    Pressure, TangentialPressure: Double;
    TiltX, TiltY, Twist: LongInt;
    AltitudeAngle, AzimuthAngle: Double;
    PointerType: string;
    IsPrimary: Boolean;
  end;

  { UI Events: the wheel's motion along each axis, in DeltaMode units. }
  TWheelEvent = class(TMouseEvent)
  public
    DeltaX, DeltaY, DeltaZ: Double;
    DeltaMode: LongWord;
  end;

  TKeyboardEvent = class(TUiEvent)
  public
    Key: string;
    Code: string;
    Location: LongWord;
    IsRepeat: Boolean;
    IsComposing: Boolean;
    CharCode: LongWord;
    KeyCode: LongWord;
  end;

  TFocusEvent = class(TUiEvent);

  TInputEvent = class(TUiEvent)
  public
    Data: string;
    HasData: Boolean;
    IsComposing: Boolean;
    InputType: string;
  end;

  { CSS Animations' and CSS Transitions' events (animationstart,
    animationend, animationiteration, animationcancel; transitionrun,
    transitionstart, transitionend, transitioncancel). }
  TAnimationEvent = class(TEvent)
  public
    AnimationName: string;
    ElapsedTime: Double;
    PseudoElement: string;
  end;

  TTransitionEvent = class(TEvent)
  public
    PropertyName: string;
    ElapsedTime: Double;
    PseudoElement: string;
  end;

implementation

function TUiEvent.ModifierState(const KeyName: string): Boolean;
begin
  if KeyName = 'Control' then
    Result := ModifierControl in Modifiers
  else if KeyName = 'Shift' then
    Result := ModifierShift in Modifiers
  else if KeyName = 'Alt' then
    Result := ModifierAlt in Modifiers
  else if KeyName = 'Meta' then
    Result := ModifierMeta in Modifiers
  else
    Result := False;
end;

end.
