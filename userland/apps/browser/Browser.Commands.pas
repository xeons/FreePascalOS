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
  The browser's commands: what a menu item, a toolbar button, a key or a
  context menu asks a window to do, by number (a menu item's Tag). The
  window runs them (TBrowserWindow.RunCommand) and says which are
  enabled and checked when a menu opens.
}
unit Browser.Commands;

{$mode objfpc}
{$H+}

interface

const
  { File. }
  CommandNewWindow = 1;
  CommandNewTab = 2;
  CommandOpenLocation = 3;
  CommandOpenFile = 4;
  CommandCloseTab = 5;
  CommandCloseWindow = 6;
  CommandSavePage = 7;
  CommandSendLink = 8;
  CommandPageSetup = 9;
  CommandPrintPreview = 10;
  CommandPrint = 11;
  CommandImport = 12;
  CommandWorkOffline = 13;
  CommandExit = 14;
  { Edit. }
  CommandUndo = 20;
  CommandRedo = 21;
  CommandCut = 22;
  CommandCopy = 23;
  CommandPaste = 24;
  CommandDelete = 25;
  CommandSelectAll = 26;
  CommandFind = 27;
  CommandFindAgain = 28;
  CommandFindPrevious = 29;
  { View. }
  CommandToggleMenuBar = 40;
  CommandToggleNavigationToolbar = 41;
  CommandToggleBookmarksToolbar = 42;
  CommandCustomizeToolbars = 43;
  CommandToggleStatusBar = 44;
  CommandSidebarBookmarks = 45;
  CommandSidebarHistory = 46;
  CommandStop = 47;
  CommandReload = 48;
  CommandReloadBypassCache = 49;
  CommandZoomIn = 50;
  CommandZoomOut = 51;
  CommandZoomReset = 52;
  CommandZoomTextOnly = 53;
  CommandPageStyleNone = 54;
  CommandPageStyleBasic = 55;
  CommandEncodingAuto = 56;
  CommandPageSource = 57;
  CommandFullScreen = 58;
  { History. }
  CommandBack = 70;
  CommandForward = 71;
  CommandHome = 72;
  CommandShowAllHistory = 73;
  CommandUndoCloseTab = 74;
  CommandUndoCloseWindow = 75;
  { Bookmarks. }
  CommandBookmarkPage = 80;
  CommandSubscribePage = 81;
  CommandBookmarkAllTabs = 82;
  CommandOrganizeBookmarks = 83;
  { Tools. }
  CommandWebSearch = 90;
  CommandDownloads = 91;
  CommandAddOns = 92;
  CommandErrorConsole = 93;
  CommandPageInfo = 94;
  CommandPrivateBrowsing = 95;
  CommandClearRecentHistory = 96;
  CommandOptions = 97;
  CommandManageSearchEngines = 98;
  { Help. }
  CommandHelpContents = 100;
  CommandTroubleshooting = 101;
  CommandReportForgery = 102;
  CommandCheckUpdates = 103;
  CommandAbout = 104;
  { Tabs. }
  CommandNextTab = 110;
  CommandPreviousTab = 111;
  CommandReloadTab = 112;
  CommandReloadAllTabs = 113;
  CommandCloseOtherTabs = 114;
  CommandBookmarkTab = 115;
  CommandFocusLocation = 116;
  CommandFocusSearch = 117;
  CommandLastTab = 118;
  { Ctrl+1 to Ctrl+8: CommandSelectTab + 0 to 7. }
  CommandSelectTab = 120;
  { The page's context menu. }
  CommandOpenLinkInWindow = 140;
  CommandOpenLinkInTab = 141;
  CommandBookmarkLink = 142;
  CommandSaveLink = 143;
  CommandCopyLink = 144;
  CommandViewImage = 145;
  CommandCopyImage = 146;
  CommandSaveImage = 147;
  CommandSetDesktopBackground = 148;
  CommandViewBackgroundImage = 149;
  CommandSearchSelection = 150;
  CommandCopyImageLocation = 151;
  CommandSendImage = 152;
  CommandViewSelectionSource = 153;
  CommandSpellNoSuggestions = 154;
  CommandOpenLink = 155;

implementation

end.
