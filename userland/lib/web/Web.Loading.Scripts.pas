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
  Script elements (HTML Standard 4.12.1 "prepare the script element"
  and 13.2.6 "the end"): which scripts run, when, and in what order.
  Running them is the JavaScript engine's (a TScriptExecutor); without
  one, scripting is off and no script is prepared (noscript is then
  parsed as markup, as with scripting disabled).

  - Types: classic (no type, or a JavaScript MIME type), module, and
    importmap (handed to the executor as is); anything else is a data
    block. nomodule classic scripts are skipped when modules work.
  - Fetching: classic external scripts with the crossorigin setting
    (no-cors by default), decoded with the Content-Type charset or the
    document's encoding; module scripts in CORS mode (same-origin
    credentials unless use-credentials), always UTF-8. The executor
    fetches a module's imports itself through FetchScript.
  - Ordering, as the standard's lists:
      * parser-inserted external classic, neither async nor defer: the
        pending parsing-blocking script - the parser pauses until it is
        fetched and no style sheet blocks scripts, then it runs and the
        parser resumes;
      * parser-inserted inline classic while a style sheet blocks
        scripts: the same, already "ready";
      * defer (or a parser-inserted module without async): the list of
        scripts that run when the document has finished parsing, in
        order (RunDeferredScripts);
      * async, or a script inserted by a script (force async): run as
        soon as each is ready;
      * an external script inserted by a script with async set false:
        the in-order list, run in order as each becomes ready;
      * anything else runs at once.
  - load fires at an external script after it runs, error when its
    fetch failed. Every fetch delays the document's load event.
}
unit Web.Loading.Scripts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Web.Dom,
  Web.Html.Parser,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches,
  Web.Loading.Preloads;

