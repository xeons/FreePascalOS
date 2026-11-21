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
  What a browser's menus and dialogs ask of the engine, on the host:
  Page Info (WebView.PageInfo: meta, media with their sizes, forms,
  links, the referrer, Last-Modified, the rendering mode), find with its
  count and wrapping (WebView.TextIndex), text-only zoom and "No Style"
  (libweb's layout), the encoding override, session restore and going
  several entries at once, and window.open reaching the host.
}
unit WebLoadTest.BrowserFeatures;

{$mode objfpc}
{$H+}

interface

procedure RunBrowserFeatureTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Url.Records,
  Url.Parser,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.LayoutSink,
  Web.Layout.Boxes,
  Web.Layout.Resources,
  Web.Layout.Document,
  Web.Paint.Painter,
  Web.Navigation.Navigables,
  Web.Navigation.SessionHistory,
  Web.Script.PageScripting,
  Web.Text.Fonts,
  WebView.Types,
  WebView.TextGroups,
  WebView.TextIndex,
  WebView.PageSelection,
  WebView.PageInfo,
  WebLoadTest.Server;

type
  TFeatureRun = class
  public
    Environment: TTestEnvironment;
    Navigable: TNavigable;
    WantedUrl: string;
    { '' any. }
    WantedCharset: string;
    Opened: string;
    function Loaded: Boolean;
    function OpenWindow(const Url, Target, Features: string): Boolean;
  end;

function TFeatureRun.Loaded: Boolean;
begin
  Result := (Navigable.ActiveDocument <> nil) and (Navigable.CurrentUrlText = WantedUrl) and
    (Navigable.Loader <> nil) and Navigable.Loader.LoadFired and
    ((WantedCharset = '') or (Navigable.ActiveDocument.CharacterSet = WantedCharset));
end;

function TFeatureRun.OpenWindow(const Url, Target, Features: string): Boolean;
begin
  Opened := Opened + Url + ' ' + Target + ' ' + Features + ';';
  Result := True;
end;

function LoadPage(Run: TFeatureRun; const Url: string): Boolean;
begin
  Run.WantedUrl := Url;
  Run.Navigable.NavigateTo(Url);
  Result := Run.Environment.RunUntil(@Run.Loaded);
end;

function WaitFor(Run: TFeatureRun; const Url: string): Boolean;
begin
  Run.WantedUrl := Url;
  Result := Run.Environment.RunUntil(@Run.Loaded);
end;

function BoxWidth(Layout: TDocumentLayout; Document: TDocument; const Id: string): Single;
var
  X, Y, Height: Single;
begin
  if not Layout.NodeBounds(Document.GetElementById(Id), X, Y, Result, Height) then
    Result := -1;
end;

function FontSizeOf(Layout: TDocumentLayout; Document: TDocument; const Id: string): Single;
var
  Box: TLayoutBox;
begin
  Result := -1;
  Box := Layout.BoxOf(Document.GetElementById(Id));
  if (Box <> nil) and (Box.Style <> nil) then
    Result := Box.Style.FontSize;
end;

function FindMedia(constref Info: TWebPageInfo; const Kind: string; out Item: TWebMediaItem): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Item := Default(TWebMediaItem);
  for Index := 0 to High(Info.Media) do
    if Info.Media[Index].Kind = Kind then
    begin
      Item := Info.Media[Index];
      Exit(True);
    end;
end;

function MetaContent(constref Info: TWebPageInfo; const Name: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Info.Meta) do
    if Info.Meta[Index].Name = Name then
      Exit(Info.Meta[Index].Content);
end;

const
  InfoPage = '<!DOCTYPE html><html><head><title>Info page</title>' +
    '<meta charset=utf-8><meta name=description content="About fruit"><meta http-equiv=refresh content="600">' +
    '<link rel="shortcut icon" href="/favicon.ico">' +
    '<style>#bg { width: 30px; height: 20px; background-image: url(bg.png) } #styled { width: 50px }' +
    ' #zoomed { font-size: 16px } #inner { font-size: 50% } #fixed { width: 100px }' +
    ' #pic { display: inline-block; width: 40px; height: 30px }</style></head>' +
    '<body style="margin:0"><img id=pic src="pic.png" alt="A picture" width=40 height=30>' +
    '<div id=bg></div><form><input type=image src="go.png" alt="Go"></form>' +
    '<a href="/a">one</a> <a href="/b">two</a> <a name=anchor>no link</a>' +
    '<p id=fruit>Apple pie, apple tart and an apple.</p>' +
    '<div id=styled>s</div><div id=attr style="width:70px">a</div>' +
    '<p id=zoomed>big <span id=inner>small</span></p><div id=fixed>f</div></body></html>';

