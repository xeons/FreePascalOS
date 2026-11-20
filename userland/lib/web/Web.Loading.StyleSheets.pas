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
  External style sheets (HTML Standard 4.2.4 "link type stylesheet",
  CSSOM "fetch a style sheet") and their @import chains:

  - A connected <link> whose rel has "stylesheet" but not "alternate",
    with an href and no disabled attribute, loads its sheet (destination
    style, no-cors unless crossorigin, its referrerpolicy). A change of
    rel, href, disabled or media, or the link leaving the document,
    drops the old sheet (StyleSheetRemoved) and loads again as needed.
  - The response must be text/css (any type in quirks mode); it is
    decoded by the CSS fallback encoding rules and parsed by libcss.
    Each @import whose supports() condition holds is fetched against
    the importing sheet's URL (that sheet is the referrer), parsed and
    hung on its rule, to MaximumImportDepth levels; a URL already in the
    chain above (a cycle) is not loaded again.
  - When the sheet and all its imports are in, the sink gets it, the
    link gets a load event (error when the sheet itself failed), and the
    load event delay ends. A sheet the parser inserted blocks scripts
    until then (BlockingCount).
  - LoadImportsOf does the import part for a sheet the style side
    parsed itself (a <style> element).
  - Priorities: render-blocking (matching media) sheets come first,
    others at a low urgency.
}
unit Web.Loading.StyleSheets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Css.Stylesheets,
  Web.Dom,
  Web.Fetch.Requests,
  Web.Loading.Contexts,
  Web.Loading.BufferedFetches,
  Web.Loading.Preloads;

