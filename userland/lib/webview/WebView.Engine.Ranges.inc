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
  TWebEngineView: range inputs (input type=range, the slider the painter
  draws as a track and a thumb). Pressing on one moves its thumb to the
  pointer and dragging moves it on (input at each change, on the step;
  change when the button comes up with another value); the arrow keys
  step it, Page Up and Page Down by a tenth of its span, Home and End to
  its ends (input and change).
}

{ Where the device point X lies along the range's thumb travel (0 at the
  start, 1 at the end), as Web.Paint.Raster's DrawRange places the
  thumb: its centre moves along the content box less one thumb. }
function TWebEngineView.RangeFractionAt(Control: TElement; X: LongInt; out Fraction: Double): Boolean;
var
  TargetLayout: TDocumentLayout;
  Box: TLayoutBox;
  OriginX, OriginY, BoxX, BoxY, ScrollX, ScrollY, Thumb, Travel, PointerX: Single;
begin
  Fraction := 0;
  Result := False;
  if (FLayout = nil) or not DocumentViewportOrigin(FLayout, Control.NodeDocument, OriginX, OriginY, TargetLayout) then
    Exit;
  Box := TargetLayout.BoxOf(Control);
  if Box = nil then
    Exit;
  Box.AbsolutePosition(BoxX, BoxY);
  TargetLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  Thumb := Min(Box.ContentHeight, Box.ContentWidth);
  Travel := Box.ContentWidth - Thumb;
  PointerX := X / DeviceScale + ScrollX - OriginX;
  if Travel <= 0 then
    Exit;
  Fraction := EnsureRange((PointerX - (BoxX + Box.ContentLeft + Thumb / 2)) / Travel, 0, 1);
  Result := True;
end;

{ A new value for the range from the user: set, input fired, drawn. }
procedure TWebEngineView.ChangeRangeValue(Control: TElement; const Value: string);
begin
  if Value = InputValue(Control) then
    Exit;
  SetInputValue(Control, Value);
  ControlEdited(Control);
end;

procedure TWebEngineView.MoveRangeTo(Control: TElement; X: LongInt);
var
  Fraction: Double;
begin
  if RangeFractionAt(Control, X, Fraction) then
    ChangeRangeValue(Control, RangeValueAt(Control, Fraction));
end;

procedure TWebEngineView.StartRangeDrag(Control: TElement; X: LongInt);
begin
  HoldElement(FRangeControl, Control);
  FRangeStartValue := InputValue(Control);
  MoveRangeTo(Control, X);
end;

procedure TWebEngineView.EndRangeDrag;
var
  Control: TElement;
begin
  if FRangeControl = nil then
    Exit;
  Control := nil;
  HoldElement(Control, FRangeControl);
  try
    HoldElement(FRangeControl, nil);
    if Control.IsConnected and (InputValue(Control) <> FRangeStartValue) then
      FireEvent(Control, 'change', True);
  finally
    HoldElement(Control, nil);
  end;
end;

{ A key on a focused range: True when it moved (or would move) it. }
function TWebEngineView.RangeKeyDown(Control: TElement; Code: LongWord): Boolean;
var
  Minimum, Maximum, Value, Step: Double;
  Allowed: TInputStep;
  Target: string;
begin
  Result := Code in [KeyArrowRight, KeyArrowUp, KeyArrowLeft, KeyArrowDown, KeyPageUp, KeyPageDown, KeyHome, KeyEnd];
  if not Result or IsDisabledControl(Control) then
    Exit;
  InputMinimum(Control, 'range', Minimum);
  InputMaximum(Control, 'range', Maximum);
  if not InputValueToNumber('range', InputValue(Control), Value) then
    Value := Minimum;
  Allowed := InputAllowedStep(Control, 'range');
  Step := Allowed.Step;
  if not Allowed.Allowed then
    Step := (Maximum - Minimum) / 100;
  case Code of
    KeyArrowRight, KeyArrowUp: Value := Value + Step;
    KeyArrowLeft, KeyArrowDown: Value := Value - Step;
    KeyPageUp: Value := Value + Max(Step, (Maximum - Minimum) / 10);
    KeyPageDown: Value := Value - Max(Step, (Maximum - Minimum) / 10);
    KeyHome: Value := Minimum;
    KeyEnd: Value := Maximum;
  end;
  Target := SanitizeNumericValue(Control, 'range', FloatingPointNumberText(Value));
  if Target = InputValue(Control) then
    Exit;
  Control.Retain;
  try
    ChangeRangeValue(Control, Target);
    if Control.IsConnected then
      FireEvent(Control, 'change', True);
  finally
    Control.Release;
  end;
end;
