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
  The browser window's menu bar, laid out as browsers had it before
  their menus were folded away: File, Edit, View, History, Bookmarks,
  Tools and Help, with the same items, access keys and shortcuts. Each
  item's Tag is its command (Browser.Commands), run by Run; the keys
  are the window's accelerators. The History and Bookmarks menus end
  with entries the window fills as they open (after FixedCount items),
  and so do Recently Closed Tabs and Windows, Recently Bookmarked,
  Recent Tags, the Bookmarks Toolbar folder and Character Encoding.

  Keys without an item: Ctrl+Tab and Ctrl+Shift+Tab (and Ctrl+Page Down
  and Up), Ctrl+1 to Ctrl+9, Ctrl+L, Alt+D and F6, Ctrl+K, Ctrl+R,
  Ctrl+Shift+R, F5 with Ctrl, Ctrl+F4, Ctrl+Shift+Z, Ctrl+G, Shift+F3,
  the numeric pad's plus and minus with Ctrl, Ctrl+Shift+B.
}
unit Browser.MenuBar;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.Menus;

type
  TBrowserMenus = record
    Bar: TMenuBar;
    FileMenu, EditMenu, ViewMenu, HistoryMenu, BookmarksMenu, ToolsMenu, HelpMenu: TMenuItem;
    ToolbarsMenu, SidebarMenu, ZoomMenu, PageStyleMenu, EncodingMenu: TMenuItem;
    ClosedTabsMenu, ClosedWindowsMenu: TMenuItem;
    ToolbarFolderMenu, RecentlyBookmarkedMenu, RecentTagsMenu: TMenuItem;
    { Items before the entries filled in as the menu opens. }
    HistoryFixedCount, BookmarksFixedCount: LongInt;
  end;

{ Builds the menu bar in Parent with Window's keys; every command item
  runs Run. }
procedure BuildBrowserMenus(Window: TControlWindow; Parent: TControl; Run: TMenuItemEvent; out Menus: TBrowserMenus);
{ The item of Menu (or below it) with command Command (nil: none). }
function FindCommandItem(Menu: TMenuItem; Command: LongInt): TMenuItem;

implementation

uses
  Abi.SystemCalls,
  Controls.Keys,
  Browser.Commands;

type
  TMenuBuilder = record
    Window: TControlWindow;
    Run: TMenuItemEvent;
  end;

function AddCommand(constref Builder: TMenuBuilder; Menu: TMenuItem; const Text: string; Command: LongInt;
  const Shortcut: string = ''; Code: LongWord = 0; Modifiers: LongWord = 0): TMenuItem;
begin
  Result := Menu.Add(Text, Builder.Run, Shortcut);
  Result.Tag := Command;
  if Code <> 0 then
    AddItemAccelerator(Builder.Window, Result, Code, Modifiers);
end;

function FindCommandItem(Menu: TMenuItem; Command: LongInt): TMenuItem;
var
  Index: LongInt;
begin
  Result := nil;
  if Menu = nil then
    Exit;
  for Index := 0 to Menu.Count - 1 do
  begin
    if (Menu[Index].Tag = Command) and not Menu[Index].IsSeparator and (Menu[Index].Count = 0) then
      Exit(Menu[Index]);
    Result := FindCommandItem(Menu[Index], Command);
    if Result <> nil then
      Exit;
  end;
end;

procedure BuildFileMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&File');
  Menus.FileMenu := Menu;
  AddCommand(B, Menu, 'New &Window', CommandNewWindow, 'Ctrl+N', KeyN, ModifierControl);
  AddCommand(B, Menu, 'New &Tab', CommandNewTab, 'Ctrl+T', KeyT, ModifierControl);
  AddCommand(B, Menu, '&Open Location...', CommandOpenLocation, 'Ctrl+L');
  AddCommand(B, Menu, 'Open &File...', CommandOpenFile, 'Ctrl+O', KeyO, ModifierControl);
  AddCommand(B, Menu, '&Close Tab', CommandCloseTab, 'Ctrl+W', KeyW, ModifierControl);
  AddCommand(B, Menu, 'Close Win&dow', CommandCloseWindow, 'Ctrl+Shift+W', KeyW, ModifierControl or ModifierShift);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Save Page &As...', CommandSavePage, 'Ctrl+S', KeyS, ModifierControl);
  AddCommand(B, Menu, 'Sen&d Link...', CommandSendLink);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Page Set&up...', CommandPageSetup);
  AddCommand(B, Menu, 'Print Pre&view', CommandPrintPreview);
  AddCommand(B, Menu, '&Print...', CommandPrint, 'Ctrl+P', KeyP, ModifierControl);
  Menu.AddSeparator;
  AddCommand(B, Menu, '&Import...', CommandImport);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Wor&k Offline', CommandWorkOffline);
  AddCommand(B, Menu, 'E&xit', CommandExit, 'Ctrl+Q', KeyQ, ModifierControl);
