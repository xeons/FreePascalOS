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
  Documents loading through a navigable from the in-process site:
  streaming into the parser as pieces arrive, readyState and the
  events of loading in order, style sheets (imports, media, alternate,
  disabled) holding the load event, images (srcset, downscaling,
  natural size), fonts, the favicon, a meta charset that restarts the
  parse, text and error documents, scripts in their standard order with
  a recording executor and the preload scanner, unload events, and
  session history (fragments, back, forward, reload). Also srcset and
  sizes on their own.
}
unit WebLoadTest.Loading;

{$mode objfpc}
{$H+}

interface

procedure RunLoadingTests;

implementation

uses
  Classes,
  SysUtils,
  SyncObjs,
  TestChecks,
  Url.Records,
  Url.Parser,
  Css.Stylesheets,
  Css.MediaQueries,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Web.Dom.Events,
  Web.Dom,
  Web.Atoms,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Loading.Scripts,
  Web.Loading.Srcset,
  Web.Loading.Documents,
  Web.Navigation.Windows,
  Web.Navigation.Navigables,
  WebLoadTest.Server;

type
  TRecordingSink = class(TResourceSink)
  public
    Log: string;
    Sheets: TList;
    LastImageWidth, LastImageHeight: Integer;
    LastNaturalWidth: Double;
    LastImageUrl: string;
    LastDownscaled: Boolean;
    FontBytes: string;
    Ratio: Double;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Text: string);
    procedure StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure StyleSheetRemoved(Owner: TElement); override;
    procedure ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo); override;
    procedure ImageFailed(Element: TElement); override;
    procedure ImageRemoved(Element: TElement); override;
    procedure FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
      const Url: string); override;
    procedure FontFailed(Rule: TCssFontFaceRule; const Family: string); override;
    function MediaEnvironment: TCssMediaEnvironment; override;
  end;

  TRecordingObserver = class(TNavigableObserver)
  public
    Log: string;
    States: string;
    LastTitle: string;
    LastUrl: string;
    IconUrl: string;
    IconWidth: Integer;
    FragmentElement: TElement;
    FragmentCalls: Integer;
    Failures: Integer;
    Downloads: string;
    procedure LocationChanged(Navigable: TNavigable; const Url: string); override;
    procedure TitleChanged(Navigable: TNavigable; const Title: string); override;
    procedure LoadingStateChanged(Navigable: TNavigable; State: TLoadingState); override;
    procedure FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage); override;
    procedure ScrollToFragment(Navigable: TNavigable; Element: TElement); override;
    procedure DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo); override;
    procedure NavigationFailed(Navigable: TNavigable; const Url, Reason: string); override;
  end;

  TRecordingExecutor = class(TScriptExecutor)
  public
    Log: string;
    procedure ExecuteScript(Script: TPendingScript); override;
  end;

  TLogListener = class(TEventListener)
  public
    Log: PString;
    Name: string;
    Document: TDocument;
    constructor Create(ALog: PString; const AName: string; ADocument: TDocument = nil);
    procedure HandleEvent(Event: TEvent); override;
  end;

  TConditions = class
  public
    Navigable: TNavigable;
    function Complete: Boolean;
    function HasFirstParagraph: Boolean;
  end;

var
  Environment: TTestEnvironment;
  Sink: TRecordingSink;
  Observer: TRecordingObserver;
  Executor: TRecordingExecutor;
  Navigable: TNavigable;
  Conditions: TConditions;
  EventLog: string;

constructor TRecordingSink.Create;
begin
  inherited Create;
  Sheets := TList.Create;
  Ratio := 1;
end;

destructor TRecordingSink.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to Sheets.Count - 1 do
    TCssStyleSheet(Sheets[Index]).Free;
  Sheets.Free;
  inherited Destroy;
end;

procedure TRecordingSink.Add(const Text: string);
begin
  if Log <> '' then
    Log := Log + ' ';
  Log := Log + Text;
end;

