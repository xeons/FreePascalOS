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
  The browser's plain logic on the host (make browser-test): what the
  location bar's text means (addresses, keywords), the history's
  queries, the bookmarks' folders, tags, keywords and file format (and
  the old one), the location bar's suggestions (matching, the special
  words, ranking), the session file and the closed tabs and windows,
  the search engine list, the Error Console's log and filters, the page
  source's colouring and saved passwords. Files go to a folder under
  /tmp.
}
program BrowserTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Browser.TextFiles,
  Browser.Addresses,
  Browser.History,
  Browser.Bookmarks,
  Browser.AwesomeBar,
  Browser.SessionStore,
  Browser.SearchEngines,
  Browser.Keywords,
  Browser.ConsoleLog,
  Browser.SourceColoring,
  Browser.Passwords;

var
  Checks, Failures: Integer;
  Folder: string;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[browser] pass: ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('[browser] FAIL: ', Name);
  end;
end;

procedure CheckText(const Name, Got, Expected: string);
begin
  Check(Name, Got = Expected);
  if Got <> Expected then
    WriteLn('    got "', Got, '", expected "', Expected, '"');
end;

procedure WriteFile(const Path, Text: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
end;

const
  Day = 86400;
  Now = 1800000000;

procedure TestAddresses;
var
  Url: string;
begin
  Check('address: a host is https', (InterpretAddress('example.com', '', Url) = AddressUrl) and
    (Url = 'https://example.com'));
  Check('address: words without a search engine are no address', InterpretAddress('free pascal', '', Url) =
    AddressInvalid);
  Check('address: words with a search URL are searched', (InterpretAddress('free pascal',
    'https://s.example/?q=%s', Url) = AddressSearch) and (Url = 'https://s.example/?q=free+pascal'));
  Check('address: localhost with a port is http', (InterpretAddress('localhost:8080/x', '', Url) = AddressUrl) and
    (Url = 'http://localhost:8080/x'));
end;

procedure TestHistory;
var
  History: THistoryStore;
  Places: THistoryPlaceList;
  Place: THistoryPlace;
begin
  History := THistoryStore.Create(Folder + '/history.txt');
  try
    History.AddVisit('https://a.example/', 'Alpha', Now - 10 * Day);
    History.AddVisit('https://b.example/page', 'Beta page', Now - 2 * Day);
    History.AddVisit('https://a.example/', 'Alpha', Now - Day);
    History.AddVisit('https://a.example/', 'Alpha again', Now - Day + 5);
    History.AddVisit('https://c.example/', 'Gamma', Now - 3600);
    Check('history: a repeated newest visit renews it', History.Count = 4);
    Places := History.Places;
    Check('history: places are grouped by URL, newest first', (Length(Places) = 3) and
      (Places[0].Url = 'https://c.example/') and (Places[1].Url = 'https://a.example/'));
    Check('history: a place counts its visits and keeps the newest title', (Places[1].VisitCount = 2) and
      (Places[1].Title = 'Alpha again') and (Places[1].FirstVisit = Now - 10 * Day));
    Check('history: search finds by words of the title or URL', (Length(History.Search('beta')) = 1) and
      (Length(History.Search('example')) = 3) and (Length(History.Search('beta gamma')) = 0));
    Check('history: places since a time', Length(History.PlacesSince(Now - Day)) = 2);
    Check('history: the recent places', (Length(History.RecentPlaces(2)) = 2));
    History.Enabled := False;
    History.AddVisit('https://private.example/', 'Private', Now);
    Check('history: nothing is kept while not enabled', not History.FindPlace('https://private.example/', Place));
    History.Enabled := True;
    History.Free;
    History := THistoryStore.Create(Folder + '/history.txt');
    History.Load;
    Check('history: the file is read back', (History.Count = 4) and History.FindPlace('https://a.example/', Place) and
      (Place.VisitCount = 2));
    History.RemoveSince(Now - 2 * Day);
    Check('history: forgetting since a time', History.Count = 1);
    History.AddVisit('https://www.d.example/x', 'D', Now);
    History.AddVisit('https://d.example/y', 'D2', Now);
    History.AddVisit('https://notd.example/', 'N', Now);
    History.RemoveHost('d.example');
    Check('history: forgetting a site takes its subdomains, not other hosts', (History.Count = 2) and
      History.FindPlace('https://notd.example/', Place));
    History.RemoveUrl('https://notd.example/');
    Check('history: forgetting a page', not History.FindPlace('https://notd.example/', Place));
    Check('history: age groups', (HistoryAgeOf(Now - 60, Now) = AgeToday) and
      (HistoryAgeOf(Now - (Now mod Day) - 60, Now) = AgeYesterday) and
      (HistoryAgeOf(Now - 5 * Day, Now) = AgeLastWeek) and (HistoryAgeOf(Now - 20 * Day, Now) = AgeThisMonth) and
      (HistoryAgeOf(Now - 90 * Day, Now) = AgeOlder));
    CheckText('history: the host of a URL', HostOfUrl('https://User@Www.Example.com:8443/x?y'), 'www.example.com');
  finally
    History.Free;
  end;
end;

procedure TestBookmarks;
var
  Store: TBookmarkStore;
  Folder1, Mark, Other: TBookmarkNode;
  Tags: TStringArray;
begin
  WriteFile(Folder + '/old-bookmarks.txt', 'Old one'#9'https://old.example/'#10'Two'#9'https://two.example/');
  Store := TBookmarkStore.Create(Folder + '/old-bookmarks.txt');
  try
    Store.Load;
    Check('bookmarks: the old format goes to the toolbar folder', (Store.ToolbarFolder.Count = 2) and
      (Store.ToolbarFolder[0].Title = 'Old one') and Store.IsBookmarked('https://two.example/'));
  finally
    Store.Free;
  end;
  Store := TBookmarkStore.Create(Folder + '/bookmarks.txt');
  try
    Check('bookmarks: three folders are always there', (Store.Root.Count = 3) and
      (Store.MenuFolder.Title = 'Bookmarks Menu') and (Store.UnsortedFolder.Id = UnsortedFolderId));
    Folder1 := Store.AddFolder(Store.MenuFolder, 'News', -1, Now);
    Mark := Store.AddBookmark(Folder1, 'Paper', 'https://paper.example/', -1, Now - 100);
    Store.SetTags(Mark, 'news, daily , News,');
    Check('bookmarks: tags are trimmed, repeats dropped', (Length(Mark.Tags) = 2) and (Mark.Tags[1] = 'daily'));
    Mark.Keyword := 'pp';
    Mark.Description := 'Morning reading';
    Store.Changed;
    Other := Store.AddBookmark(nil, 'Search', 'https://s.example/?q=%s', -1, Now);
    Other.Keyword := 'se';
    Store.SetTags(Other, 'tools');
    Store.AddSeparator(Store.MenuFolder);
    Store.AddBookmark(Store.ToolbarFolder, 'Bar', 'https://bar.example/', -1, Now - 50);
    Check('bookmarks: no folder given is Unsorted', Other.Parent = Store.UnsortedFolder);
    Tags := Store.AllTags;
    Check('bookmarks: every tag, sorted', (Length(Tags) = 3) and (Tags[0] = 'daily') and (Tags[2] = 'tools'));
    Check('bookmarks: tagged', (Length(Store.Tagged('NEWS')) = 1) and (Store.Tagged('news')[0] = Mark));
    Check('bookmarks: recently bookmarked, newest first', (Store.RecentlyBookmarked(2)[0] = Other) and
      (Store.RecentlyBookmarked(2)[1].Title = 'Bar'));
    Check('bookmarks: recent tags', (Length(Store.RecentTags(5)) = 3) and (Store.RecentTags(5)[0] = 'tools'));
    Check('bookmarks: search over name, address, tags, keyword, description', (Length(Store.Search('morning')) = 1)
      and (Length(Store.Search('daily paper')) = 1) and (Length(Store.Search('example')) = 3));
    Check('bookmarks: keywords', Store.FindKeyword('PP') = Mark);
    Check('bookmarks: a folder cannot go into itself', not Store.Move(Folder1, Folder1, 0));
    Check('bookmarks: a root folder does not move', not Store.Move(Store.MenuFolder, Store.ToolbarFolder, 0));
    Check('bookmarks: moving to another folder', Store.Move(Mark, Store.ToolbarFolder, 0) and
      (Store.ToolbarFolder[0] = Mark) and (Folder1.Count = 0));
    Store.AddBookmark(Store.ToolbarFolder, 'Third', 'https://third.example/');
    Check('bookmarks: moving down within a folder', Store.Move(Mark, Store.ToolbarFolder, 3) and
      (Store.ToolbarFolder[2] = Mark));
    Store.Move(Mark, Folder1, -1);
  finally
    Store.Free;
  end;
  Store := TBookmarkStore.Create(Folder + '/bookmarks.txt');
  try
    Store.Load;
    Mark := Store.FindUrl('https://paper.example/');
    Check('bookmarks: the file is read back with folders, tags, keyword and description', (Mark <> nil) and
      (Mark.Parent.Title = 'News') and (Mark.Parent.Parent = Store.MenuFolder) and (Mark.TagText = 'news, daily') and
      (Mark.Keyword = 'pp') and (Mark.Description = 'Morning reading') and (Mark.Added = Now - 100));
    Check('bookmarks: separators and order are kept', (Store.MenuFolder.Count = 2) and
      (Store.MenuFolder[1].Kind = BookmarkSeparator));
    Store.DeleteUrl('https://paper.example/');
    Check('bookmarks: deleting by address', not Store.IsBookmarked('https://paper.example/'));
  finally
    Store.Free;
  end;
end;

function Candidate(const Title, Url: string; Visits: Integer; LastVisit: Int64; Bookmarked: Boolean;
  const Tags: string): TSuggestionCandidate;
begin
  Result.Title := Title;
  Result.Url := Url;
  Result.VisitCount := Visits;
  Result.LastVisit := LastVisit;
  Result.Bookmarked := Bookmarked;
  Result.Tags := ParseTags(Tags);
end;

procedure TestAwesomeBar;
var
  Candidates: TSuggestionCandidates;
  Found: TSuggestions;
  Words: TStringArray;
  Restrictions: TSuggestRestrictions;
  History: THistoryStore;
  Marks: TBookmarkStore;
begin
  Candidates := nil;
  SetLength(Candidates, 5);
  Candidates[0] := Candidate('Free Pascal wiki', 'https://wiki.freepascal.org/', 3, Now - Day, False, '');
  Candidates[1] := Candidate('Old pascal page', 'https://old.example/pascal', 10, Now - 200 * Day, False, '');
  Candidates[2] := Candidate('Compiler docs', 'https://docs.example/fpc', 0, 0, True, 'pascal, compiler');
  Candidates[3] := Candidate('Weather', 'https://weather.example/', 20, Now - Day, False, '');
  Candidates[4] := Candidate('Mail', 'https://mail.example/inbox', 1, Now - Day, True, '');
  Check('suggest: frecency weights recent visits and bookmarks', (Frecency(3, Now - Day, Now, False) = 300) and
    (Frecency(10, Now - 200 * Day, Now, False) = 100) and (Frecency(0, 0, Now, True) = 100) and
    (Frecency(1, Now, Now, True) = 175) and (Frecency(50, Now, Now, False) = 1000));
  Found := RankSuggestions('pascal', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: every page with the word in its title, address or tags', Length(Found) = 3);
  Check('suggest: the best first (recent and at a word start)', (Length(Found) = 3) and
    (Found[0].Url = 'https://wiki.freepascal.org/'));
  Found := RankSuggestions('free wiki', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: every word must match', (Length(Found) = 1) and (Found[0].Title = 'Free Pascal wiki'));
  Found := RankSuggestions('weather', Candidates, Now, SuggestBookmarks, 10);
  Check('suggest: bookmarks only', Length(Found) = 0);
  Found := RankSuggestions('compiler', Candidates, Now, SuggestHistory, 10);
  Check('suggest: history only leaves out unvisited bookmarks', Length(Found) = 0);
  Check('suggest: nothing', Length(RankSuggestions('mail', Candidates, Now, SuggestNothing, 10)) = 0);
  ParseTyped('* pascal @', Words, Restrictions);
  Check('suggest: the special words', (Length(Words) = 1) and (Words[0] = 'pascal') and
    (Restrictions = [RestrictBookmarks, RestrictUrl]));
  Found := RankSuggestions('pascal *', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: "*" bookmarks only', (Length(Found) = 1) and (Found[0].Title = 'Compiler docs'));
  Found := RankSuggestions('pascal +', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: "+" tagged only', (Length(Found) = 1) and (Found[0].Title = 'Compiler docs'));
  Found := RankSuggestions('pascal @', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: "@" the address only', (Length(Found) = 2));
  Found := RankSuggestions('pascal #', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: "#" the title only', (Length(Found) = 2) and (Found[0].Title = 'Free Pascal wiki'));
  Found := RankSuggestions('pascal ^', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: "^" history only', Length(Found) = 2);
  Found := RankSuggestions('mail.ex', Candidates, Now, SuggestHistoryAndBookmarks, 10);
  Check('suggest: typed text an address starts with', (Length(Found) = 1) and (Found[0].Url =
    'https://mail.example/inbox'));
  Found := RankSuggestions('e', Candidates, Now, SuggestHistoryAndBookmarks, 2);
  Check('suggest: at most the count asked for', Length(Found) = 2);
  Check('suggest: nothing for empty text', Length(RankSuggestions('  ', Candidates, Now,
    SuggestHistoryAndBookmarks, 10)) = 0);
  CheckText('suggest: the stripped address', StrippedAddress('HTTPS://www.Example.com/A'), 'example.com/a');
  { From the stores: a bookmark visited is one candidate with its name. }
  History := THistoryStore.Create('');
  Marks := TBookmarkStore.Create('');
  try
    History.AddVisit('https://x.example/', 'Page title', Now - 60);
    History.AddVisit('https://y.example/', 'Other', Now - 60);
    Marks.SetTags(Marks.AddBookmark(nil, 'My name', 'https://x.example/'), 'mine');
    Marks.AddBookmark(nil, 'Unvisited', 'https://z.example/');
    Candidates := GatherCandidates(History, Marks);
    Check('suggest: history and bookmarks gathered once each', Length(Candidates) = 3);
    Found := SuggestPlaces('mine', History, Marks, Now, SuggestHistoryAndBookmarks);
    Check('suggest: a visited bookmark keeps its name and tags', (Length(Found) = 1) and
      (Found[0].Title = 'My name') and Found[0].Bookmarked);
  finally
    History.Free;
    Marks.Free;
  end;
end;

function MakeTab(const Urls: array of string; Index: Integer): TSessionTab;
var
  Item: Integer;
begin
  Result := Default(TSessionTab);
  SetLength(Result.Entries, Length(Urls));
  for Item := 0 to High(Urls) do
  begin
    Result.Entries[Item].Url := Urls[Item];
    Result.Entries[Item].Title := 'Title ' + IntToStr(Item);
  end;
  Result.Index := Index;
  Result.ZoomPercent := 100;
end;

procedure TestSession;
var
  Session, Back: TSession;
  Window: TSessionWindow;
  Closed: TClosedTab;
  Text: string;
  Index: Integer;
begin
  Session := Default(TSession);
  Session.Running := True;
  Window := Default(TSessionWindow);
  Window.Left := 10;
  Window.Top := 20;
  Window.Width := 800;
  Window.Height := 600;
  SetLength(Window.Tabs, 2);
  Window.Tabs[0] := MakeTab(['https://a.example/', 'https://b.example/'], 1);
  Window.Tabs[1] := MakeTab(['https://c.example/'], 0);
  Window.Tabs[1].ZoomPercent := 150;
  Window.Tabs[1].Entries[0].Title := 'Tab'#9'with a tab';
  Window.Selected := 1;
  SetLength(Session.Windows, 1);
  Session.Windows[0] := Window;
  RememberClosedTab(Session, MakeTab(['https://closed.example/'], 0), 0, 1, Now);
  RememberClosedTab(Session, MakeTab(['about:blank'], 0), 0, 1, Now);
  Check('session: a blank closed tab is not kept', Length(Session.ClosedTabs) = 1);
  RememberClosedWindow(Session, Window, Now - 5);
  Text := SessionToText(Session);
  Check('session: written and read back', TextToSession(Text, Back));
  Check('session: running state', Back.Running);
  Check('session: windows and their place', (Length(Back.Windows) = 1) and (Back.Windows[0].Width = 800) and
    (Back.Windows[0].Top = 20) and (Back.Windows[0].Selected = 1));
  Check('session: tabs, entries, the shown one, zoom', (Length(Back.Windows[0].Tabs) = 2) and
    (Length(Back.Windows[0].Tabs[0].Entries) = 2) and (Back.Windows[0].Tabs[0].Index = 1) and
    (CurrentEntry(Back.Windows[0].Tabs[0]).Url = 'https://b.example/') and
    (Back.Windows[0].Tabs[1].ZoomPercent = 150));
  CheckText('session: a tab in a title becomes a space', Back.Windows[0].Tabs[1].Entries[0].Title, 'Tab with a tab');
  Check('session: closed tabs', (Length(Back.ClosedTabs) = 1) and (Back.ClosedTabs[0].Position = 1) and
    (CurrentEntry(Back.ClosedTabs[0].Tab).Url = 'https://closed.example/'));
  Check('session: closed windows', (Length(Back.ClosedWindows) = 1) and (Back.ClosedWindows[0].ClosedAt = Now - 5) and
    (Length(Back.ClosedWindows[0].Tabs) = 2));
  Check('session: not a session', not TextToSession('hello', Back));
  Check('session: a bad index is put within the entries', TextToSession('#session 1'#10'window'#9'0'#9'0'#9'1'#9'1' +
    #9'9'#10'tab'#9'7'#9'100'#10'entry'#9'https://x.example/'#9'X', Back) and (Back.Windows[0].Tabs[0].Index = 0) and
    (Back.Windows[0].Selected = 0));
  for Index := 1 to MaximumClosedTabs + 3 do
    RememberClosedTab(Session, MakeTab(['https://n' + IntToStr(Index) + '.example/'], 0), 0, 0, Now);
  Check('session: at most so many closed tabs, newest first', (Length(Session.ClosedTabs) = MaximumClosedTabs) and
    (CurrentEntry(Session.ClosedTabs[0].Tab).Url = 'https://n' + IntToStr(MaximumClosedTabs + 3) + '.example/'));
  Check('session: undo close takes the newest', TakeClosedTab(Session, 0, Closed) and
    (Length(Session.ClosedTabs) = MaximumClosedTabs - 1));
  Check('session: taking what is not there', not TakeClosedTab(Session, 99, Closed));
  Check('session: saved to a file and loaded', SaveSession(Session, Folder + '/session.txt') and
    LoadSession(Folder + '/session.txt', Back) and (Length(Back.ClosedTabs) = MaximumClosedTabs - 1));
  Check('session: a closed window taken back', TakeClosedWindow(Session, 0, Window) and (Length(Window.Tabs) = 2) and
    (Length(Session.ClosedWindows) = 0));
end;

procedure TestSearchEngines;
var
  Engines: TSearchEngineList;
  Lines: TStringList;
  Index: Integer;
  Url: string;
  Marks: TBookmarkStore;
begin
  Engines := TSearchEngineList.Create;
  Lines := TStringList.Create;
  try
    Check('engines: four ship with the browser', (Engines.Count = 4) and (Engines.IndexOf('DuckDuckGo') = 0) and
      Engines[3].BuiltIn);
    CheckText('engines: words go into the URL form-encoded', BuildSearchUrl(Engines[0].Url, ' free pascal & more'),
      'https://html.duckduckgo.com/html/?q=free+pascal+%26+more');
    Check('engines: a search URL needs http(s) and %s', IsSearchTemplate('https://x.example/?q=%s') and
      not IsSearchTemplate('https://x.example/') and not IsSearchTemplate('ftp://x/%s'));
    Index := Engines.Add('My search', 'https://my.example/find?w=%s', 'my');
    Check('engines: adding one', (Index = 4) and (Engines.IndexOfKeyword('MY') = 4));
    Check('engines: a taken name is refused', Engines.Add('google', 'https://g.example/?q=%s', '') = -1);
    Check('engines: a URL without %s is refused', Engines.Add('Bad', 'https://bad.example/', '') = -1);
    Engines.Move(4, 0);
    Check('engines: moving one up', (Engines[0].Name = 'My search') and (Engines[1].Name = 'DuckDuckGo'));
    Engines.Move(0, 2);
    Check('engines: moving one down', (Engines[2].Name = 'My search') and (Engines[0].Name = 'DuckDuckGo'));
    Engines.Remove(Engines.IndexOf('Google'));
    Check('engines: removing a shipped one', Engines.IndexOf('Google') < 0);
    Engines.SaveToLines(Lines);
    Engines.Free;
    Engines := TSearchEngineList.Create;
    Engines.LoadFromLines(Lines);
    Check('engines: the order, the user''s engine and the removal are kept', (Engines.Count = 4) and
      (Engines[2].Name = 'My search') and (Engines.IndexOf('Google') < 0) and not Engines[2].BuiltIn);
    Engines.RestoreDefaults;
    Check('engines: restoring the defaults brings a removed one back', (Engines.IndexOf('Google') >= 0) and
      (Engines.IndexOf('My search') >= 0));
    Check('engines: a URL is found', Engines.IndexOfUrl('https://www.bing.com/search?q=%s') >= 0);
    Lines.Text := 'engine'#9'Mine'#9'https://mine.example/?q=%s'#9'mi';
    Engines.LoadFromLines(Lines);
    Check('engines: a shipped engine new to the file is added after the user''s', (Engines[0].Name = 'Mine') and
      (Engines.Count = 5));
    { Keywords in the location bar. }
    Marks := TBookmarkStore.Create('');
    try
      Marks.AddBookmark(nil, 'Dictionary', 'https://dict.example/?w=%s').Keyword := 'dict';
      Marks.AddBookmark(nil, 'Home', 'https://home.example/').Keyword := 'h';
      Check('keywords: a bookmark keyword with words', (ResolveLocation('dict hello world', '', Marks, Engines, Url) =
        AddressUrl) and (Url = 'https://dict.example/?w=hello+world'));
      Check('keywords: a bookmark keyword alone', (ResolveLocation('h', '', Marks, Engines, Url) = AddressUrl) and
        (Url = 'https://home.example/'));
      Check('keywords: an engine keyword', (ResolveLocation('mi pascal', '', Marks, Engines, Url) = AddressSearch) and
        (Url = 'https://mine.example/?q=pascal'));
      Check('keywords: otherwise an address', (ResolveLocation('example.org', '', Marks, Engines, Url) = AddressUrl) and
        (Url = 'https://example.org'));
      Check('keywords: words without an engine are no address', ResolveLocation('just words', '', Marks, Engines,
        Url) = AddressInvalid);
    finally
      Marks.Free;
    end;
  finally
    Lines.Free;
    Engines.Free;
  end;
end;

procedure TestConsoleAndSource;
var
  Log: TConsoleLog;
  Colored: string;
  Store: TPasswordStore;
begin
  Log := TConsoleLog.Create;
  try
    Log.Add('log', 'hello world', 'file:///a.html', Now);
    Log.Add('error', 'Uncaught TypeError', 'https://b.example/', Now);
    Log.Add('warn', 'deprecated thing', 'https://b.example/', Now);
    Check('console: levels become severities', (Log.Entries[0].Severity = SeverityMessage) and
      (Log.Entries[1].Severity = SeverityError) and (Log.Entries[2].Severity = SeverityWarning));
    Check('console: filters', (Length(Log.Filtered(FilterAll, '')) = 3) and (Length(Log.Filtered(FilterErrors, '')) = 1)
      and (Length(Log.Filtered(FilterWarnings, '')) = 1) and (Length(Log.Filtered(FilterMessages, '')) = 1));
    Check('console: search by text or source', (Length(Log.Filtered(FilterAll, 'TYPEERROR')) = 1) and
      (Length(Log.Filtered(FilterAll, 'b.example')) = 2));
    Log.Clear;
    Check('console: clear', Log.Count = 0);
  finally
    Log.Free;
  end;
  Colored := ColorSource('<!DOCTYPE html><a href="x&y">A &amp; B</a><!-- c -->');
  Check('source: the doctype', Pos('<span class="doctype">&lt;!DOCTYPE html&gt;</span>', Colored) > 0);
  Check('source: a tag and its attribute', (Pos('<span class="tag">&lt;a</span>', Colored) > 0) and
    (Pos('<span class="attribute">href</span>', Colored) > 0) and
    (Pos('<span class="value">&quot;x&amp;y&quot;</span>', Colored) > 0));
  Check('source: a character reference', Pos('<span class="entity">&amp;amp;</span>', Colored) > 0);
  Check('source: a comment', Pos('<span class="comment">&lt;!-- c --&gt;</span>', Colored) > 0);
  Check('source: text is escaped', Pos('A ', Colored) > 0);
  Check('source: a whole page', Pos('<pre>', ColoredSourcePage('x', 'T', True)) > 0);
  Store := TPasswordStore.Create(Folder + '/passwords.txt');
  try
    Store.Remember('https://a.example', 'me', 'secret');
    Store.Remember('https://a.example', 'me', 'newer');
    Store.Remember('https://b.example', 'you', 'pw');
    Check('passwords: one per site and user, replaced', (Store.Count = 2) and (Store.Logins[0].Password = 'newer'));
  finally
    Store.Free;
  end;
  Store := TPasswordStore.Create(Folder + '/passwords.txt');
  try
    Store.Load;
    Check('passwords: read back', (Store.Count = 2) and (Store.IndexOf('https://B.example', 'you') = 1));
    Store.Remove(0);
    Check('passwords: removed', Store.Count = 1);
  finally
    Store.Free;
  end;
  DeleteFile(Folder + '/passwords.txt');
end;

begin
  Folder := GetTempDir(False) + 'browser-test-' + IntToStr(GetProcessID);
  ForceDirectories(Folder);
  TestAddresses;
  TestHistory;
  TestBookmarks;
  TestAwesomeBar;
  TestSession;
  TestSearchEngines;
  TestConsoleAndSource;
  DeleteFile(Folder + '/history.txt');
  DeleteFile(Folder + '/bookmarks.txt');
  DeleteFile(Folder + '/old-bookmarks.txt');
  DeleteFile(Folder + '/session.txt');
  RemoveDir(Folder);
  WriteLn('[browser] ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
