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
  What the task manager tells its standard output as things happen, a
  line each (the program's header lists them), and where things are on
  the screen ("place NAME X Y", screen pixels), so a test can follow it
  and click what it needs.
}
unit TaskManager.Output;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Windowing.Windows;

procedure Say(const Text: string);
{ "place NAME X Y": the point (X, Y) of Window's surface on the screen. }
procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);
{ "place NAME X Y" for the middle of Control, a control of Window. }
procedure SayControlPlace(const Name: string; Window: TWindow; Control: TControl);

implementation

uses
  SysUtils,
  Sys.Streams,
  Drawing.Rectangles,
  Windowing.Connection;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);
begin
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + X, Scaled(Window.ScreenTop) + Y]));
end;

procedure SayControlPlace(const Name: string; Window: TWindow; Control: TControl);
var
  Bounds: TRectangle;
begin
  Bounds := Control.PixelBounds;
  SayPlace(Name, Window, (Bounds.Left + Bounds.Right) div 2, (Bounds.Top + Bounds.Bottom) div 2);
end;

end.