procedure TRecordingSink.StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
  Add('sheet:' + ExtractFileName(StringReplace(Sheet.Href, '/', PathDelim, [rfReplaceAll])));
  Sheets.Add(Sheet);
end;

procedure TRecordingSink.StyleSheetRemoved(Owner: TElement);
begin
  Add('sheet-removed');
end;

procedure TRecordingSink.ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
  Add('imports');
end;

procedure TRecordingSink.ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo);
begin
  Add('image');
  LastImageWidth := Image.Width;
  LastImageHeight := Image.Height;
  LastNaturalWidth := Info.NaturalWidth;
  LastImageUrl := Info.CurrentUrl;
  LastDownscaled := Info.Downscaled;
  Image.Free;
end;

procedure TRecordingSink.ImageFailed(Element: TElement);
begin
  Add('image-failed');
end;

procedure TRecordingSink.ImageRemoved(Element: TElement);
begin
end;

procedure TRecordingSink.FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
  const Url: string);
begin
  Add('font:' + Family);
  SetString(FontBytes, PChar(@Data[0]), Length(Data));
end;

procedure TRecordingSink.FontFailed(Rule: TCssFontFaceRule; const Family: string);
begin
  Add('font-failed:' + Family);
end;

function TRecordingSink.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := ScreenMediaEnvironment(800, 600, Ratio);
end;

procedure TRecordingObserver.LocationChanged(Navigable: TNavigable; const Url: string);
begin
  LastUrl := Url;
end;

procedure TRecordingObserver.TitleChanged(Navigable: TNavigable; const Title: string);
begin
  LastTitle := Title;
end;

procedure TRecordingObserver.LoadingStateChanged(Navigable: TNavigable; State: TLoadingState);
const
  Names: array[TLoadingState] of string = ('idle', 'requesting', 'receiving', 'interactive', 'complete');
begin
  if States <> '' then
    States := States + ' ';
  States := States + Names[State];
end;

procedure TRecordingObserver.FaviconChanged(Navigable: TNavigable; const Url: string; Image: TImage);
begin
  IconUrl := Url;
  if Image <> nil then
    IconWidth := Image.Width;
  Image.Free;
end;

procedure TRecordingObserver.ScrollToFragment(Navigable: TNavigable; Element: TElement);
begin
  FragmentElement := Element;
  Inc(FragmentCalls);
end;

procedure TRecordingObserver.DownloadRequested(Navigable: TNavigable; constref Download: TDownloadInfo);
begin
  Downloads := Downloads + Download.FileName + ' ';
end;

procedure TRecordingObserver.NavigationFailed(Navigable: TNavigable; const Url, Reason: string);
begin
  Inc(Failures);
end;

procedure TRecordingExecutor.ExecuteScript(Script: TPendingScript);
begin
  if Log <> '' then
    Log := Log + ' ';
  Log := Log + Trim(Script.Source);
end;

constructor TLogListener.Create(ALog: PString; const AName: string; ADocument: TDocument);
begin
  inherited Create;
  Log := ALog;
  Name := AName;
  Document := ADocument;
end;

procedure TLogListener.HandleEvent(Event: TEvent);
var
  Text: string;
begin
  Text := Name;
  if Document <> nil then
    Text := Text + ':' + Document.ReadyStateText;
  if Log^ <> '' then
    Log^ := Log^ + ' ';
  Log^ := Log^ + Text;
end;

function TConditions.Complete: Boolean;
begin
  Result := (Navigable.State = LoadingComplete) and Navigable.Loader.LoadFired;
end;

function TConditions.HasFirstParagraph: Boolean;
begin
  Result := Navigable.ActiveDocument.GetElementById('first') <> nil;
end;

function MakeUrl(const Text: string): TUrlRecord;
begin
  if not ParseUrl(Text, Result) then
    raise Exception.Create('bad test URL ' + Text);
end;

function PngBytes(Width, Height: Integer): string;
var
  Image: TImage;
  Bytes: TBytes;
