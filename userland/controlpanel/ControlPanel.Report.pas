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
  What the Control Panel tells its standard output as things happen, a
  line each (the program's header lists them), and where its controls
  are on the screen ("place NAME X Y", pixels), so a test can follow it
  and click them.
}
unit ControlPanel.Report;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Base;

procedure Say(const Text: string);
{ "place NAME X Y": the point (X, Y) of Control (its own pixels) on the
  screen; Window is the window it is in. }
procedure SayPlace(const Name: string; Window: TWindow; Control: TControl; X, Y: LongInt);
{ The same for the middle of Control. }
procedure SayControlPlace(const Name: string; Window: TWindow; Control: TControl);

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Sys.Streams,
  Util.Output,
  Windowing.Connection;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure SayPlace(const Name: string; Window: TWindow; Control: TControl; X, Y: LongInt);
begin
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + Control.PixelBounds.Left + X,
    Scaled(Window.ScreenTop) + Control.PixelBounds.Top + Y]));
end;

procedure SayControlPlace(const Name: string; Window: TWindow; Control: TControl);
begin
  SayPlace(Name, Window, Control, RectangleWidth(Control.PixelBounds) div 2,
    RectangleHeight(Control.PixelBounds) div 2);
end;

end.
