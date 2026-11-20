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
  One webbrowse run: a TWebPage over the host network with the layout
  sink and page scripting, driven the way the web view drives it (tasks
  in 12 ms slices, a frame every 16 ms: rendering steps, then style and
  layout), until the page has loaded and gone quiet (or the time is
  up); then the outputs the options ask for. It measures what makes a
  GUI stutter: the longest slice of tasks and the longest frame.
}
unit WebBrowse.Session;

{$mode objfpc}
{$H+}

interface

type
  TBrowseOptions = record
    Url: string;
    Width, Height, Scale: Double;
    WholePage: Boolean;
    PngFile: string;
    LayoutFile: string;
    DomFile: string;
    ShowConsole: Boolean;
    ShowNetwork: Boolean;
    LiveNetwork: Boolean;
    ShowPhases: Boolean;
    ShowMemory: Boolean;
    Scripting: Boolean;
    TimeoutSeconds: Double;
    QuietMilliseconds: Double;
    StallSeconds: Integer;
    FontDirectory: string;
    EvalSource: string;
    Verbose: Boolean;
  end;

function DefaultBrowseOptions: TBrowseOptions;
{ The exit status: 0 loaded, 1 failed, 2 timed out. }
function RunBrowse(const Options: TBrowseOptions): Integer;

implementation

uses
  SysUtils,
  Classes,
  Math,
  Linux,
  UnixType,
  Http.Client,
  Http.Observers,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Image.Model,
  Image.Surfaces,
  Image.Codecs,
  Image.Files,
  Image.StandardCodecs,
  Js.Engine,
  Js.Values,
  Web.Dom,
  Web.Html.Serializer,
  Web.Fetch.NetworkContexts,
  Web.Loading.LayoutSink,
  Web.Layout.Resources,
  Web.Layout.Document,
  Web.Layout.Dump,
  Web.Paint.Painter,
  Web.Navigation.Navigables,
  Web.Navigation.Windows,
  Web.Navigation.Pages,
  Web.Bindings.Context,
  Web.Script.Context,
  Web.Script.PageScripting,
  Web.Text.Fonts,
  Web.Profiling,
  WebBrowse.HostNetwork,
  WebBrowse.NetworkLog,
  WebBrowse.Watchdog;

const
  SliceMilliseconds = 12;
  FrameMilliseconds = 16;
  UserAgentText = 'Mozilla/5.0 (FreePascalOS) libweb/1.0';

type
  TBrowseSession = class
  private
    FOptions: TBrowseOptions;
    FStarted: Double;
    FNetwork: TNetworkContext;
    FSink: TLayoutResourceSink;
    FPage: TWebPage;
    FExecutor: TPageScriptExecutor;
    FLog: TNetworkLog;
    FDocument: TDocument;
    FLayout: TDocumentLayout;
    FConsole: TStringList;
    FLastFrame: Double;
    FQuietSince: Double;
    FLongestSlice, FLongestFrame: Double;
    FLongestSliceWhen, FLongestFrameWhen: Double;
    FFrames: Integer;
    FLoadedAt, FFirstLayoutAt: Double;
    FFailure: string;
    procedure ConsoleMessage(const Level, Text: string);
    procedure AdoptDocument(Document: TDocument);
    procedure ReleaseDocument;
    procedure Frame;
    function Loaded: Boolean;
    function Quiet: Boolean;
    procedure Report;
    procedure PaintPng;
    procedure RunEval;
  public
    constructor Create(const Options: TBrowseOptions);
    destructor Destroy; override;
    function Clock: Double;
    function Run: Integer;
  end;

  TSessionObserver = class(TNavigableObserver)
  public
    Session: TBrowseSession;
    procedure NavigationFailed(Navigable: TNavigable; const Url, Reason: string); override;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
  end;

function MonotonicMicroseconds: Double;
var
  Spec: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @Spec);
  Result := Double(Spec.tv_sec) * 1000000 + Double(Spec.tv_nsec) / 1000;
end;

function DefaultBrowseOptions: TBrowseOptions;
begin
  Result := Default(TBrowseOptions);
  Result.Width := 1280;
  Result.Height := 800;
  Result.Scale := 1;
  Result.Scripting := True;
  Result.TimeoutSeconds := 60;
  Result.QuietMilliseconds := 500;
  Result.StallSeconds := 5;
  Result.FontDirectory := 'userland/fonts';