end;

procedure BuildEditMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&Edit');
  Menus.EditMenu := Menu;
  { The edit keys go to what has the focus (an edit box or the page):
    the items run them from the menu only. }
  AddCommand(B, Menu, '&Undo', CommandUndo, 'Ctrl+Z');
  AddCommand(B, Menu, '&Redo', CommandRedo, 'Ctrl+Y');
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Cu&t', CommandCut, 'Ctrl+X');
  AddCommand(B, Menu, '&Copy', CommandCopy, 'Ctrl+C');
  AddCommand(B, Menu, '&Paste', CommandPaste, 'Ctrl+V');
  AddCommand(B, Menu, '&Delete', CommandDelete, 'Del');
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Select &All', CommandSelectAll, 'Ctrl+A');
  Menu.AddSeparator;
  AddCommand(B, Menu, '&Find...', CommandFind, 'Ctrl+F', KeyF, ModifierControl);
  AddCommand(B, Menu, 'Find A&gain', CommandFindAgain, 'F3', KeyF3, 0);
end;

procedure BuildViewMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu, Sub: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&View');
  Menus.ViewMenu := Menu;
  Sub := Menu.Add('&Toolbars');
  Menus.ToolbarsMenu := Sub;
  AddCommand(B, Sub, '&Menu Bar', CommandToggleMenuBar);
  AddCommand(B, Sub, '&Navigation Toolbar', CommandToggleNavigationToolbar);
  AddCommand(B, Sub, '&Bookmarks Toolbar', CommandToggleBookmarksToolbar);
  Sub.AddSeparator;
  AddCommand(B, Sub, '&Customize...', CommandCustomizeToolbars);
  AddCommand(B, Menu, 'Status &Bar', CommandToggleStatusBar);
  Sub := Menu.Add('Sid&ebar');
  Menus.SidebarMenu := Sub;
  AddCommand(B, Sub, '&Bookmarks', CommandSidebarBookmarks, 'Ctrl+B', KeyB, ModifierControl);
  AddCommand(B, Sub, '&History', CommandSidebarHistory, 'Ctrl+H', KeyH, ModifierControl);
  Menu.AddSeparator;
  AddCommand(B, Menu, '&Stop', CommandStop, 'Esc');
  AddCommand(B, Menu, '&Reload', CommandReload, 'F5', KeyF5, 0);
  Menu.AddSeparator;
  Sub := Menu.Add('&Zoom');
  Menus.ZoomMenu := Sub;
  AddCommand(B, Sub, 'Zoom &In', CommandZoomIn, 'Ctrl++', KeyEquals, ModifierControl);
  AddCommand(B, Sub, 'Zoom &Out', CommandZoomOut, 'Ctrl+-', KeyMinus, ModifierControl);
  Sub.AddSeparator;
  AddCommand(B, Sub, '&Reset', CommandZoomReset, 'Ctrl+0', Key0, ModifierControl);
  Sub.AddSeparator;
  AddCommand(B, Sub, 'Zoom &Text Only', CommandZoomTextOnly);
  Sub := Menu.Add('Page St&yle');
  Menus.PageStyleMenu := Sub;
  AddCommand(B, Sub, '&No Style', CommandPageStyleNone);
  AddCommand(B, Sub, '&Basic Page Style', CommandPageStyleBasic);
  Sub := Menu.Add('Character Enco&ding');
  Menus.EncodingMenu := Sub;
  AddCommand(B, Sub, '&Auto-Detect', CommandEncodingAuto);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Page So&urce', CommandPageSource, 'Ctrl+U', KeyU, ModifierControl);
  AddCommand(B, Menu, '&Full Screen', CommandFullScreen, 'F11', KeyF11, 0);
end;

