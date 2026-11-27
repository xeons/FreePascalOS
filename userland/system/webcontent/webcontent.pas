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
  webcontent - a browser's content process (a renderer)

  webcontent --channel=HANDLE --site=SITE [--scale=PERCENT,DPI]
             [--script-limit=MS] [--memory-limit=MB] [--theme=KEY]
             [--sandbox | --no-sandbox]

  Started by a program with web views (libwebview's
  WebView.ContentProcesses), never by hand: HANDLE is its end of a
  channel to that program, SITE the one site whose pages it shows. It
  hosts the pages of its views (parsing, style, layout, paint, scripts)
  and paints them into sections the program shows; the network, files,
  cookies and storage it asks the program for. It restricts itself
  before any page runs (WebContent.Sandbox). The units are in
  userland/system/webcontent.
}
program WebContent;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  WebContent.Process;

var
  Options: TContentOptions;
  Problem: string;
begin
  if not ParseContentOptions(Options, Problem) then
  begin
    WriteLn(StdErr, 'webcontent: ', Problem);
    Halt(2);
  end;
  Halt(RunContentProcess(Options));
end.