end;

{ Before the old document goes (as the web view does). }
procedure TSessionObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
  Session.AdoptDocument(Document);
end;

procedure TSessionObserver.NavigationFailed(Navigable: TNavigable; const Url, Reason: string);
begin
  Session.FFailure := Url + ': ' + Reason;
  WriteLn(StdErr, 'navigation failed: ', Session.FFailure);
end;

constructor TBrowseSession.Create(const Options: TBrowseOptions);
var
  Settings: THttpClientSettings;
begin
  inherited Create;
  FOptions := Options;
  FStarted := MonotonicMicroseconds;
  FConsole := TStringList.Create;
  Settings := DefaultClientSettings;
  Settings.UserAgent := UserAgentText;
  Settings.AllowHttp3 := False;
  Settings.TimeoutMilliseconds := 20000;
  FNetwork := TNetworkContext.Create(CreateHostClient(Settings), True);
  FSink := TLayoutResourceSink.Create;
  FPage := TWebPage.Create(FNetwork, FSink, nil);
  FLog := TNetworkLog.Create(@Clock);
  FLog.Live := Options.LiveNetwork;
  FPage.Fetcher.Monitor := FLog;
  FSink.AttachNavigable(FPage.Navigable);
  FSink.SetViewport(Options.Width, Options.Height, Options.Scale);
  FExecutor := TPageScriptExecutor.Create(FPage.Navigable);
  FExecutor.Environment.UserAgentText := UserAgentText;
  FExecutor.OnConsoleMessage := @ConsoleMessage;
  if Options.Scripting then
    FPage.Navigable.Executor := FExecutor;
  FPage.Navigable.ObserverObject := TSessionObserver.Create;
  TSessionObserver(FPage.Navigable.ObserverObject).Session := Self;
  AdoptDocument(FPage.Navigable.ActiveDocument);
  FLoadedAt := -1;
  FFirstLayoutAt := -1;
  FQuietSince := -1;
end;

destructor TBrowseSession.Destroy;
var
  Observer: TNavigableObserver;
begin
  FPage.Fetcher.Monitor := nil;
  Observer := FPage.Navigable.ObserverObject;
  FPage.Navigable.ObserverObject := nil;
  Observer.Free;
  FExecutor.Shutdown;
  ReleaseDocument;
  FPage.Free;
  FExecutor.Free;
  FSink.Free;
  FNetwork.Free;
  FLog.Free;
  FConsole.Free;
  inherited Destroy;
end;

{ Milliseconds since the start. }
function TBrowseSession.Clock: Double;
begin
  Result := (MonotonicMicroseconds - FStarted) / 1000;
end;

procedure TBrowseSession.ConsoleMessage(const Level, Text: string);
var
  Line: string;
begin
  Line := Format('%8.0f %s: %s', [Clock, Level, Text]);
  FConsole.Add(Line);
  if FOptions.Verbose then
    WriteLn(StdErr, 'console ', Line);
end;

procedure TBrowseSession.ReleaseDocument;
begin
  FreeAndNil(FLayout);
  if FDocument <> nil then
  begin
    FSink.DocumentGoing(FDocument);
    FreeDocumentResources(FDocument);
  end;
  FDocument := nil;
end;

procedure TBrowseSession.AdoptDocument(Document: TDocument);
begin
  if Document = FDocument then
    Exit;
  ReleaseDocument;
  FDocument := Document;
  if Document = nil then
    Exit;
  if FOptions.Verbose then
    WriteLn(StdErr, Format('%8.0f document %s', [Clock, Document.Url]));
  FSink.PrepareDocument(Document);
  FLayout := TDocumentLayout.Create(Document);
  FLayout.SetViewport(FOptions.Width, FOptions.Height, FOptions.Scale);
end;

{ What the web view does on its frame timer. }
procedure TBrowseSession.Frame;
var
  Began, Took: Double;
begin
  Began := Clock;
  FPage.RenderingOpportunity;
  if (FLayout <> nil) and FLayout.NeedsUpdate then
  begin
    FLayout.Update;
    if FFirstLayoutAt < 0 then
      FFirstLayoutAt := Clock;
  end;
  Took := Clock - Began;
  Inc(FFrames);
  if Took > FLongestFrame then
  begin
    FLongestFrame := Took;
    FLongestFrameWhen := Began;
  end;
  FLastFrame := Clock;
end;

