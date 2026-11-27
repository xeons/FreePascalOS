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
  The browser's settings, the user's (group Browser), as the Options
  window shows them (Browser.Options.*), pane by pane:

  - Main: Startup (home, blank or session: what a new start shows),
    HomePage (about:home unless set; several separated by "|" open a
    tab each), DownloadFolder ('' ~/Downloads), AskWhereToSave,
    ShowDownloads (the Downloads window when a download starts),
    CloseDownloadsWhenDone.
  - Tabs: NewWindowsInTabs (links that ask for a new window open a tab),
    WarnClosingTabs, WarnOpeningTabs, AlwaysShowTabBar, SwitchToNewTabs.
  - Content: BlockPopups, LoadImages, JavaScript (with
    ScriptsMoveWindows, ScriptsRaiseWindows, ScriptsDisableMenus,
    ScriptsChangeStatus), DefaultFont, DefaultFontSize, Languages
    (preferred languages, comma separated).
  - Applications: ContentActions ("type=action" pairs, ";" separated;
    an action is save, ask or open).
  - Privacy: History (remember, never or custom), RememberHistory,
    RememberDownloads, RememberForms, AlwaysPrivate, AcceptCookies,
    ThirdPartyCookies, KeepCookies (expire, close or ask),
    CookiesAllowed, CookiesBlocked (host lists), ClearOnClose,
    ClearOnCloseAsk, ClearItems (what Clear Recent History clears, a
    letter each: h history, d downloads, f forms, c cookies, a cache,
    s logins, o offline data), LocationSuggest (both, history,
    bookmarks or nothing).
  - Security: WarnAddons, BlockAttackSites, BlockForgeries,
    RememberPasswords.
  - Advanced: General (CaretBrowsing, SearchWhenTyping, SmoothScrolling,
    CheckSpelling), Network (ProxyMode none, system or manual;
    ProxyHost, ProxyPort, NoProxyFor; Http3; CacheMegabytes), Update
    (CheckUpdates, a stub), Encryption (Ssl3, Tls1: offered protocols).

  The window's state: BookmarksToolbar, MenuBar, NavigationToolbar,
  StatusBar (shown or not), NavigationItems and BookmarksItems (the
  toolbars' items in order, comma separated, from Customize),
  ToolbarMode (icons, text or both), SmallIcons, SearchEngine (the one
  chosen: '' none, nothing is searched) and SearchUrl (its URL, which
  the location bar uses).

  How pages run (not in the window; for tests and for the curious):
  SeparateProcesses (pages in content processes, one per site; on),
  Sandbox (content processes restrict themselves; on), HangTimeout
  (seconds without an answer before a page is "not responding"; 8, 0
  never) and ScriptRunLimit (seconds a script may run before the slow
  script watchdog ends it; 10, 0 never).
}
unit Browser.Settings;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  DefaultHomePage = 'about:home';
  DefaultNavigationItems = 'back,forward,reload,stop,home,location,search';
  DefaultBookmarksItems = 'bookmarks';
  DefaultLanguages = 'en-us, en';