procedure BuildHistoryMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('Hi&story');
  Menus.HistoryMenu := Menu;
  AddCommand(B, Menu, '&Back', CommandBack, 'Alt+Left', KeyArrowLeft, ModifierAlt);
  AddCommand(B, Menu, '&Forward', CommandForward, 'Alt+Right', KeyArrowRight, ModifierAlt);
  AddCommand(B, Menu, '&Home', CommandHome, 'Alt+Home', KeyHome, ModifierAlt);
  AddCommand(B, Menu, 'Show All &History', CommandShowAllHistory, 'Ctrl+Shift+H', KeyH,
    ModifierControl or ModifierShift);
  Menu.AddSeparator;
  Menus.ClosedTabsMenu := Menu.Add('Recently Closed &Tabs');
  Menus.ClosedWindowsMenu := Menu.Add('Recently Closed &Windows');
  Menu.AddSeparator;
  Menus.HistoryFixedCount := Menu.Count;
end;

procedure BuildBookmarksMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&Bookmarks');
  Menus.BookmarksMenu := Menu;
  AddCommand(B, Menu, '&Bookmark This Page', CommandBookmarkPage, 'Ctrl+D', KeyD, ModifierControl);
  AddCommand(B, Menu, 'S&ubscribe to This Page...', CommandSubscribePage);
  AddCommand(B, Menu, 'Bookmark &All Tabs...', CommandBookmarkAllTabs, 'Ctrl+Shift+D', KeyD,
    ModifierControl or ModifierShift);
  AddCommand(B, Menu, '&Organize Bookmarks...', CommandOrganizeBookmarks, 'Ctrl+Shift+B', KeyB,
    ModifierControl or ModifierShift);
  Menu.AddSeparator;
  Menus.ToolbarFolderMenu := Menu.Add('Bookmarks &Toolbar');
  Menus.RecentlyBookmarkedMenu := Menu.Add('Recently &Bookmarked');
  Menus.RecentTagsMenu := Menu.Add('Recent Ta&gs');
  Menu.AddSeparator;
  Menus.BookmarksFixedCount := Menu.Count;
end;

procedure BuildToolsMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&Tools');
  Menus.ToolsMenu := Menu;
  AddCommand(B, Menu, '&Web Search', CommandWebSearch, 'Ctrl+K', KeyK, ModifierControl);
  Menu.AddSeparator;
  AddCommand(B, Menu, '&Downloads', CommandDownloads, 'Ctrl+J', KeyJ, ModifierControl);
  AddCommand(B, Menu, '&Add-ons', CommandAddOns, 'Ctrl+Shift+A', KeyA, ModifierControl or ModifierShift);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Error &Console', CommandErrorConsole, 'Ctrl+Shift+J', KeyJ, ModifierControl or ModifierShift);
  AddCommand(B, Menu, 'Page &Info', CommandPageInfo, 'Ctrl+I', KeyI, ModifierControl);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Start &Private Browsing', CommandPrivateBrowsing, 'Ctrl+Shift+P', KeyP,
    ModifierControl or ModifierShift);
  AddCommand(B, Menu, 'Clear Recent &History...', CommandClearRecentHistory, 'Ctrl+Shift+Del', KeyDelete,
    ModifierControl or ModifierShift);
  Menu.AddSeparator;
  AddCommand(B, Menu, '&Options...', CommandOptions);
end;

procedure BuildHelpMenu(constref B: TMenuBuilder; var Menus: TBrowserMenus);
var
  Menu: TMenuItem;
begin
  Menu := Menus.Bar.Menu.Add('&Help');
  Menus.HelpMenu := Menu;
  AddCommand(B, Menu, '&Help Contents', CommandHelpContents, 'F1', KeyF1, 0);
  AddCommand(B, Menu, '&Troubleshooting Information', CommandTroubleshooting);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Report Web &Forgery...', CommandReportForgery);
  Menu.AddSeparator;
  AddCommand(B, Menu, 'Check for &Updates...', CommandCheckUpdates);
  Menu.AddSeparator;
  AddCommand(B, Menu, '&About Browser', CommandAbout);
end;

procedure BuildBrowserMenus(Window: TControlWindow; Parent: TControl; Run: TMenuItemEvent; out Menus: TBrowserMenus);
var
  Builder: TMenuBuilder;
begin
  Menus := Default(TBrowserMenus);
  Builder.Window := Window;
  Builder.Run := Run;
  Menus.Bar := TMenuBar.Create(Parent);
  Menus.Bar.AutoReveal := True;
  BuildFileMenu(Builder, Menus);
  BuildEditMenu(Builder, Menus);
  BuildViewMenu(Builder, Menus);
  BuildHistoryMenu(Builder, Menus);
  BuildBookmarksMenu(Builder, Menus);
  BuildToolsMenu(Builder, Menus);
  BuildHelpMenu(Builder, Menus);
end;

end.
