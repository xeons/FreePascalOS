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
  Typing into a hostile page (a fuzz test of the editing path): the page
  (editing-fuzz.html) is loaded through a navigable with page scripting
  and laid out like the web view does it; then thousands of random key
  presses, edits and clicks are given to it the way the web view gives
  them (keydown, keypress, the text field's editing in
  WebView.FieldEditing, keyup; mousedown, focus, mouseup, click), while
  its listeners replace, remove, move, hide and retype the very fields
  being edited, rebuild forms and move the focus during the events. After
  each step the page's tasks, microtasks and frames run, and often the
  layout is brought up to date, painted, hit tested and the focused
  field's box and selection read as the caret painter does; the script
  collector and the DOM collector run now and then. The test passes when
  all of it survives with consistent state: every text field's selection
  within its value, the document whole, no uncaught script errors.
}
unit WebLoadTest.Editing;

{$mode objfpc}
{$H+}

interface

procedure RunEditingTests;

implementation

uses
  Classes,
  SysUtils,
  Math,
  TestChecks,
  Drawing.Colors,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Js.Values,
  Web.Dom,
  Web.Dom.Focus,
  Web.Dom.FormControls,
  Web.Loading.LayoutSink,
  Web.Layout.Boxes,
  Web.Layout.Document,
  Web.Layout.Resources,
  Web.Paint.Painter,
  Web.Navigation.Pages,
  Web.Navigation.Navigables,
  Web.Navigation.Windows,
  Web.Script.Context,
  Web.Script.Layout,
  Web.Script.PageScripting,
  WebView.TextEditing,
  WebBrowse.Input,
  WebLoadTest.Server;

const
  PageUrl = 'https://e.test/page.html';
  StepCount = 2500;
  { Keys by their KeyboardEvent code, with modifiers. }
  NamedKeys: array[0..19] of string = ('Backspace', 'Delete', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
    'Home', 'End', 'Enter', 'Tab', 'shift+ArrowLeft', 'shift+End', 'ctrl+Backspace', 'ctrl+Delete', 'ctrl+KeyA',
    'ctrl+KeyC', 'ctrl+KeyX', 'ctrl+KeyV', 'shift+Tab', 'ctrl+ArrowRight');
  Typed: string = 'abcxyz 019.-é';

