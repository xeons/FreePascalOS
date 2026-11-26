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
  Pointer capture (Pointer Events 3, 10): setPointerCapture,
  releasePointerCapture and hasPointerCapture on an element, for the one
  pointer there is, the mouse (pointer id 1). The pending capture is the
  document's (TDocument.PendingPointerCapture); whoever dispatches
  pointer events (WebView.MouseEvents) tells the buttons held and turns
  the pending capture into the capture before each pointer event,
  firing gotpointercapture and lostpointercapture.
}
unit Web.Dom.PointerCapture;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

const
  MousePointerId = 1;

type
  TPointerCaptureOutcome = (CaptureDone, CaptureUnknownPointer, CaptureNotConnected);

var
  { The mouse buttons held now (MouseEvent.buttons bits); a capture is
    only set while one is held. }
  MouseButtonsHeld: Word = 0;

function SetPointerCapture(Element: TElement; PointerId: LongInt): TPointerCaptureOutcome;
function ReleasePointerCapture(Element: TElement; PointerId: LongInt): TPointerCaptureOutcome;
function HasPointerCapture(Element: TElement; PointerId: LongInt): Boolean;

implementation

function SetPointerCapture(Element: TElement; PointerId: LongInt): TPointerCaptureOutcome;
begin
  if PointerId <> MousePointerId then
    Exit(CaptureUnknownPointer);
  if not Element.IsConnected then
    Exit(CaptureNotConnected);
  Result := CaptureDone;
  if MouseButtonsHeld = 0 then
    Exit;
  Element.OwnerDocument.PendingPointerCapture := Element;
end;

function ReleasePointerCapture(Element: TElement; PointerId: LongInt): TPointerCaptureOutcome;
begin
  if PointerId <> MousePointerId then
    Exit(CaptureUnknownPointer);
  Result := CaptureDone;
  if HasPointerCapture(Element, PointerId) then
    Element.OwnerDocument.PendingPointerCapture := nil;
end;

function HasPointerCapture(Element: TElement; PointerId: LongInt): Boolean;
begin
  Result := (PointerId = MousePointerId) and (Element.OwnerDocument <> nil) and
    (Element.OwnerDocument.PendingPointerCapture = Element);
end;

end.
