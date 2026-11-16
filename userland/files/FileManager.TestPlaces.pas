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
  Telling where things are on the screen, for a test to click them:
  "place NAME X Y", in the screen's pixels, of a point given in a
  control's own pixels. Names are one word (spaces become dashes), so a
  test can read them back with a simple pattern.
}
unit FileManager.TestPlaces;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base;

procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
{ The middle of Control. }
procedure TellControlPlace(const Name: string; Control: TControl);

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Windowing.Connection,
  Windowing.Windows,
  FileManager.Output;

function OneWord(const Name: string): string;
var
  Index: LongInt;
begin
  Result := Name;
  for Index := 1 to Length(Result) do
    if Result[Index] in [' ', #9, #10, #13] then
      Result[Index] := '-';
end;

procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
var
  Window: TWindow;
begin
  if (Control.Host = nil) or not (Control.Host.OwnerWindow is TWindow) then
    Exit;
  Window := TWindow(Control.Host.OwnerWindow);
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [OneWord(Name), Scaled(Window.ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(Window.ScreenTop) + Control.PixelBounds.Top + Y]));
end;

procedure TellControlPlace(const Name: string; Control: TControl);
begin
  TellPlace(Name, Control, RectangleWidth(Control.PixelBounds) div 2, RectangleHeight(Control.PixelBounds) div 2);
end;

end.
