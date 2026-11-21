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
  browser - the web browser

  browser [ADDRESS...]

  A tab per ADDRESS (as typed in the address bar: a URL, a host, a
  path), else the home page (about:home unless set). Tabs (Ctrl+T,
  Ctrl+W, Ctrl+Tab, a middle click on a link), the address bar
  (Ctrl+L; not an address: the search URL if one is set, else a page
  saying so), back, forward, reload and stop, home, the bookmarks bar
  and menu (Ctrl+D), the history (about:history, Ctrl+H), downloads to
  ~/Downloads (about:downloads, Ctrl+J), find (Ctrl+F, F3), zoom
  (Ctrl++, Ctrl+-, Ctrl+0) and settings (Tools > Settings: home page,
  search URL, HTTP/3, JavaScript, the bookmarks bar). HTTP/3 comes from
  libquic. Prints what happens, a line each, for tests:

    tabs N               the number of tabs changed
    go URL               an address was gone to
    not-an-address TEXT  the address bar's text is no address
    location URL         a tab's page is now at URL
    title TEXT           a page's title
    state STATE          requesting, receiving, interactive, complete
    loaded URL           a page finished loading
    icon WxH             a page's icon arrived
    link URL             a link was followed
    found TEXT / not-found TEXT   find in page
    zoom PERCENT         the zoom changed
    bookmarked URL / unbookmarked URL
    download NAME started|done|failed|cancelled
    alert TEXT / confirm TEXT / prompt TEXT   a page's prompts
    console LEVEL TEXT   a page's console
    failed URL REASON    a page could not be loaded
    process WHAT N tab I a tab's content process: started PID, crashed
                         STATUS, hung, responsive, wait, stop,
                         script-interrupted COUNT
    exit                 the browser ends

  Pages run in content processes (/bin/webcontent, one per site,
  sandboxed). about:crash crashes the tab's process, about:kill ends it
  and about:hang makes it stop answering: for tests of what the browser
  does then (the tab shows it crashed, or a bar to wait or stop it).

  The units are in userland/browser (Browser.MainWindow and its parts).
}
program Browser;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  Http3.SystemConnections,
  WebView.Types,
  WebView.Network,
  WebView.Control,
  WebView.ContentProcesses,
  Browser.Settings,
  Browser.MainWindow;

var
  Window: TBrowserWindow;
  Index: Integer;
  Settings: TBrowserSettings;
begin
  EnableHttp3;
  Settings := LoadBrowserSettings;
  if not Settings.SeparateProcesses then
    DefaultWebViewProcessModel := ProcessModelInProcess;
  ContentProcesses.Sandboxed := Settings.Sandbox;
  ContentProcesses.HangTimeoutMilliseconds := QWord(Settings.HangTimeoutSeconds) * 1000;
  ContentProcesses.ScriptRunLimitMilliseconds := QWord(Settings.ScriptRunLimitSeconds) * 1000;
  Window := TBrowserWindow.Create;
  if ParamCount = 0 then
    Window.OpenTab(LoadBrowserSettings.HomePage, True)
  else
    for Index := 1 to ParamCount do
      Window.OpenTab(ParamStr(Index), Index = 1);
  Window.Show;
  RunMessageLoop;
  Window.Free;
  FreeContentProcesses;
end.