type
  TStyleSheetLoader = class;

  TSheetReadyEvent = procedure(Owner: TElement; Sheet: TCssStyleSheet) of object;
  TSheetGoingEvent = procedure(Sheet: TCssStyleSheet) of object;

  { One sheet being put together: the root sheet and its imports. }
  TSheetLoad = class
  public
    Loader: TStyleSheetLoader;
    Owner: TElement;
    Url: TUrlRecord;
    Href: string;
    Root: TBufferedFetch;
    Sheet: TCssStyleSheet;
    { Imports still loading. }
    Pending: Integer;
    { The sheet was given by the sink (LoadImportsOf). }
    External: Boolean;
    Failed: Boolean;
    Blocking: Boolean;
    Imports: TList;
    destructor Destroy; override;
  end;

  TImportFetch = class
  public
    Load: TSheetLoad;
    Rule: TCssImportRule;
    Depth: Integer;
    Chain: string;
    Fetch: TBufferedFetch;
  end;

  TLinkState = class
  public
    Element: TElement;
    Load: TSheetLoad;
    { What was given to the sink (not owned). }
    Delivered: TCssStyleSheet;
    Key: string;
  end;

  TStyleSheetLoader = class
  private
    FContext: TLoadingContext;
    FPreloads: TPreloadCache;
    FLinks: TList;
    FExternalLoads: TList;
    FBlockingCount: Integer;
    FOnSheetReady: TSheetReadyEvent;
    FOnSheetGoing: TSheetGoingEvent;
    FOnBlockingDone: TNotifyEvent;
    function StateOf(Element: TElement): TLinkState;
    function WantsSheet(Element: TElement; out Url: TUrlRecord): Boolean;
    procedure StartLoad(State: TLinkState; constref Url: TUrlRecord; ParserInserted: Boolean);
    procedure DropLoad(State: TLinkState);
    procedure RootComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure ImportComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure StartImports(Load: TSheetLoad; Sheet: TCssStyleSheet; Depth: Integer; const Chain: string);
    procedure CheckDone(Load: TSheetLoad);
    procedure Finish(Load: TSheetLoad);
    procedure FireLinkEvent(Element: TElement; const Name: string);
    function DocumentEncodingName: string;
    function ParseSheet(Fetch: TBufferedFetch): TCssStyleSheet;
  public
    constructor Create(Context: TLoadingContext; Preloads: TPreloadCache);
    destructor Destroy; override;
    { A link connected or changed (attributes); ParserInserted for links
      the parser made. }
    procedure LinkChanged(Element: TElement; ParserInserted: Boolean);
    procedure LinkRemoved(Element: TElement);
    { The imports of the sink's own sheet; ImportsLoaded comes after. }
    procedure LoadImportsOf(Owner: TElement; Sheet: TCssStyleSheet; constref BaseUrl: TUrlRecord);
    { Parser-inserted sheets still loading (they block scripts). }
    property BlockingCount: Integer read FBlockingCount;
    property OnSheetReady: TSheetReadyEvent read FOnSheetReady write FOnSheetReady;
    property OnSheetGoing: TSheetGoingEvent read FOnSheetGoing write FOnSheetGoing;
    property OnBlockingDone: TNotifyEvent read FOnBlockingDone write FOnBlockingDone;
  end;

{ The rel attribute has the token (ASCII case-insensitive). }
function RelHasToken(Element: TElement; const Token: string): Boolean;

implementation

uses
  Web.Profiling,
  Url.Parser,
  Css.Parser,
  Css.MediaQueries,
  Web.Atoms,
  Web.EventLoop.Tasks,
  Web.Encoding.Labels,
  Web.Fetch.MimeTypes,
  Web.Navigation.Events,
  Web.Loading.Priorities,
  Web.Loading.TextDecoding;

type
  TElementEvent = class
  public
    Element: TElement;
    Name: string;
    destructor Destroy; override;
  end;

  TEventFirer = class
  public
    procedure Fire(Data: TObject);
  end;

var
  EventFirer: TEventFirer;

destructor TElementEvent.Destroy;
begin
  Element.Release;
  inherited Destroy;
end;

procedure TEventFirer.Fire(Data: TObject);
var
  Item: TElementEvent;
begin
  Item := TElementEvent(Data);
  FireEvent(Item.Element, Item.Name);
end;

function RelHasToken(Element: TElement; const Token: string): Boolean;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Parts := AsciiLowerCase(Element.AttributeValueOf(AtomRel)).Split([' ', #9, #10, #12, #13],
    TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Parts) do
    if Parts[Index] = Token then
      Exit(True);
  Result := False;
end;

destructor TSheetLoad.Destroy;
var
  Index: Integer;
  Import: TImportFetch;
begin
  if Root <> nil then
  begin
    Root.Cancel;
    Root.Free;
  end;
  if Imports <> nil then
    for Index := 0 to Imports.Count - 1 do
    begin
      Import := TImportFetch(Imports[Index]);
      if Import.Fetch <> nil then
      begin
        Import.Fetch.Cancel;
        Import.Fetch.Free;
      end;
      Import.Free;
    end;
  Imports.Free;
  if not External then
    Sheet.Free;
  if Owner <> nil then
    Owner.Release;
  inherited Destroy;
end;

constructor TStyleSheetLoader.Create(Context: TLoadingContext; Preloads: TPreloadCache);
begin
  inherited Create;
  FContext := Context;
  FPreloads := Preloads;
  FLinks := TList.Create;
  FExternalLoads := TList.Create;
end;

destructor TStyleSheetLoader.Destroy;
var
  Index: Integer;
  State: TLinkState;
begin
  for Index := 0 to FLinks.Count - 1 do
  begin
    State := TLinkState(FLinks[Index]);
    State.Load.Free;
    State.Element.Release;
    State.Free;
  end;
  FLinks.Free;
  for Index := 0 to FExternalLoads.Count - 1 do
    TSheetLoad(FExternalLoads[Index]).Free;
  FExternalLoads.Free;
  inherited Destroy;
end;

function TStyleSheetLoader.StateOf(Element: TElement): TLinkState;
var
  Index: Integer;
begin
  for Index := 0 to FLinks.Count - 1 do
    if TLinkState(FLinks[Index]).Element = Element then
      Exit(TLinkState(FLinks[Index]));
  Result := nil;
end;

function TStyleSheetLoader.WantsSheet(Element: TElement; out Url: TUrlRecord): Boolean;
begin
  Url := EmptyUrl;
  Result := Element.IsConnected and RelHasToken(Element, 'stylesheet') and not RelHasToken(Element, 'alternate') and
    not Element.HasAttributeAtom(AtomDisabled) and (Element.AttributeValueOf(AtomHref) <> '') and
    FContext.ResolveUrl(Element.AttributeValueOf(AtomHref), Url);
end;

procedure TStyleSheetLoader.LinkChanged(Element: TElement; ParserInserted: Boolean);
var
  State: TLinkState;
  Url: TUrlRecord;
  Key: string;
begin
  State := StateOf(Element);
  if not WantsSheet(Element, Url) then
  begin
    if State <> nil then
      LinkRemoved(Element);
    Exit;
  end;
  Key := SerializeUrl(Url) + ' ' + Element.AttributeValueOf(AtomMedia) + ' ' +
    Element.AttributeValueOf(AtomCrossorigin);
  if State = nil then
  begin
    State := TLinkState.Create;
    State.Element := Element;
    Element.Retain;
    FLinks.Add(State);
  end
  else if State.Key = Key then
    Exit
  else
    DropLoad(State);
  State.Key := Key;
  StartLoad(State, Url, ParserInserted);
end;

procedure TStyleSheetLoader.DropLoad(State: TLinkState);
begin
  if State.Load <> nil then
  begin
    if State.Load.Blocking then
    begin
      Dec(FBlockingCount);
      if (FBlockingCount = 0) and Assigned(FOnBlockingDone) then
        FOnBlockingDone(Self);
    end;
    FreeAndNil(State.Load);
    FContext.UndelayLoad;
  end;
  if State.Delivered <> nil then
  begin
    if Assigned(FOnSheetGoing) then
      FOnSheetGoing(State.Delivered);
    State.Delivered := nil;
    FContext.Sink.StyleSheetRemoved(State.Element);
  end;
end;

procedure TStyleSheetLoader.LinkRemoved(Element: TElement);
var
  State: TLinkState;
begin
  State := StateOf(Element);
  if State = nil then
    Exit;
  DropLoad(State);
  FLinks.Remove(State);
  State.Element.Release;
  State.Free;
end;

procedure TStyleSheetLoader.StartLoad(State: TLinkState; constref Url: TUrlRecord; ParserInserted: Boolean);
var
  Load: TSheetLoad;
  Request: TFetchRequest;
  Media: TCssMediaQueryList;
  Matches: Boolean;
  Claimed: TBufferedFetch;
begin
  Load := TSheetLoad.Create;
  Load.Loader := Self;
  Load.Owner := State.Element;
  Load.Owner.Retain;
  Load.Url := Url;
  Load.Imports := TList.Create;
  State.Load := Load;
  FContext.DelayLoad;
  Matches := True;
  if State.Element.AttributeValueOf(AtomMedia) <> '' then
  begin
    Media := ParseMediaQueryText(State.Element.AttributeValueOf(AtomMedia));
    try
      Matches := (Media = nil) or Media.Matches(FContext.Sink.MediaEnvironment);
    finally
      Media.Free;
    end;
  end;
  Load.Blocking := ParserInserted and Matches;
  if Load.Blocking then
    Inc(FBlockingCount);
  if FPreloads.Claim(Url, DestinationStyle, @RootComplete, Claimed) then
  begin
    Load.Root := Claimed;
    Claimed.Data := Load;
    Exit;
  end;
  Request := FContext.NewRequest(Url, DestinationStyle, FetchModeNoCors, FetchCredentialsSameOrigin);
  FContext.ApplyCorsSettings(Request, State.Element, FetchModeNoCors);
  FContext.ApplyReferrerPolicyAttribute(Request, State.Element);
  Request.InitiatorType := 'link';
  if ParserInserted then
    Request.ParserMetadata := ParserMetadataInserted
  else
    Request.ParserMetadata := ParserMetadataNotInserted;
  if Matches then
    Request.Priority := PriorityFor(ResourceBlockingStyle,
      FetchPriorityFromAttribute(State.Element.AttributeValueOf(Atomize('fetchpriority'))))
  else
    Request.Priority := PriorityFor(ResourceNonMatchingStyle);
  Load.Root := TBufferedFetch.Create(@RootComplete);
  Load.Root.Data := Load;
  Load.Root.Start(FContext.Fetcher, Request, FContext);
end;

function TStyleSheetLoader.DocumentEncodingName: string;
begin
  Result := FContext.Document.CharacterSet;
end;

function TStyleSheetLoader.ParseSheet(Fetch: TBufferedFetch): TCssStyleSheet;
var
  Encoding: TTextEncoding;
  Text: string;
begin
  if not EncodingForLabel(DocumentEncodingName, Encoding) then
    Encoding := TextEncodingUtf8;
  Text := DecodeStyleSheetBytes(Fetch.Body, Fetch.Charset, Encoding);
  EnterPhase(PhaseStyleSheetParse);
  try
    SetPhaseDetail(SerializeUrl(Fetch.FinalUrl));
    Result := ParseStyleSheet(Text, coAuthor, SerializeUrl(Fetch.FinalUrl));
  finally
    LeavePhase;
  end;
end;

procedure TStyleSheetLoader.RootComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Load: TSheetLoad;
begin
  Load := TSheetLoad(Fetch.Data);
  if Success and (FContext.Document.Mode <> DocumentModeQuirks) and (Fetch.Essence <> 'text/css') then
    Success := False;
  if not Success then
  begin
    Load.Failed := True;
    Finish(Load);
    Exit;
  end;
  Load.Sheet := ParseSheet(Fetch);
  Load.Href := Load.Sheet.Href;
  if Load.Owner.AttributeValueOf(AtomMedia) <> '' then
    Load.Sheet.Media := ParseMediaQueryText(Load.Owner.AttributeValueOf(AtomMedia));
  StartImports(Load, Load.Sheet, 1, ' ' + Load.Href + ' ');
  CheckDone(Load);
end;

procedure TStyleSheetLoader.StartImports(Load: TSheetLoad; Sheet: TCssStyleSheet; Depth: Integer;
  const Chain: string);
var
  Index: Integer;
  Rule: TCssImportRule;
  Base, Target: TUrlRecord;
  Import: TImportFetch;
  Request: TFetchRequest;
begin
  if Depth > FContext.Settings.MaximumImportDepth then
    Exit;
  if (Sheet.Href = '') or not ParseUrl(Sheet.Href, Base) then
    Base := FContext.BaseUrl;
  for Index := 0 to High(Sheet.Rules) do
  begin
    if not (Sheet.Rules[Index] is TCssImportRule) then
      Continue;
    Rule := TCssImportRule(Sheet.Rules[Index]);
    if not Rule.SupportsMatches or (Rule.StyleSheet <> nil) or not ParseUrl(Rule.Url, Base, Target) then
      Continue;
    if Pos(' ' + SerializeUrl(Target) + ' ', Chain) > 0 then
      Continue;
    Import := TImportFetch.Create;
    Import.Load := Load;
    Import.Rule := Rule;
    Import.Depth := Depth;
    Import.Chain := Chain + SerializeUrl(Target) + ' ';
    Load.Imports.Add(Import);
    Inc(Load.Pending);
    Request := FContext.NewRequest(Target, DestinationStyle, FetchModeNoCors, FetchCredentialsSameOrigin);
    Request.ReferrerKind := ReferrerUrl;
    Request.ReferrerUrl := Base;
    Request.InitiatorType := 'css';
    Request.Priority := PriorityFor(ResourceBlockingStyle);
    Import.Fetch := TBufferedFetch.Create(@ImportComplete);
    Import.Fetch.Data := Import;
    Import.Fetch.Start(FContext.Fetcher, Request, FContext);
  end;
end;

procedure TStyleSheetLoader.ImportComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Import: TImportFetch;
  Load: TSheetLoad;
  Imported: TCssStyleSheet;
begin
  Import := TImportFetch(Fetch.Data);
  Load := Import.Load;
  Dec(Load.Pending);
  if Success and ((FContext.Document.Mode = DocumentModeQuirks) or (Fetch.Essence = 'text/css')) then
  begin
    Imported := ParseSheet(Fetch);
    Import.Rule.StyleSheet := Imported;
    StartImports(Load, Imported, Import.Depth + 1, Import.Chain);
  end;
  Import.Fetch := nil;
  Load.Imports.Remove(Import);
  Import.Free;
  Fetch.Free;
  CheckDone(Load);
end;

procedure TStyleSheetLoader.CheckDone(Load: TSheetLoad);
begin
  if Load.Pending = 0 then
    Finish(Load);
end;

procedure TStyleSheetLoader.FireLinkEvent(Element: TElement; const Name: string);
var
  Item: TElementEvent;
begin
  Item := TElementEvent.Create;
  Item.Element := Element;
  Element.Retain;
  Item.Name := Name;
  FContext.Loop.QueueTask(TDataTask.Create(@EventFirer.Fire, Item), TaskSourceDomManipulation, FContext);
end;

procedure TStyleSheetLoader.Finish(Load: TSheetLoad);
var
  State: TLinkState;
  Sheet: TCssStyleSheet;
  WasBlocking: Boolean;
begin
  if Load.External then
  begin
    FExternalLoads.Remove(Load);
    FContext.Sink.ImportsLoaded(Load.Owner, Load.Sheet);
    Load.Free;
    FContext.UndelayLoad;
    Exit;
  end;
  State := StateOf(Load.Owner);
  if (State = nil) or (State.Load <> Load) then
    Exit;
  State.Load := nil;
  WasBlocking := Load.Blocking;
  if WasBlocking then
    Dec(FBlockingCount);
  if Load.Failed then
    FireLinkEvent(Load.Owner, 'error')
  else
  begin
    Sheet := Load.Sheet;
    Load.Sheet := nil;
    State.Delivered := Sheet;
    FContext.Sink.StyleSheetLoaded(Load.Owner, Sheet);
    if Assigned(FOnSheetReady) then
      FOnSheetReady(Load.Owner, Sheet);
    FireLinkEvent(Load.Owner, 'load');
  end;
  if Load.Root <> nil then
  begin
    Load.Root.Free;
    Load.Root := nil;
  end;
  Load.Free;
  FContext.UndelayLoad;
  if WasBlocking and (FBlockingCount = 0) and Assigned(FOnBlockingDone) then
    FOnBlockingDone(Self);
end;

procedure TStyleSheetLoader.LoadImportsOf(Owner: TElement; Sheet: TCssStyleSheet; constref BaseUrl: TUrlRecord);
var
  Load: TSheetLoad;
begin
  Load := TSheetLoad.Create;
  Load.Loader := Self;
  Load.Owner := Owner;
  Owner.Retain;
  Load.External := True;
  Load.Sheet := Sheet;
  Load.Imports := TList.Create;
  if Sheet.Href = '' then
    Sheet.Href := SerializeUrl(BaseUrl);
  FExternalLoads.Add(Load);
  FContext.DelayLoad;
  StartImports(Load, Sheet, 1, ' ' + Sheet.Href + ' ');
  CheckDone(Load);
end;

initialization
  EventFirer := TEventFirer.Create;

finalization
  EventFirer.Free;

end.