begin
  Image := TImage.Create(Width, Height);
  try
    Image.Fill($FF336699);
    Bytes := EncodeImage(Image, ImageFormatPng);
  finally
    Image.Free;
  end;
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

procedure NewNavigable;
var
  Settings: TLoadingSettings;
begin
  Navigable.Free;
  Settings := DefaultLoadingSettings;
  Settings.DecodeImagesOnThreads := GetEnvironmentVariable('WEBLOADTEST_NOTHREADS') = '';
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, Settings, Executor);
  Navigable.ObserverObject := Observer;
  Conditions.Navigable := Navigable;
end;

procedure LoadAndWait(const Url: string);
begin
  Navigable.NavigateTo(Url);
  Environment.RunUntil(@Conditions.Complete);
end;

procedure CheckSrcset;
var
  Candidates: TImageCandidateArray;
  Choice: TImageSourceChoice;
  Media: TCssMediaEnvironment;
begin
  { The data: URL takes the comma after it (URLs end at whitespace), so
    its candidate has the bad descriptor and goes. }
  Candidates := ParseSrcset('a.png 1x, b.png 2x,c.png  3x , data:image/png;base64,AAA=,bad.png 2q, d.png,, e.png 1.5x');
  Check((Length(Candidates) = 5) and (Candidates[1].Url = 'b.png') and (Candidates[1].Density = 2) and
    (Candidates[3].Url = 'd.png') and (Candidates[4].Url = 'e.png') and (Candidates[4].Density = 1.5),
    'srcset: parsed, a bad descriptor dropped (' + IntToStr(Length(Candidates)) + ')');
  Candidates := ParseSrcset('small.jpg 400w, big.jpg 1600w, x.jpg 1x 2x');
  Check((Length(Candidates) = 2) and Candidates[1].HasWidth and (Candidates[1].Width = 1600), 'srcset: widths');
  Media := ScreenMediaEnvironment(800, 600, 2);
  Check(Abs(ParseSizes('(max-width: 500px) 100px, (min-width: 700px) 50vw, 10px', Media) - 400) < 0.01,
    'sizes: first matching condition');
  Check(Abs(ParseSizes('', Media) - 800) < 0.01, 'sizes: 100vw by default');
  Check(Abs(ParseSizes('bogus, 20em', Media) - 320) < 0.01, 'sizes: bad entries skipped');
  Choice := SelectImageCandidate(ParseSrcset('a.png 1x, b.png 2x, c.png 3x'), '', 0, 2);
  Check(Choice.Found and (Choice.Url = 'b.png'), 'srcset: density 2 chosen at ratio 2');
  Choice := SelectImageCandidate(ParseSrcset('a.png 1x, b.png 2x'), '', 0, 3);
  Check(Choice.Url = 'b.png', 'srcset: the largest when none is enough');
  Choice := SelectImageCandidate(ParseSrcset('small.jpg 400w, big.jpg 1600w'), 'src.jpg', 400, 2);
  Check((Choice.Url = 'big.jpg') and (Abs(Choice.Density - 4) < 0.01), 'srcset: widths against sizes (' +
    Choice.Url + ')');
  Choice := SelectImageCandidate(ParseSrcset('hi.png 2x'), 'lo.png', 0, 1);
  Check(Choice.Url = 'lo.png', 'srcset: src as the 1x candidate');
end;

procedure CheckStreamingAndEvents;
var
  Route: TTestRoute;
  Document: TDocument;
  Text: string;
