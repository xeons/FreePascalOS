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
  The browser's own pages, made as they are asked for (the fetcher's
  about: provider): about:home (the start page: bookmarks and recent
  pages), about:history, about:bookmarks, about:downloads, about:help
  (Help Contents), about:support (Troubleshooting Information: the
  browser, the engine, the processes), about:addons (none yet),
  about:privatebrowsing, about:license, and the page shown for text
  that is not an address. They take the theme's colours
  (the golden header band, the face, the selection), so they match the
  window in either theme.
}
unit Browser.AboutPages;

{$mode objfpc}
{$H+}

interface

uses
  Browser.History,
  Browser.Bookmarks,
  Browser.Downloads;

type
  TAboutPages = class
  private
    FHistory: THistoryStore;
    FBookmarks: TBookmarkStore;
    FDownloads: TDownloadManager;
    function HomePage: string;
    function HistoryPage: string;
    function BookmarksPage: string;
    function DownloadsPage: string;
    function HelpPage: string;
    function SupportPage: string;
    function AddonsPage: string;
    function PrivatePage: string;
    function LicensePage: string;
  public
    constructor Create(History: THistoryStore; Bookmarks: TBookmarkStore; Downloads: TDownloadManager);
    { The fetcher's provider: the HTML for about:Path. }
    function Provide(const Path: string; out Html: string): Boolean;
  end;

{ Text with &, <, > and " escaped. }
function EscapeHtml(const Text: string): string;
{ The page for address bar text that is not an address. }
function InvalidAddressPage(const Text: string): string;
{ The page shell: the theme's style sheet around Body. }
function ThemedPage(const Title, Body: string): string;

implementation

uses
  SysUtils,
  Math,
  DateUtils,
  Drawing.Colors,
  Windowing.Theme,
  WebIpc.Messages,
  WebView.Network,
  WebView.ContentProcesses,
  Browser.Profile;

const
  RecentCount = 8;
  HistoryPageLimit = 500;

function EscapeHtml(const Text: string): string;
begin
  Result := StringReplace(Text, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function CssColor(Color: TColor): string;
begin
  Result := '#' + IntToHex((Color shr 16) and $FF, 2) + IntToHex((Color shr 8) and $FF, 2) + IntToHex(Color and $FF, 2);
end;

function ThemedPage(const Title, Body: string): string;
var
  BandTop, BandBottom, BandText, Face, FaceText, Field, Link, Edge: string;
begin
  BandTop := CssColor(Theme.HeaderBandTop);
  BandBottom := CssColor(Theme.HeaderBandBottom);
  BandText := CssColor(Theme.HeaderBandText);
  if not Theme.HeaderBandsShown then
  begin
    BandTop := CssColor(Theme.ActiveTitleStart);
    BandBottom := CssColor(Theme.ActiveTitleEnd);
    BandText := CssColor(Theme.ActiveTitleText);
  end;
  Face := CssColor(Theme.Face);
  FaceText := CssColor(Theme.FaceText);
  Field := CssColor(Theme.Field);
  Link := CssColor(Theme.Selection);
  Edge := CssColor(Theme.Shadow);
  Result := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + EscapeHtml(Title) + '</title><style>' +
    'body { margin: 0; background: ' + Face + '; color: ' + FaceText + '; font-family: sans-serif; font-size: 15px }' +
    'header { background: linear-gradient(' + BandTop + ', ' + BandBottom + '); color: ' + BandText + ';' +
    ' padding: 18px 32px; border-bottom: 1px solid ' + Edge + ' }' +
    'header h1 { margin: 0; font-size: 26px }' +
    'header p { margin: 4px 0 0 0; opacity: 0.85 }' +
    'main { padding: 20px 32px; max-width: 900px }' +
    'h2 { font-size: 17px; margin: 22px 0 8px 0; border-bottom: 1px solid ' + Edge + '; padding-bottom: 4px }' +
    'a { color: ' + Link + '; text-decoration: none } a:hover { text-decoration: underline }' +
    '.tiles { display: flex; flex-wrap: wrap; gap: 12px }' +
    '.tile { display: block; width: 180px; padding: 12px; background: ' + Field + '; border: 1px solid ' + Edge + ';' +
    ' border-radius: 6px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis }' +
    '.tile small { display: block; color: ' + FaceText + '; opacity: 0.7; overflow: hidden }' +
    'table { border-collapse: collapse; width: 100%; background: ' + Field + '; border: 1px solid ' + Edge + ' }' +
    'td, th { padding: 6px 10px; text-align: left; border-bottom: 1px solid ' + Face + ' }' +
    'th { background: ' + Face + ' }' +
    '.quiet { opacity: 0.7 }' +
    '.links a { margin-right: 18px }' +
    '</style></head><body>' + Body + '</body></html>';
end;

function InvalidAddressPage(const Text: string): string;
begin
  Result := ThemedPage('Not an address',
    '<header><h1>Not an address</h1><p>' + EscapeHtml(Text) + '</p></header><main>' +
    '<p>The text typed in the location bar is not a web address, and no search engine is chosen, so it was not ' +
    'sent anywhere.</p>' +
    '<p>Type an address such as <b>example.com</b>, <b>https://example.com/</b> or <b>/home/user/page.html</b>, ' +
    'or choose a search engine in the search bar''s menu (beside the location bar) or in Tools &gt; Options &gt; ' +
    'Main to search for words typed here.</p></main>');
end;

constructor TAboutPages.Create(History: THistoryStore; Bookmarks: TBookmarkStore; Downloads: TDownloadManager);
begin
  inherited Create;
  FHistory := History;
  FBookmarks := Bookmarks;
  FDownloads := Downloads;
end;

function TAboutPages.Provide(const Path: string; out Html: string): Boolean;
begin
  Result := True;
  if Path = 'home' then
    Html := HomePage
  else if Path = 'history' then
    Html := HistoryPage
  else if Path = 'bookmarks' then
    Html := BookmarksPage
  else if Path = 'downloads' then
    Html := DownloadsPage
  else if (Path = 'help') or (Copy(Path, 1, 5) = 'help#') then
    Html := HelpPage
  else if Path = 'support' then
    Html := SupportPage
  else if Path = 'addons' then
    Html := AddonsPage
  else if Path = 'privatebrowsing' then
    Html := PrivatePage
  else if Path = 'license' then
    Html := LicensePage
  else
  begin
    Html := '';
    Result := False;
  end;
end;

function Tile(const Url, Title: string): string;
var
  Shown: string;
begin
  Shown := Title;
  if Shown = '' then
    Shown := Url;
  Result := '<a class="tile" href="' + EscapeHtml(Url) + '">' + EscapeHtml(Shown) + '<small>' + EscapeHtml(Url) +
    '</small></a>';
end;

function TAboutPages.HomePage: string;
var
  Body: string;
  Index: Integer;
  Places: THistoryPlaceList;
  Toolbar: TBookmarkNode;
  Shown: Integer;
begin
  Body := '<header><h1>Browser</h1><p>FreePascalOS</p></header><main>' +
    '<p class="links"><a href="about:bookmarks">Bookmarks</a><a href="about:history">History</a>' +
    '<a href="about:downloads">Downloads</a><a href="about:help">Help</a></p>';
  Body := Body + '<h2>Bookmarks Toolbar</h2>';
  Toolbar := FBookmarks.ToolbarFolder;
  Shown := 0;
  Body := Body + '<div class="tiles">';
  for Index := 0 to Toolbar.Count - 1 do
    if Toolbar[Index].Kind = BookmarkItem then
    begin
      Body := Body + Tile(Toolbar[Index].Url, Toolbar[Index].Title);
      Inc(Shown);
    end;
  Body := Body + '</div>';
  if Shown = 0 then
    Body := Body + '<p class="quiet">No bookmarks on the toolbar yet: press Ctrl+D on a page, or drag a page''s ' +
      'icon from the location bar to the bookmarks toolbar.</p>';
  Body := Body + '<h2>Recently visited</h2><div class="tiles">';
  Shown := 0;
  Places := FHistory.RecentPlaces(RecentCount * 2);
  for Index := 0 to High(Places) do
    if (Shown < RecentCount) and (Pos('about:', Places[Index].Url) <> 1) then
    begin
      Body := Body + Tile(Places[Index].Url, Places[Index].Title);
      Inc(Shown);
    end;
  Body := Body + '</div>';
  if Shown = 0 then
    Body := Body + '<p class="quiet">Pages you visit will be listed here.</p>';
  Result := ThemedPage('New Tab', Body + '</main>');
end;

function FormatVisitTime(UnixTime: Int64): string;
begin
  if UnixTime <= 0 then
    Exit('');
  Result := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(UnixTime));
end;

function TAboutPages.HistoryPage: string;
var
  Body, Title: string;
  Places: THistoryPlaceList;
  Index: Integer;
begin
  Places := FHistory.Places;
  Body := '<header><h1>History</h1><p>' + IntToStr(Length(Places)) + ' pages (Ctrl+Shift+H shows them in the ' +
    'Library)</p></header><main>';
  if Length(Places) = 0 then
    Body := Body + '<p class="quiet">No pages visited yet.</p>'
  else
  begin
    Body := Body + '<table><tr><th>Last visit</th><th>Page</th><th>Visits</th></tr>';
    for Index := 0 to Min(High(Places), HistoryPageLimit - 1) do
    begin
      Title := Places[Index].Title;
      if Title = '' then
        Title := Places[Index].Url;
      Body := Body + '<tr><td class="quiet">' + FormatVisitTime(Places[Index].LastVisit) + '</td><td><a href="' +
        EscapeHtml(Places[Index].Url) + '">' + EscapeHtml(Title) + '</a><br><small class="quiet">' +
        EscapeHtml(Places[Index].Url) + '</small></td><td>' + IntToStr(Places[Index].VisitCount) + '</td></tr>';
    end;
    Body := Body + '</table>';
  end;
  Result := ThemedPage('History', Body + '</main>');
end;

function TAboutPages.BookmarksPage: string;
var
  Body: string;
  Marks: TBookmarkNodeList;
  Index: Integer;
begin
  Marks := FBookmarks.AllBookmarks;
  Body := '<header><h1>Bookmarks</h1><p>' + IntToStr(Length(Marks)) + ' pages (Ctrl+Shift+B organizes them)</p>' +
    '</header><main>';
  if Length(Marks) = 0 then
    Body := Body + '<p class="quiet">No bookmarks yet: press Ctrl+D on a page.</p>'
  else
  begin
    Body := Body + '<table><tr><th>Page</th><th>Folder</th><th>Tags</th></tr>';
    for Index := 0 to High(Marks) do
      Body := Body + '<tr><td><a href="' + EscapeHtml(Marks[Index].Url) + '">' +
        EscapeHtml(Marks[Index].ShownTitle) + '</a><br><small class="quiet">' + EscapeHtml(Marks[Index].Url) +
        '</small></td><td>' + EscapeHtml(Marks[Index].Parent.ShownTitle) + '</td><td class="quiet">' +
        EscapeHtml(Marks[Index].TagText) + '</td></tr>';
    Body := Body + '</table>';
  end;
  Result := ThemedPage('Bookmarks', Body + '</main>');
end;

function TAboutPages.DownloadsPage: string;
const
  StateNames: array[TDownloadState] of string = ('Downloading', 'Done', 'Failed', 'Cancelled', 'Paused');
var
  Body, State: string;
  Index: Integer;
  Item: TDownloadItem;
begin
  Body := '<header><h1>Downloads</h1><p>Saved in ' + EscapeHtml(DownloadsFolder) + '</p></header><main>';
  if FDownloads.Count = 0 then
    Body := Body + '<p class="quiet">Nothing downloaded in this session.</p>'
  else
  begin
    Body := Body + '<table><tr><th>File</th><th>State</th><th>Size</th></tr>';
    for Index := FDownloads.Count - 1 downto 0 do
    begin
      Item := FDownloads.Items[Index];
      State := StateNames[Item.State];
      if Item.ErrorText <> '' then
        State := State + ': ' + Item.ErrorText;
      Body := Body + '<tr><td><a href="file://' + EscapeHtml(Item.Path) + '">' + EscapeHtml(Item.FileName) +
        '</a><br><small class="quiet">' + EscapeHtml(Item.Url) + '</small></td><td>' + EscapeHtml(State) +
        '</td><td>' + SizeText(Item.Received) + '</td></tr>';
    end;
    Body := Body + '</table>';
  end;
  Result := ThemedPage('Downloads', Body + '</main>');
end;

function TAboutPages.HelpPage: string;

  function Keys(const Rows: array of string): string;
  var
    Index: Integer;
  begin
    Result := '<table>';
    Index := 0;
    while Index < High(Rows) do
    begin
      Result := Result + '<tr><td><b>' + EscapeHtml(Rows[Index]) + '</b></td><td>' + EscapeHtml(Rows[Index + 1]) +
        '</td></tr>';
      Inc(Index, 2);
    end;
    Result := Result + '</table>';
  end;

begin
  Result := ThemedPage('Tuxcat Help',
    '<header><h1>Tuxcat Help</h1><p>Getting around the browser</p></header><main>' +
    '<h2>The window</h2><p>From the top: the menu bar (View &gt; Toolbars hides it; Alt shows it again), the ' +
    'Navigation Toolbar (Back and Forward - hold them or right-click for the pages before and after; Reload, Stop, ' +
    'Home; the location bar; the search bar), the Bookmarks Toolbar, the tabs, the page, the find bar and the ' +
    'status bar. View &gt; Toolbars &gt; Customize... lets you drag buttons to and from the toolbars.</p>' +
    '<h2>The location bar</h2><p>Type an address, or words from the title, address or tags of a page you have ' +
    'visited or bookmarked: matching pages are suggested as you type. A first word that is a bookmark''s or a ' +
    'search engine''s keyword goes there. Special words narrow the suggestions: ^ history, * bookmarks, + tagged ' +
    'pages, @ addresses only, # titles only.</p>' +
    '<h2>Searching</h2><p>No search engine is chosen at first, so nothing you type is sent anywhere. Pick one in ' +
    'the search bar''s menu (the button at its left) or in Tools &gt; Options &gt; Main; Manage Search Engines... ' +
    'adds, removes, orders them and gives them keywords.</p>' +
    '<h2>Keys</h2>' + Keys(['Ctrl+T', 'New tab', 'Ctrl+W', 'Close tab', 'Ctrl+Shift+T', 'Undo close tab',
    'Ctrl+Tab, Ctrl+Shift+Tab', 'Next and previous tab', 'Ctrl+1 to Ctrl+9', 'Choose a tab (9: the last)',
    'Ctrl+N', 'New window', 'Ctrl+L, F6, Alt+D', 'Location bar', 'Ctrl+K', 'Search bar', 'Ctrl+D',
    'Bookmark this page', 'Ctrl+Shift+D', 'Bookmark all tabs', 'Ctrl+B', 'Bookmarks sidebar', 'Ctrl+H',
    'History sidebar', 'Ctrl+Shift+B', 'Organize bookmarks', 'Ctrl+Shift+H', 'Show all history', 'Ctrl+J',
    'Downloads', 'Ctrl+U', 'Page source', 'Ctrl+I', 'Page info', 'Ctrl+F, F3, Shift+F3', 'Find, again, previous',
    'F5, Ctrl+F5', 'Reload, reload past the cache', 'Alt+Left, Alt+Right, Alt+Home', 'Back, forward, home',
    'Ctrl++, Ctrl+-, Ctrl+0', 'Zoom in, out, reset', 'F11', 'Full screen', 'Ctrl+Shift+P', 'Private browsing',
    'Ctrl+Shift+Del', 'Clear recent history', 'Ctrl+Shift+J', 'Error console']) +
    '<h2 id="options">Options</h2><p>Tools &gt; Options...: Main (start-up, home page, downloads, search engine), ' +
    'Tabs, Content (pop-ups, images, JavaScript, fonts, languages), Applications (what downloads do), Privacy ' +
    '(history, cookies, clearing, location bar suggestions), Security (passwords) and Advanced (accessibility, ' +
    'network and cache, encryption and certificates).</p></main>');
end;

function TAboutPages.SupportPage: string;
var
  Rows: string;

  procedure Row(const Name, Value: string);
  begin
    Rows := Rows + '<tr><td>' + EscapeHtml(Name) + '</td><td>' + EscapeHtml(Value) + '</td></tr>';
  end;

begin
  Rows := '';
  Row('Name', 'Tuxcat');
  Row('Version', '2.0');
  Row('User agent', WebViewUserAgent);
  Row('Profile folder', BrowserProfileFolder);
  Row('Content processes', IntToStr(ContentProcesses.ProcessCount) + ' (one per site, at most 30)');
  Row('Sandboxed', BoolToStr(ContentProcesses.Sandboxed, 'yes', 'no'));
  Row('Process protocol', 'version ' + IntToStr(WebIpcProtocolVersion));
  Row('HTTP/3', BoolToStr(Http3Allowed, 'allowed', 'off'));
  Row('Private browsing', BoolToStr(PrivateBrowsing, 'on', 'off'));
  Row('Working offline', BoolToStr(WorkOffline, 'yes', 'no'));
  Row('HTTP cache', IntToStr(HttpCacheBytes div 1024) + ' KiB');
  Row('Cookies', IntToStr(Length(ListCookies)));
  Row('History', IntToStr(FHistory.Count) + ' visits');
  Row('Bookmarks', IntToStr(Length(FBookmarks.AllBookmarks)));
  Row('Downloads', IntToStr(FDownloads.Count));
  Result := ThemedPage('Troubleshooting Information',
    '<header><h1>Troubleshooting Information</h1><p>What the browser is running on, for when something goes ' +
    'wrong</p></header><main><h2>Application basics</h2><table>' + Rows + '</table>' +
    '<h2>Engine</h2><table><tr><td>Layout and scripts</td><td>libweb, libcss, libjavascript</td></tr>' +
    '<tr><td>Network</td><td>libhttp (HTTP/1.1, HTTP/2), libquic (HTTP/3), libtls (TLS 1.2, 1.3)</td></tr>' +
    '<tr><td>Pictures</td><td>libimage, libsvg</td></tr></table></main>');
end;

function TAboutPages.AddonsPage: string;
begin
  Result := ThemedPage('Add-ons Manager',
    '<header><h1>Add-ons</h1><p>Extensions, themes and plugins</p></header><main>' +
    '<h2>Extensions</h2><p class="quiet">No extensions are installed.</p>' +
    '<h2>Themes</h2><p class="quiet">The browser follows the system''s theme (Sunrise or Classic: Control Panel ' +
    '&gt; Appearance).</p><h2>Plugins</h2><p class="quiet">No plugins are installed.</p></main>');
end;

function TAboutPages.PrivatePage: string;
begin
  Result := ThemedPage('Private Browsing',
    '<header><h1>Private Browsing</h1><p>The browser will not remember any history for this session</p></header>' +
    '<main><p>In a private browsing session, the browser keeps no browser history, search history, download ' +
    'history, web form history, cookies or temporary internet files once it ends. Bookmarks you make are kept.</p>' +
    '<p>To stop private browsing, choose Tools &gt; Stop Private Browsing: your windows and tabs from before come ' +
    'back.</p></main>');
end;

function TAboutPages.LicensePage: string;
begin
  Result := ThemedPage('Licence',
    '<header><h1>Licence</h1><p>Browser and FreePascalOS</p></header><main>' +
    '<p>This program is free software: you can redistribute it and/or modify it under the terms of the GNU General ' +
    'Public License as published by the Free Software Foundation, either version 3 of the License, or (at your ' +
    'option) any later version.</p><p>This program is distributed in the hope that it will be useful, but WITHOUT ' +
    'ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See ' +
    'the GNU General Public License for more details.</p></main>');
end;

end.
