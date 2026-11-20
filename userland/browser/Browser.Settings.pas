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
  The browser's settings, the user's (group Browser): the home page
  (about:home unless set), the search URL (empty: no search engine;
  "%s" stands for the words, percent-encoded), whether HTTP/3 is used,
  whether pages run JavaScript and whether the bookmarks bar shows. Saved when the settings dialog
  is closed with OK.
}
unit Browser.Settings;

{$mode objfpc}
{$H+}

interface

const
  DefaultHomePage = 'about:home';

type
  TBrowserSettings = record
    HomePage: string;
    SearchUrl: string;
    Http3: Boolean;
    BookmarksBar: Boolean;
    JavaScript: Boolean;
  end;

function LoadBrowserSettings: TBrowserSettings;
procedure SaveBrowserSettings(constref Settings: TBrowserSettings);

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  HomePageSetting = 'Browser/HomePage';
  SearchUrlSetting = 'Browser/SearchUrl';
  Http3Setting = 'Browser/Http3';
  BookmarksBarSetting = 'Browser/BookmarksBar';
  JavaScriptSetting = 'Browser/JavaScript';

function LoadBrowserSettings: TBrowserSettings;
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Result.HomePage := Store.ReadString(HomePageSetting, DefaultHomePage);
    if Result.HomePage = '' then
      Result.HomePage := DefaultHomePage;
    Result.SearchUrl := Store.ReadString(SearchUrlSetting, '');
    Result.Http3 := Store.ReadBoolean(Http3Setting, True);
    Result.BookmarksBar := Store.ReadBoolean(BookmarksBarSetting, True);
    Result.JavaScript := Store.ReadBoolean(JavaScriptSetting, True);
  finally
    Store.Free;
  end;
end;

{ Freeing the settings flushes them. }
procedure SaveBrowserSettings(constref Settings: TBrowserSettings);
var
  Store: TSettings;
begin
  Store := OpenSettings;
  try
    Store.WriteString(HomePageSetting, Settings.HomePage);
    Store.WriteString(SearchUrlSetting, Settings.SearchUrl);
    Store.WriteBoolean(Http3Setting, Settings.Http3);
    Store.WriteBoolean(BookmarksBarSetting, Settings.BookmarksBar);
    Store.WriteBoolean(JavaScriptSetting, Settings.JavaScript);
  finally
    Store.Free;
  end;
end;

end.
