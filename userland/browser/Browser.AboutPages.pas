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
  pages), about:history, about:bookmarks, about:downloads, and the page
  shown for text that is not an address. They take the theme's colours
  (the golden header band, the face, the selection), so they match the
  window in either theme.
}
unit Browser.AboutPages;

{$mode objfpc}
{$H+}

interface

uses
  Browser.Stores,
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
  DateUtils,
  Drawing.Colors,
  Windowing.Theme;

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
    '<p>The text typed in the address bar is not a web address, and no search engine is set.</p>' +
    '<p>Type an address such as <b>example.com</b>, <b>https://example.com/</b> or <b>/home/user/page.html</b>, ' +
    'or set a search URL in Tools &gt; Settings.</p></main>');
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
  Index, Shown: Integer;
  Seen: string;
begin
  Body := '<header><h1>Browser</h1><p>FreePascalOS</p></header><main>' +
    '<p class="links"><a href="about:bookmarks">Bookmarks</a><a href="about:history">History</a>' +
    '<a href="about:downloads">Downloads</a></p>';
  Body := Body + '<h2>Bookmarks</h2>';
  if FBookmarks.Count = 0 then
    Body := Body + '<p class="quiet">No bookmarks yet: press Ctrl+D on a page to keep it here.</p>'
  else
  begin
    Body := Body + '<div class="tiles">';
    for Index := 0 to FBookmarks.Count - 1 do
      Body := Body + Tile(FBookmarks.Items[Index].Url, FBookmarks.Items[Index].Title);
    Body := Body + '</div>';
  end;
  Body := Body + '<h2>Recently visited</h2>';
  Shown := 0;
  Seen := #10;
  Index := FHistory.Count - 1;
  Body := Body + '<div class="tiles">';
  while (Index >= 0) and (Shown < RecentCount) do
  begin
    if (Pos(#10 + FHistory.Entries[Index].Url + #10, Seen) = 0) and (Pos('about:', FHistory.Entries[Index].Url) <> 1) then
    begin
      Body := Body + Tile(FHistory.Entries[Index].Url, FHistory.Entries[Index].Title);
      Seen := Seen + FHistory.Entries[Index].Url + #10;
      Inc(Shown);
    end;
    Dec(Index);
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
  Index, Shown: Integer;
begin
  Body := '<header><h1>History</h1><p>' + IntToStr(FHistory.Count) + ' visits</p></header><main>';
  if FHistory.Count = 0 then
    Body := Body + '<p class="quiet">No pages visited yet.</p>'
  else
  begin
    Body := Body + '<table><tr><th>Time</th><th>Page</th></tr>';
    Shown := 0;
    Index := FHistory.Count - 1;
    while (Index >= 0) and (Shown < HistoryPageLimit) do
    begin
      Title := FHistory.Entries[Index].Title;
      if Title = '' then
        Title := FHistory.Entries[Index].Url;
      Body := Body + '<tr><td class="quiet">' + FormatVisitTime(FHistory.Entries[Index].Time) + '</td><td><a href="' +
        EscapeHtml(FHistory.Entries[Index].Url) + '">' + EscapeHtml(Title) + '</a><br><small class="quiet">' +
        EscapeHtml(FHistory.Entries[Index].Url) + '</small></td></tr>';
      Inc(Shown);
      Dec(Index);
    end;
    Body := Body + '</table>';
  end;
  Result := ThemedPage('History', Body + '</main>');
end;

function TAboutPages.BookmarksPage: string;
var
  Body: string;
  Index: Integer;
begin
  Body := '<header><h1>Bookmarks</h1><p>' + IntToStr(FBookmarks.Count) + ' pages</p></header><main>';
  if FBookmarks.Count = 0 then
    Body := Body + '<p class="quiet">No bookmarks yet: press Ctrl+D on a page.</p>'
  else
  begin
    Body := Body + '<table><tr><th>Page</th><th>Address</th></tr>';
    for Index := 0 to FBookmarks.Count - 1 do
      Body := Body + '<tr><td><a href="' + EscapeHtml(FBookmarks.Items[Index].Url) + '">' +
        EscapeHtml(FBookmarks.Items[Index].Title) + '</a></td><td class="quiet">' +
        EscapeHtml(FBookmarks.Items[Index].Url) + '</td></tr>';
    Body := Body + '</table>';
  end;
  Result := ThemedPage('Bookmarks', Body + '</main>');
end;

function SizeText(Bytes: Int64): string;
begin
  if Bytes < 1024 then
    Result := IntToStr(Bytes) + ' bytes'
  else if Bytes < 1024 * 1024 then
    Result := FormatFloat('0.0', Bytes / 1024) + ' KiB'
  else
    Result := FormatFloat('0.0', Bytes / (1024 * 1024)) + ' MiB';
end;

function TAboutPages.DownloadsPage: string;
const
  StateNames: array[TDownloadState] of string = ('Downloading', 'Done', 'Failed', 'Cancelled');
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

end.
