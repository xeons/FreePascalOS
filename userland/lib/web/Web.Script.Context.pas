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
  The script context of a window: the binding context with the
  interfaces installed, scripts run (HTML Standard 4.12.1 and 8.1),
  the parser's script host, and the calls the loader and the event loop
  make.

    Context := TScriptContext.Create(Document, Environment);
    Context.ParseDocument(Html);            // a whole page: scripts run
    Context.ExecuteClassicScript(Source, Url, nil);
    Context.Free;                           // before the document goes

  For a page loaded in pieces the loader makes the parser itself and
  calls BeginParsing(Parser), feeds it, then FinishParsing (readyState
  "interactive", DOMContentLoaded) and DocumentLoaded (readyState
  "complete", the window's load event) once deferred scripts and
  sub-resources are done.

  Script elements: the parser's script end tag and every script element
  that becomes connected (or gets its text while connected) go through
  PrepareScript, the standard's "prepare the script element": inline
  classic scripts run at once; external ones go to the environment's
  FetchClassicScript with their mode (parser-blocking ones pause the
  parser, which the loader resumes after ExecuteClassicScript). Module
  scripts are not supported yet (libjavascript has no modules), so
  nomodule scripts run.
}
unit Web.Script.Context;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Events,
  Web.Dom,
  Web.Html.Parser,
  Web.Bindings.Context,
  Web.ScriptEnvironment;

