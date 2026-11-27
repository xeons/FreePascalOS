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
  What the controls tour prints: a line for each thing that happens, at
  once (a test reads it while the tour runs), and where its controls
  are on the screen.
}
unit Tour.Output;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window;

procedure Say(const Text: string);
{ "place NAME X Y": (X, Y) of Control's pixels on the screen. }
procedure TellPlace(Window: TControlWindow; const Name: string; Control: TControl; X, Y: LongInt);

implementation

uses
  SysUtils,
  Sys.Streams,
  Windowing.Connection;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure TellPlace(Window: TControlWindow; const Name: string; Control: TControl; X, Y: LongInt);
begin
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(Window.ScreenTop) + Control.PixelBounds.Top + Y]));
end;

end.
