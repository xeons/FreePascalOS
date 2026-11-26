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
    ResizeWidth, ResizeHeight: Double;
    ScrollY: Double;
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
    { Sample the page thread's stack every millisecond and print where
      the time went. }
    Profile: Boolean;
    { Moves of the pointer down the viewport once quiet (hover). }
    HoverMoves: Integer;
    { What a user does once the page is quiet (after -e), each step when
      the page is quiet again (or ten seconds on): "eval:JS",
      "type:TEXT" (\n is Enter), "key:NAME" ("Enter", "ctrl+KeyA"),
      "click:SELECTOR", "wait:MS", "shot:FILE.png"; with the web view's
      pointer (WebBrowse.Pointer, viewport CSS px): "scroll:DY",
      "hover:X,Y", "press:X,Y", "move:X,Y", "release:X,Y",
      "drag:X1,Y1,X2,Y2", "dblclick:X,Y", "tripleclick:X,Y", "selectall",
      "copy" (prints the selected text). Two of them also take another
      shape of argument: "scroll:top" and "scroll:bottom" scroll the
      viewport there (a number is the wheel's DY), "hover:SELECTOR"
      moves the pointer to the middle of the first element matching
      (scrolled into view; X,Y is a point). And "scrollby:DY" scrolls
      the viewport itself by DY, "hoverat:X,Y" is "hover:X,Y", "back"
      and "forward" go through the session history. }
    Steps: array of string;
    { How long a step waits for quiet before it goes on anyway. }
    StepPatienceMilliseconds: Double;
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
  Web.Script.Layout,
  Web.Layout.AnimationEvents,
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
  Font.Configuration,
  Web.Profiling,
  Css.ElementAdapter,
  Web.Bindings.Selectors,
  Web.UserAgent,
  WebBrowse.Input,
  WebBrowse.Pointer,
  WebView.PageSelection,
  WebView.ClipboardEvents,
  WebBrowse.HostNetwork,
  WebBrowse.NetworkLog,
  WebBrowse.Sampler,
  WebBrowse.Watchdog;

const
  SliceMilliseconds = 12;
  FrameMilliseconds = 16;
  { Between typed characters, and the longest wait for quiet before a step. }
  KeyMilliseconds = 60;
  { The browser's. }
  UserAgentText = EngineUserAgent;

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
    FScriptLayout: TDocumentScriptLayout;
    { Frames paint the viewport here as the web view does (url() images
      are asked for when the display list is built). }
    FFramePainter: TDocumentPainter;
    FFrameSurface: TSurface;
    FPaintedVersion: LongWord;
    FConsole: TStringList;
    FLastFrame: Double;
    FQuietSince: Double;
    FLongestSlice, FLongestFrame: Double;
    FLongestSliceWhen, FLongestFrameWhen: Double;
    FFrames: Integer;
    FLoadedAt, FFirstLayoutAt: Double;
    FFailure: string;
    FInput: TPageInput;
    { The user's selection and pointer, as the web view has them. }
    FSelection: TPageSelection;
    FPointer: TPagePointer;
    FSelectionObserver: TDocumentObserver;
    FStepIndex: Integer;
    FStepReadyAt: Double;
    FTyping: string;
    FNextKeyAt: Double;
    FWaitUntil: Double;
    procedure ConsoleMessage(const Level, Text: string);
    procedure AdoptDocument(Document: TDocument);
    procedure ReleaseDocument;
    procedure Frame;
    function Loaded: Boolean;
    function Quiet: Boolean;
    procedure Report;
    procedure PaintPng;
    procedure RunEval;
    procedure Evaluate(const Source: string);
    procedure SweepHover;
    procedure SavePng(const FileName: string);
    function StepsBusy: Boolean;
    procedure TypeNextCharacter;
    procedure RunStep(const Step: string);
    function RunPointerStep(const Kind, Argument: string): Boolean;
    procedure ScrollViewport(const Argument: string; Relative: Boolean);
    procedure HoverElement(const Selector: string);
  public
    constructor Create(const Options: TBrowseOptions);
    destructor Destroy; override;
    function Clock: Double;
    function Run: Integer;
  end;

  { The document's selection changes reach the session's selection. }
  TSelectionObserver = class(TDocumentObserver)
  public
    Selection: TPageSelection;
    procedure SelectionChanged(Document: TDocument); override;
  end;

  TSessionObserver = class(TNavigableObserver)
  public
    Session: TBrowseSession;
    procedure NavigationFailed(Navigable: TNavigable; const Url, Reason: string); override;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
  end;

procedure TSelectionObserver.SelectionChanged(Document: TDocument);
begin
  Selection.DocumentSelectionChanged;
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
  Result.StepPatienceMilliseconds := 10000;
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
  FInput := TPageInput.Create(FPage.Navigable);
  FSelection := TPageSelection.Create;
  FPointer := TPagePointer.Create;
  FSelectionObserver := TSelectionObserver.Create;
  TSelectionObserver(FSelectionObserver).Selection := FSelection;
  FExecutor := TPageScriptExecutor.Create(FPage.Navigable);
  FExecutor.Environment.UserAgentText := UserAgentText;
  FScriptLayout := TDocumentScriptLayout.Create;
  FExecutor.Environment.Layout := FScriptLayout;
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
  FInput.Free;
  FPointer.Free;
  FSelection.Free;
  FSelectionObserver.Free;
  FScriptLayout.Free;
  FSink.Free;
  FNetwork.Free;
  FLog.Free;
  FConsole.Free;
  FreeSurface(FFrameSurface);
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
  FPointer.Attach(nil, nil, nil, nil);
  FSelection.Attach(nil, nil, nil);
  if FDocument <> nil then
    FDocument.RemoveObserver(FSelectionObserver);
  if FScriptLayout <> nil then
  begin
    FScriptLayout.Layout := nil;
    FScriptLayout.Painter := nil;
  end;
  FreeAndNil(FFramePainter);
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
  FFramePainter := TDocumentPainter.Create(FLayout);
  FPaintedVersion := High(LongWord);
  FLayout.SetViewport(FOptions.Width, FOptions.Height, FOptions.Scale);
  if FScriptLayout <> nil then
  begin
    FScriptLayout.Layout := FLayout;
    FScriptLayout.Painter := FFramePainter;
  end;
  FSelection.Attach(Document, FLayout, FFramePainter);
  FPointer.Attach(Document, FLayout, FFramePainter, FSelection);
  FPointer.ViewportHeight := FOptions.Height;
  Document.AddObserver(FSelectionObserver);
end;

{ What the web view does on its frame timer. }
procedure TBrowseSession.Frame;
var
  Began, Took: Double;
begin
  Began := Clock;
  FPage.RenderingOpportunity;
  if FLayout <> nil then
    FLayout.AdvanceAnimations;
  if (FLayout <> nil) and FLayout.NeedsUpdate then
  begin
    FLayout.Update;
    if FFirstLayoutAt < 0 then
      FFirstLayoutAt := Clock;
  end;
  if FLayout <> nil then
    QueueAnimationEvents(FPage.Loop, FLayout.Document, FLayout.TakeAnimationEvents);
  if (FLayout <> nil) and (FLayout.PaintVersion <> FPaintedVersion) then
  begin
    if FFrameSurface.Pixels = nil then
      CreateSurface(FFrameSurface, Max(1, Round(FOptions.Width * FOptions.Scale)),
        Max(1, Round(FOptions.Height * FOptions.Scale)), ColorWhite);
    if FFrameSurface.Pixels <> nil then
      FFramePainter.Paint(FFrameSurface, MakeRectangle(0, 0, FFrameSurface.Width, FFrameSurface.Height));
    FPaintedVersion := FLayout.PaintVersion;
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
  { A running animation (an endless spinner) keeps the layout due:
    that alone does not keep the page from being quiet. }
  Result := Loaded and (FPage.Fetcher.ActiveJobCount = 0) and (FSink.PendingStyleImageCount = 0) and
    not FPage.Loop.HasReadyTask and ((FLayout = nil) or not FLayout.NeedsUpdate or FLayout.AnimationsRunning);
end;

{ The pointer moved down the middle of the viewport in HoverMoves steps,
  :hover set on the chain under it as the web view does, the page laid
  out and painted after each move: how long the GUI would be busy. }
procedure TBrowseSession.SweepHover;
var
  Move, Index: Integer;
  Hit: THitTestResult;
  Node: TNode;
  Previous, Current: array of TElement;
  Began, Took, Longest, Total: Double;

  function Contains(const Chain: array of TElement; Element: TElement): Boolean;
  var
    Item: Integer;
  begin
    for Item := 0 to High(Chain) do
      if Chain[Item] = Element then
        Exit(True);
    Result := False;
  end;

begin
  if (FOptions.HoverMoves <= 0) or (FLayout = nil) then
    Exit;
  Previous := nil;
  Longest := 0;
  Total := 0;
  for Move := 0 to FOptions.HoverMoves - 1 do
  begin
    Began := Clock;
    Hit := FFramePainter.HitTest(FOptions.Width * (0.2 + 0.6 * (Move mod 7) / 6),
      FOptions.Height * (Move + 0.5) / FOptions.HoverMoves);
    Current := nil;
    Node := Hit.Element;
    while Node <> nil do
    begin
      if Node.IsElement then
      begin
        SetLength(Current, Length(Current) + 1);
        Current[High(Current)] := TElement(Node);
      end;
      Node := Node.ParentNode;
    end;
    for Index := 0 to High(Previous) do
      if not Contains(Current, Previous[Index]) then
        FLayout.SetElementStates(Previous[Index], []);
    for Index := 0 to High(Current) do
      if not Contains(Previous, Current[Index]) then
        FLayout.SetElementStates(Current[Index], [esHover]);
    Previous := Current;
    Frame;
    Took := Clock - Began;
    Total := Total + Took;
    if Took > Longest then
      Longest := Took;
  end;
  WriteLn(Format('hover: %d moves, %.1f ms on average, %.1f ms the longest', [FOptions.HoverMoves,
    Total / FOptions.HoverMoves, Longest]));
end;

procedure TBrowseSession.RunEval;
begin
  Evaluate(FOptions.EvalSource);
end;

procedure TBrowseSession.Evaluate(const Source: string);
var
  Context: TScriptContext;
  Value: TJsValue;
  ErrorText: string;
begin
  if (Source = '') or (FDocument = nil) then
    Exit;
  Context := FExecutor.ContextOf(FDocument);
  if Context = nil then
  begin
    WriteLn('eval: no script context (scripting off?)');
    Exit;
  end;
  Context.EnterScript;
  try
    if Context.Engine.TryEvaluate(Source, '<webbrowse>', Value, ErrorText) then
      WriteLn('eval: ', Context.Engine.Inspect(Value))
    else
      WriteLn('eval: error: ', ErrorText);
  finally
    Context.LeaveScript;
  end;
end;

{ Typing or waiting: the page is not left alone yet. }
function TBrowseSession.StepsBusy: Boolean;
begin
  Result := (FTyping <> '') or (Clock < FWaitUntil);
end;

procedure TBrowseSession.TypeNextCharacter;
var
  Length_: Integer;
  Lead: Byte;
  Character: LongWord;
begin
  Lead := Ord(FTyping[1]);
  if Lead < $80 then
  begin
    Length_ := 1;
    Character := Lead;
  end
  else if Lead < $E0 then
  begin
    Length_ := 2;
    Character := Lead and $1F;
  end
  else if Lead < $F0 then
  begin
    Length_ := 3;
    Character := Lead and $0F;
  end
  else
  begin
    Length_ := 4;
    Character := Lead and $07;
  end;
  while Length_ > 1 do
  begin
    Delete(FTyping, 1, 1);
    Dec(Length_);
    if FTyping = '' then
      Exit;
    Character := (Character shl 6) or (Ord(FTyping[1]) and $3F);
  end;
  Delete(FTyping, 1, 1);
  if FOptions.Verbose then
    WriteLn(StdErr, Format('%8.0f type %d', [Clock, Character]));
  FInput.TypeCharacter(FDocument, Character);
  FNextKeyAt := Clock + KeyMilliseconds;
end;

procedure TBrowseSession.RunStep(const Step: string);
var
  Kind, Argument: string;
  Element: TElement;
begin
  Kind := Copy(Step, 1, Pos(':', Step) - 1);
  { A step without an argument ("copy"). }
  if Pos(':', Step) = 0 then
    Kind := Step;
  Argument := Copy(Step, Pos(':', Step) + 1, MaxInt);
  WriteLn(Format('%8.0f step %s', [Clock, Step]));
  if Kind = 'eval' then
    Evaluate(Argument)
  else if Kind = 'type' then
  begin
    FTyping := StringReplace(Argument, '\n', #10, [rfReplaceAll]);
    FNextKeyAt := Clock;
  end
  else if Kind = 'key' then
  begin
    if not FInput.PressNamedKey(FDocument, Argument) then
      WriteLn('step: no key named ', Argument);
  end
  else if Kind = 'click' then
  begin
    Element := nil;
    if FDocument <> nil then
      Element := QuerySelector(FDocument, Argument);
    if Element = nil then
      WriteLn('step: nothing matches ', Argument)
    else
      FInput.Click(Element);
  end
  else if Kind = 'wait' then
    FWaitUntil := Clock + StrToFloatDef(Argument, 0)
  else if Kind = 'shot' then
    SavePng(Argument)
  else if (Kind = 'scroll') and ((Argument = 'top') or (Argument = 'bottom')) then
    ScrollViewport(Argument, False)
  else if Kind = 'scrollby' then
    ScrollViewport(Argument, True)
  else if (Kind = 'hover') and (Argument <> '') and not (Argument[1] in ['0'..'9', '-', '.']) then
    HoverElement(Argument)
  else if Kind = 'hoverat' then
    RunPointerStep('hover', Argument)
  else if Kind = 'back' then
    FPage.Navigable.Back
  else if Kind = 'forward' then
    FPage.Navigable.Forward
  else if not RunPointerStep(Kind, Argument) then
    WriteLn('step: unknown ', Step);
end;

{ The viewport scrolled to the top or the bottom, or by Argument CSS px. }
procedure TBrowseSession.ScrollViewport(const Argument: string; Relative: Boolean);
var
  ScrollX, ScrollY: Single;
  Target: Double;
begin
  if FLayout = nil then
    Exit;
  if FLayout.NeedsUpdate then
    FLayout.Update;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  if Argument = 'top' then
    Target := 0
  else if Argument = 'bottom' then
    Target := Max(0, FLayout.DocumentHeight - FLayout.ViewportHeight)
  else
    Target := ScrollY + StrToFloatDef(Argument, 0);
  FLayout.SetScrollOffset(nil, ScrollX, Target);
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  WriteLn(Format('scrolled to %.0f of %.0f', [ScrollY, FLayout.DocumentHeight]));
end;

{ The pointer moved to the middle of the first element matching Selector,
  the viewport scrolled first when it is out of view. }
procedure TBrowseSession.HoverElement(const Selector: string);
var
  Element: TElement;
  X, Y, Width, Height: Double;
  ScrollX, ScrollY: Single;
begin
  if (FDocument = nil) or (FLayout = nil) then
    Exit;
  Element := QuerySelector(FDocument, Selector);
  if Element = nil then
  begin
    WriteLn('step: nothing matches ', Selector);
    Exit;
  end;
  if not FScriptLayout.BorderBox(Element, X, Y, Width, Height) then
  begin
    WriteLn('step: no box for ', Selector);
    Exit;
  end;
  FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  if (Y + Height / 2 < ScrollY) or (Y + Height / 2 > ScrollY + FLayout.ViewportHeight) then
  begin
    FLayout.SetScrollOffset(nil, ScrollX, Y + Height / 2 - FLayout.ViewportHeight / 2);
    FLayout.GetScrollOffset(nil, ScrollX, ScrollY);
  end;
  RunPointerStep('hover', Format('%.1f,%.1f', [X + Width / 2 - ScrollX, Y + Height / 2 - ScrollY],
    DefaultFormatSettings));
end;

{ The pointer steps; the numbers of Argument are viewport CSS px. }
function TBrowseSession.RunPointerStep(const Kind, Argument: string): Boolean;
var
  Numbers: array of Single;
  Parts: TStringArray;
  Index: Integer;
  Copied: string;
  Outcome: TClipboardOutcome;

  function Need(Count: Integer): Boolean;
  begin
    Result := Length(Numbers) >= Count;
    if not Result then
      WriteLn('step: ', Kind, ' needs ', Count, ' numbers');
  end;

begin
  Result := True;
  Numbers := nil;
  Parts := Argument.Split([',']);
  for Index := 0 to High(Parts) do
    if Trim(Parts[Index]) <> '' then
    begin
      SetLength(Numbers, Length(Numbers) + 1);
      Numbers[High(Numbers)] := StrToFloatDef(Trim(Parts[Index]), 0);
    end;
  if not ((Kind = 'scroll') or (Kind = 'hover') or (Kind = 'press') or (Kind = 'move') or (Kind = 'release') or
     (Kind = 'drag') or (Kind = 'dblclick') or (Kind = 'tripleclick') or (Kind = 'selectall') or
     (Kind = 'copy')) then
    Exit(False);
  if FLayout = nil then
  begin
    WriteLn('step: no layout for ', Kind);
    Exit;
  end;
  if Kind = 'scroll' then
  begin
    if Need(1) then
      FPointer.Wheel(Numbers[0]);
  end
  else if (Kind = 'hover') or (Kind = 'move') then
  begin
    if Need(2) then
      FPointer.MoveTo(Numbers[0], Numbers[1]);
  end
  else if Kind = 'press' then
  begin
    if Need(2) then
      FPointer.Press(Numbers[0], Numbers[1], 1);
  end
  else if Kind = 'release' then
  begin
    if Need(2) then
      FPointer.Release(Numbers[0], Numbers[1], 1);
  end
  else if Kind = 'drag' then
  begin
    if Need(4) then
      FPointer.Drag(Numbers[0], Numbers[1], Numbers[2], Numbers[3], 12);
  end
  else if Kind = 'dblclick' then
  begin
    if Need(2) then
      FPointer.ClickAt(Numbers[0], Numbers[1], 2);
  end
  else if Kind = 'tripleclick' then
  begin
    if Need(2) then
      FPointer.ClickAt(Numbers[0], Numbers[1], 3);
  end
  else if Kind = 'selectall' then
  begin
    if FLayout.NeedsUpdate then
      FLayout.Update;
    FSelection.SelectAll;
  end
  else
  begin
    if FLayout.NeedsUpdate then
      FLayout.Update;
    FSelection.Refresh;
    { The page's copy event first, as the web view sends it. }
    Outcome := FireCopyEvent(ClipboardEventTarget(FDocument), 'copy');
    if not Outcome.Proceed then
    begin
      WriteLn('copy: cancelled by the page, ', Length(Outcome.Data), ' bytes of its own');
      WriteLn(Outcome.Data);
      Exit;
    end;
    Copied := FSelection.SelectedText;
    WriteLn('copy: ', Length(Copied), ' bytes');
    WriteLn(Copied);
  end;
end;

function TBrowseSession.Run: Integer;
var
  Began, Took, Deadline, Wait, Next: Double;
  Evaluated, Resized: Boolean;
begin
  Result := 0;
  if not FPage.NavigateTo(FOptions.Url) then
  begin
    WriteLn(StdErr, 'webbrowse: not a URL: ', FOptions.Url);
    Exit(1);
  end;
  Deadline := FOptions.TimeoutSeconds * 1000;
  Evaluated := FOptions.EvalSource = '';
  FStepReadyAt := 0;
  Resized := FOptions.ResizeWidth <= 0;
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
    if (FTyping <> '') and (Clock >= FNextKeyAt) then
      TypeNextCharacter;
    if Evaluated and (FStepIndex < Length(FOptions.Steps)) and not StepsBusy and Loaded and
      (Clock - FStepReadyAt >= FOptions.StepPatienceMilliseconds) then
    begin
      { Not quiet for this long: the next step goes on anyway. }
      RunStep(FOptions.Steps[FStepIndex]);
      Inc(FStepIndex);
      FStepReadyAt := Clock;
      FQuietSince := -1;
    end;
    if Quiet and not StepsBusy then
    begin
      if FQuietSince < 0 then
        FQuietSince := Clock;
      if Clock - FQuietSince >= FOptions.QuietMilliseconds then
      begin
        if not Resized then
        begin
          { The window resized once the page settled (as a user would). }
          Resized := True;
          if FOptions.Verbose then
            WriteLn(StdErr, Format('%8.0f resize to %.0fx%.0f', [Clock, FOptions.ResizeWidth, FOptions.ResizeHeight]));
          FOptions.Width := FOptions.ResizeWidth;
          FOptions.Height := FOptions.ResizeHeight;
          FSink.SetViewport(FOptions.Width, FOptions.Height, FOptions.Scale);
          FreeSurface(FFrameSurface);
          FFrameSurface := Default(TSurface);
          if FLayout <> nil then
            FLayout.SetViewport(FOptions.Width, FOptions.Height, FOptions.Scale);
          FQuietSince := -1;
          Continue;
        end;
        if Evaluated and (FStepIndex >= Length(FOptions.Steps)) then
          Break;
        if not Evaluated then
        begin
          RunEval;
          Evaluated := True;
        end
        else
        begin
          RunStep(FOptions.Steps[FStepIndex]);
          Inc(FStepIndex);
        end;
        FStepReadyAt := Clock;
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
      WriteLn(StdErr, Format('webbrowse: timed out after %.0f s (state %d, %d fetches active, %d url() images pending, ' +
        'a task ready: %s, layout due: %s)', [FOptions.TimeoutSeconds, Ord(FPage.Navigable.State),
        FPage.Fetcher.ActiveJobCount, FSink.PendingStyleImageCount, BoolToStr(FPage.Loop.HasReadyTask, 'yes', 'no'),
        BoolToStr((FLayout <> nil) and FLayout.NeedsUpdate, 'yes', 'no')]));
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
  SweepHover;
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
begin
  if FOptions.PngFile <> '' then
    SavePng(FOptions.PngFile);
end;

procedure TBrowseSession.SavePng(const FileName: string);
var
  Painter: TDocumentPainter;
  Surface: TSurface;
  Width, Height: LongInt;
  Image: TImage;
  Began: Double;
begin
  if (FileName = '') or (FLayout = nil) then
    Exit;
  Began := Clock;
  if FOptions.WholePage and (FLayout.DocumentHeight > FLayout.ViewportHeight) then
  begin
    FLayout.SetViewport(FLayout.ViewportWidth, Min(Ceil(FLayout.DocumentHeight), 30000), FLayout.Scale);
    FLayout.Update;
  end
  else if FOptions.ScrollY > 0 then
    FLayout.SetScrollOffset(nil, 0, FOptions.ScrollY);
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
      SaveImage(Image, FileName, ImageFormatPng);
    finally
      Image.Free;
    end;
  finally
    Painter.Free;
  end;
end;

{ The system's font configuration beside the font directory
  (userland/etc/fonts.conf for userland/fonts), so Arial and Helvetica
  are Liberation Sans as in the system, not the built-in DejaVu Sans. }
procedure UseSystemFontConfiguration(const FontDirectory: string);
var
  Path: string;
begin
  Path := ExtractFilePath(ExcludeTrailingPathDelimiter(ExpandFileName(FontDirectory))) + 'etc' + PathDelim +
    'fonts.conf';
  if not FileExists(Path) then
    Exit;
  FontConfigurationPath := Path;
  ResetSystemFontConfiguration;
end;

function RunBrowse(const Options: TBrowseOptions): Integer;
var
  Session: TBrowseSession;
begin
  if Options.FontDirectory <> '' then
  begin
    UseSystemFontConfiguration(Options.FontDirectory);
    WebFontDirectory := Options.FontDirectory;
    ResetWebFontLibrary;
  end;
  StartProfiling(@MonotonicMicroseconds);
  PrepareSampling;
  StartWatchdog(Options.StallSeconds, Max(60, Round(Options.TimeoutSeconds) + 60));
  Session := TBrowseSession.Create(Options);
  try
    if Options.Profile then
      StartProfiler(1000);
    Result := Session.Run;
    if Options.Profile then
      StopProfiler(40);
  finally
    StopWatchdog;
    Session.Free;
  end;
end;

initialization
  RegisterStandardImageCodecs;
end.