type
  TScriptContext = class(TBindingContext)
  private
    FActiveParser: THtmlParser;
    { The script-created parser document.open made (owned until
      document.close or the context goes). }
    FOpenedParser: THtmlParser;
    FReadyState: string;
    FScriptCount: Integer;
    FObservedDocuments: array of TDocument;
    FPreparesScripts: Boolean;
    FReadyStateFromDocument: Boolean;
    procedure ObserveDocument(Target: TDocument);
    procedure WriteToOpenedParser(const Text: string; Finish: Boolean);
    procedure DropOpenedParser;
    procedure FireSimpleEvent(Target: TEventTarget; const EventType: string; Bubbles: Boolean);
    function ScriptSource(Script: TElement): string;
    procedure Setup;
  protected
    procedure NodeWrapped(Node: TNode); override;
  public
    constructor Create(ADocument: TDocument; AEnvironment: TScriptEnvironment = nil; AWindow: TEventTarget = nil);
    { An iframe's window (Web.Script.Frames makes them). }
    constructor CreateFrame(ADocument: TDocument; AEnvironment: TScriptEnvironment; Parent: TBindingContext;
      AFrameElement: TElement);
    destructor Destroy; override;

    { Runs a classic script (an inline one, or an external one the
      environment fetched): errors are reported to the console with the
      file and line, then the microtasks run. Element (may be nil) is
      document.currentScript meanwhile; an external script's element
      gets its load event. }
    procedure ExecuteClassicScript(const Source, Url: string; Element: TElement; FireLoad: Boolean = True);
    { An external script that could not be fetched: its error event. }
    procedure ScriptFetchFailed(Element: TElement);
    { The standard's "prepare the script element". True when the parser
      must wait for it (a parser-blocking external script). }
    function PrepareScript(Script: TElement; Parser: THtmlParser): Boolean;

    { Parsing with scripts. }
    procedure BeginParsing(Parser: THtmlParser);
    procedure FinishParsing;
    procedure DocumentLoaded;
    { Parses Html into the document (UTF-8 text), running its scripts,
      then finishes and loads it. For environments that run external
      scripts as they fetch them: a paused parser is resumed at once. }
    procedure ParseDocument(const Html: string);

    { The environment's timer is due. }
    procedure FireTimer(TimerId: Integer);

    procedure DocumentOpen(Target: TDocument); override;
    procedure DocumentWrite(Target: TDocument; const Text: string); override;
    procedure DocumentClose(Target: TDocument); override;
    function ReadyState(Target: TDocument): string; override;
    procedure InvokeEventHandler(EventType: TAtom; Event: TEvent); override;

    { The parser document.write writes to, when a loader parses (it is the
      parser's script host itself). }
    procedure AttachParser(Parser: THtmlParser);
    property ActiveParser: THtmlParser read FActiveParser;
    { False under a loader that prepares and runs script elements
      itself (Web.Loading.Scripts): the context then only runs what it
      is given. }
    property PreparesScripts: Boolean read FPreparesScripts write FPreparesScripts;
    { document.readyState is the document's own (a loader sets it). }
    property ReadyStateFromDocument: Boolean read FReadyStateFromDocument write FReadyStateFromDocument;
  end;

  { The parser's script host for a context. }
  TParserScriptHost = class(TScriptHost)
  private
    FContext: TScriptContext;
  public
    constructor Create(Context: TScriptContext);
    function ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean; override;
  end;

implementation

uses
  Web.Profiling,
  Js.Objects,
  Js.Engine,
  Web.Bindings.Install,
  Web.Bindings.EventHandlers,
  Web.Bindings.MutationObservers,
  Web.Bindings.UrlResolution,
  Web.Script.Timers,
  Web.Script.Prelude,
  Web.Script.Natives,
  Web.Script.Frames;

type
  { Forwards the document's changes to event handlers, script elements
    and mutation observers. }
  TScriptDocumentObserver = class(TDocumentObserver)
  private
    FContext: TScriptContext;
  public
    constructor Create(Context: TScriptContext);
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray;
      PreviousSibling, NextSibling: TNode); override;
    procedure ChildrenChanged(Parent: TNode); override;
    procedure NodeConnected(Node: TNode); override;
    procedure NodeDisconnected(Node: TNode); override;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); override;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); override;
  end;

{ TScriptDocumentObserver }

constructor TScriptDocumentObserver.Create(Context: TScriptContext);
begin
  inherited Create;
  FContext := Context;
end;

procedure TScriptDocumentObserver.TreeMutated(Target: TNode; const Added, Removed: TNodeArray;
  PreviousSibling, NextSibling: TNode);
begin
  if FContext.MutationObservers <> nil then
    TMutationObservers(FContext.MutationObservers).TreeMutated(Target, Added, Removed, PreviousSibling, NextSibling);
end;

function IsPendingScript(Node: TNode): Boolean;
begin
  Result := (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomScript) and
    ((TElement(Node).ElementState and (ElementStateParserInserted or ElementStateAlreadyStarted)) = 0);
end;

procedure TScriptDocumentObserver.ChildrenChanged(Parent: TNode);
begin
  { A script element that gets its text while connected runs then. }
  if IsPendingScript(Parent) and Parent.IsConnected then
    FContext.PrepareScript(TElement(Parent), nil);
end;

procedure TScriptDocumentObserver.NodeDisconnected(Node: TNode);
begin
  if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomIframe) then
    FrameElementDisconnected(FContext, TElement(Node));
end;

procedure TScriptDocumentObserver.NodeConnected(Node: TNode);
begin
  if Node.NodeType <> NodeTypeElement then
    Exit;
  if TElement(Node).IsHtmlElement(AtomIframe) and (Node.OwnerDocument = FContext.Document) then
    FrameElementConnected(FContext, TElement(Node));
  if TElement(Node).HasAttributes then
    ActivateEventHandlerAttributes(FContext, TElement(Node));
  if IsPendingScript(Node) then
    FContext.PrepareScript(TElement(Node), nil);
end;

procedure TScriptDocumentObserver.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
begin
  if (NamespaceId = NamespaceNone) and IsEventHandlerAttribute(NameOfAtom(LocalName)) then
    EventHandlerAttributeChanged(FContext, Element, LocalName);
  if FContext.MutationObservers <> nil then
    TMutationObservers(FContext.MutationObservers).AttributeChanged(Element, LocalName, NamespaceId, OldValue,
      HadValue);
end;

procedure TScriptDocumentObserver.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
begin
  if FContext.MutationObservers <> nil then
    TMutationObservers(FContext.MutationObservers).CharacterDataChanged(Node, OldValue);
end;

{ TScriptContext }

constructor TScriptContext.Create(ADocument: TDocument; AEnvironment: TScriptEnvironment; AWindow: TEventTarget);
begin
  inherited Create(ADocument, AEnvironment, AWindow);
  Setup;
end;

constructor TScriptContext.CreateFrame(ADocument: TDocument; AEnvironment: TScriptEnvironment;
  Parent: TBindingContext; AFrameElement: TElement);
begin
  inherited CreateFrame(ADocument, AEnvironment, Parent, AFrameElement);
  Setup;
end;

procedure TScriptContext.Setup;
var
  Global: TJsObject;
  Clone: TJsValue;
begin
  FPreparesScripts := True;
  FReadyState := 'complete';
  FDocumentObserver := TScriptDocumentObserver.Create(Self);
  InstallBindings(Self);
  InstallPlatform(Self);
  ObserveDocument(Document);
  Global := Engine.GlobalObject;
  if not Environment.SupportsTimers then
  begin
    Global.DeleteProperty(Engine.Realm, Engine.Realm.Intern('setTimeout'));
    Global.DeleteProperty(Engine.Realm, Engine.Realm.Intern('setInterval'));
    Global.DeleteProperty(Engine.Realm, Engine.Realm.Intern('clearTimeout'));
    Global.DeleteProperty(Engine.Realm, Engine.Realm.Intern('clearInterval'));
  end;
  Clone := Engine.Evaluate(StructuredCloneSource, 'prelude');
  SetSingleton(SingletonStructuredClone, Clone);
  { The document's wrapper is a root: every wrapper of its tree lives
    with it. }
  WrapNode(Document);
end;

destructor TScriptContext.Destroy;
var
  Index: Integer;
begin
  DropOpenedParser;
  for Index := 0 to High(FObservedDocuments) do
    if FObservedDocuments[Index] <> Document then
    begin
      FObservedDocuments[Index].RemoveObserver(FDocumentObserver);
      FObservedDocuments[Index].Release;
    end;
  inherited Destroy;
end;

procedure TScriptContext.ObserveDocument(Target: TDocument);
var
  Index: Integer;
begin
  for Index := 0 to High(FObservedDocuments) do
    if FObservedDocuments[Index] = Target then
      Exit;
  SetLength(FObservedDocuments, Length(FObservedDocuments) + 1);
  FObservedDocuments[High(FObservedDocuments)] := Target;
  Target.AddObserver(FDocumentObserver);
  { Other documents are kept while observed (the window's document is
    the context's anyway). }
  if Target <> Document then
    Target.Retain;
end;

procedure TScriptContext.NodeWrapped(Node: TNode);
begin
  if Node.NodeDocument <> Document then
    ObserveDocument(Node.NodeDocument);
end;

procedure TScriptContext.FireSimpleEvent(Target: TEventTarget; const EventType: string; Bubbles: Boolean);
var
  Event: TEvent;
begin
  Event := TEvent.Create(EventType, Bubbles, False);
  try
    Event.TimeStamp := Now;
    Event.IsTrusted := True;
    Target.DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

procedure TScriptContext.ExecuteClassicScript(const Source, Url: string; Element: TElement; FireLoad: Boolean);
var
  SavedScript: TElement;
  Name: string;
begin
  SavedScript := CurrentScript;
  CurrentScript := Element;
  Inc(FScriptCount);
  Name := Url;
  if Name = '' then
    Name := DocumentUrlText(Document);
  if (Element <> nil) and not Element.HasAttributeAtom(AtomSrc) then
    Name := Name + ' (inline script ' + IntToStr(FScriptCount) + ')';
  EnterScript;
  SetPhaseDetail(Name);
  try
    try
      Engine.Evaluate(Source, Name);
    except
      on Error: EJsError do
        if Copy(Error.StackText, 1, 9) = 'Uncaught ' then
          Console('error', Error.StackText)
        else
          Console('error', 'Uncaught ' + Error.StackText);
    end;
  finally
    CurrentScript := SavedScript;
    LeaveScript;
  end;
  if FireLoad and (Element <> nil) and Element.HasAttributeAtom(AtomSrc) then
    FireSimpleEvent(Element, 'load', False);
end;

procedure TScriptContext.AttachParser(Parser: THtmlParser);
begin
  FActiveParser := Parser;
end;

procedure TScriptContext.ScriptFetchFailed(Element: TElement);
begin
  FireSimpleEvent(Element, 'error', False);
end;

function TScriptContext.ScriptSource(Script: TElement): string;
var
  Child: TNode;
begin
  Result := '';
  Child := Script.FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = NodeTypeText then
      Result := Result + TCharacterData(Child).Data;
    Child := Child.NextSibling;
  end;
end;

function IsClassicScriptType(Script: TElement): Boolean;
const
  JavaScriptTypes: array[0..15] of string = ('application/ecmascript', 'application/javascript',
    'application/x-ecmascript', 'application/x-javascript', 'text/ecmascript', 'text/javascript',
    'text/javascript1.0', 'text/javascript1.1', 'text/javascript1.2', 'text/javascript1.3', 'text/javascript1.4',
    'text/javascript1.5', 'text/jscript', 'text/livescript', 'text/x-ecmascript', 'text/x-javascript');
var
  TypeText, Language: string;
  Index: Integer;
begin
  if Script.HasAttributeAtom(AtomType) then
    TypeText := Trim(AsciiLowerCase(Script.AttributeValueOf(AtomType)))
  else
    TypeText := '';
  if (TypeText = '') and Script.HasAttributeAtom(AtomType) then
    Exit(True);
  if not Script.HasAttributeAtom(AtomType) then
  begin
    Language := Script.AttributeValueOf(Atomize('language'));
    if Language = '' then
      Exit(True);
    TypeText := 'text/' + AsciiLowerCase(Language);
  end;
  for Index := 0 to High(JavaScriptTypes) do
    if JavaScriptTypes[Index] = TypeText then
      Exit(True);
  Result := False;
end;

function TScriptContext.PrepareScript(Script: TElement; Parser: THtmlParser): Boolean;
var
  State: Word;
  Source, Resolved: string;
  Mode: TScriptFetchMode;
  ParserInserted: Boolean;
begin
  Result := False;
  if not FPreparesScripts then
    Exit;
  State := Script.ElementState;
  if (State and ElementStateAlreadyStarted) <> 0 then
    Exit;
  ParserInserted := (State and ElementStateParserInserted) <> 0;
  if ParserInserted and (Parser = nil) then
    Exit;
  Source := ScriptSource(Script);
  if not Script.HasAttributeAtom(AtomSrc) and (Source = '') then
    Exit;
  if not Script.IsConnected then
    Exit;
  if not IsClassicScriptType(Script) then
  begin
    if AsciiLowerCase(Trim(Script.AttributeValueOf(AtomType))) = 'module' then
      Console('warn', 'module scripts are not supported yet');
    Exit;
  end;
  Script.ElementState := Script.ElementState or ElementStateAlreadyStarted;
  if Script.NodeDocument <> Document then
    Exit;
  if Script.HasAttributeAtom(AtomSrc) then
  begin
    if (Script.AttributeValueOf(AtomSrc) = '') or
      not ResolveUrlText(Document, Script.AttributeValueOf(AtomSrc), Resolved) then
    begin
      ScriptFetchFailed(Script);
      Exit;
    end;
    if ParserInserted and Script.HasAttributeAtom(AtomDefer) and not Script.HasAttributeAtom(AtomAsync) then
      Mode := ScriptFetchDeferred
    else if ParserInserted and not Script.HasAttributeAtom(AtomAsync) then
      Mode := ScriptFetchParserBlocking
    else
      { Script-inserted scripts are async (their "force async" flag is
        not tracked yet, so async=false does not make them in order). }
      Mode := ScriptFetchAsync;
    try
      Environment.FetchClassicScript(Self, Script, Resolved, Script.AttributeValueOf(AtomCharset), Mode);
    except
      on Error: EScriptEnvironmentUnsupported do
      begin
        Console('error', 'cannot load ' + Resolved + ': ' + Error.Message);
        ScriptFetchFailed(Script);
        Exit;
      end;
    end;
    Result := Mode = ScriptFetchParserBlocking;
    Exit;
  end;
  ExecuteClassicScript(Source, DocumentUrlText(Document), Script);
end;

procedure TScriptContext.BeginParsing(Parser: THtmlParser);
begin
  FActiveParser := Parser;
  Parser.ScriptHost := TParserScriptHost.Create(Self);
  Parser.ScriptingEnabled := True;
  Document.ScriptingEnabled := True;
  FReadyState := 'loading';
end;

procedure TScriptContext.FinishParsing;
var
  Host: TScriptHost;
begin
  if FActiveParser <> nil then
  begin
    Host := FActiveParser.ScriptHost;
    FActiveParser.ScriptHost := nil;
    Host.Free;
  end;
  FActiveParser := nil;
  FReadyState := 'interactive';
  FireSimpleEvent(Document, 'readystatechange', False);
  FireSimpleEvent(Document, 'DOMContentLoaded', True);
  PerformMicrotaskCheckpoint;
end;

procedure TScriptContext.DocumentLoaded;
begin
  FReadyState := 'complete';
  FireSimpleEvent(Document, 'readystatechange', False);
  FireSimpleEvent(Window, 'load', False);
  PerformMicrotaskCheckpoint;
end;

procedure TScriptContext.ParseDocument(const Html: string);
var
  Parser: THtmlParser;
begin
  Parser := THtmlParser.Create(Document);
  try
    BeginParsing(Parser);
    try
      Parser.WriteText(Html);
      while Parser.Paused do
        Parser.Resume;
      Parser.Finish;
      while Parser.Paused do
        Parser.Resume;
    finally
      FinishParsing;
    end;
  finally
    Parser.Free;
  end;
  DocumentLoaded;
end;

procedure TScriptContext.FireTimer(TimerId: Integer);
begin
  if Timers <> nil then
    TScriptTimers(Timers).Fire(TimerId);
end;

procedure TScriptContext.DropOpenedParser;
var
  Host: TScriptHost;
begin
  if FOpenedParser = nil then
    Exit;
  if FActiveParser = FOpenedParser then
    FActiveParser := nil;
  Host := FOpenedParser.ScriptHost;
  FOpenedParser.ScriptHost := nil;
  Host.Free;
  FreeAndNil(FOpenedParser);
end;

{ Text into the script-created parser; its scripts run as the parser
  reaches them (under a loader too, which only runs the scripts of its
  own parser). }
procedure TScriptContext.WriteToOpenedParser(const Text: string; Finish: Boolean);
var
  Saved: Boolean;
  Parser: THtmlParser;
begin
  Parser := FOpenedParser;
  Saved := FPreparesScripts;
  FPreparesScripts := True;
  try
    if Text <> '' then
      Parser.WriteText(Text);
    while Parser.Paused do
      Parser.Resume;
    if Finish then
    begin
      Parser.Finish;
      while Parser.Paused do
        Parser.Resume;
    end;
  finally
    FPreparesScripts := Saved;
  end;
end;

{ HTML 8.4.1, the document open steps: in a script the parser runs,
  nothing; else the document's children go and a script-created parser
  takes what is written until document.close (an iframe's about:blank
  document written by its parent, a page writing itself anew). }
procedure TScriptContext.DocumentOpen(Target: TDocument);
var
  Parser: THtmlParser;
begin
  if (Target = Document) and (FActiveParser <> nil) and (FActiveParser.ScriptNestingLevel > 0) then
    Exit;
  if Target <> Document then
    RaiseUnsupported('document.open of a document without its own window');
  if (FActiveParser <> nil) and (FActiveParser <> FOpenedParser) then
    RaiseUnsupported('document.open while the document loads');
  DropOpenedParser;
  while Document.FirstChild <> nil do
    Document.RemoveChild(Document.FirstChild);
  Parser := THtmlParser.Create(Document);
  FOpenedParser := Parser;
  BeginParsing(Parser);
end;

procedure TScriptContext.DocumentWrite(Target: TDocument; const Text: string);
begin
  if (Target = Document) and (FActiveParser <> nil) and (FActiveParser.ScriptNestingLevel > 0) then
  begin
    FActiveParser.DocumentWrite(Text);
    Exit;
  end;
  if (Target = Document) and (FOpenedParser <> nil) and (FActiveParser = FOpenedParser) then
  begin
    WriteToOpenedParser(Text, False);
    Exit;
  end;
  if (Target = Document) and (FActiveParser <> nil) then
  begin
    Console('warn', 'document.write from an asynchronous script was ignored');
    Exit;
  end;
  { After the document was parsed: an implicit document.open. }
  DocumentOpen(Target);
  WriteToOpenedParser(Text, False);
end;

procedure TScriptContext.DocumentClose(Target: TDocument);
begin
  if (Target <> Document) or (FOpenedParser = nil) or (FActiveParser <> FOpenedParser) then
    Exit;
  WriteToOpenedParser('', True);
  FinishParsing;
  DropOpenedParser;
  DocumentLoaded;
end;

function TScriptContext.ReadyState(Target: TDocument): string;
begin
  if (Target = Document) and FReadyStateFromDocument then
    Result := Document.ReadyStateText
  else if Target = Document then
    Result := FReadyState
  else
    Result := 'complete';
end;

procedure TScriptContext.InvokeEventHandler(EventType: TAtom; Event: TEvent);
begin
  RunEventHandler(Self, EventType, Event);
end;

{ TParserScriptHost }

constructor TParserScriptHost.Create(Context: TScriptContext);
begin
  inherited Create;
  FContext := Context;
end;

function TParserScriptHost.ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean;
begin
  Result := FContext.PrepareScript(Script, Parser);
end;

end.