begin
  Text := '<!DOCTYPE html><html><head><title>Hello</title></head><body><p id="first">one</p>' +
    StringOfChar(' ', 2000) + '<p id="second">two</p></body></html>';
  Route := Environment.Site.AddRoute('a.test/stream.html', 200, 'Content-Type: text/html; charset=utf-8', Text);
  Route.Pieces := 2;
  Route.Gate := SyncObjs.TEvent.Create(nil, True, False, '');
  Navigable.NavigateTo('https://a.test/stream.html');
  Check(Environment.RunUntil(@Conditions.HasFirstParagraph), 'stream: the first piece is parsed before the rest');
  Document := Navigable.ActiveDocument;
  Check((Document.ReadyState = ReadyStateLoading) and (Document.GetElementById('second') = nil),
    'stream: still loading, the rest not there');
  EventLog := '';
  Document.AddEventListener('readystatechange', TLogListener.Create(@EventLog, 'readystatechange', Document));
  Document.AddEventListener('DOMContentLoaded', TLogListener.Create(@EventLog, 'DOMContentLoaded', Document));
  Navigable.Window.AddEventListener('load', TLogListener.Create(@EventLog, 'load', Document));
  Navigable.Window.AddEventListener('pageshow', TLogListener.Create(@EventLog, 'pageshow', Document));
  Navigable.Window.AddEventListener('DOMContentLoaded', TLogListener.Create(@EventLog, 'window-bubble', Document));
  Route.Gate.SetEvent;
  Environment.RunUntil(@Conditions.Complete);
  Check(Document.GetElementById('second') <> nil, 'stream: the rest parsed');
  Check(EventLog = 'readystatechange:interactive DOMContentLoaded:interactive window-bubble:interactive ' +
    'readystatechange:complete load:complete pageshow:complete', 'stream: events in order (' + EventLog + ')');
  Check((Observer.LastTitle = 'Hello') and (Observer.LastUrl = 'https://a.test/stream.html'),
    'stream: title and location told');
  Check(Observer.States = 'requesting receiving interactive complete', 'stream: loading states (' +
    Observer.States + ')');
  Check(Navigable.Title = 'Hello', 'stream: navigable title');
end;

procedure CheckStyleSheets;
var
  Route: TTestRoute;
  Sheet: TCssStyleSheet;
  Index: Integer;
  ImportFound: Boolean;
begin
  Sink.Log := '';
  Environment.Site.AddRoute('a.test/styled.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><link rel=stylesheet href=main.css><link rel="alternate stylesheet" href=alt.css>' +
    '<link rel=stylesheet href=off.css disabled><link rel=stylesheet href=print.css media=print>' +
    '<link rel=stylesheet href=wrong.css><p>styled</p>');
  Route := Environment.Site.AddRoute('a.test/main.css', 200, 'Content-Type: text/css',
    '@import "imp.css"; @import url(imp.css) supports(nonsense: 1); p { color: red }');
  Route.Pieces := 2;
  Route.Gate := SyncObjs.TEvent.Create(nil, True, False, '');
  Environment.Site.AddRoute('a.test/imp.css', 200, 'Content-Type: text/css',
    '@import "main.css"; @font-face { font-family: Test; src: url(f.woff2) format("woff2"), url(f.ttf) }');
  Environment.Site.AddRoute('a.test/print.css', 200, 'Content-Type: text/css', 'p { color: black }');
  Environment.Site.AddRoute('a.test/wrong.css', 200, 'Content-Type: text/plain', 'p { color: blue }');
  Environment.Site.AddRoute('a.test/f.woff2', 200, 'Content-Type: font/woff2', 'wOF2fontdata');
  Navigable.NavigateTo('https://a.test/styled.html');
  Environment.RunFor(150);
  Check(not Navigable.Loader.LoadFired and Navigable.Loader.DomContentLoadedFired,
    'sheets: DOMContentLoaded fired, load waits for the sheet');
  Route.Gate.SetEvent;
  Environment.RunUntil(@Conditions.Complete);
  Check(Navigable.Loader.LoadFired, 'sheets: load after the sheet');
  Check((Environment.Site.RequestCount('alt.css') = 0) and (Environment.Site.RequestCount('off.css') = 0),
    'sheets: alternate and disabled not fetched');
  Check(Environment.Site.RequestCount('print.css') = 1, 'sheets: non-matching media still fetched');
  Check((Pos('sheet:main.css', Sink.Log) > 0) and (Pos('sheet:print.css', Sink.Log) > 0) and
    (Pos('wrong.css', Sink.Log) = 0), 'sheets: delivered, wrong type refused (' + Sink.Log + ')');
  Check(Environment.Site.RequestCount('imp.css') = 1, 'sheets: import fetched once (supports() false skipped)');
  ImportFound := False;
  for Index := 0 to Sink.Sheets.Count - 1 do
  begin
    Sheet := TCssStyleSheet(Sink.Sheets[Index]);
    if (Pos('main.css', Sheet.Href) > 0) and (Length(Sheet.Rules) > 0) and (Sheet.Rules[0] is TCssImportRule) and
       (TCssImportRule(Sheet.Rules[0]).StyleSheet <> nil) and
       (Pos('imp.css', TCssImportRule(Sheet.Rules[0]).StyleSheet.Href) > 0) then
      ImportFound := True;
  end;
  Check(ImportFound, 'sheets: the imported sheet hangs on its rule');
  Check(Environment.Site.RequestCount('a.test/main.css') = 1, 'sheets: an import cycle is not followed');
  Check((Pos('font:Test', Sink.Log) > 0) and (Sink.FontBytes = 'wOF2fontdata') and
    (Environment.Site.RequestCount('f.ttf') = 0), 'sheets: @font-face first supported source loaded');
