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
  The pointer over a hostile page (a fuzz test of the web view's pointer
  path): the page (pointer-fuzz.html: long generated text, sticky and
  fixed boxes, floats, transforms, animations, an inner scroll
  container, a frame) is loaded through a navigable with page scripting
  and laid out as the web view does it; then thousands of random pointer
  moves, presses, drags (past the viewport's edges too), releases,
  double and triple clicks, wheel steps (during drags too), resizes,
  copies and select-alls are given to it the way TWebView gives them:
  the hover's chain and pointer shape read from the hit before the
  page's events, the hit's element held while its events are
  dispatched, the selection kept by WebView.PageSelection (the web
  view's own) and its places looked up again after every event
  (WebBrowse.Pointer). The
  page's listeners lay the page out inside the events, remove, split,
  merge and hide the text under the pointer and in the selection, set
  the selection (also out of the document) and scroll. Between steps
  the page's tasks and frames run, the layout is brought up to date or
  left behind (a slow layout waits in the web view), and it is painted
  and hit tested; the script collector and the DOM collector run now
  and then. It runs once as it is and once with the script engines
  collecting every 16 KiB (JS_GC_STRESS's setting). It passes when all
  of it survives with consistent state: the document's selection inside
  the document, the view's selection inside the current index, its text
  and rectangles readable, no uncaught script errors.
}
unit WebLoadTest.Pointer;

{$mode objfpc}
{$H+}

interface

procedure RunPointerTests;

implementation

uses
  Classes,
  SysUtils,
  Math,
  TestChecks,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Css.ElementAdapter,
  Css.PropertyIds,
  Css.Keywords,
  Js.Values,
  Web.Dom,
  Web.Loading.LayoutSink,
  Web.Layout.Boxes,
  Web.Layout.Document,
  Web.Layout.Resources,
  Web.Paint.Painter,
  Web.Navigation.Pages,
  Web.Navigation.Navigables,
  Web.Navigation.Windows,
  Web.Bindings.Context,
  Web.Script.Context,
  Web.Script.Layout,
  Web.Script.PageScripting,
  WebView.MouseEvents,
  WebView.TextGroups,
  WebView.TextIndex,
  WebView.PageSelection,
  WebBrowse.Pointer,
  WebLoadTest.Server;

const
  PageUrl = 'https://e.test/pointer.html';

type
  TPointerRun = class
  public
    Page: TWebPage;
    Console: TStringList;
    Sink: TLayoutResourceSink;
    ScriptLayout: TDocumentScriptLayout;
    Layout: TDocumentLayout;
    Painter: TDocumentPainter;
    Selection: TPageSelection;
    Driver: TPagePointer;
    LaidOut: TDocument;
    Width, Height: Single;
    procedure ConsoleMessage(const Level, Text: string);
    function Loaded: Boolean;
    procedure DropLayout;
    { The layout brought up to date, or (a slow layout in the web view)
      left as it is unless Force. }
    procedure MaybeLayOut(Force: Boolean);
    { Asked by the pointer before it reads the layout. }
    procedure PointerLayOut(Force: Boolean);
    function View: TTextViewport;
  end;

  TPointerObserver = class(TNavigableObserver)
  public
    Run: TPointerRun;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
  end;

  { The document's selection change reaches the view's selection. }
  TPointerDocumentObserver = class(TDocumentObserver)
  public
    Run: TPointerRun;
    procedure SelectionChanged(Document: TDocument); override;
  end;

procedure TPointerDocumentObserver.SelectionChanged(Document: TDocument);
begin
  if Run.Selection <> nil then
    Run.Selection.DocumentSelectionChanged;
end;

{ TPointerRun }

procedure TPointerRun.DropLayout;
begin
  if Driver <> nil then
    Driver.Attach(nil, nil, nil, nil);
  if Selection <> nil then
    Selection.Attach(nil, nil, nil);
  ScriptLayout.Layout := nil;
  ScriptLayout.Painter := nil;
  FreeAndNil(Painter);
  FreeAndNil(Layout);
  if LaidOut <> nil then
  begin
    Sink.DocumentGoing(LaidOut);
    FreeDocumentResources(LaidOut);
  end;
  LaidOut := nil;
end;

procedure TPointerObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
  if Document <> Run.LaidOut then
    Run.DropLayout;
end;

procedure TPointerRun.ConsoleMessage(const Level, Text: string);
begin
  Console.Add(Level + ': ' + Text);
end;

function TPointerRun.Loaded: Boolean;
begin
  Result := (Page.Navigable.ActiveDocument <> nil) and (Page.Navigable.ActiveDocument.Url = PageUrl) and
    (Page.Navigable.Loader <> nil) and Page.Navigable.Loader.LoadFired;
end;

procedure TPointerRun.MaybeLayOut(Force: Boolean);
begin
  if (Layout <> nil) and Layout.NeedsUpdate and (Force or (Random(3) > 0)) then
    Layout.Update;
end;

procedure TPointerRun.PointerLayOut(Force: Boolean);
begin
  MaybeLayOut(Force);
end;

function TPointerRun.View: TTextViewport;
begin
  Result := ViewportOfLayout(Layout);
end;

function ReadTextFile(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

{ The document's selection lies in the document; the view's in the
  index it was taken from. }
function SelectionsConsistent(Run: TPointerRun; Document: TDocument; out Problem: string): Boolean;
var
  Range: TLiveRange;
  Selection: TPageSelection;
begin
  Result := True;
  Problem := '';
  Range := Document.Selection.Range;
  if Range <> nil then
  begin
    if Range.Root <> Document then
      Problem := 'the document''s selection is out of the document'
    else if (Range.StartOffset > NodeLength(Range.StartContainer)) or
      (Range.EndOffset > NodeLength(Range.EndContainer)) then
      Problem := 'the document''s selection is past its nodes';
  end;
  Selection := Run.Selection;
  if (Problem = '') and Selection.HasSelection then
  begin
    if not Selection.IndexCurrent then
      Problem := 'the view''s selection is read from an old index'
    else if (Selection.Anchor.Run >= Selection.Index.Count) or (Selection.Focus.Run >= Selection.Index.Count) then
      Problem := 'the view''s selection is past the index';
  end;
  Result := Problem = '';
end;

{ A burst of fast wheel input, as a spun wheel or a flicked touchpad
  gives it: many steps both ways with the pointer moving over the page
  (hovering what scrolls under it), the layout left behind as a busy web
  view leaves it, the page's tasks, frames and animations run in
  between, and now and then a resize in the middle. }
procedure WheelBurst(Run: TPointerRun);
var
  Index, Count: Integer;
begin
  Count := 10 + Random(50);
  Index := 0;
  while (Index < Count) and (Run.Layout <> nil) do
  begin
    if Random(3) = 0 then
      Run.Driver.MoveTo(Random(Round(Run.Width)), Random(Round(Run.Height)));
    if Run.Layout = nil then
      Break;
    if Random(5) = 0 then
      Run.Driver.Wheel(-(Random(1200)))
    else
      Run.Driver.Wheel(60 + Random(1200));
    if Run.Layout = nil then
      Break;
    case Random(8) of
      0: Run.Page.Loop.RunPendingTasks;
      1: Run.Page.RenderingOpportunity;
      2: if Run.Layout.AnimationsRunning then
           Run.Layout.AdvanceAnimations;
      3: Run.MaybeLayOut(False);
      4: Run.Painter.HitTest(Random(Round(Run.Width)), Random(Round(Run.Height)));
      5: if Random(6) = 0 then
         begin
           Run.Width := 200 + Random(500);
           Run.Height := 150 + Random(350);
           Run.Layout.SetViewport(Run.Width, Run.Height, 1);
           Run.Sink.SetViewport(Run.Width, Run.Height, 1);
           Run.Driver.ViewportHeight := Run.Height;
         end;
    end;
    Inc(Index);
  end;
end;

procedure FuzzPointer(const Name: string; StepCount: Integer; StressCollector, WheelStorm: Boolean);
var
  Environment: TTestEnvironment;
  Run: TPointerRun;
  Observer: TPointerObserver;
  DocumentObserver: TPointerDocumentObserver;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Surface: TSurface;
  Context: TScriptContext;
  Step, Choice, Uncaught, Index, ClickCount, Copies: Integer;
  Problem, Copied: string;
  Consistent, Verbose: Boolean;
  SavedThreshold: Int64;
  Rectangles: TTextRectangleArray;
begin
  Verbose := GetEnvironmentVariable('WEB_POINTER_VERBOSE') <> '';
  RandSeed := 20261121;
  SavedThreshold := ContextHeapThreshold;
  if StressCollector then
    ContextHeapThreshold := 16 * 1024;
  Environment := TTestEnvironment.Create;
  Run := TPointerRun.Create;
  Run.Console := TStringList.Create;
  Run.Sink := TLayoutResourceSink.Create;
  Run.Width := 480;
  Run.Height := 320;
  Run.Page := TWebPage.Create(Environment.Network, Run.Sink, nil);
  Run.Sink.AttachNavigable(Run.Page.Navigable);
  Run.Sink.SetViewport(Run.Width, Run.Height, 1);
  Executor := TPageScriptExecutor.Create(Run.Page.Navigable);
  Executor.OnConsoleMessage := @Run.ConsoleMessage;
  Run.ScriptLayout := TDocumentScriptLayout.Create;
  Executor.Environment.Layout := Run.ScriptLayout;
  Run.Page.Navigable.Executor := Executor;
  Observer := TPointerObserver.Create;
  Observer.Run := Run;
  Run.Page.Navigable.ObserverObject := Observer;
  Run.Selection := TPageSelection.Create;
  Run.Driver := TPagePointer.Create;
  Run.Driver.OnLayOut := @Run.PointerLayOut;
  DocumentObserver := TPointerDocumentObserver.Create;
  DocumentObserver.Run := Run;
  Surface := Default(TSurface);
  Document := nil;
  Consistent := True;
  Copies := 0;
  try
    Environment.Site.AddRoute('e.test/pointer.html', 200, 'Content-Type: text/html; charset=utf-8',
      ReadTextFile('tools/WebLoadTest/pointer-fuzz.html'));
    Run.Page.Navigable.NavigateTo(PageUrl);
    Check(Run.Page.Run(@Run.Loaded, 10000), Name + ': the hostile page loads');
    Document := Run.Page.Navigable.ActiveDocument;
    if (Document = nil) or (Document.Url <> PageUrl) then
      Exit;
    Run.Sink.PrepareDocument(Document);
    Run.LaidOut := Document;
    Run.Layout := TDocumentLayout.Create(Document);
    Run.Layout.SetViewport(Run.Width, Run.Height, 1);
    Run.Painter := TDocumentPainter.Create(Run.Layout);
    Run.ScriptLayout.Layout := Run.Layout;
    Run.ScriptLayout.Painter := Run.Painter;
    Run.Selection.Attach(Document, Run.Layout, Run.Painter);
    Run.Driver.Attach(Document, Run.Layout, Run.Painter, Run.Selection);
    Run.Driver.ViewportHeight := Run.Height;
    Document.AddObserver(DocumentObserver);
    Run.Layout.Update;
    CreateSurface(Surface, Round(Run.Width), Round(Run.Height), ColorWhite);
    Context := Executor.ContextOf(Document);
    Check(Context <> nil, Name + ': the page has a script context');
    if Context = nil then
      Exit;
    for Step := 1 to StepCount do
    begin
      if (Run.Layout = nil) or (Run.Page.Navigable.ActiveDocument <> Document) then
      begin
        Check(False, Name + ': the page stays (it went at step ' + IntToStr(Step) + ')');
        Exit;
      end;
      Choice := Random(100);
      if WheelStorm and (Choice < 60) then
        Choice := 1000;
      if Verbose then
      begin
        WriteLn(Format('step %d choice %d nodes %d boxes %d runs %d', [Step, Choice, LiveNodeCount, LiveBoxCount,
          Run.Selection.Index.Count]));
        Flush(Output);
      end;
      if Choice = 1000 then
        WheelBurst(Run)
      else if Choice < 28 then
        Run.Driver.MoveTo(Random(Round(Run.Width)), Random(Round(Run.Height)))
      else if Choice < 40 then
      begin
        { A press, a drag of a few moves (past the edges sometimes, the
          wheel turned in the middle sometimes) and the release. }
        Run.Driver.Press(Random(Round(Run.Width)), Random(Round(Run.Height)), 1);
        for Index := 1 to 1 + Random(6) do
        begin
          Run.Driver.MoveTo(Random(Round(Run.Width)), Random(Round(Run.Height) + 120) - 60);
          if Random(4) = 0 then
            Run.Driver.Wheel(Random(300) - 150);
          if Random(3) = 0 then
            Run.Page.Loop.RunPendingTasks;
          if Random(3) = 0 then
            Run.Driver.Frame;
          if Run.Layout = nil then
            Break;
        end;
        if Run.Layout <> nil then
          Run.Driver.Release(Random(Round(Run.Width)), Random(Round(Run.Height)), 1);
      end
      else if Choice < 50 then
      begin
        { A double or triple click. }
        ClickCount := 2 + Random(2);
        Index := 1;
        while (Index <= ClickCount) and (Run.Layout <> nil) do
        begin
          Run.Driver.Press(100 + Random(200), 50 + Random(200), Index);
          if Run.Layout <> nil then
            Run.Driver.Release(100 + Random(200), 50 + Random(200), Index);
          Inc(Index);
        end;
      end
      else if Choice < 62 then
        Run.Driver.Wheel(Random(600) - 250)
      else if Choice < 66 then
      begin
        Run.Width := 200 + Random(500);
        Run.Height := 150 + Random(350);
        Run.Layout.SetViewport(Run.Width, Run.Height, 1);
        Run.Sink.SetViewport(Run.Width, Run.Height, 1);
        Run.Driver.ViewportHeight := Run.Height;
      end
      else if Choice < 74 then
      begin
        { Copying: the selected text, as Ctrl+C reads it. }
        Run.MaybeLayOut(False);
        Run.Selection.Refresh;
        Copied := Run.Selection.SelectedText;
        if Copied <> '' then
          Inc(Copies);
      end
      else if Choice < 77 then
      begin
        Run.MaybeLayOut(False);
        Run.Selection.SelectAll;
      end
      else if Choice < 79 then
        Run.Selection.Clear
      else
        Run.Page.Loop.RunPendingTasks;
      if Run.Layout = nil then
        Continue;
      Run.Page.Loop.RunPendingTasks;
      if Run.Layout = nil then
        Continue;
      if Step mod 3 = 0 then
      begin
        Run.Page.RenderingOpportunity;
        if Run.Layout = nil then
          Continue;
        if Run.Layout.AnimationsRunning then
          Run.Layout.AdvanceAnimations;
        Run.MaybeLayOut(Step mod 6 = 0);
        Run.Driver.Frame;
        Run.Painter.HitTest(Random(Round(Run.Width)), Random(Round(Run.Height)));
        { What painting the selection reads. }
        Run.Selection.Refresh;
        Rectangles := Run.Selection.Rectangles(Run.View);
        if Length(Rectangles) > Run.Selection.Index.Count then
          Check(False, Name + ': a rectangle per selected run at most');
      end;
      if Step mod 25 = 0 then
      begin
        Run.Painter.Paint(Surface, MakeRectangle(0, 0, Surface.Width, Surface.Height));
      end;
      if Step mod 150 = 0 then
      begin
        Context.Engine.CollectGarbage;
        Web.Dom.CollectGarbage;
      end;
      if Consistent and not SelectionsConsistent(Run, Document, Problem) then
      begin
        Consistent := False;
        Check(False, Name + ': ' + Problem + ' at step ' + IntToStr(Step));
      end;
    end;
    Check(Consistent, Name + ': the selections stay consistent');
    Check((Document.DocumentElement <> nil) and (Document.Body <> nil), Name + ': the document is whole');
    Uncaught := 0;
    for Index := 0 to Run.Console.Count - 1 do
      if Pos('Uncaught', Run.Console[Index]) > 0 then
        Inc(Uncaught);
    Check(Uncaught = 0, Name + ': no uncaught script errors (' + IntToStr(Uncaught) + ')' + LineEnding +
      Copy(Run.Console.Text, 1, 2000));
    Check(Context.Engine.Evaluate('counts.events > 1000 && counts.upsets > 300 && counts.layouts > 30') = JsTrue,
      Name + ': the page saw the events and upset itself (' +
      Context.Engine.ToText(Context.Engine.Evaluate('JSON.stringify(counts) + " last exception: " + lastException')) + ')');
    Check(Copies > 10, Name + ': text was selected and copied (' + IntToStr(Copies) + ' times)');
    WriteLn(Format('perf %s: %d steps, %d copies, %d cursor shapes, %d runs at the end',
      [Name, StepCount, Copies, Run.Driver.Shapes, Run.Selection.Index.Count]));
  finally
    FreeSurface(Surface);
    if (Document <> nil) and (Run.LaidOut = Document) then
      Document.RemoveObserver(DocumentObserver);
    Run.DropLayout;
    Run.Driver.Free;
    Run.Selection.Free;
    Run.Page.Navigable.ObserverObject := nil;
    Observer.Free;
    Executor.Shutdown;
    Run.Page.Free;
    Executor.Free;
    Run.ScriptLayout.Free;
    Run.Sink.Free;
    Run.Console.Free;
    Run.Free;
    DocumentObserver.Free;
    Environment.Free;
    ContextHeapThreshold := SavedThreshold;
  end;
end;

procedure RunPointerTests;
begin
  FuzzPointer('pointer fuzz', 3000, False, False);
  FuzzPointer('pointer fuzz (collector stress)', 600, True, False);
  FuzzPointer('pointer wheel storm', 2000, False, True);
end;

end.