type
  TScriptKind = (ScriptClassic, ScriptModule, ScriptImportMap);

  TPendingScript = class
  public
    Element: TElement;
    Kind: TScriptKind;
    External: Boolean;
    Url: TUrlRecord;
    Source: string;
    Ready: Boolean;
    Failed: Boolean;
    ParserInserted: Boolean;
    Fetch: TBufferedFetch;
    Delaying: Boolean;
    destructor Destroy; override;
  end;

  { The JavaScript engine's side. }
  TScriptExecutor = class
  public
    function SupportsModules: Boolean; virtual;
    { Runs a script (Source is UTF-8; Url its URL, or the document's
      for an inline script). document.currentScript is Script.Element
      for classic scripts. }
    procedure ExecuteScript(Script: TPendingScript); virtual; abstract;
    { A document loader (Web.Loading.Documents' TDocumentLoader) made
      its document, before any byte is parsed: the engine makes the
      document's global (event handler attributes need it even without
      script elements). }
    procedure DocumentStarted(Loader: TObject); virtual;
    { The navigation's times are in the loader's Times (the navigable sets
      them right after making the loader, before any content). }
    procedure DocumentTimed(Loader: TObject); virtual;
    { The loader stopped (aborted: the document is being left): timers
      stop, nothing more runs. Called again when it is freed. }
    procedure DocumentStopped(Loader: TObject); virtual;
    { The loader is going: what the engine kept for its document goes. }
    procedure DocumentFreed(Loader: TObject); virtual;
  end;

  TBlockingQuery = function: Boolean of object;

  TScriptTextEvent = procedure(const Source: string; Success: Boolean; Data: TObject) of object;

  TScriptScheduler = class(TScriptHost)
  private
    FContext: TLoadingContext;
    FPreloads: TPreloadCache;
    FExecutor: TScriptExecutor;
    FParser: THtmlParser;
    FParsingBlocking: TPendingScript;
    FDeferred: TList;
    FInOrder: TList;
    FAsync: TList;
    FAll: TList;
    { The fetches of FetchScript still running (their TBufferedFetch). }
    FTextFetches: TList;
    FRunningDeferred: Boolean;
    FLastError: string;
    FOnDeferredDone: TNotifyEvent;
    FOnParserResume: TNotifyEvent;
    FStyleSheetsBlocking: TBlockingQuery;
    function DetermineKind(Element: TElement; out Kind: TScriptKind): Boolean;
    procedure StartFetch(Script: TPendingScript; Element: TElement);
    procedure FetchComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure TextFetchComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure Execute(Script: TPendingScript);
    procedure Forget(Script: TPendingScript);
    procedure ProcessReady;
    procedure ProcessReadyTask;
    procedure QueueProcessReady;
    procedure FireScriptEvent(Element: TElement; const Name: string);
    function BlockedByStyleSheets: Boolean;
  public
    constructor Create(Context: TLoadingContext; Preloads: TPreloadCache);
    destructor Destroy; override;
    { The parser's hook. }
    function ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean; override;
    { A script element became connected (or its src or children
      changed) outside the parser. }
    procedure ScriptChanged(Element: TElement);
    { Prepares Element; True when it became the pending parsing-blocking
      script. }
    function Prepare(Element: TElement; ParserInserted: Boolean): Boolean;
    { Style sheets that blocked scripts are all in. }
    procedure StyleSheetsUnblocked;
    { The end: run the deferred scripts in order; OnDeferredDone after. }
    procedure RunDeferredScripts;
    { For the executor: a module import or other script text. OnDone
      comes once, in a later task; when the scheduler goes first it
      never comes and Data is freed. }
    procedure FetchScript(constref Url: TUrlRecord; IsModule: Boolean; OnDone: TScriptTextEvent; Data: TObject);
    function HasParsingBlockingScript: Boolean;
    { Scripts of the async and in-order lists not run yet. }
    function PendingAsapCount: Integer;
    property Executor: TScriptExecutor read FExecutor write FExecutor;
    { The last exception an executor let through. }
    property LastError: string read FLastError;
    property Parser: THtmlParser read FParser write FParser;
    property OnDeferredDone: TNotifyEvent read FOnDeferredDone write FOnDeferredDone;
    { The parser paused for a script may go on (the loader resumes it). }
    property OnParserResume: TNotifyEvent read FOnParserResume write FOnParserResume;
    property StyleSheetsBlocking: TBlockingQuery read FStyleSheetsBlocking write FStyleSheetsBlocking;
  end;

implementation

uses
  Url.Parser,
  Web.Atoms,
  Web.EventLoop.Tasks,
  Web.Encoding.Labels,
  Web.Fetch.Requests,
  Web.Fetch.MimeTypes,
  Web.Navigation.Events,
  Web.Loading.Priorities,
  Web.Loading.TextDecoding,
  Web.Fetch.CspChecks;

type
  TScriptEvent = class
  public
    Element: TElement;
    Name: string;
    destructor Destroy; override;
  end;

  TScriptTextRequest = class
  public
    OnDone: TScriptTextEvent;
    Data: TObject;
    IsModule: Boolean;
    Encoding: TTextEncoding;
  end;

  TScriptEventFirer = class
  public
    procedure Fire(Data: TObject);
  end;

var
  ScriptEventFirer: TScriptEventFirer;

destructor TScriptEvent.Destroy;
begin
  Element.Release;
  inherited Destroy;
end;

procedure TScriptEventFirer.Fire(Data: TObject);
begin
  FireEvent(TScriptEvent(Data).Element, TScriptEvent(Data).Name);
end;

procedure TScriptScheduler.TextFetchComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Request: TScriptTextRequest;
  Text: string;
begin
  FTextFetches.Remove(Fetch);
  Request := TScriptTextRequest(Fetch.Data);
  Text := '';
  if Success then
  begin
    if Request.IsModule then
      Text := DecodeUtf8Bytes(Fetch.Body)
    else
      Text := DecodeClassicScriptBytes(Fetch.Body, Fetch.Charset, Request.Encoding);
  end;
  Request.OnDone(Text, Success, Request.Data);
  Request.Free;
  Fetch.Free;
end;

{ A FetchScript fetch that never completed: freeing it cancels its job. }
procedure FreeTextFetch(Fetch: TBufferedFetch);
var
  Request: TScriptTextRequest;
begin
  Request := TScriptTextRequest(Fetch.Data);
  Fetch.Free;
  Request.Data.Free;
  Request.Free;
end;

destructor TPendingScript.Destroy;
begin
  if Fetch <> nil then
  begin
    Fetch.Cancel;
    Fetch.Free;
  end;
  Element.Release;
  inherited Destroy;
end;

function TScriptExecutor.SupportsModules: Boolean;
begin
  Result := True;
end;

procedure TScriptExecutor.DocumentStarted(Loader: TObject);
begin
end;

procedure TScriptExecutor.DocumentTimed(Loader: TObject);
begin
end;

procedure TScriptExecutor.DocumentStopped(Loader: TObject);
begin
end;

procedure TScriptExecutor.DocumentFreed(Loader: TObject);
begin
end;

constructor TScriptScheduler.Create(Context: TLoadingContext; Preloads: TPreloadCache);
begin
  inherited Create;
  FContext := Context;
  FPreloads := Preloads;
  FDeferred := TList.Create;
  FInOrder := TList.Create;
  FAsync := TList.Create;
  FAll := TList.Create;
  FTextFetches := TList.Create;
end;

destructor TScriptScheduler.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to FAll.Count - 1 do
    TPendingScript(FAll[Index]).Free;
  FAll.Free;
  for Index := 0 to FTextFetches.Count - 1 do
    FreeTextFetch(TBufferedFetch(FTextFetches[Index]));
  FTextFetches.Free;
  FDeferred.Free;
  FInOrder.Free;
  FAsync.Free;
  inherited Destroy;
end;

function TScriptScheduler.BlockedByStyleSheets: Boolean;
begin
  Result := Assigned(FStyleSheetsBlocking) and FStyleSheetsBlocking();
end;

function TScriptScheduler.DetermineKind(Element: TElement; out Kind: TScriptKind): Boolean;
var
  TypeText, Language: string;
begin
  Kind := ScriptClassic;
  TypeText := Element.AttributeValueOf(AtomType);
  Language := Element.AttributeValueOf(Atomize('language'));
  if not Element.HasAttributeAtom(AtomType) and not Element.HasAttributeAtom(Atomize('language')) or
     Element.HasAttributeAtom(AtomType) and (TypeText = '') or
     not Element.HasAttributeAtom(AtomType) and (Language = '') then
    Exit(True);
  if not Element.HasAttributeAtom(AtomType) then
    Exit(IsJavaScriptMimeType('text/' + AsciiLowerCase(Language)));
  TypeText := AsciiLowerCase(TrimHttpWhitespace(TypeText));
  if IsJavaScriptMimeType(TypeText) then
    Exit(True);
  if TypeText = 'module' then
  begin
    Kind := ScriptModule;
    Exit(True);
  end;
  if TypeText = 'importmap' then
  begin
    Kind := ScriptImportMap;
    Exit(True);
  end;
  Result := False;
end;

procedure TScriptScheduler.FireScriptEvent(Element: TElement; const Name: string);
var
  Item: TScriptEvent;
begin
  Item := TScriptEvent.Create;
  Item.Element := Element;
  Element.Retain;
  Item.Name := Name;
  FContext.Loop.QueueTask(TDataTask.Create(@ScriptEventFirer.Fire, Item), TaskSourceDomManipulation, FContext);
end;

function TScriptScheduler.ScriptEndTagReached(Parser: THtmlParser; Script: TElement): Boolean;
begin
  FParser := Parser;
  Prepare(Script, True);
  Result := FParsingBlocking <> nil;
  if Result and FParsingBlocking.Ready and not BlockedByStyleSheets and (Parser.ScriptNestingLevel <= 1) then
  begin
    { Ready now (an inline script whose sheets came in meanwhile). }
    Execute(FParsingBlocking);
    Result := False;
  end;
end;

procedure TScriptScheduler.ScriptChanged(Element: TElement);
begin
  if (Element.ElementState and ElementStateParserInserted) <> 0 then
    Exit;
  Prepare(Element, False);
end;

function TScriptScheduler.Prepare(Element: TElement; ParserInserted: Boolean): Boolean;
var
  Script: TPendingScript;
  Kind: TScriptKind;
  HasSrc, IsAsync, IsDefer, ForceAsync: Boolean;
begin
  Result := False;
  if FExecutor = nil then
    Exit;
  if (Element.ElementState and ElementStateAlreadyStarted) <> 0 then
    Exit;
  ForceAsync := not ParserInserted and ((Element.ElementState and ElementStateForceAsync) <> 0);
  if ParserInserted then
    Element.ElementState := Element.ElementState and not ElementStateParserInserted;
  HasSrc := Element.HasAttributeAtom(AtomSrc);
  if not HasSrc and (Element.TextContent = '') then
    Exit;
  if not Element.IsConnected then
    Exit;
  if not DetermineKind(Element, Kind) then
    Exit;
  Element.ElementState := Element.ElementState or ElementStateAlreadyStarted;
  if (Kind = ScriptClassic) and Element.HasAttributeAtom(AtomNomodule) and FExecutor.SupportsModules then
    Exit;
  if (Kind = ScriptModule) and not FExecutor.SupportsModules then
    Exit;
  { CSP: an inline script runs only if the document's policies allow
    it (by 'unsafe-inline', its nonce or its hash). }
  if not HasSrc and CspBlocksInline(FContext.Client, CspInlineScript, Element.TextContent,
    Element.AttributeValueOf(AtomNonce), Element, SerializeUrl(FContext.DocumentUrl, True)) then
    Exit;
  Script := TPendingScript.Create;
  Script.Element := Element;
  Element.Retain;
  Script.Kind := Kind;
  Script.ParserInserted := ParserInserted;
  FAll.Add(Script);
  IsAsync := Element.HasAttributeAtom(AtomAsync) or ForceAsync;
  IsDefer := Element.HasAttributeAtom(AtomDefer);
  if HasSrc and (Kind <> ScriptImportMap) then
  begin
    Script.External := True;
    if (Element.AttributeValueOf(AtomSrc) = '') or
       not FContext.ResolveUrl(Element.AttributeValueOf(AtomSrc), Script.Url) then
    begin
      FireScriptEvent(Element, 'error');
      Forget(Script);
      Exit;
    end;
    StartFetch(Script, Element);
  end
  else
  begin
    Script.Url := FContext.DocumentUrl;
    Script.Source := Element.TextContent;
    Script.Ready := True;
  end;
  if Kind = ScriptImportMap then
  begin
    Execute(Script);
    Exit;
  end;
  if Script.External and (Kind = ScriptClassic) then
  begin
    if ParserInserted and IsDefer and not IsAsync then
      FDeferred.Add(Script)
    else if ParserInserted and not IsAsync then
    begin
      FParsingBlocking := Script;
      Result := True;
    end
    else if not IsAsync then
      FInOrder.Add(Script)
    else
      FAsync.Add(Script);
  end
  else if Kind = ScriptModule then
  begin
    if IsAsync then
      FAsync.Add(Script)
    else if ParserInserted then
      FDeferred.Add(Script)
    else
      FInOrder.Add(Script);
  end
  else if ParserInserted and BlockedByStyleSheets and (FParser <> nil) and (FParser.ScriptNestingLevel <= 1) then
  begin
    FParsingBlocking := Script;
    Result := True;
  end
  else
    Execute(Script);
  if Script.Ready and (FAsync.IndexOf(Script) >= 0) then
    QueueProcessReady;
end;

procedure TScriptScheduler.StartFetch(Script: TPendingScript; Element: TElement);
var
  Request: TFetchRequest;
  Claimed: TBufferedFetch;
  Kind: TResourceKind;
begin
  Script.Delaying := True;
  FContext.DelayLoad;
  if (Script.Kind = ScriptClassic) and not Element.HasAttributeAtom(AtomCrossorigin) and
     FPreloads.Claim(Script.Url, DestinationScript, @FetchComplete, Claimed) then
  begin
    Script.Fetch := Claimed;
    Claimed.Data := Script;
    Exit;
  end;
  if Script.Kind = ScriptModule then
  begin
    Request := FContext.NewRequest(Script.Url, DestinationScript, FetchModeCors, FetchCredentialsSameOrigin);
    if AsciiLowerCase(Element.AttributeValueOf(AtomCrossorigin)) = 'use-credentials' then
      Request.Credentials := FetchCredentialsInclude;
  end
  else
  begin
    Request := FContext.NewRequest(Script.Url, DestinationScript, FetchModeNoCors, FetchCredentialsSameOrigin);
    FContext.ApplyCorsSettings(Request, Element, FetchModeNoCors);
  end;
  FContext.ApplyReferrerPolicyAttribute(Request, Element);
  Request.InitiatorType := 'script';
  Request.CryptographicNonce := Element.AttributeValueOf(AtomNonce);
  Request.Integrity := Element.AttributeValueOf(AtomIntegrity);
  if Script.ParserInserted then
    Request.ParserMetadata := ParserMetadataInserted
  else
    Request.ParserMetadata := ParserMetadataNotInserted;
  if Element.HasAttributeAtom(AtomAsync) then
    Kind := ResourceAsyncScript
  else if Element.HasAttributeAtom(AtomDefer) or (Script.Kind = ScriptModule) then
    Kind := ResourceDeferredScript
  else
    Kind := ResourceBlockingScript;
  Request.Priority := PriorityFor(Kind, FetchPriorityFromAttribute(Element.AttributeValueOf(Atomize('fetchpriority'))));
  Script.Fetch := TBufferedFetch.Create(@FetchComplete);
  Script.Fetch.Data := Script;
  Script.Fetch.Start(FContext.Fetcher, Request, FContext);
end;

procedure TScriptScheduler.FetchComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Script: TPendingScript;
  Encoding: TTextEncoding;
begin
  Script := TPendingScript(Fetch.Data);
  Script.Fetch := nil;
  if Success then
  begin
    if Script.Kind = ScriptModule then
      Script.Source := DecodeUtf8Bytes(Fetch.Body)
    else
    begin
      if not EncodingForLabel(FContext.Document.CharacterSet, Encoding) then
        Encoding := TextEncodingUtf8;
      Script.Source := DecodeClassicScriptBytes(Fetch.Body, Fetch.Charset, Encoding);
    end;
  end
  else
    Script.Failed := True;
  Script.Ready := True;
  Fetch.Free;
  ProcessReady;
end;

procedure TScriptScheduler.Execute(Script: TPendingScript);
var
  Element: TElement;
  WasExternal, Failed: Boolean;
begin
  if Script = FParsingBlocking then
    FParsingBlocking := nil;
  FDeferred.Remove(Script);
  FInOrder.Remove(Script);
  FAsync.Remove(Script);
  Element := Script.Element;
  WasExternal := Script.External;
  Failed := Script.Failed;
  if Failed then
    FireScriptEvent(Element, 'error')
  else
  begin
    try
      FExecutor.ExecuteScript(Script);
    except
      { The executor reports its own errors; the page goes on. }
      on Error: Exception do
        FLastError := Error.Message;
    end;
    if WasExternal then
      FireScriptEvent(Element, 'load');
  end;
  Forget(Script);
end;

procedure TScriptScheduler.Forget(Script: TPendingScript);
begin
  FAll.Remove(Script);
  if Script.Delaying then
    FContext.UndelayLoad;
  Script.Delaying := False;
  Script.Free;
end;

procedure TScriptScheduler.QueueProcessReady;
begin
  FContext.Loop.QueueMethod(@ProcessReadyTask, TaskSourceNetworking, FContext);
end;

procedure TScriptScheduler.ProcessReadyTask;
begin
  ProcessReady;
end;

procedure TScriptScheduler.ProcessReady;
var
  Script: TPendingScript;
  Index: Integer;
begin
  { The parsing-blocking script first: the parser goes on after it. }
  if (FParsingBlocking <> nil) and FParsingBlocking.Ready and not BlockedByStyleSheets then
  begin
    Execute(FParsingBlocking);
    if Assigned(FOnParserResume) then
      FOnParserResume(Self);
  end;
  while (FInOrder.Count > 0) and TPendingScript(FInOrder[0]).Ready do
    Execute(TPendingScript(FInOrder[0]));
  Index := 0;
  while Index < FAsync.Count do
  begin
    Script := TPendingScript(FAsync[Index]);
    if Script.Ready then
      Execute(Script)
    else
      Inc(Index);
  end;
  if FRunningDeferred then
  begin
    while (FDeferred.Count > 0) and TPendingScript(FDeferred[0]).Ready and not BlockedByStyleSheets do
      Execute(TPendingScript(FDeferred[0]));
    if FDeferred.Count = 0 then
    begin
      FRunningDeferred := False;
      if Assigned(FOnDeferredDone) then
        FOnDeferredDone(Self);
    end;
  end;
end;

procedure TScriptScheduler.StyleSheetsUnblocked;
begin
  QueueProcessReady;
end;

procedure TScriptScheduler.RunDeferredScripts;
begin
  FRunningDeferred := True;
  ProcessReady;
end;

procedure TScriptScheduler.FetchScript(constref Url: TUrlRecord; IsModule: Boolean; OnDone: TScriptTextEvent;
  Data: TObject);
var
  Request: TFetchRequest;
  TextRequest: TScriptTextRequest;
  Fetch: TBufferedFetch;
begin
  if IsModule then
    Request := FContext.NewRequest(Url, DestinationScript, FetchModeCors, FetchCredentialsSameOrigin)
  else
    Request := FContext.NewRequest(Url, DestinationScript, FetchModeNoCors, FetchCredentialsSameOrigin);
  Request.InitiatorType := 'script';
  Request.Priority := PriorityFor(ResourceDeferredScript);
  TextRequest := TScriptTextRequest.Create;
  TextRequest.OnDone := OnDone;
  TextRequest.Data := Data;
  TextRequest.IsModule := IsModule;
  if not EncodingForLabel(FContext.Document.CharacterSet, TextRequest.Encoding) then
    TextRequest.Encoding := TextEncodingUtf8;
  Fetch := TBufferedFetch.Create(@TextFetchComplete);
  Fetch.Data := TextRequest;
  FTextFetches.Add(Fetch);
  Fetch.Start(FContext.Fetcher, Request, FContext);
end;

function TScriptScheduler.HasParsingBlockingScript: Boolean;
begin
  Result := FParsingBlocking <> nil;
end;

function TScriptScheduler.PendingAsapCount: Integer;
begin
  Result := FInOrder.Count + FAsync.Count;
end;

initialization
  ScriptEventFirer := TScriptEventFirer.Create;

finalization
  ScriptEventFirer.Free;

end.
