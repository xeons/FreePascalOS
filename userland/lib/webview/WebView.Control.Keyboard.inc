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

{ WebView.Control: keys. }

const
  { Scan codes (set 1) the view looks at beyond Controls.Keys'. }
  KeyEquals = $0D;
  KeyMinus = $0C;
  KeyZero = $0B;
  KeyNumpadPlus = $4E;
  KeyNumpadMinus = $4A;
  { CSS pixels an arrow key scrolls. }
  ArrowStep = 40;

function TWebView.KeyDown(Code, Character, Modifiers: LongWord): Boolean;
var
  Control: Boolean;
  Kind: TFormControlKind;
  Next: TElement;
  ViewHeight: Double;
begin
  Result := True;
  Control := (Modifiers and ModifierControl) <> 0;
  { A text field with the focus takes what it types. }
  if TypeIntoField(Code, Character, Modifiers) then
    Exit;
  if Control and ((Code = KeyEquals) or (Code = KeyNumpadPlus)) then
  begin
    ZoomIn;
    Exit;
  end;
  if Control and ((Code = KeyMinus) or (Code = KeyNumpadMinus)) then
  begin
    ZoomOut;
    Exit;
  end;
  if Control and (Code = KeyZero) then
  begin
    ResetZoom;
    Exit;
  end;
  if Control and (Code = KeyC) then
  begin
    CopySelection;
    Exit;
  end;
  if Control and (Code = KeyA) then
  begin
    SelectAll;
    Exit;
  end;
  if ((Modifiers and ModifierAlt) <> 0) and (Code = KeyArrowLeft) then
  begin
    GoBack;
    Exit;
  end;
  if ((Modifiers and ModifierAlt) <> 0) and (Code = KeyArrowRight) then
  begin
    GoForward;
    Exit;
  end;
  if (Code = KeyTab) and not Control then
  begin
    Next := NextFocusableElement(FDocument, FFocusedElement, (Modifiers and ModifierShift) = 0);
    if Next = nil then
    begin
      SetFocusedElement(nil, False);
      Exit(False);
    end;
    SetFocusedElement(Next, True);
    if FLayout <> nil then
      ScrollToElement(Next);
    Exit;
  end;
  if (FFocusedElement <> nil) and (IsEnterKey(Code) or (Code = KeySpace)) and not Control then
  begin
    Kind := FormControlKindOf(FFocusedElement);
    if (Kind <> FormControlNone) and ((Code = KeySpace) or (Kind in [FormControlSubmit, FormControlReset,
       FormControlButton, FormControlSelect])) then
    begin
      ActivateControl(FFocusedElement);
      Exit;
    end;
    if IsEnterKey(Code) and (LinkElementOf(FFocusedElement) = FFocusedElement) then
    begin
      ActivateLink(FFocusedElement, DispositionFor(ButtonLeft, Modifiers, FFocusedElement));
      Exit;
    end;
  end;
  ViewHeight := ViewportCssHeight;
  case Code of
    KeyArrowDown:
      ScrollBy(0, ArrowStep);
    KeyArrowUp:
      ScrollBy(0, -ArrowStep);
    KeyArrowRight:
      ScrollBy(ArrowStep, 0);
    KeyArrowLeft:
      ScrollBy(-ArrowStep, 0);
    KeyPageDown:
      ScrollBy(0, ViewHeight - ArrowStep);
    KeyPageUp:
      ScrollBy(0, -(ViewHeight - ArrowStep));
    KeySpace:
      if (Modifiers and ModifierShift) <> 0 then
        ScrollBy(0, -(ViewHeight - ArrowStep))
      else
        ScrollBy(0, ViewHeight - ArrowStep);
    KeyHome:
      if FLayout <> nil then
        ScrollViewportTo(0, 0);
    KeyEnd:
      if FLayout <> nil then
        ScrollViewportTo(0, FLayout.DocumentHeight);
    KeyEscape:
      if HasSelection then
        ClearSelection
      else
        Result := False;
  else
    Result := inherited KeyDown(Code, Character, Modifiers);
  end;
end;