function TBrowseSession.Loaded: Boolean;
begin
  Result := (FPage.Navigable.State = LoadingComplete) and (FPage.Navigable.Loader <> nil) and
    FPage.Navigable.Loader.LoadFired;
end;

function TBrowseSession.Quiet: Boolean;
begin
  Result := Loaded and (FPage.Fetcher.ActiveJobCount = 0) and (FSink.PendingStyleImageCount = 0) and
    not FPage.Loop.HasReadyTask and ((FLayout = nil) or not FLayout.NeedsUpdate);
end;

procedure TBrowseSession.RunEval;
var
  Context: TScriptContext;
  Value: TJsValue;
  ErrorText: string;
begin
  if (FOptions.EvalSource = '') or (FDocument = nil) then
    Exit;
  Context := FExecutor.ContextOf(FDocument);
  if Context = nil then
  begin
    WriteLn('eval: no script context (scripting off?)');
    Exit;
  end;
  Context.EnterScript;
  try
    if Context.Engine.TryEvaluate(FOptions.EvalSource, '<webbrowse>', Value, ErrorText) then
      WriteLn('eval: ', Context.Engine.Inspect(Value))
    else
      WriteLn('eval: error: ', ErrorText);
  finally
    Context.LeaveScript;
  end;
end;

function TBrowseSession.Run: Integer;
var
  Began, Took, Deadline, Wait, Next: Double;
  Evaluated: Boolean;
begin
  Result := 0;
  if not FPage.NavigateTo(FOptions.Url) then
  begin
    WriteLn(StdErr, 'webbrowse: not a URL: ', FOptions.Url);
    Exit(1);
  end;
  Deadline := FOptions.TimeoutSeconds * 1000;
  Evaluated := FOptions.EvalSource = '';
  while True do
  begin
    Beat;
    Began := Clock;
    FPage.ProcessPendingWork(SliceMilliseconds);
    Took := Clock - Began;
    if Took > FLongestSlice then
    begin
      FLongestSlice := Took;
      FLongestSliceWhen := Began;
    end;
    if Clock - FLastFrame >= FrameMilliseconds then
      Frame;
    if (FLoadedAt < 0) and Loaded then
    begin
      FLoadedAt := Clock;
      if FOptions.Verbose then
        WriteLn(StdErr, Format('%8.0f load event', [FLoadedAt]));
    end;
    if Quiet then
    begin
      if FQuietSince < 0 then
        FQuietSince := Clock;
      if Clock - FQuietSince >= FOptions.QuietMilliseconds then
      begin
        if Evaluated then
          Break;
        RunEval;
        Evaluated := True;
        FQuietSince := -1;
      end;
    end
    else
      FQuietSince := -1;
    if (FFailure <> '') and not FPage.Loop.HasReadyTask and (FPage.Fetcher.ActiveJobCount = 0) then
    begin
      Result := 1;
      Break;
    end;
    if Clock >= Deadline then
    begin
      WriteLn(StdErr, Format('webbrowse: timed out after %.0f s (state %d, %d fetches active, %d url() images pending)',
        [FOptions.TimeoutSeconds, Ord(FPage.Navigable.State), FPage.Fetcher.ActiveJobCount,
        FSink.PendingStyleImageCount]));
      Result := 2;
      Break;
    end;
    if not FPage.Loop.HasReadyTask then
    begin
      Wait := FrameMilliseconds - (Clock - FLastFrame);
      Next := FPage.MillisecondsUntilNextTimer;
      if (Next >= 0) and (Next < Wait) then
        Wait := Next;
      if Wait >= 1 then
        FPage.Loop.WaitForWork(Ceil(Wait));
    end;
  end;
  Frame;
  Report;
  PaintPng;
end;

function PeakMemoryText: string;
var
  Status: TStringList;
  Index: Integer;
begin
  Result := '';
  Status := TStringList.Create;
  try
    try
      Status.LoadFromFile('/proc/self/status');
    except
      Exit;
    end;
    for Index := 0 to Status.Count - 1 do
      if (Copy(Status[Index], 1, 6) = 'VmHWM:') or (Copy(Status[Index], 1, 6) = 'VmRSS:') then
        Result := Result + ' ' + Trim(Status[Index]);
  finally
    Status.Free;
  end;
end;

procedure WriteTextFile(const FileName, Text: string);
var
  Stream: TFileStream;
