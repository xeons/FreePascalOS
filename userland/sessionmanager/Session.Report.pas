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
  What the session manager says on its standard output (its service's
  log, /var/log/session.log, which the desktop it starts writes to too):
  a line for each thing that happens, and where the login window's
  parts are ("place NAME X Y", screen pixels), so a test can find them.
}
unit Session.Report;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure Say(const Text: string);
{ "place NAME X Y": the point (X, Y) of Window's surface on the screen. }
procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);

implementation

uses
  SysUtils,
  Sys.Streams,
  Windowing.Connection;

procedure Say(const Text: string);
begin
  PrintStringLine('session: ' + Text);
  FlushStream(StandardOutput);
end;

procedure SayPlace(const Name: string; Window: TWindow; X, Y: LongInt);
begin
  Window.PrepareToReceive;
  Say(Format('place %s %d %d', [Name, Scaled(Window.ScreenLeft) + X, Scaled(Window.ScreenTop) + Y]));
end;

end.
