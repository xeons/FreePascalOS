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
  notepad - a plain text editor

  notepad [FILE]

  A window titled with the file's name ("Untitled" without one) holding
  the text to edit, a menu bar and a status bar with the caret's line
  and column:

    File    New (Ctrl+N), Open... (Ctrl+O), Save (Ctrl+S), Save As...,
            Exit
    Edit    Undo (Ctrl+Z), Redo (Ctrl+Y), Cut, Copy, Paste, Delete,
            Find... (Ctrl+F), Find Next (F3), Replace... (Ctrl+H),
            Go To... (Ctrl+G), Select All, Time/Date (F5)
    Format  Word Wrap, Font...
    View    Status Bar
    Help    About Notepad

  Files are UTF-8 text with lines ending in line feeds; a file with
  carriage returns and line feeds keeps them when saved (Notepad.Files).
  New, Open, Exit and closing the window ask first whether to save
  changes. FILE is opened at start; one that does not exist yet is
  made when saved. Word wrap, the status bar and the font are kept in
  the user's settings (group Notepad) when chosen, and the next Notepad
  starts with them. Prints what happens, a line each:

    settings word-wrap on|off, status-bar on|off, font TENTHS WEIGHT FAMILY
                          the format it starts with (from the settings)
    title TEXT            the window's title changed
    opened PATH           a file was opened (or a new one named)
    first-line TEXT       the first line of the file just opened
    saved PATH            the text was saved
    status LINE COLUMN    the caret moved (counted from 1)
    undone TEXT           Undo: the caret's line afterwards
    redone TEXT           Redo: the same
    found LINE COLUMN     Find: where the match starts
    not-found TEXT        Find: no more matches
    replaced COUNT        Replace All
    wrap on|off ROWS      word wrap toggled, and the rows the text takes
    font TENTHS WEIGHT FAMILY  a face chosen
    answer yes|no|cancel  the answer to saving changes
    exit                  the program ends
  The units are in userland/apps/notepad: Notepad.Files (reading and
  writing), Notepad.DocumentWindow (the file: New, Open, Save, the
  title, asking to save), Notepad.MainWindow (menus, status bar, find
  and replace, the format), Notepad.Settings (what it remembers),
  Notepad.GoToDialog and Notepad.Output.
}
program Notepad;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  Notepad.MainWindow;

var
  Window: TNotepadWindow;
begin
  Window := TNotepadWindow.Create;
  if ParamCount >= 1 then
    Window.OpenDocument(ParamStr(1));
  Window.Show;
  RunMessageLoop;
end.