type
  TEditingRun = class
  public
    Page: TWebPage;
    Console: TStringList;
    Sink: TLayoutResourceSink;
    ScriptLayout: TDocumentScriptLayout;
    Layout: TDocumentLayout;
    Painter: TDocumentPainter;
    LaidOut: TDocument;
    procedure ConsoleMessage(const Level, Text: string);
    function Loaded: Boolean;
    { The layout goes before its document (as the web view's does). }
    procedure DropLayout;
  end;

  TEditingObserver = class(TNavigableObserver)
  public
    Run: TEditingRun;
    procedure DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow); override;
  end;

procedure TEditingRun.DropLayout;
begin
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

procedure TEditingObserver.DocumentChanged(Navigable: TNavigable; Document: TDocument; Window: TWebWindow);
begin
  if Document <> Run.LaidOut then
    Run.DropLayout;
end;

procedure TEditingRun.ConsoleMessage(const Level, Text: string);
begin
  Console.Add(Level + ': ' + Text);
end;

function TEditingRun.Loaded: Boolean;
begin
  Result := (Page.Navigable.ActiveDocument <> nil) and (Page.Navigable.ActiveDocument.Url = PageUrl) and
    (Page.Navigable.Loader <> nil) and Page.Navigable.Loader.LoadFired;
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

{ The page's text fields in tree order. }
function TextFields(Document: TDocument): TNodeArray;
var
  Node: TNode;
begin
  Result := nil;
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement and IsTextControl(TElement(Node)) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Node;
    end;
    Node := Node.NextInTree(Document);
  end;
end;

{ Any element of the page (fields more often). }
function RandomElement(Document: TDocument): TElement;
var
  Node: TNode;
  Count, Wanted: Integer;
begin
  Result := Document.Body;
  Count := 0;
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
      Inc(Count);
    Node := Node.NextInTree(Document);
  end;
  if Count = 0 then
    Exit;
  Wanted := Random(Count);
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      if Wanted = 0 then
        Exit(TElement(Node));
      Dec(Wanted);
    end;
    Node := Node.NextInTree(Document);
  end;
end;

{ What the web view's caret painter reads of the focused field: its box,
  the box's style and font, its value and selection. }
procedure ReadCaret(Layout: TDocumentLayout; Document: TDocument);
var
  Focused: TElement;
  Box: TLayoutBox;
  X, Y: Single;
  Start, Finish: Integer;
  Direction, Value, Before: string;
begin
  Focused := Document.FocusedElement;
  if (Focused = nil) or not IsTextControl(Focused) then
    Exit;
  Box := Layout.BoxOf(Focused);
  if Box <> nil then
  begin
    Box.AbsolutePosition(X, Y);
    if Box.Style = nil then
      Check(False, 'editing: the focused field''s box has a style');
  end;
  Value := TextControlValue(Focused);
  GetTextSelection(Focused, Start, Finish, Direction);
  Before := Copy(Value, 1, ByteIndexOfUtf16(Value, Finish) - 1);
  if Length(Before) > Length(Value) then
    Check(False, 'editing: the text before the caret is part of the value');
end;

{ Every text field's selection lies within its value. }
function SelectionsConsistent(Document: TDocument; out Problem: string): Boolean;
var
  Fields: TNodeArray;
  Index, Start, Finish, Length_: Integer;
  Direction: string;
begin
  Result := True;
  Problem := '';
  Fields := TextFields(Document);
  for Index := 0 to High(Fields) do
  begin
    GetTextSelection(TElement(Fields[Index]), Start, Finish, Direction);
    Length_ := Utf16CountOf(TextControlValue(TElement(Fields[Index])));
    if (Start < 0) or (Finish < Start) or (Finish > Length_) then
    begin
      Problem := Format('%s: %d..%d of %d', [TElement(Fields[Index]).LocalName, Start, Finish, Length_]);
      Exit(False);
    end;
  end;
end;

procedure TypeIntoHostilePage;
var
  Environment: TTestEnvironment;
  Run: TEditingRun;
  Observer: TEditingObserver;
  Executor: TPageScriptExecutor;
  Input: TPageInput;
  Document: TDocument;
  Surface: TSurface;
  Context: TScriptContext;
  Fields: TNodeArray;
  Step, Choice, Uncaught, Index: Integer;
  Problem: string;
  Consistent, Verbose: Boolean;
begin
  { WEB_EDITING_VERBOSE: a line per step (to find where a run goes wrong). }
  Verbose := GetEnvironmentVariable('WEB_EDITING_VERBOSE') <> '';
  RandSeed := 20261120;
  Environment := TTestEnvironment.Create;
  Run := TEditingRun.Create;
  Run.Console := TStringList.Create;
  Run.Sink := TLayoutResourceSink.Create;
  Run.Page := TWebPage.Create(Environment.Network, Run.Sink, nil);
  Run.Sink.AttachNavigable(Run.Page.Navigable);
  Run.Sink.SetViewport(400, 300, 1);
  Executor := TPageScriptExecutor.Create(Run.Page.Navigable);
  Executor.OnConsoleMessage := @Run.ConsoleMessage;
  Run.ScriptLayout := TDocumentScriptLayout.Create;
  Executor.Environment.Layout := Run.ScriptLayout;
  Run.Page.Navigable.Executor := Executor;
  Observer := TEditingObserver.Create;
  Observer.Run := Run;
  Run.Page.Navigable.ObserverObject := Observer;
  Input := TPageInput.Create(Run.Page.Navigable);
  Surface := Default(TSurface);
  Consistent := True;
  try
    Environment.Site.AddRoute('e.test/page.html', 200, 'Content-Type: text/html; charset=utf-8',
      ReadTextFile('tools/WebLoadTest/editing-fuzz.html'));
    Run.Page.Navigable.NavigateTo(PageUrl);
    Check(Run.Page.Run(@Run.Loaded, 10000), 'editing: the hostile page loads');
    Document := Run.Page.Navigable.ActiveDocument;
    if (Document = nil) or (Document.Url <> PageUrl) then
      Exit;
    Run.Sink.PrepareDocument(Document);
    Run.LaidOut := Document;
    Run.Layout := TDocumentLayout.Create(Document);
    Run.Layout.SetViewport(400, 300, 1);
    Run.Painter := TDocumentPainter.Create(Run.Layout);
    Run.ScriptLayout.Layout := Run.Layout;
    Run.ScriptLayout.Painter := Run.Painter;
    CreateSurface(Surface, 400, 300, ColorWhite);
    Context := Executor.ContextOf(Document);
    Check(Context <> nil, 'editing: the page has a script context');
    if Context = nil then
      Exit;
    Check((Document.FocusedElement <> nil) and (Document.FocusedElement.GetAttribute('id') = 'a'),
      'editing: the page focused its first field');
    for Step := 1 to StepCount do
    begin
      { Every submission is cancelled or of a form out of the document:
        the page never goes. }
      if Run.Page.Navigable.ActiveDocument <> Document then
      begin
        Check(False, 'editing: the page stays (it went at step ' + IntToStr(Step) + ' to ' +
          Run.Page.Navigable.ActiveDocument.Url + ')' + LineEnding + Copy(Run.Console.Text,
          Max(1, Length(Run.Console.Text) - 3000), 3000));
        Exit;
      end;
      Choice := Random(100);
      if Verbose then
      begin
        WriteLn(Format('step %d choice %d fields %d nodes %d listed %d in tree %s', [Step, Choice,
          Length(TextFields(Document)), LiveNodeCount, ListedNodeCount,
          Context.Engine.ToText(Context.Engine.Evaluate('document.getElementsByTagName("*").length + "/" + ' +
          'document.body.textContent.length + "/" + counts.mutations'))]));
        Flush(Output);
      end;
      if Choice < 45 then
        Input.TypeCharacter(Document, Ord(Typed[1 + Random(Length(Typed))]))
      else if Choice < 75 then
        Input.PressNamedKey(Document, NamedKeys[Random(Length(NamedKeys))])
      else if Choice < 85 then
        Input.Click(RandomElement(Document))
      else
      begin
        Fields := TextFields(Document);
        if Length(Fields) > 0 then
          FocusElement(TElement(Fields[Random(Length(Fields))]));
      end;
      Run.Page.Loop.RunPendingTasks;
      if Run.Layout = nil then
        Continue;
      if Step mod 3 = 0 then
      begin
        Run.Page.RenderingOpportunity;
        if Run.Layout = nil then
          Continue;
        Run.Layout.Update;
        ReadCaret(Run.Layout, Document);
        Run.Painter.HitTest(Random(400), Random(300));
      end;
      if Step mod 25 = 0 then
        Run.Painter.Paint(Surface, MakeRectangle(0, 0, 400, 300));
      if Step mod 200 = 0 then
      begin
        Context.Engine.CollectGarbage;
        Web.Dom.CollectGarbage;
      end;
      if Consistent and not SelectionsConsistent(Document, Problem) then
      begin
        Consistent := False;
        Check(False, 'editing: a selection outside its value at step ' + IntToStr(Step) + ' (' + Problem + ')');
      end;
    end;
    Check(Consistent, 'editing: every field''s selection stays within its value');
    Check((Document.DocumentElement <> nil) and (Document.Body <> nil), 'editing: the document is whole');
    Check((Document.FocusedElement = nil) or Document.FocusedElement.IsConnected,
      'editing: the focused element is in the document');
    Uncaught := 0;
    for Index := 0 to Run.Console.Count - 1 do
      if Pos('Uncaught', Run.Console[Index]) > 0 then
        Inc(Uncaught);
    Check(Uncaught = 0, 'editing: no uncaught script errors (' + IntToStr(Uncaught) + ')' + LineEnding +
      Copy(Run.Console.Text, 1, 2000));
    Check(Context.Engine.Evaluate('counts.input > 200 && counts.keydown > 1000 && counts.mutations > 100') =
      JsTrue, 'editing: the page saw input, keys and mutations (' +
      Context.Engine.ToText(Context.Engine.Evaluate('JSON.stringify(counts)')) + ')');
    WriteLn(Format('perf editing fuzz: %d steps, %d fields at the end', [StepCount, Length(TextFields(Document))]));
  finally
    FreeSurface(Surface);
    Run.DropLayout;
    Input.Free;
    Run.Page.Navigable.ObserverObject := nil;
    Observer.Free;
    Executor.Shutdown;
    Run.Page.Free;
    Executor.Free;
    Run.ScriptLayout.Free;
    Run.Sink.Free;
    Run.Console.Free;
    Run.Free;
    Environment.Free;
  end;
end;

procedure RunEditingTests;
begin
  TypeIntoHostilePage;
end;

end.