type
  TStartupMode = (StartupHomePage, StartupBlank, StartupSession);
  THistoryMode = (HistoryRemember, HistoryNever, HistoryCustom);
  TKeepCookies = (KeepUntilExpire, KeepUntilClose, KeepAsk);
  TProxyMode = (ProxyNone, ProxySystem, ProxyManual);
  TToolbarMode = (ToolbarIcons, ToolbarText, ToolbarIconsAndText);
  TLocationSuggest = (LocationSuggestBoth, LocationSuggestHistory, LocationSuggestBookmarks, LocationSuggestNothing);

  TBrowserSettings = record
    { Main. }
    Startup: TStartupMode;
    HomePage: string;
    DownloadFolder: string;
    AskWhereToSave: Boolean;
    ShowDownloads: Boolean;
    CloseDownloadsWhenDone: Boolean;
    { Tabs. }
    NewWindowsInTabs: Boolean;
    WarnClosingTabs: Boolean;
    WarnOpeningTabs: Boolean;
    AlwaysShowTabBar: Boolean;
    SwitchToNewTabs: Boolean;
    { Content. }
    BlockPopups: Boolean;
    LoadImages: Boolean;
    JavaScript: Boolean;
    ScriptsMoveWindows: Boolean;
    ScriptsRaiseWindows: Boolean;
    ScriptsDisableMenus: Boolean;
    ScriptsChangeStatus: Boolean;
    DefaultFont: string;
    DefaultFontSize: LongInt;
    Languages: string;
    { Applications. }
    ContentActions: string;
    { Privacy. }
    History: THistoryMode;
    RememberHistory: Boolean;
    RememberDownloads: Boolean;
    RememberForms: Boolean;
    AlwaysPrivate: Boolean;
    AcceptCookies: Boolean;
    ThirdPartyCookies: Boolean;
    KeepCookies: TKeepCookies;
    CookiesAllowed: string;
    CookiesBlocked: string;
    ClearOnClose: Boolean;
    ClearOnCloseAsk: Boolean;
    ClearItems: string;
    LocationSuggest: TLocationSuggest;
    { Security. }
    WarnAddons: Boolean;
    BlockAttackSites: Boolean;
    BlockForgeries: Boolean;
    RememberPasswords: Boolean;
    { Advanced. }
    CaretBrowsing: Boolean;
    SearchWhenTyping: Boolean;
    SmoothScrolling: Boolean;
    CheckSpelling: Boolean;
    ProxyMode: TProxyMode;
    ProxyHost: string;
    ProxyPort: LongInt;
    NoProxyFor: string;
    Http3: Boolean;
    CacheMegabytes: LongInt;
    CheckUpdates: Boolean;
    Ssl3: Boolean;
    Tls1: Boolean;
    { The window. }
    MenuBar: Boolean;
    NavigationToolbar: Boolean;
    BookmarksToolbar: Boolean;
    StatusBar: Boolean;
    NavigationItems: string;
    BookmarksItems: string;
    ToolbarMode: TToolbarMode;
    SmallIcons: Boolean;
    SearchEngine: string;
    SearchUrl: string;
    { How pages run. }
    SeparateProcesses: Boolean;
    Sandbox: Boolean;
    HangTimeoutSeconds: LongInt;
    ScriptRunLimitSeconds: LongInt;
  end;

