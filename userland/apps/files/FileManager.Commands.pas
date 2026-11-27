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
  The file manager's commands by number, so the command bar's buttons,
  every menu item and the keys lead to one place (the window's
  RunCommand, with the number in the button's or item's Tag). Ranges
  carry an index: a view, a column to sort by, a grouping, a template,
  a filter, a program to open with.
}
unit FileManager.Commands;

{$mode objfpc}
{$H+}

interface

const
  CommandOpen = 1;
  CommandOpenInNewTab = 2;
  CommandOpenInNewWindow = 3;
  CommandOpenWith = 4;
  CommandChooseDefault = 5;
  CommandNewFolder = 6;
  CommandCut = 7;
  CommandCopy = 8;
  CommandPaste = 9;
  CommandRename = 10;
  CommandCopyPath = 11;
  CommandSendToDesktop = 12;
  CommandSendToDocuments = 13;
  CommandDelete = 14;
  CommandDeletePermanently = 15;
  CommandUndo = 16;
  CommandRedo = 17;
  CommandSelectAll = 18;
  CommandSelectNone = 19;
  CommandInvertSelection = 20;
  CommandProperties = 21;
  CommandOptions = 22;
  CommandCompress = 23;
  CommandExtract = 24;
  CommandPin = 25;
  CommandUnpin = 26;
  CommandFavorite = 27;
  CommandUnfavorite = 28;
  CommandRefresh = 29;
  CommandRestore = 30;
  CommandRestoreAll = 31;
  CommandEmptyTrash = 32;
  CommandNewTab = 33;
  CommandCloseTab = 34;
  CommandNewWindow = 35;
  CommandCompact = 36;
  CommandCheckBoxes = 37;
  CommandExtensions = 38;
  CommandHiddenItems = 39;
  CommandPreviewPane = 40;
  CommandDetailsPane = 41;
  CommandAscending = 42;
  CommandDescending = 43;
  CommandClearFilter = 44;
  CommandShowMoreOptions = 45;
  CommandBack = 46;
  CommandForward = 47;
  CommandUp = 48;
  CommandFocusAddress = 49;
  CommandFocusSearch = 50;
  CommandShowNavigationPane = 51;
  CommandAbout = 52;
  { Ranges: the base plus an index. }
  CommandViewBase = 100;
  CommandSortBase = 200;
  CommandGroupBase = 300;
  CommandNewFileBase = 400;
  CommandFilterKindBase = 500;
  CommandFilterDateBase = 600;
  CommandOpenWithBase = 700;
  CommandRangeSize = 100;

  DateFilters: array[0..5] of string = ('today', 'yesterday', 'thisweek', 'lastweek', 'thismonth', 'thisyear');
  DateFilterCaptions: array[0..5] of string = ('&Today', '&Yesterday', 'This &week', '&Last week', 'This &month',
    'This y&ear');

{ The range a command is in (its base), and its index there. }
function CommandBase(Command: LongInt): LongInt;
function CommandIndex(Command: LongInt): LongInt;

implementation

function CommandBase(Command: LongInt): LongInt;
begin
  if Command < CommandViewBase then
    Result := Command
  else
    Result := (Command div CommandRangeSize) * CommandRangeSize;
end;

function CommandIndex(Command: LongInt): LongInt;
begin
  if Command < CommandViewBase then
    Result := 0
  else
    Result := Command mod CommandRangeSize;
end;

end.