end;

procedure CheckImages;
begin
  Sink.Log := '';
  Sink.Ratio := 2;
  Environment.Site.AddRoute('a.test/pics.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><img src=big.png width=10 height=10><img srcset="lo.png 1x, hi.png 2x" src=lo.png>' +
    '<img src=broken.png><link rel=icon href=icon.png sizes=32x32><link rel=icon href=other.png sizes=16x16>');
  Environment.Site.AddRoute('a.test/big.png', 200, 'Content-Type: image/png', PngBytes(100, 50));
  Environment.Site.AddRoute('a.test/hi.png', 200, 'Content-Type: application/octet-stream', PngBytes(8, 8));
  Environment.Site.AddRoute('a.test/broken.png', 200, 'Content-Type: image/png', 'not a png');
  Environment.Site.AddRoute('a.test/icon.png', 200, 'Content-Type: image/png', PngBytes(32, 32));
  LoadAndWait('https://a.test/pics.html');
  Check(Environment.Site.RequestCount('hi.png') = 1, 'images: srcset 2x at ratio 2');
  Check(Environment.Site.RequestCount('lo.png') = 0, 'images: the 1x not fetched');
  Check(Pos('image-failed', Sink.Log) > 0, 'images: a bad image fails');
  Check(Navigable.Loader.LoadFired, 'images: load after the images');
  Check((Observer.IconUrl = 'https://a.test/icon.png') and (Observer.IconWidth = 32), 'icons: the best size chosen (' +
    Observer.IconUrl + ')');
  Sink.Ratio := 1;
end;

procedure CheckDownscale;
begin
  Sink.Log := '';
  Environment.Site.AddRoute('a.test/one.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><img src=big.png width=10 height=10>');
  LoadAndWait('https://a.test/one.html');
  Check(Sink.Log = 'image', 'images: one image (' + Sink.Log + ')');
  Check(Sink.LastDownscaled and (Sink.LastImageWidth <= 20) and (Abs(Sink.LastNaturalWidth - 100) < 0.01),
    'images: downscaled to the need, natural size kept (' + IntToStr(Sink.LastImageWidth) + ')');
end;

procedure CheckEncodingRestart;
var
  Text: string;