function LoadBrowserSettings: TBrowserSettings;
procedure SaveBrowserSettings(constref Settings: TBrowserSettings);
{ The settings a new profile has (what Load gives without any stored). }
function DefaultBrowserSettings: TBrowserSettings;
{ Whether visits are kept, with the Privacy pane's choices. }
function KeepsHistory(constref Settings: TBrowserSettings): Boolean;
{ The home pages ("|" between several). }
function HomePages(constref Settings: TBrowserSettings): TStringArray;

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  Group = 'Browser/';
  StartupNames: array[TStartupMode] of string = ('home', 'blank', 'session');
  HistoryNames: array[THistoryMode] of string = ('remember', 'never', 'custom');
  KeepCookieNames: array[TKeepCookies] of string = ('expire', 'close', 'ask');
  ProxyNames: array[TProxyMode] of string = ('none', 'system', 'manual');
  ToolbarModeNames: array[TToolbarMode] of string = ('icons', 'text', 'both');
  SuggestNames: array[TLocationSuggest] of string = ('both', 'history', 'bookmarks', 'nothing');

function DefaultBrowserSettings: TBrowserSettings;
begin
  Result := Default(TBrowserSettings);
  Result.Startup := StartupHomePage;
  Result.HomePage := DefaultHomePage;
  Result.ShowDownloads := True;
  Result.NewWindowsInTabs := True;
  Result.WarnClosingTabs := True;
  Result.WarnOpeningTabs := True;
  Result.AlwaysShowTabBar := True;
  Result.BlockPopups := True;
  Result.LoadImages := True;
  Result.JavaScript := True;
  Result.ScriptsMoveWindows := True;
  Result.ScriptsRaiseWindows := True;
  Result.ScriptsDisableMenus := True;
  Result.ScriptsChangeStatus := False;
  Result.DefaultFont := 'Sans';
  Result.DefaultFontSize := 16;
  Result.Languages := DefaultLanguages;
  Result.History := HistoryRemember;
  Result.RememberHistory := True;
  Result.RememberDownloads := True;
  Result.RememberForms := True;
  Result.AcceptCookies := True;
  Result.ThirdPartyCookies := True;
  Result.KeepCookies := KeepUntilExpire;
  Result.ClearItems := 'hdfca';
  Result.LocationSuggest := LocationSuggestBoth;
  Result.WarnAddons := True;
  Result.BlockAttackSites := True;
  Result.BlockForgeries := True;
  Result.RememberPasswords := True;
  Result.SearchWhenTyping := False;
  Result.SmoothScrolling := True;
  Result.CheckSpelling := True;
  Result.ProxyMode := ProxySystem;
  Result.ProxyPort := 8080;
  Result.NoProxyFor := 'localhost, 127.0.0.1';
  Result.Http3 := True;
  Result.CacheMegabytes := 50;
  Result.CheckUpdates := True;
  Result.Ssl3 := False;
  Result.Tls1 := True;
  Result.MenuBar := True;
  Result.NavigationToolbar := True;
  Result.BookmarksToolbar := True;
  Result.StatusBar := True;
  Result.NavigationItems := DefaultNavigationItems;
  Result.BookmarksItems := DefaultBookmarksItems;
  Result.ToolbarMode := ToolbarIcons;
  Result.SmallIcons := False;
  Result.SeparateProcesses := True;
  Result.Sandbox := True;
  Result.HangTimeoutSeconds := 8;
  Result.ScriptRunLimitSeconds := 10;
end;

function ReadChoice(Store: TSettings; const Name: string; const Names: array of string; Default: Integer): Integer;
var
  Value: string;
  Index: Integer;
begin
  Value := LowerCase(Store.ReadString(Group + Name, Names[Default]));
  for Index := 0 to High(Names) do
    if Names[Index] = Value then
      Exit(Index);
  Result := Default;
end;

function LoadBrowserSettings: TBrowserSettings;
var
  Store: TSettings;
  D: TBrowserSettings;

  function B(const Name: string; Value: Boolean): Boolean;
  begin
    Result := Store.ReadBoolean(Group + Name, Value);
  end;

  function S(const Name, Value: string): string;
  begin
    Result := Store.ReadString(Group + Name, Value);
  end;

begin
  D := DefaultBrowserSettings;
  Result := D;
  Store := OpenSettings;
  try
    Result.Startup := TStartupMode(ReadChoice(Store, 'Startup', StartupNames, Ord(D.Startup)));
    Result.HomePage := S('HomePage', D.HomePage);
    if Trim(Result.HomePage) = '' then
      Result.HomePage := DefaultHomePage;
    Result.DownloadFolder := S('DownloadFolder', '');
    Result.AskWhereToSave := B('AskWhereToSave', D.AskWhereToSave);
    Result.ShowDownloads := B('ShowDownloads', D.ShowDownloads);
    Result.CloseDownloadsWhenDone := B('CloseDownloadsWhenDone', D.CloseDownloadsWhenDone);
    Result.NewWindowsInTabs := B('NewWindowsInTabs', D.NewWindowsInTabs);
    Result.WarnClosingTabs := B('WarnClosingTabs', D.WarnClosingTabs);
    Result.WarnOpeningTabs := B('WarnOpeningTabs', D.WarnOpeningTabs);
    Result.AlwaysShowTabBar := B('AlwaysShowTabBar', D.AlwaysShowTabBar);
    Result.SwitchToNewTabs := B('SwitchToNewTabs', D.SwitchToNewTabs);
    Result.BlockPopups := B('BlockPopups', D.BlockPopups);
    Result.LoadImages := B('LoadImages', D.LoadImages);
    Result.JavaScript := B('JavaScript', D.JavaScript);
    Result.ScriptsMoveWindows := B('ScriptsMoveWindows', D.ScriptsMoveWindows);
    Result.ScriptsRaiseWindows := B('ScriptsRaiseWindows', D.ScriptsRaiseWindows);
    Result.ScriptsDisableMenus := B('ScriptsDisableMenus', D.ScriptsDisableMenus);
    Result.ScriptsChangeStatus := B('ScriptsChangeStatus', D.ScriptsChangeStatus);
    Result.DefaultFont := S('DefaultFont', D.DefaultFont);
    Result.DefaultFontSize := Store.ReadIntegerWithin(Group + 'DefaultFontSize', D.DefaultFontSize, 6, 72);
    Result.Languages := S('Languages', D.Languages);
    Result.ContentActions := S('ContentActions', D.ContentActions);
    Result.History := THistoryMode(ReadChoice(Store, 'History', HistoryNames, Ord(D.History)));
    Result.RememberHistory := B('RememberHistory', D.RememberHistory);
    Result.RememberDownloads := B('RememberDownloads', D.RememberDownloads);
    Result.RememberForms := B('RememberForms', D.RememberForms);
    Result.AlwaysPrivate := B('AlwaysPrivate', D.AlwaysPrivate);
    Result.AcceptCookies := B('AcceptCookies', D.AcceptCookies);
    Result.ThirdPartyCookies := B('ThirdPartyCookies', D.ThirdPartyCookies);
    Result.KeepCookies := TKeepCookies(ReadChoice(Store, 'KeepCookies', KeepCookieNames, Ord(D.KeepCookies)));
    Result.CookiesAllowed := S('CookiesAllowed', '');
    Result.CookiesBlocked := S('CookiesBlocked', '');
    Result.ClearOnClose := B('ClearOnClose', D.ClearOnClose);
    Result.ClearOnCloseAsk := B('ClearOnCloseAsk', D.ClearOnCloseAsk);
    Result.ClearItems := S('ClearItems', D.ClearItems);
    Result.LocationSuggest := TLocationSuggest(ReadChoice(Store, 'LocationSuggest', SuggestNames,
      Ord(D.LocationSuggest)));
    Result.WarnAddons := B('WarnAddons', D.WarnAddons);
    Result.BlockAttackSites := B('BlockAttackSites', D.BlockAttackSites);
    Result.BlockForgeries := B('BlockForgeries', D.BlockForgeries);
    Result.RememberPasswords := B('RememberPasswords', D.RememberPasswords);
    Result.CaretBrowsing := B('CaretBrowsing', D.CaretBrowsing);
    Result.SearchWhenTyping := B('SearchWhenTyping', D.SearchWhenTyping);
    Result.SmoothScrolling := B('SmoothScrolling', D.SmoothScrolling);
    Result.CheckSpelling := B('CheckSpelling', D.CheckSpelling);
    Result.ProxyMode := TProxyMode(ReadChoice(Store, 'ProxyMode', ProxyNames, Ord(D.ProxyMode)));
    Result.ProxyHost := S('ProxyHost', '');
    Result.ProxyPort := Store.ReadIntegerWithin(Group + 'ProxyPort', D.ProxyPort, 1, 65535);
    Result.NoProxyFor := S('NoProxyFor', D.NoProxyFor);
    Result.Http3 := B('Http3', D.Http3);
    Result.CacheMegabytes := Store.ReadIntegerWithin(Group + 'CacheMegabytes', D.CacheMegabytes, 0, 1024);
    Result.CheckUpdates := B('CheckUpdates', D.CheckUpdates);
    Result.Ssl3 := B('Ssl3', D.Ssl3);
    Result.Tls1 := B('Tls1', D.Tls1);
    Result.MenuBar := B('MenuBar', D.MenuBar);
    Result.NavigationToolbar := B('NavigationToolbar', D.NavigationToolbar);
    Result.BookmarksToolbar := B('BookmarksBar', D.BookmarksToolbar);
    Result.StatusBar := B('StatusBar', D.StatusBar);
    Result.NavigationItems := S('NavigationItems', D.NavigationItems);
    Result.BookmarksItems := S('BookmarksItems', D.BookmarksItems);
    Result.ToolbarMode := TToolbarMode(ReadChoice(Store, 'ToolbarMode', ToolbarModeNames, Ord(D.ToolbarMode)));
    Result.SmallIcons := B('SmallIcons', D.SmallIcons);
    Result.SearchEngine := S('SearchEngine', '');
    Result.SearchUrl := S('SearchUrl', '');
    Result.SeparateProcesses := B('SeparateProcesses', D.SeparateProcesses);
    Result.Sandbox := B('Sandbox', D.Sandbox);
    Result.HangTimeoutSeconds := Store.ReadIntegerWithin(Group + 'HangTimeout', D.HangTimeoutSeconds, 0, 3600);
    Result.ScriptRunLimitSeconds := Store.ReadIntegerWithin(Group + 'ScriptRunLimit', D.ScriptRunLimitSeconds, 0,
      3600);
  finally
    Store.Free;
  end;
end;

{ Freeing the settings flushes them. How pages run is not written: it is
  set by hand. }
procedure SaveBrowserSettings(constref Settings: TBrowserSettings);
var
  Store: TSettings;

  procedure B(const Name: string; Value: Boolean);
  begin
    Store.WriteBoolean(Group + Name, Value);
  end;

  procedure S(const Name, Value: string);
  begin
    Store.WriteString(Group + Name, Value);
  end;

  procedure I(const Name: string; Value: Int64);
  begin
    Store.WriteInteger(Group + Name, Value);
  end;

begin
  Store := OpenSettings;
  try
    S('Startup', StartupNames[Settings.Startup]);
    S('HomePage', Settings.HomePage);
    S('DownloadFolder', Settings.DownloadFolder);
    B('AskWhereToSave', Settings.AskWhereToSave);
    B('ShowDownloads', Settings.ShowDownloads);
    B('CloseDownloadsWhenDone', Settings.CloseDownloadsWhenDone);
    B('NewWindowsInTabs', Settings.NewWindowsInTabs);
    B('WarnClosingTabs', Settings.WarnClosingTabs);
    B('WarnOpeningTabs', Settings.WarnOpeningTabs);
    B('AlwaysShowTabBar', Settings.AlwaysShowTabBar);
    B('SwitchToNewTabs', Settings.SwitchToNewTabs);
    B('BlockPopups', Settings.BlockPopups);
    B('LoadImages', Settings.LoadImages);
    B('JavaScript', Settings.JavaScript);
    B('ScriptsMoveWindows', Settings.ScriptsMoveWindows);
    B('ScriptsRaiseWindows', Settings.ScriptsRaiseWindows);
    B('ScriptsDisableMenus', Settings.ScriptsDisableMenus);
    B('ScriptsChangeStatus', Settings.ScriptsChangeStatus);
    S('DefaultFont', Settings.DefaultFont);
    I('DefaultFontSize', Settings.DefaultFontSize);
    S('Languages', Settings.Languages);
    S('ContentActions', Settings.ContentActions);
    S('History', HistoryNames[Settings.History]);
    B('RememberHistory', Settings.RememberHistory);
    B('RememberDownloads', Settings.RememberDownloads);
    B('RememberForms', Settings.RememberForms);
    B('AlwaysPrivate', Settings.AlwaysPrivate);
    B('AcceptCookies', Settings.AcceptCookies);
    B('ThirdPartyCookies', Settings.ThirdPartyCookies);
    S('KeepCookies', KeepCookieNames[Settings.KeepCookies]);
    S('CookiesAllowed', Settings.CookiesAllowed);
    S('CookiesBlocked', Settings.CookiesBlocked);
    B('ClearOnClose', Settings.ClearOnClose);
    B('ClearOnCloseAsk', Settings.ClearOnCloseAsk);
    S('ClearItems', Settings.ClearItems);
    S('LocationSuggest', SuggestNames[Settings.LocationSuggest]);
    B('WarnAddons', Settings.WarnAddons);
    B('BlockAttackSites', Settings.BlockAttackSites);
    B('BlockForgeries', Settings.BlockForgeries);
    B('RememberPasswords', Settings.RememberPasswords);
    B('CaretBrowsing', Settings.CaretBrowsing);
    B('SearchWhenTyping', Settings.SearchWhenTyping);
    B('SmoothScrolling', Settings.SmoothScrolling);
    B('CheckSpelling', Settings.CheckSpelling);
    S('ProxyMode', ProxyNames[Settings.ProxyMode]);
    S('ProxyHost', Settings.ProxyHost);
    I('ProxyPort', Settings.ProxyPort);
    S('NoProxyFor', Settings.NoProxyFor);
    B('Http3', Settings.Http3);
    I('CacheMegabytes', Settings.CacheMegabytes);
    B('CheckUpdates', Settings.CheckUpdates);
    B('Ssl3', Settings.Ssl3);
    B('Tls1', Settings.Tls1);
    B('MenuBar', Settings.MenuBar);
    B('NavigationToolbar', Settings.NavigationToolbar);
    B('BookmarksBar', Settings.BookmarksToolbar);
    B('StatusBar', Settings.StatusBar);
    S('NavigationItems', Settings.NavigationItems);
    S('BookmarksItems', Settings.BookmarksItems);
    S('ToolbarMode', ToolbarModeNames[Settings.ToolbarMode]);
    B('SmallIcons', Settings.SmallIcons);
    S('SearchEngine', Settings.SearchEngine);
    S('SearchUrl', Settings.SearchUrl);
  finally
    Store.Free;
  end;
end;

function KeepsHistory(constref Settings: TBrowserSettings): Boolean;
begin
  case Settings.History of
    HistoryNever:
      Result := False;
    HistoryCustom:
      Result := Settings.RememberHistory and not Settings.AlwaysPrivate;
  else
    Result := True;
  end;
end;

function HomePages(constref Settings: TBrowserSettings): TStringArray;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Result := nil;
  Parts := Settings.HomePage.Split(['|']);
  for Index := 0 to High(Parts) do
    if Trim(Parts[Index]) <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Trim(Parts[Index]);
    end;
  if Length(Result) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := DefaultHomePage;
  end;
end;

end.
