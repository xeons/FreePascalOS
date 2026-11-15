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
  Double clicks on title bars (which maximize a window or restore it).

  A press is the second of a double click if the one before it was on
  the same window's title bar, at most DoubleClickTime milliseconds
  earlier (by the input events' own times, so a busy server does not
  miss one), and the pointer has not gone more than a few pixels from
  it. A third press starts again: it is the first of a new pair.
}
unit Server.DoubleClicks;

{$mode objfpc}

interface

uses
  Server.Windows;

const
  DoubleClickTime = 500;

{ A press on Window's title bar at (X, Y), Time (milliseconds): True if
  it ends a double click. Window nil: a press elsewhere (it breaks a
  pair). }
function TitlePressIsDoubleClick(Window: PServerWindow; X, Y: LongInt; Time: QWord): Boolean;
{ The window is going. }
procedure ForgetWindowInDoubleClicks(Window: PServerWindow);

implementation

uses
  Server.Theme;

const
  { Logical units the pointer may move between the two presses. }
  DoubleClickDistance = 4;

var
  LastWindow: PServerWindow;
  LastX: LongInt;
  LastY: LongInt;
  LastTime: QWord;

function TitlePressIsDoubleClick(Window: PServerWindow; X, Y: LongInt; Time: QWord): Boolean;
var
  Distance: LongInt;
begin
  Distance := ScaledMetric(DoubleClickDistance);
  Result := (Window <> nil) and (Window = LastWindow) and (Time >= LastTime) and
    (Time - LastTime <= DoubleClickTime) and (Abs(X - LastX) <= Distance) and (Abs(Y - LastY) <= Distance);
  if Result then
    LastWindow := nil
  else
  begin
    LastWindow := Window;
    LastX := X;
    LastY := Y;
    LastTime := Time;
  end;
end;

procedure ForgetWindowInDoubleClicks(Window: PServerWindow);
begin
  if LastWindow = Window then
    LastWindow := nil;
end;

end.
