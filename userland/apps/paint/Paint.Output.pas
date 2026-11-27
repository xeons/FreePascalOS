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
  What Paint tells its standard output as things happen, a line each
  (the program's header lists them), so a test can follow it; and where
  things are on the screen ("place NAME X Y", screen pixels), for a
  test to point at them.
}
unit Paint.Output;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base;

procedure Say(const Text: string);
{ "place NAME X Y": (X, Y) of Control's own pixels on the screen. }
procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);

implementation

uses
  SysUtils,
  Sys.Streams,
  Windowing.Connection,
  Windowing.Windows;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure TellPlace(const Name: string; Control: TControl; X, Y: LongInt);
var
  Window: TWindow;
begin
  if (Control.Host = nil) or not (Control.Host.OwnerWindow is TWindow) then
    Exit;
  Window := TWindow(Control.Host.OwnerWindow);
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(Window.ScreenTop) + Control.PixelBounds.Top + Y]));
end;

end.
