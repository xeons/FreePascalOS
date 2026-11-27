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
  files - the file manager

  files [PLACE]

  A window with tabs showing a place: a folder (PLACE relative to the
  current folder), a page ("Home", the default; "Gallery", "Computer",
  "Network", "Recycle bin"), or a folder inside a ZIP or tar archive.
  Its parts, from the top: tabs, Back/Forward/Up/Refresh with the
  address bar (breadcrumbs, chevrons, typing with completion) and the
  search box, the command bar, the navigation pane, the items in eight
  views with groups and thumbnails, the details or preview pane, and
  the status bar. See the units for each part:

    FileManager.MainWindow       the command bar and the keys
    FileManager.MenuWindow       the menus, every command carried out
    FileManager.ItemCommands     open, new, rename, compress, pin...
    FileManager.CommandWindow    delete, the clipboard, drops, undo
    FileManager.BrowserWindow    the layout, tabs, going places, search
    FileManager.FolderView       the page's items, watched
    FileManager.Sources          what each page shows
    FileManager.NavigationPane   the tree at the left, volumes watched
    FileManager.SidePane         the details and preview panes
    FileManager.OperationRunner  copy, move, delete, trash, archives...
    FileManager.OperationWorker  ... the work itself, on its own thread
    FileManager.Searcher         searching, on its own thread
    FileManager.Settings         what it remembers (group Files)

  Prints what happens, a line each, for tests:

    folder ADDRESS COUNT     a place shown, with how many items
    place NAME X Y           where something a test clicks is (pixels):
                             command-*, tab-*, segment-*, chevron-*,
                             address, search, back, forward, up,
                             tree-*, item-NAME, header-*, group-*,
                             folder-empty-space, context-*, question-*,
                             permission-*, properties-*, progress-*
    selected N               the selection changed
    view MODE, sort COLUMN ascending|descending, group BY, filter TEXT
    tab new|close|switch|duplicate|moved ...
    search SCOPE TEXT, search-result N, search-done N, search-cancelled
    preview image|text|web|summary|none PATH, pane preview|details|none
    refreshed                the page read again (it changed)
    new-folder NAME, new-file NAME, renamed OLD NEW, renamed-batch N NAME
    clipboard copy|cut N, copied-path N
    dropped move|copy N FOLDER, pinned PATH, unpinned PATH
    operation VERB N         an operation starts
    progress-shown VERB, progress-paused, progress-resumed, progress-cancelled
    question conflict NAME, question error PATH, answer WORD
    copied N, moved N, deleted N, trashed N, restored N, compressed N,
    extracted N              an operation ended (items done whole)
    undo-recorded WHAT, undo WHAT, redo WHAT
    asking delete N, delete cancelled
    properties PATH size BYTES mode OCTAL, mode PATH OCTAL
    opened-with-notepad PATH, opened-with NAME PATH, started PATH
    volume-added NAME, volume-removed NAME, folder-gone PATH
    error ...                something failed, and why
    exit                     the program ends
}
program Files;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Windowing.Windows,
  Controls.FileNames,
  Svg.Images,
  FileManager.Locations,
  FileManager.MainWindow;

{ Where to start: the place named (a path relative to the current
  folder, or a page's name), or Home. }
function StartLocation: TLocation;
var
  Current: string;
begin
  if ParamCount < 1 then
    Exit(PageLocation(LocationHome));
  if CurrentDirectoryPath(Current) <> ErrorNone then
    Current := '/';
  if not ParseAddress(ParamStr(1), Current, Result) then
    Result := PageLocation(LocationHome);
end;

var
  Window: TFileManagerWindow;
begin
  Window := TFileManagerWindow.Create;
  Window.NewTab(StartLocation);
  if Window.TabCount = 0 then
    Window.NewTab(PageLocation(LocationHome));
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