procedure CheckPageInfoAndLayout(Run: TFeatureRun);
var
  Document: TDocument;
  Sink: TLayoutResourceSink;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Selection: TPageSelection;
  Info: TWebPageInfo;
  Item: TWebMediaItem;
  Present: Boolean;
  Matches: TTextMatchArray;
  MatchStart, MatchEnd: TTextPosition;
  Wrapped: Boolean;
  Options: TNavigateOptions;
  Target: TUrlRecord;
begin
  Run.Environment.Site.AddRoute('b.test/start.html', 200, 'Content-Type: text/html', '<p>start</p>');
  Run.Environment.Site.AddRoute('b.test/info.html', 200,
    'Content-Type: text/html; charset=utf-8|Last-Modified: Tue, 03 Nov 2026 10:00:00 GMT', InfoPage);
  Check(LoadPage(Run, 'https://b.test/start.html'), 'browser features: the first page loads');
  { A navigation the page asks for (not the user): it has a referrer. }
  ParseUrl('https://b.test/info.html', Target);
  Options := DefaultNavigateOptions;
  Options.UserInitiated := False;
  Options.Source := Run.Navigable.Loader;
  Run.Navigable.Navigate(Target, Options);
  Check(WaitFor(Run, 'https://b.test/info.html'), 'browser features: the info page loads');
  Document := Run.Navigable.ActiveDocument;
  Sink := TLayoutResourceSink(Run.Navigable.Sink);
  Sink.PrepareDocument(Document);
  Layout := TDocumentLayout.Create(Document);
  Painter := nil;
  Selection := TPageSelection.Create;
  try
    Layout.SetViewport(800, 600, 1);
    Layout.Update;
    Info := CollectPageInfo(Document, Layout);
    Check((Info.Url = 'https://b.test/info.html') and (Info.Title = 'Info page'), 'page info: address and title');
    Check(Info.Referrer = 'https://b.test/start.html', 'page info: the referrer (' + Info.Referrer + ')');
    Check((Info.ContentType = 'text/html') and (Info.Encoding = 'UTF-8') and
      (Info.RenderMode = 'Standards compliance mode'), 'page info: type, encoding and mode (' + Info.ContentType + ', ' +
      Info.Encoding + ', ' + Info.RenderMode + ')');
    Check(Info.LastModified = 'Tue, 03 Nov 2026 10:00:00 GMT', 'page info: Last-Modified as sent');
    Check((MetaContent(Info, 'description') = 'About fruit') and (MetaContent(Info, 'refresh') = '600') and
      (MetaContent(Info, 'charset') = 'utf-8'), 'page info: the meta elements (' + IntToStr(Length(Info.Meta)) + ')');
    Present := FindMedia(Info, 'Image', Item);
    Check(Present and (Item.Url = 'https://b.test/pic.png') and (Item.AltText = 'A picture') and
      (Item.Width = 40) and (Item.Height = 30), 'page info: the image with its alt text and size (' +
      IntToStr(Item.Width) + 'x' + IntToStr(Item.Height) + ')');
    Present := FindMedia(Info, 'Background', Item);
    Check(Present and (Item.Url = 'https://b.test/bg.png') and (Item.Width = 30) and (Item.Height = 20),
      'page info: the background image (' + Item.Url + ')');
    Present := FindMedia(Info, 'Icon', Item);
    Check(Present and (Item.Url = 'https://b.test/favicon.ico'), 'page info: the icon');
    Present := FindMedia(Info, 'Input image', Item);
    Check(Present and (Item.Url = 'https://b.test/go.png') and (Item.AltText = 'Go'), 'page info: the image button');
    Check((Info.FormCount = 1) and (Info.LinkCount = 2), 'page info: forms and links (' + IntToStr(Info.FormCount) +
      ', ' + IntToStr(Info.LinkCount) + ')');
    Check(NearestBackgroundImageUrl(Layout, Document.GetElementById('bg')) = 'https://b.test/bg.png',
      'context menu: the background image of the element');
    Check(NearestBackgroundImageUrl(Layout, Document.GetElementById('fruit')) = '',
      'context menu: no background image where there is none');
    Check(IsEditableElement(Document.GetElementById('fruit')) = False, 'context menu: a paragraph is not editable');

    { Find: the count, and wrapping past the end. }
    Painter := TDocumentPainter.Create(Layout);
    Selection.Attach(Document, Layout, Painter);
    Selection.Refresh;
    Matches := Selection.Index.AllMatches('apple', False, 100);
    Check(Length(Matches) = 3, 'find: three matches without case (' + IntToStr(Length(Matches)) + ')');
    Check(Length(Selection.Index.AllMatches('apple', True, 100)) = 2, 'find: two matching case');
    Check(Length(Selection.Index.AllMatches('apple', False, 2)) = 2, 'find: the count stops at the limit');
    Check(Selection.Index.FindWrapping('apple', TextPosition(-1, 0), True, False, MatchStart, MatchEnd, Wrapped) and
      not Wrapped and (TPageTextIndex.Compare(MatchStart, Matches[0].Start) = 0),
      'find: from nowhere, the first match, not wrapped');
    Check(Selection.Index.FindWrapping('apple', Matches[2].Finish, True, False, MatchStart, MatchEnd, Wrapped) and
      Wrapped and (TPageTextIndex.Compare(MatchStart, Matches[0].Start) = 0),
      'find: past the last match, wrapped to the first');
    Check(Selection.Index.FindWrapping('apple', Matches[0].Start, False, False, MatchStart, MatchEnd, Wrapped) and
      Wrapped and (TPageTextIndex.Compare(MatchStart, Matches[2].Start) = 0),
      'find: backwards before the first match, wrapped to the last');
    Check(Selection.Index.FindWrapping('apple', Matches[0].Finish, True, False, MatchStart, MatchEnd, Wrapped) and
      not Wrapped and (TPageTextIndex.Compare(MatchStart, Matches[1].Start) = 0), 'find: the next match');

    { Zooming the text only: absolute font sizes double, relative ones
      follow, lengths stay. }
    Check(Abs(FontSizeOf(Layout, Document, 'zoomed') - 16) < 0.01, 'text zoom: 16px before');
    Layout.SetTextZoom(2);
    Layout.Update;
    Check(Abs(FontSizeOf(Layout, Document, 'zoomed') - 32) < 0.01, 'text zoom: 32px at 200 % (' +
      FloatToStr(FontSizeOf(Layout, Document, 'zoomed')) + ')');
    Check(Abs(FontSizeOf(Layout, Document, 'inner') - 16) < 0.01, 'text zoom: 50 % of the zoomed size (' +
      FloatToStr(FontSizeOf(Layout, Document, 'inner')) + ')');
    Check(Abs(BoxWidth(Layout, Document, 'fixed') - 100) < 0.01, 'text zoom: a width in px stays');
    Layout.SetTextZoom(1);
    Layout.Update;
    Check(Abs(FontSizeOf(Layout, Document, 'zoomed') - 16) < 0.01, 'text zoom: back to 16px');

    { "No Style": the page's sheets and style attributes go, and come back. }
    Check((Abs(BoxWidth(Layout, Document, 'styled') - 50) < 0.01) and
      (Abs(BoxWidth(Layout, Document, 'attr') - 70) < 0.01), 'no style: the page''s styles apply');
    Layout.SetAuthorStylesEnabled(False);
    Layout.Update;
    { The body's margin attribute went too: the user agent's 8px. }
    Check((Abs(BoxWidth(Layout, Document, 'styled') - 784) < 0.01) and
      (Abs(BoxWidth(Layout, Document, 'attr') - 784) < 0.01), 'no style: sheets and style attributes ignored (' +
      FloatToStr(BoxWidth(Layout, Document, 'styled')) + ', ' + FloatToStr(BoxWidth(Layout, Document, 'attr')) + ')');
    Layout.SetAuthorStylesEnabled(True);
    Layout.Update;
    Check((Abs(BoxWidth(Layout, Document, 'styled') - 50) < 0.01) and
      (Abs(BoxWidth(Layout, Document, 'attr') - 70) < 0.01), 'no style: the page''s styles back');
  finally
    Selection.Free;
    Painter.Free;
    Layout.Free;
  end;
end;

procedure CheckEncodingOverride(Run: TFeatureRun);
var
  Text: string;
begin
  { "При" in windows-1251, sent without a charset (sniffed as windows-1252). }
  Run.Environment.Site.AddRoute('b.test/cyrillic.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><title>t</title><p id=word>'#$CF#$F0#$E8'</p>');
  Check(LoadPage(Run, 'https://b.test/cyrillic.html'), 'encoding: the page loads');
  Check(Run.Navigable.ActiveDocument.CharacterSet = 'windows-1252', 'encoding: sniffed as windows-1252 (' +
    Run.Navigable.ActiveDocument.CharacterSet + ')');
  Run.Navigable.EncodingOverride := 'windows-1251';
  Run.Navigable.Reload;
  Run.WantedCharset := 'windows-1251';
  Check(Run.Environment.RunUntil(@Run.Loaded), 'encoding: reloaded with the override');
  Run.WantedCharset := '';
  Text := Run.Navigable.ActiveDocument.GetElementById('word').TextContent;
  Check(Text = #$D0#$9F#$D1#$80#$D0#$B8, 'encoding: the text decoded as Cyrillic');
  Run.Navigable.EncodingOverride := '';
end;

procedure CheckSessionRestore(Run: TFeatureRun);
var
  Entries: array of TSessionRestoreEntry;
begin
  Run.Environment.Site.AddRoute('h.test/one.html', 200, 'Content-Type: text/html', '<title>One</title>1');
  Run.Environment.Site.AddRoute('h.test/two.html', 200, 'Content-Type: text/html', '<title>Two</title>2');
  Run.Environment.Site.AddRoute('h.test/three.html', 200, 'Content-Type: text/html', '<title>Three</title>3');
  Entries := nil;
  SetLength(Entries, 3);
  ParseUrl('https://h.test/one.html', Entries[0].Url);
  Entries[0].Title := 'One (saved)';
  ParseUrl('https://h.test/two.html', Entries[1].Url);
  ParseUrl('https://h.test/three.html', Entries[2].Url);
  Entries[2].Title := 'Three (saved)';
  Run.Navigable.RestoreSession(Entries, 1);
  Check(WaitFor(Run, 'https://h.test/two.html'), 'restore: the current entry loads');
  Check((Run.Navigable.History.Count = 3) and (Run.Navigable.History.Index = 1),
    'restore: three entries, the second current (' + IntToStr(Run.Navigable.History.Count) + ', ' +
    IntToStr(Run.Navigable.History.Index) + ')');
  Check((Run.Navigable.History[0].Title = 'One (saved)') and (Run.Navigable.History[1].Title = 'Two'),
    'restore: the saved titles, the loaded page''s own');
  Run.Navigable.Traverse(1);
  Check(WaitFor(Run, 'https://h.test/three.html') and (Run.Navigable.History.Index = 2),
    'restore: forward loads the third');
  Run.Navigable.Traverse(-2);
  Check(WaitFor(Run, 'https://h.test/one.html') and (Run.Navigable.History.Index = 0) and
    (Run.Navigable.History.Count = 3), 'restore: two back at once loads the first');
end;

{ A navigable of its own with a script executor (freed before the
  executor, as the documents' contexts are the executor's). }
procedure CheckWindowOpen(Run: TFeatureRun);
var
  Executor: TPageScriptExecutor;
  Sink: TLayoutResourceSink;
  Kept: TNavigable;
begin
  Kept := Run.Navigable;
  Sink := TLayoutResourceSink.Create;
  Run.Navigable := TNavigable.Create(Run.Environment.Fetcher, Sink, DefaultLoadingSettings);
  Sink.AttachNavigable(Run.Navigable);
  Executor := TPageScriptExecutor.Create(Run.Navigable);
  Executor.OnOpenWindow := @Run.OpenWindow;
  Run.Navigable.Executor := Executor;
  try
    Run.Environment.Site.AddRoute('w.test/opener.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><title>t</title><script>var w = window.open("popup.html?a=1", "side", "width=300");' +
      'var v = window.open(); document.title = String(w) + "," + String(v);</script>');
    Check(LoadPage(Run, 'https://w.test/opener.html'), 'window.open: the page loads');
    Check(Run.Opened = 'https://w.test/popup.html?a=1 side width=300;about:blank _blank ;',
      'window.open: the host is asked with the resolved URL, target and features (' + Run.Opened + ')');
    Check(Run.Navigable.ActiveDocument.Title = 'null,null', 'window.open: returns null (another tab) (' +
      Run.Navigable.ActiveDocument.Title + ')');
  finally
    if Run.Navigable.ActiveDocument <> nil then
    begin
      Sink.DocumentGoing(Run.Navigable.ActiveDocument);
      FreeDocumentResources(Run.Navigable.ActiveDocument);
    end;
    Run.Navigable.Free;
    Executor.Free;
    Sink.Free;
    Run.Navigable := Kept;
  end;
end;

procedure RunBrowserFeatureTests;
var
  Run: TFeatureRun;
  Sink: TLayoutResourceSink;
begin
  WebFontDirectory := 'userland/fonts';
  ResetWebFontLibrary;
  Run := TFeatureRun.Create;
  Run.Environment := TTestEnvironment.Create;
  Sink := TLayoutResourceSink.Create;
  Run.Navigable := TNavigable.Create(Run.Environment.Fetcher, Sink, DefaultLoadingSettings);
  Sink.AttachNavigable(Run.Navigable);
  try
    CheckPageInfoAndLayout(Run);
    CheckEncodingOverride(Run);
    CheckSessionRestore(Run);
    CheckWindowOpen(Run);
  finally
    if Run.Navigable.ActiveDocument <> nil then
    begin
      Sink.DocumentGoing(Run.Navigable.ActiveDocument);
      FreeDocumentResources(Run.Navigable.ActiveDocument);
    end;
    Run.Navigable.Free;
    Sink.Free;
    Run.Environment.Free;
    Run.Free;
  end;
end;

end.
