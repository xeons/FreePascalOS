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

  files [FOLDER]

  A window showing a folder (FOLDER, relative to the current folder, or
  the user's home folder) as large icons, a list or details, with the
  places to go at the left (home, the file system, every volume, disks
  plugged in included), Back, Forward and Up, and an address box. Items
  open with a double click or Enter (folders shown, programs run, text
  in Notepad); they are made, renamed, deleted, cut, copied and pasted
  from the menus, the keys, a context menu, or dragged with the mouse
  (within a volume they move, onto another they are copied; Ctrl
  copies, Shift moves). Copies, moves and deletes run in the background
  with a progress window, asking about names already taken and errors.
  The folder shown follows changes other programs make. See the units
  for each part:

    FileManager.MainWindow       menus, toolbar, keys, context menus
    FileManager.CommandWindow    the commands on files
    FileManager.BrowserWindow    the layout, going from folder to folder
    FileManager.FolderView       the items of the folder, watched
    FileManager.PlacesPane       the places, volumes coming and going
    FileManager.OperationRunner  copy, move and delete in the background
    FileManager.OperationWorker  ... the work itself, on its own thread
    FileManager.Associations     what opening a file does
    FileManager.PropertiesDialog properties and permissions
    FileManager.Settings         what it remembers (group Files)

  Prints what happens, a line each, for tests:

    folder PATH COUNT        a folder shown, with how many items
    place NAME X Y           where something a test clicks is (pixels):
                             menu-*, view-*, back, forward, up, address,
                             tree-*, item-NAME, folder-empty-space,
                             context-*, question-*, permission-*,
                             progress-cancel, properties-close
    selected N               the selection changed
    view icons|list|details  the view chosen
    sort COLUMN ascending|descending
    hidden shown|not shown
    refreshed                the folder read again (it changed)
    new-folder NAME          a folder made
    renamed OLD NEW          a rename in place
    clipboard copy|cut N     items put on the clipboard
    dropped move|copy N FOLDER  files dropped on a folder
    operation copying|moving|deleting N  an operation starts
    progress-shown VERB      its progress window appeared
    question conflict NAME   a name is taken: what to do?
    question error PATH      an error: skip or stop?
    answer WORD              the answer to a question
    copied N, moved N, deleted N  an operation ended (items done whole)
    stopped                  ... stopped by the user
    asking delete N, delete cancelled
    properties PATH size BYTES mode OCTAL
    properties-size PATH BYTES FILES FOLDERS
    properties-volume NAME TYPE TOTAL FREE
    mode PATH OCTAL          a permission changed
    opened-with-notepad PATH, started PATH
    volume-added NAME, volume-removed NAME
    folder-gone PATH         the folder shown went away
    error ...                something failed, and why
    exit                     the program ends
}
program Files;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Files,
  Windowing.Windows,
  Controls.FileNames,
  FileManager.PlacesPane,
  FileManager.MainWindow;

{ Where to start: the folder named (relative to the current folder), or
  the home folder. }
function StartFolder: string;
var
  Buffer: array[0..PathCapacity - 1] of Char;
  Current: string;
begin
  if ParamCount < 1 then
    Exit(HomeFolder);
  Current := '/';
  if GetCurrentDirectory(@Buffer[0], PathCapacity) >= 0 then
    Current := StrPas(@Buffer[0]);
  Result := CombinePath(Current, ParamStr(1));
end;

var
  Window: TFileManagerWindow;
begin
  Window := TFileManagerWindow.Create;
  if not Window.Navigate(StartFolder) then
    Window.Navigate(HomeFolder);
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
