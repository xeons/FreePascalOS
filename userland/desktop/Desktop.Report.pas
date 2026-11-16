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
  What the desktop says on its standard output: a line for each thing
  that happens (a program started, the taskbar's list changed, the clock
  showing a new time), and where things are on the screen ("place NAME
  X Y", desktop pixels), so a test can click them.
}
unit Desktop.Report;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure Say(const Text: string);
{ "place NAME X Y": the point (X, Y) of Window's surface on the screen.
  Spaces in Name become dashes, so it stays one word. }
procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);

implementation

uses
  SysUtils,
  Sys.Streams,
  Util.Output,
  Windowing.Connection;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);
begin
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [StringReplace(Name, ' ', '-', [rfReplaceAll]), Scaled(Window.ScreenLeft) + X,
    Scaled(Window.ScreenTop) + Y]));
end;

end.