begin
  if FileName = '-' then
  begin
    Write(Text);
    Exit;
  end;
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    if Text <> '' then
      Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
end;

procedure TBrowseSession.Report;
var
  Phase: TWebPhase;
  Index: Integer;
begin
  WriteLn(Format('url: %s', [FPage.Navigable.CurrentUrlText]));
  WriteLn(Format('title: %s', [FPage.Navigable.Title]));
  WriteLn(Format('load event: %.0f ms, first layout: %.0f ms, done: %.0f ms', [FLoadedAt, FFirstLayoutAt, Clock]));
  WriteLn(Format('requests: %d (%d unfinished), %d bytes', [FLog.Count, FLog.UnfinishedCount, FLog.TotalBytes]));
  WriteLn(Format('longest task slice: %.1f ms at %.0f ms; longest frame: %.1f ms at %.0f ms; frames: %d',
    [FLongestSlice, FLongestSliceWhen, FLongestFrame, FLongestFrameWhen, FFrames]));
  if FLayout <> nil then
    WriteLn(Format('document: %.0f x %.0f CSS px', [FLayout.DocumentWidth, FLayout.DocumentHeight]));
  if FOptions.ShowPhases then
  begin
    WriteLn('phase          total ms   count  longest ms');
    for Phase := Low(TWebPhase) to High(TWebPhase) do
      if Phase <> PhaseIdle then
        WriteLn(Format('%-12s %10.1f %7d %11.1f', [PhaseName(Phase), PhaseMilliseconds(Phase), PhaseCount(Phase),
          PhaseLongestMilliseconds(Phase)]));
  end;
  if FOptions.ShowMemory then
    WriteLn('memory:', PeakMemoryText);
  if FOptions.ShowNetwork then
    FLog.Print(Output);
  if FOptions.ShowConsole then
  begin
    WriteLn('console messages: ', FConsole.Count);
    for Index := 0 to FConsole.Count - 1 do
      WriteLn('  ', FConsole[Index]);
  end;
  if (FOptions.LayoutFile <> '') and (FLayout <> nil) then
    WriteTextFile(FOptions.LayoutFile, DumpLayoutTree(FLayout.Root));
  if (FOptions.DomFile <> '') and (FDocument <> nil) then
    WriteTextFile(FOptions.DomFile, SerializeChildren(FDocument));
end;

procedure TBrowseSession.PaintPng;
var
  Painter: TDocumentPainter;
  Surface: TSurface;
  Width, Height: LongInt;
  Image: TImage;
  Began: Double;
begin
  if (FOptions.PngFile = '') or (FLayout = nil) then
    Exit;
  Began := Clock;
  if FOptions.WholePage and (FLayout.DocumentHeight > FLayout.ViewportHeight) then
  begin
    FLayout.SetViewport(FLayout.ViewportWidth, Min(Ceil(FLayout.DocumentHeight), 30000), FLayout.Scale);
    FLayout.Update;
  end;
  Width := Max(1, Round(FLayout.ViewportWidth * FLayout.Scale));
  Height := Max(1, Round(FLayout.ViewportHeight * FLayout.Scale));
  if not CreateSurface(Surface, Width, Height, ColorWhite) then
  begin
    WriteLn(StdErr, 'webbrowse: cannot make a ', Width, 'x', Height, ' surface');
    Exit;
  end;
  Painter := TDocumentPainter.Create(FLayout);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, Width, Height));
    WriteLn(Format('paint: %.1f ms (%d x %d)', [Clock - Began, Width, Height]));
    Image := ImageTakingSurface(Surface);
    try
      SaveImage(Image, FOptions.PngFile, ImageFormatPng);
    finally
      Image.Free;
    end;
  finally
    Painter.Free;
  end;
end;

function RunBrowse(const Options: TBrowseOptions): Integer;
var
  Session: TBrowseSession;
begin
  if Options.FontDirectory <> '' then
  begin
    WebFontDirectory := Options.FontDirectory;
    ResetWebFontLibrary;
  end;
  StartProfiling(@MonotonicMicroseconds);
  StartWatchdog(Options.StallSeconds, Max(60, Round(Options.TimeoutSeconds) + 60));
  Session := TBrowseSession.Create(Options);
  try
    Result := Session.Run;
  finally
    StopWatchdog;
    Session.Free;
  end;
end;

initialization
  RegisterStandardImageCodecs;
end.