begin
  Text := '<!DOCTYPE html><html><head><!--' + StringOfChar('x', 1100) + '--><title>caf'#$C3#$A9'</title>' +
    '<meta charset="utf-8"></head><body><p id=first>x</p></body></html>';
  Environment.Site.AddRoute('a.test/late-meta.html', 200, 'Content-Type: text/html', Text);
  LoadAndWait('https://a.test/late-meta.html');
  Check(Navigable.Loader.Restarts = 1, 'encoding: the late meta restarted the parse');
  Check(Navigable.Title = 'caf'#$C3#$A9, 'encoding: decoded as UTF-8 after the restart (' + Navigable.Title + ')');
  Check(Navigable.ActiveDocument.CharacterSet = 'UTF-8', 'encoding: document character set');
end;

procedure CheckTextAndErrors;
var
  Pre: TElement;
begin
  Environment.Site.AddRoute('a.test/notes.txt', 200, 'Content-Type: text/plain; charset=utf-8', 'line <one>'#10'two');
  LoadAndWait('https://a.test/notes.txt');
  Pre := TElement(Navigable.ActiveDocument.GetElementsByTagName('pre').Item(0));
  Check((Pre <> nil) and (Pre.TextContent = 'line <one>'#10'two'), 'text: shown in a pre');
  Navigable.NavigateTo('gopher://nowhere.test/');
  Environment.RunUntil(@Conditions.Complete);
  Check((Observer.Failures = 1) and (Navigable.Title = 'Cannot open the page') and
    (Navigable.CurrentUrlText = 'gopher://nowhere.test/'), 'errors: an error page for a network error');
  Environment.Site.AddRoute('a.test/file.zip', 200, 'Content-Type: application/zip|' +
    'Content-Disposition: attachment; filename="pack.zip"', 'PK');
  Navigable.NavigateTo('https://a.test/file.zip');
  Environment.RunFor(100);
  Check((Observer.Downloads = 'pack.zip ') and (Navigable.CurrentUrlText = 'gopher://nowhere.test/'),
    'downloads: handed over, the page stays');
end;

procedure CheckScripts;
var
  Route: TTestRoute;
  Requested: Boolean;
begin
  Executor.Log := '';
  Environment.Site.AddRoute('a.test/scripts.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><script defer src=d.js></script><script async src=as.js></script>' +
    '<script src=block.js></script><script>inline</script><img src=later.png>' +
    '<script type=text/plain>data block</script><script nomodule>legacy</script>' +
    '<script type=module>module</script><p>end</p>');
  Environment.Site.AddRoute('a.test/d.js', 200, 'Content-Type: text/javascript', 'deferred');
  Environment.Site.AddRoute('a.test/as.js', 200, 'Content-Type: text/javascript', 'async');
  Route := Environment.Site.AddRoute('a.test/block.js', 200, 'Content-Type: text/javascript', 'blocking;');
  Route.Pieces := 2;
  Route.Gate := SyncObjs.TEvent.Create(nil, True, False, '');
  Environment.Site.AddRoute('a.test/later.png', 200, 'Content-Type: image/png', PngBytes(4, 4));
  Navigable.NavigateTo('https://a.test/scripts.html');
  Environment.RunFor(200);
  Requested := Environment.Site.RequestCount('later.png') = 1;
  Check(Requested and (Pos('blocking', Executor.Log) = 0), 'scripts: the preload scanner fetched ahead while blocked');
  Check(Navigable.ActiveDocument.GetElementsByTagName('img').Length = 0, 'scripts: the parser waits for the script');
  Route.Gate.SetEvent;
  Environment.RunUntil(@Conditions.Complete);
  Check(Pos('blocking; inline', Executor.Log) > 0, 'scripts: the blocking script, then the inline one (' +
    Executor.Log + ')');
  Check((Pos('deferred', Executor.Log) > Pos('inline', Executor.Log)) and
    (Pos('module', Executor.Log) > Pos('deferred', Executor.Log)), 'scripts: deferred and modules at the end, in order');
  Check(Pos('async', Executor.Log) > 0, 'scripts: async ran');
  Check((Pos('data block', Executor.Log) = 0) and (Pos('legacy', Executor.Log) = 0),
    'scripts: data blocks and nomodule skipped');
  Check(Environment.Site.RequestCount('later.png') = 1, 'scripts: the speculative fetch was used, not repeated');
end;

procedure CheckHistory;
var
  Before: Integer;
  OldWindowLog: string;
  OldWindow: TWebWindow;
begin
  Environment.Site.AddRoute('a.test/h1.html', 200, 'Content-Type: text/html', '<title>one</title><p>1');
  Environment.Site.AddRoute('a.test/h2.html', 200, 'Content-Type: text/html',
    '<title>two</title><p id=x>section</p>');
  LoadAndWait('https://a.test/h1.html');
  OldWindowLog := '';
  OldWindow := Navigable.Window;
  OldWindow.AddEventListener('pagehide', TLogListener.Create(@OldWindowLog, 'pagehide'));
  OldWindow.AddEventListener('unload', TLogListener.Create(@OldWindowLog, 'unload'));
  OldWindow.AddEventListener('beforeunload', TLogListener.Create(@OldWindowLog, 'beforeunload'));
  LoadAndWait('https://a.test/h2.html');
  Check(OldWindowLog = 'beforeunload pagehide unload', 'history: the old page unloaded (' + OldWindowLog + ')');
  Before := Environment.Site.RequestCount('h2.html');
  EventLog := '';
  Navigable.Window.AddEventListener('hashchange', TLogListener.Create(@EventLog, 'hashchange'));
  Navigable.Window.AddEventListener('popstate', TLogListener.Create(@EventLog, 'popstate'));
  Observer.FragmentCalls := 0;
  Navigable.NavigateTo('https://a.test/h2.html#x');
  Environment.RunFor(30);
  Check((Environment.Site.RequestCount('h2.html') = Before) and (Navigable.CurrentUrlText = 'https://a.test/h2.html#x'),
    'history: fragment navigation loads nothing');
  Check((Observer.FragmentElement <> nil) and (Navigable.ActiveDocument.TargetElement = Observer.FragmentElement) and
    (Observer.FragmentElement.Id = 'x'), 'history: :target and scroll to the fragment');
  Check(EventLog = 'hashchange', 'history: hashchange (' + EventLog + ')');
  Check((Navigable.History.Count >= 3) and Navigable.History.CanGoBack and not Navigable.History.CanGoForward,
    'history: entries');
  Navigable.Back;
  Environment.RunFor(30);
  Check((Navigable.CurrentUrlText = 'https://a.test/h2.html') and (Environment.Site.RequestCount('h2.html') = Before),
    'history: back within the document');
  Check(EventLog = 'hashchange popstate hashchange', 'history: popstate and hashchange (' + EventLog + ')');
  Navigable.Back;
  Environment.RunUntil(@Conditions.Complete);
  Check((Navigable.CurrentUrlText = 'https://a.test/h1.html') and (Navigable.Title = 'one') and
    (Observer.LastUrl = 'https://a.test/h1.html'), 'history: back to the other document');
  Check(Navigable.History.CanGoForward, 'history: forward possible');
  Navigable.Forward;
  Environment.RunUntil(@Conditions.Complete);
  Check(Navigable.CurrentUrlText = 'https://a.test/h2.html', 'history: forward');
  Before := Environment.Site.RequestCount('h2.html');
  Navigable.Reload;
  Environment.RunUntil(@Conditions.Complete);
  Check((Environment.Site.RequestCount('h2.html') = Before + 1) and (Navigable.Title = 'two'), 'history: reload');
end;

procedure RunLoadingTests;
begin
  CheckSrcset;
  Environment := TTestEnvironment.Create;
  Sink := TRecordingSink.Create;
  Observer := TRecordingObserver.Create;
  Executor := TRecordingExecutor.Create;
  Conditions := TConditions.Create;
  Navigable := nil;
  try
    NewNavigable;
    CheckStreamingAndEvents;
    CheckStyleSheets;
    CheckImages;
    CheckDownscale;
    CheckEncodingRestart;
    CheckTextAndErrors;
    CheckScripts;
    CheckHistory;
  finally
    Navigable.Free;
    Environment.Free;
    Conditions.Free;
    Executor.Free;
    Observer.Free;
    Sink.Free;
  end;
end;

end.
