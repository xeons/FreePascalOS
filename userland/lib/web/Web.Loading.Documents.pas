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
  Loading one document (HTML Standard 7.4.6 "loading a document" and
  13.2.6 "the end"):

  - HTML: the response's bytes go into the HTML parser as they arrive
    (the encoding sniffed with the transport charset). While the
    confidence is tentative the bytes are kept; a <meta charset> that
    changes what was decoded makes the document start over in the new
    encoding (its tree emptied and the kept bytes parsed again). While
    the parser waits for a script, the preload scanner reads the bytes
    that come in meanwhile.
  - Plain text (text/plain and the text-like types): a <pre> that the
    decoded text is appended to as it comes. Images: an <img> of the
    document's URL in an otherwise empty document.
  - The end: readyState "interactive", the deferred scripts in order,
    DOMContentLoaded (a task), then, once nothing delays the load event
    (style sheets, images, fonts, scripts) and no async or in-order
    script waits, readyState "complete", load at the window, pageshow,
    and OnLoaded.
  - Subresources start from the tree (Web.Loading.Observers): link
    style sheets and icons, <link rel=preload>, images, scripts, base,
    meta (Content-Security-Policy, referrer, refresh), the title.
  - Abort stops it all: fetches cancelled, the parser dropped, no load
    event.
}
unit Web.Loading.Documents;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Url.Origins,
  Image.Model,
  Css.Stylesheets,
  Web.TextBuffers,
  Web.Atoms,
  Web.Dom,
  Web.Html.Parser,
  Web.Encoding.Labels,
  Web.Encoding.Decoders,
  Web.EventLoop,
  Web.Fetch.Requests,
  Web.Fetch.Fetcher,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Loading.Observers,
  Web.Loading.Preloads,
  Web.Loading.StyleSheets,
  Web.Loading.Images,
  Web.Loading.Scripts,
  Web.Loading.Icons,
  Web.Loading.Fonts,
  Web.Loading.CspReports,
  Web.Navigation.Windows;

type
  TDocumentLoader = class;
  PUrlOrigin = ^TUrlOrigin;

  TDocumentContentKind = (ContentHtml, ContentText, ContentImage, ContentPrepared, ContentXml);

  TTitleChangedEvent = procedure(Loader: TDocumentLoader; const Title: string) of object;
  TLoaderEvent = procedure(Loader: TDocumentLoader) of object;
  TRefreshEvent = procedure(Loader: TDocumentLoader; DelaySeconds: Double; constref Url: TUrlRecord) of object;
  TLoaderIconEvent = procedure(Loader: TDocumentLoader; const Url: string; Image: TImage) of object;
  { An iframe or frame of the document: inserted, an attribute changed
    (Attribute: its atom), or removed. }
  TLoaderFrameEvent = procedure(Loader: TDocumentLoader; Element: TElement; Attribute: TAtom) of object;

  TDocumentLoader = class(TLoadingContext)
  private
    FEvents: TLoadingEvents;
    FObserver: TLoadingObserver;
    FPreloads: TPreloadCache;
    FStyleSheets: TStyleSheetLoader;
    FImages: TImageLoader;
    FScripts: TScriptScheduler;
    FIcons: TIconLoader;
    FFonts: TFontLoader;
    FScanner: TPreloadScanner;
    FParser: THtmlParser;
    FContentKind: TDocumentContentKind;
    FTransportCharset: string;
    FKeptBytes: string;
    FKeepingBytes: Boolean;
    FScanPending: string;
    FInParser: Integer;
    FInputEnded: Boolean;
    FParsingDone: Boolean;
    FDomContentLoadedFired: Boolean;
    FLoadQueued: Boolean;
    FLoadFired: Boolean;
    FAborted: Boolean;
    FRestarts: Integer;
    FTitleCheckQueued: Boolean;
    FLastTitle: string;
    FTextDecoder: TTextDecoder;
    FTextBuffer: TTextBuffer;
    FTextNode: TText;
    FTextPending: string;
    { An XML document's bytes, parsed whole once they are all here. }
    FXmlBytes: string;
    FOnTitleChanged: TTitleChangedEvent;
    FOnDomContentLoaded: TLoaderEvent;
    FOnLoaded: TLoaderEvent;
    FOnRefresh: TRefreshEvent;
    FOnIconChanged: TLoaderIconEvent;
    FOnRestarted: TLoaderEvent;
    FOnFrameInserted: TLoaderFrameEvent;
    FOnFrameChanged: TLoaderFrameEvent;
    FOnFrameRemoved: TLoaderFrameEvent;
    FCspReporter: TDocumentCspReporter;
    procedure CspConsoleMessage(const Level, Text: string);
    procedure ParserCall(Bytes: PByte; Count: SizeInt; Finish, Resume: Boolean);
    procedure CheckRestart;
    procedure ScanIfBlocked;
    procedure Restart;
    procedure CheckParserEnded;
    procedure TheEnd;
    procedure DeferredScriptsDone(Sender: TObject);
    procedure FireDomContentLoaded;
    procedure LoadDelaysGone(Sender: TObject);
    procedure CheckLoadComplete;
    procedure FireLoad;
    procedure ParserResumeWanted(Sender: TObject);
    procedure ResumeParserTask;
    procedure StyleSheetsUnblocked(Sender: TObject);
    function StyleSheetsBlockScripts: Boolean;
    procedure SheetReady(Owner: TElement; Sheet: TCssStyleSheet);
    procedure SheetGoing(Sheet: TCssStyleSheet);
    procedure IconChanged(const Url: string; Image: TImage);
    procedure CheckTitle;
    procedure AppendTextContent(Bytes: PByte; Count: SizeInt; Flush: Boolean);
    procedure BuildTextDocument;
    procedure BuildXmlDocument;
    procedure BuildImageDocument;
  protected
    procedure HandleLinkChanged(Element: TElement);
    procedure HandleLinkRemoved(Element: TElement);
    procedure HandleMeta(Element: TElement);
    procedure HandleTitleMayHaveChanged;
    procedure HandleFrame(Event: TLoaderFrameEvent; Element: TElement; Attribute: TAtom);
  public
    { Loads into Document (shown in Window) from DocumentUrl. Executor:
      nil for scripting off. }
    constructor Create(ADocument: TDocument; AWindow: TWebWindow; AFetcher: TFetcher; ASink: TResourceSink;
      constref ADocumentUrl: TUrlRecord; constref ASettings: TLoadingSettings; Executor: TScriptExecutor;
      TopLevelOrigin: PUrlOrigin = nil);
    destructor Destroy; override;
    { What the response is (before the first bytes); TransportCharset:
      the Content-Type charset ('' for none). }
    procedure BeginContent(Kind: TDocumentContentKind; const TransportCharset: string);
    procedure ReceiveBytes(Data: Pointer; Count: PtrUInt);
    procedure EndOfInput;
    { Stops loading: no more fetches, no load event. }
    procedure Abort;
    { document.write for the bindings (False: no parser to write to). }
    function DocumentWrite(const Text: string): Boolean;
    { The sink's own sheet (a style element's): its imports load. }
    procedure LoadImportsOf(Owner: TElement; Sheet: TCssStyleSheet);
    { Layout: an image is near the viewport; the viewport changed. }
    procedure LoadLazyImage(Element: TElement);
    procedure EnvironmentChanged;
    property ContentKind: TDocumentContentKind read FContentKind;
    property Parser: THtmlParser read FParser;
    property Scripts: TScriptScheduler read FScripts;
    property StyleSheets: TStyleSheetLoader read FStyleSheets;
    property Images: TImageLoader read FImages;
    property Fonts: TFontLoader read FFonts;
    property Preloads: TPreloadCache read FPreloads;
    property ParsingDone: Boolean read FParsingDone;
    property DomContentLoadedFired: Boolean read FDomContentLoadedFired;
    property LoadFired: Boolean read FLoadFired;
    property Aborted: Boolean read FAborted;
    property Restarts: Integer read FRestarts;
    property OnTitleChanged: TTitleChangedEvent read FOnTitleChanged write FOnTitleChanged;
    property OnDomContentLoaded: TLoaderEvent read FOnDomContentLoaded write FOnDomContentLoaded;
    property OnLoaded: TLoaderEvent read FOnLoaded write FOnLoaded;
    property OnRefresh: TRefreshEvent read FOnRefresh write FOnRefresh;
    property OnIconChanged: TLoaderIconEvent read FOnIconChanged write FOnIconChanged;
    { The document started over in another encoding. }
    property OnRestarted: TLoaderEvent read FOnRestarted write FOnRestarted;
    { Frames (the navigable makes and drops child navigables). }
    property OnFrameInserted: TLoaderFrameEvent read FOnFrameInserted write FOnFrameInserted;
    property OnFrameChanged: TLoaderFrameEvent read FOnFrameChanged write FOnFrameChanged;
    property OnFrameRemoved: TLoaderFrameEvent read FOnFrameRemoved write FOnFrameRemoved;
    { The document's origin is not its URL's (about:blank and srcdoc
      documents: their creator's; sandboxed ones: opaque): the client's
      and the document's. }
    procedure SetOrigin(constref Origin: TUrlOrigin);
    { The response's Content-Security-Policy, -Report-Only and
      Reporting-Endpoints fields, and the document's referrer. }
    procedure ApplyResponsePolicies(const Enforced, ReportOnly, Endpoints, Referrer: string);
    { A local-scheme document's policies, taken from its creator. }
    procedure InheritPolicies(Source: TFetchClient);
    property CspReporter: TDocumentCspReporter read FCspReporter;
  end;

implementation

uses
  Web.Profiling,
  Url.Parser,
  Web.Namespaces,
  Web.EventLoop.Tasks,
  Web.Encoding.Sniffing,
  Web.Encoding.DecoderFactory,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.ContentSecurityPolicy,
  Web.Navigation.Events,
  Web.Origins,
  Web.Xml.Parser;

type
  { The observer's calls, forwarded to the loader. }
  TLoaderEvents = class(TLoadingEvents)
  private
    FLoader: TDocumentLoader;
  public
    constructor Create(Loader: TDocumentLoader);
    procedure LinkChanged(Element: TElement); override;
    procedure LinkRemoved(Element: TElement); override;
    procedure ImageChanged(Element: TElement); override;
    procedure ImageRemoved(Element: TElement); override;
    procedure ScriptChanged(Element: TElement); override;
    procedure BaseChanged; override;
    procedure MetaInserted(Element: TElement); override;
    procedure TitleMayHaveChanged; override;
    procedure FrameInserted(Element: TElement); override;
    procedure FrameAttributeChanged(Element: TElement; Attribute: TAtom); override;
    procedure FrameRemoved(Element: TElement); override;
  end;

constructor TLoaderEvents.Create(Loader: TDocumentLoader);
begin
  inherited Create;
  FLoader := Loader;
end;

procedure TLoaderEvents.LinkChanged(Element: TElement);
begin
  FLoader.HandleLinkChanged(Element);
end;

procedure TLoaderEvents.LinkRemoved(Element: TElement);
begin
  FLoader.HandleLinkRemoved(Element);
end;

procedure TLoaderEvents.ImageChanged(Element: TElement);
begin
  if not FLoader.Aborted then
    FLoader.Images.ImageChanged(Element);
end;

procedure TLoaderEvents.ImageRemoved(Element: TElement);
begin
  FLoader.Images.ImageRemoved(Element);
end;

procedure TLoaderEvents.ScriptChanged(Element: TElement);
begin
  if not FLoader.Aborted then
    FLoader.Scripts.ScriptChanged(Element);
end;

procedure TLoaderEvents.BaseChanged;
begin
  FLoader.InvalidateBaseUrl;
end;

procedure TLoaderEvents.MetaInserted(Element: TElement);
begin
  FLoader.HandleMeta(Element);
end;

procedure TLoaderEvents.TitleMayHaveChanged;
begin
  FLoader.HandleTitleMayHaveChanged;
end;

procedure TLoaderEvents.FrameInserted(Element: TElement);
begin
  FLoader.HandleFrame(FLoader.FOnFrameInserted, Element, AtomNone);
end;

procedure TLoaderEvents.FrameAttributeChanged(Element: TElement; Attribute: TAtom);
begin
  FLoader.HandleFrame(FLoader.FOnFrameChanged, Element, Attribute);
end;

procedure TLoaderEvents.FrameRemoved(Element: TElement);
begin
  FLoader.HandleFrame(FLoader.FOnFrameRemoved, Element, AtomNone);
end;

constructor TDocumentLoader.Create(ADocument: TDocument; AWindow: TWebWindow; AFetcher: TFetcher; ASink: TResourceSink;
  constref ADocumentUrl: TUrlRecord; constref ASettings: TLoadingSettings; Executor: TScriptExecutor;
  TopLevelOrigin: PUrlOrigin);
begin
  inherited Create;
  FDocument := ADocument;
  FDocument.Retain;
  FWindow := AWindow;
  FFetcher := AFetcher;
  FLoop := AFetcher.Loop;
  FSink := ASink;
  FDocumentUrl := ADocumentUrl;
  FSettings := ASettings;
  FClient := TFetchClient.Create;
  if TopLevelOrigin <> nil then
  begin
    FClient.TopLevelOrigin := TopLevelOrigin^;
    FClient.HasTopLevelOrigin := True;
  end;
  FClient.SetDocumentUrl(ADocumentUrl);
  FDocument.Url := SerializeUrl(ADocumentUrl);
  { An opaque origin (file:, data:) stays the same one for the document
    (its about:blank frames get it). }
  if FClient.Origin.Opaque then
    SetDocumentOrigin(FDocument, FClient.Origin);
  FDocument.BrowsingContext := Self;
  FCspReporter := TDocumentCspReporter.Create(Self);
  FCspReporter.OnConsole := @CspConsoleMessage;
  FClient.CspReporter := FCspReporter;
  FDocument.SecurityPolicy := FClient;
  FDocument.ScriptingEnabled := Executor <> nil;
  OnLoadDelaysGone := @LoadDelaysGone;
  FPreloads := TPreloadCache.Create(Self);
  FStyleSheets := TStyleSheetLoader.Create(Self, FPreloads);
  FStyleSheets.OnSheetReady := @SheetReady;
  FStyleSheets.OnSheetGoing := @SheetGoing;
  FStyleSheets.OnBlockingDone := @StyleSheetsUnblocked;
  FImages := TImageLoader.Create(Self, FPreloads);
  FScripts := TScriptScheduler.Create(Self, FPreloads);
  FScripts.Executor := Executor;
  FScripts.OnDeferredDone := @DeferredScriptsDone;
  FScripts.OnParserResume := @ParserResumeWanted;
  FScripts.StyleSheetsBlocking := @StyleSheetsBlockScripts;
  FIcons := TIconLoader.Create(Self);
  FIcons.OnIconChanged := @IconChanged;
  FFonts := TFontLoader.Create(Self);
  FScanner := TPreloadScanner.Create(Self, FPreloads);
  FEvents := TLoaderEvents.Create(Self);
  FObserver := TLoadingObserver.Create(FEvents);
  FDocument.AddObserver(FObserver);
  if Executor <> nil then
    Executor.DocumentStarted(Self);
end;

destructor TDocumentLoader.Destroy;
begin
  if FScripts.Executor <> nil then
  begin
    FScripts.Executor.DocumentStopped(Self);
    FScripts.Executor.DocumentFreed(Self);
  end;
  FAborted := True;
  FDocument.RemoveObserver(FObserver);
  FFetcher.CancelGroup(Self);
  FLoop.DiscardTasks(Self);
  FParser.Free;
  FScanner.Free;
  FIcons.Free;
  FScripts.Free;
  FImages.Free;
  FFonts.Free;
  FStyleSheets.Free;
  FPreloads.Free;
  FObserver.Free;
  FEvents.Free;
  FTextDecoder.Free;
  FTextBuffer.Free;
  FCspReporter.Free;
  if FDocument.SecurityPolicy = FClient then
    FDocument.SecurityPolicy := nil;
  FClient.Free;
  if FDocument.BrowsingContext = Self then
    FDocument.BrowsingContext := nil;
  FDocument.Release;
  inherited Destroy;
end;

procedure TDocumentLoader.CspConsoleMessage(const Level, Text: string);
begin
  if (FScripts <> nil) and (FScripts.Executor <> nil) then
    FScripts.Executor.LoaderConsoleMessage(Self, Level, Text);
end;

procedure TDocumentLoader.ApplyResponsePolicies(const Enforced, ReportOnly, Endpoints, Referrer: string);
begin
  if Enforced <> '' then
    FClient.Csp.AddFromField(Enforced, CspEnforce);
  if ReportOnly <> '' then
    FClient.Csp.AddFromField(ReportOnly, CspReport);
  FClient.DocumentReferrer := Referrer;
  FCspReporter.SetEndpoints(Endpoints);
end;

procedure TDocumentLoader.InheritPolicies(Source: TFetchClient);
begin
  InheritCsp(FClient, Source);
end;

procedure TDocumentLoader.BeginContent(Kind: TDocumentContentKind; const TransportCharset: string);
begin
  FContentKind := Kind;
  FTransportCharset := TransportCharset;
  FDocument.ReadyState := ReadyStateLoading;
  case Kind of
    ContentHtml:
      begin
        FDocument.ContentType := 'text/html';
        FParser := THtmlParser.Create(FDocument);
        FParser.SetTransportCharset(TransportCharset);
        FParser.ScriptHost := FScripts;
        FScripts.Parser := FParser;
        FKeepingBytes := True;
      end;
    ContentText:
      BuildTextDocument;
    ContentImage:
      BuildImageDocument;
    ContentXml:
      FDocument.IsXmlDocumentObject := True;
  end;
end;

{ The XML document from its bytes (the byte order mark, else the
  transport's charset, else UTF-8), or the parser error document. }
procedure TDocumentLoader.BuildXmlDocument;
var
  Encoding: TTextEncoding;
  MarkLength: Integer;
  Decoder: TTextDecoder;
  Buffer: TTextBuffer;
  Bytes, Error: string;
  Root: TElement;
begin
  Bytes := FXmlBytes;
  FXmlBytes := '';
  MarkLength := 0;
  if not SniffByteOrderMark(PByte(PChar(Bytes)), Length(Bytes), Encoding, MarkLength) then
    if (FTransportCharset = '') or not EncodingForLabel(FTransportCharset, Encoding) then
      Encoding := TextEncodingUtf8;
  if not IsDecodableEncoding(Encoding) then
    Encoding := TextEncodingUtf8;
  FDocument.CharacterSet := EncodingName(Encoding);
  Delete(Bytes, 1, MarkLength);
  Decoder := CreateDecoder(Encoding);
  Buffer := TTextBuffer.Create;
  try
    Decoder.Decode(PByte(PChar(Bytes)), Length(Bytes), Buffer, True);
    if ParseXmlInto(FDocument, Buffer.Text, Error) then
      Exit;
  finally
    Buffer.Free;
    Decoder.Free;
  end;
  FDocument.ReplaceChildren([]);
  Root := FDocument.CreateElementNS('http://www.mozilla.org/newlayout/xml/parsererror.xml', 'parsererror');
  Root.AppendChild(FDocument.CreateTextNode('XML Parsing Error: ' + Error));
  FDocument.AppendChild(Root);
end;

procedure TDocumentLoader.BuildTextDocument;
var
  Html, Head, Body, Pre: TElement;
begin
  Html := FDocument.CreateElement('html');
  Head := FDocument.CreateElement('head');
  Body := FDocument.CreateElement('body');
  Pre := FDocument.CreateElement('pre');
  FTextNode := FDocument.CreateTextNode('');
  Pre.AppendChild(FTextNode);
  Body.AppendChild(Pre);
  Html.AppendChild(Head);
  Html.AppendChild(Body);
  FDocument.AppendChild(Html);
  FTextBuffer := TTextBuffer.Create;
end;

procedure TDocumentLoader.BuildImageDocument;
var
  Html, Head, Body, Image, Title: TElement;
begin
  Html := FDocument.CreateElement('html');
  Head := FDocument.CreateElement('head');
  Title := FDocument.CreateElement('title');
  Title.AppendChild(FDocument.CreateTextNode(ExtractFileName(FDocumentUrl.Path)));
  Head.AppendChild(Title);
  Body := FDocument.CreateElement('body');
  Html.AppendChild(Head);
  Html.AppendChild(Body);
  FDocument.AppendChild(Html);
  Image := FDocument.CreateElement('img');
  Image.SetAttributeAtom(AtomSrc, NamespaceNone, FDocument.Url);
  Body.AppendChild(Image);
end;

procedure TDocumentLoader.AppendTextContent(Bytes: PByte; Count: SizeInt; Flush: Boolean);
var
  Encoding: TTextEncoding;
  MarkLength: Integer;
  Pending: string;
begin
  if FTextDecoder = nil then
  begin
    if not Flush and (Length(FTextPending) + Count < 3) then
    begin
      SetLength(Pending, Count);
      if Count > 0 then
        Move(Bytes^, Pending[1], Count);
      FTextPending := FTextPending + Pending;
      Exit;
    end;
    SetLength(Pending, Count);
    if Count > 0 then
      Move(Bytes^, Pending[1], Count);
    Pending := FTextPending + Pending;
    FTextPending := '';
    MarkLength := 0;
    if not SniffByteOrderMark(PByte(PChar(Pending)), Length(Pending), Encoding, MarkLength) then
    begin
      if (FTransportCharset = '') or not EncodingForLabel(FTransportCharset, Encoding) then
        Encoding := TextEncodingUtf8;
    end;
    if not IsDecodableEncoding(Encoding) then
      Encoding := TextEncodingWindows1252;
    FDocument.CharacterSet := EncodingName(Encoding);
    FTextDecoder := CreateDecoder(Encoding);
    Delete(Pending, 1, MarkLength);
    FTextBuffer.Clear;
    FTextDecoder.Decode(PByte(PChar(Pending)), Length(Pending), FTextBuffer, Flush);
  end
  else
  begin
    FTextBuffer.Clear;
    FTextDecoder.Decode(Bytes, Count, FTextBuffer, Flush);
  end;
  if FTextBuffer.Length > 0 then
    FTextNode.AppendData(FTextBuffer.Text);
end;

procedure TDocumentLoader.ParserCall(Bytes: PByte; Count: SizeInt; Finish, Resume: Boolean);
begin
  Inc(FInParser);
  EnterPhase(PhaseHtmlParse);
  try
    if Resume then
      FParser.Resume
    else if Finish then
      FParser.Finish
    else
      FParser.WriteBytes(Bytes, Count);
  finally
    LeavePhase;
    Dec(FInParser);
  end;
end;

procedure TDocumentLoader.ReceiveBytes(Data: Pointer; Count: PtrUInt);
var
  Chunk: string;
begin
  if FAborted or (Count = 0) then
    Exit;
  Inc(Times.BytesReceived, Count);
  case FContentKind of
    ContentText:
      AppendTextContent(Data, Count, False);
    ContentXml:
      begin
        SetString(Chunk, PChar(Data), Count);
        FXmlBytes := FXmlBytes + Chunk;
      end;
    ContentHtml:
      begin
        SetString(Chunk, PChar(Data), Count);
        if FKeepingBytes then
          FKeptBytes := FKeptBytes + Chunk;
        FScanPending := FScanPending + Chunk;
        ParserCall(Data, Count, False, False);
        CheckRestart;
        ScanIfBlocked;
        if FKeepingBytes and (FParser.Confidence <> ConfidenceTentative) then
        begin
          FKeepingBytes := False;
          FKeptBytes := '';
        end;
      end;
  end;
end;

{ The bytes the parser has not got to yet are scanned while it waits
  for a script; once it is running (and decoding) they are its own. }
procedure TDocumentLoader.ScanIfBlocked;
begin
  if FParser = nil then
    Exit;
  if FParser.Paused then
  begin
    if FScanPending <> '' then
      FScanner.Scan(FScanPending);
    FScanPending := '';
  end
  else if FParser.EncodingDecided then
    FScanPending := '';
end;

procedure TDocumentLoader.EndOfInput;
begin
  if FAborted or FInputEnded then
    Exit;
  FInputEnded := True;
  if Times.ResponseEnd = 0 then
    Times.ResponseEnd := GetTickCount64;
  case FContentKind of
    ContentHtml:
      begin
        ParserCall(nil, 0, True, False);
        CheckRestart;
        ScanIfBlocked;
        CheckParserEnded;
      end;
    ContentText:
      begin
        AppendTextContent(nil, 0, True);
        TheEnd;
      end;
    ContentXml:
      begin
        BuildXmlDocument;
        TheEnd;
      end;
  else
    TheEnd;
  end;
end;

procedure TDocumentLoader.CheckRestart;
begin
  if (FParser <> nil) and FParser.RestartRequested then
    Restart;
end;

procedure TDocumentLoader.Restart;
var
  Encoding: TTextEncoding;
  Bytes: string;
  Bom: TTextEncoding;
  MarkLength: Integer;
begin
  Encoding := FParser.RestartEncoding;
  Bytes := FKeptBytes;
  Inc(FRestarts);
  FreeAndNil(FParser);
  { The tree so far goes (its loads are cancelled as elements leave). }
  FDocument.ReplaceChildren([]);
  FParser := THtmlParser.Create(FDocument);
  FParser.ScriptHost := FScripts;
  FScripts.Parser := FParser;
  if SniffByteOrderMark(PByte(PChar(Bytes)), Length(Bytes), Bom, MarkLength) then
  begin
    Encoding := Bom;
    Delete(Bytes, 1, MarkLength);
  end;
  FParser.SetEncoding(Encoding, ConfidenceCertain);
  FKeepingBytes := False;
  FKeptBytes := '';
  if Assigned(FOnRestarted) then
    FOnRestarted(Self);
  ParserCall(PByte(PChar(Bytes)), Length(Bytes), False, False);
  if FInputEnded then
    ParserCall(nil, 0, True, False);
end;

procedure TDocumentLoader.CheckParserEnded;
begin
  if (FParser <> nil) and FParser.Ended and not FParsingDone then
    TheEnd;
end;

procedure TDocumentLoader.ParserResumeWanted(Sender: TObject);
begin
  { The parser goes on in a task of its own, never inside the script
    scheduler's call. }
  FLoop.QueueMethod(@ResumeParserTask, TaskSourceNetworking, Self);
end;

procedure TDocumentLoader.ResumeParserTask;
begin
  if FAborted or (FParser = nil) or not FParser.Paused then
    Exit;
  ParserCall(nil, 0, False, True);
  CheckRestart;
  CheckParserEnded;
end;

procedure TDocumentLoader.StyleSheetsUnblocked(Sender: TObject);
begin
  FScripts.StyleSheetsUnblocked;
end;

function TDocumentLoader.StyleSheetsBlockScripts: Boolean;
begin
  Result := FStyleSheets.BlockingCount > 0;
end;

procedure TDocumentLoader.TheEnd;
begin
  if FParsingDone or FAborted then
    Exit;
  FParsingDone := True;
  Times.DomInteractive := GetTickCount64;
  FDocument.ReadyState := ReadyStateInteractive;
  FIcons.Activate;
  if FScripts.Executor <> nil then
    FScripts.RunDeferredScripts
  else
    DeferredScriptsDone(Self);
end;

procedure TDocumentLoader.DeferredScriptsDone(Sender: TObject);
begin
  FLoop.QueueMethod(@FireDomContentLoaded, TaskSourceDomManipulation, Self);
end;

procedure TDocumentLoader.FireDomContentLoaded;
begin
  if FAborted or FDomContentLoadedFired then
    Exit;
  FDomContentLoadedFired := True;
  Times.DomContentLoadedStart := GetTickCount64;
  FireEvent(FDocument, 'DOMContentLoaded', True);
  Times.DomContentLoadedEnd := GetTickCount64;
  if Assigned(FOnDomContentLoaded) then
    FOnDomContentLoaded(Self);
  CheckLoadComplete;
end;

procedure TDocumentLoader.LoadDelaysGone(Sender: TObject);
begin
  CheckLoadComplete;
end;

procedure TDocumentLoader.CheckLoadComplete;
begin
  if FAborted or not FDomContentLoadedFired or FLoadQueued or (LoadDelays > 0) or
     (FScripts.PendingAsapCount > 0) then
    Exit;
  FLoadQueued := True;
  FLoop.QueueMethod(@FireLoad, TaskSourceDomManipulation, Self);
end;

procedure TDocumentLoader.FireLoad;
var
  Show: TPageTransitionEvent;
begin
  if FAborted or FLoadFired then
    Exit;
  FLoadFired := True;
  Times.DomComplete := GetTickCount64;
  FDocument.ReadyState := ReadyStateComplete;
  Times.LoadEventStart := GetTickCount64;
  if FWindow <> nil then
    FireEvent(FWindow, 'load');
  Times.LoadEventEnd := GetTickCount64;
  FPreloads.DropUnclaimed;
  FImages.LoadEventFired;
  if FWindow <> nil then
  begin
    Show := TPageTransitionEvent.Create('pageshow');
    Show.Persisted := False;
    FireTrustedEvent(FWindow, Show);
  end;
  if Assigned(FOnLoaded) then
    FOnLoaded(Self);
end;

procedure TDocumentLoader.Abort;
begin
  if FAborted then
    Exit;
  FAborted := True;
  if FScripts.Executor <> nil then
    FScripts.Executor.DocumentStopped(Self);
  FFetcher.CancelGroup(Self);
  FLoop.DiscardTasks(Self);
  FreeAndNil(FParser);
  FScripts.Parser := nil;
end;

function TDocumentLoader.DocumentWrite(const Text: string): Boolean;
begin
  Result := (FParser <> nil) and not FParser.Ended and (FInParser > 0);
  if Result then
    FParser.DocumentWrite(Text);
end;

procedure TDocumentLoader.HandleLinkChanged(Element: TElement);
var
  AsValue: string;
  Url: TUrlRecord;
  Request: TFetchRequest;
begin
  if FAborted then
    Exit;
  FStyleSheets.LinkChanged(Element, FInParser > 0);
  FIcons.LinkChanged(Element);
  if RelHasToken(Element, 'preload') and (Element.AttributeValueOf(AtomHref) <> '') and
     ResolveUrl(Element.AttributeValueOf(AtomHref), Url) then
  begin
    AsValue := AsciiLowerCase(Element.AttributeValueOf(Atomize('as')));
    if AsValue = 'style' then
      Request := NewRequest(Url, DestinationStyle, FetchModeNoCors, FetchCredentialsSameOrigin)
    else if AsValue = 'script' then
      Request := NewRequest(Url, DestinationScript, FetchModeNoCors, FetchCredentialsSameOrigin)
    else if AsValue = 'image' then
      Request := NewRequest(Url, DestinationImage, FetchModeNoCors, FetchCredentialsSameOrigin)
    else if AsValue = 'font' then
      Request := NewRequest(Url, DestinationFont, FetchModeCors, FetchCredentialsSameOrigin)
    else
      Exit;
    ApplyCorsSettings(Request, Element, Request.Mode);
    Request.CryptographicNonce := Element.AttributeValueOf(AtomNonce);
    if AsValue = 'font' then
      Request.Mode := FetchModeCors;
    if AsValue = 'image' then
      Request.SniffContent := True;
    FPreloads.Preload(Request, False);
  end;
end;

procedure TDocumentLoader.HandleLinkRemoved(Element: TElement);
begin
  FStyleSheets.LinkRemoved(Element);
  FIcons.LinkRemoved(Element);
end;

procedure TDocumentLoader.HandleMeta(Element: TElement);
var
  Equiv, Content, UrlText: string;
  Semicolon, Position: Integer;
  Delay: Double;
  Target: TUrlRecord;
begin
  Equiv := AsciiLowerCase(Element.AttributeValueOf(AtomHttpEquiv));
  Content := Element.AttributeValueOf(AtomContent);
  if AsciiLowerCase(Element.AttributeValueOf(AtomName)) = 'referrer' then
    FClient.ReferrerPolicy := ReferrerPolicyFromAttribute(Trim(Content))
  else if Equiv = 'content-security-policy' then
    FClient.Csp.AddFromMeta(Content)
  else if Equiv = 'refresh' then
  begin
    { "5; url=next.html", "0", "3;URL='x'" }
    Semicolon := Pos(';', Content);
    if Semicolon = 0 then
      Semicolon := Pos(',', Content);
    if Semicolon = 0 then
      Semicolon := Length(Content) + 1;
    if not TryStrToFloat(Trim(Copy(Content, 1, Semicolon - 1)), Delay) or (Delay < 0) then
      Exit;
    UrlText := Trim(Copy(Content, Semicolon + 1, MaxInt));
    if AsciiLowerCase(Copy(UrlText, 1, 3)) = 'url' then
    begin
      Position := 4;
      while (Position <= Length(UrlText)) and (UrlText[Position] = ' ') do
        Inc(Position);
      if (Position <= Length(UrlText)) and (UrlText[Position] = '=') then
        UrlText := Trim(Copy(UrlText, Position + 1, MaxInt));
    end;
    if (Length(UrlText) >= 2) and (UrlText[1] in ['''', '"']) and (UrlText[Length(UrlText)] = UrlText[1]) then
      UrlText := Copy(UrlText, 2, Length(UrlText) - 2);
    if UrlText = '' then
      Target := FDocumentUrl
    else if not ResolveUrl(UrlText, Target) then
      Exit;
    if Assigned(FOnRefresh) then
      FOnRefresh(Self, Delay, Target);
  end;
end;

procedure TDocumentLoader.HandleFrame(Event: TLoaderFrameEvent; Element: TElement; Attribute: TAtom);
begin
  if Assigned(Event) and (not FAborted or (Event = FOnFrameRemoved)) then
    Event(Self, Element, Attribute);
end;

procedure TDocumentLoader.SetOrigin(constref Origin: TUrlOrigin);
begin
  FClient.Origin := Origin;
  FClient.IsSecureContext := OriginIsPotentiallyTrustworthy(Origin);
  SetDocumentOrigin(FDocument, Origin);
end;

procedure TDocumentLoader.HandleTitleMayHaveChanged;
begin
  if FTitleCheckQueued or FAborted then
    Exit;
  FTitleCheckQueued := True;
  FLoop.QueueMethod(@CheckTitle, TaskSourceDomManipulation, Self);
end;

procedure TDocumentLoader.CheckTitle;
var
  Title: string;
begin
  FTitleCheckQueued := False;
  Title := FDocument.Title;
  if Title = FLastTitle then
    Exit;
  FLastTitle := Title;
  if Assigned(FOnTitleChanged) then
    FOnTitleChanged(Self, Title);
end;

procedure TDocumentLoader.SheetReady(Owner: TElement; Sheet: TCssStyleSheet);
begin
  if FSettings.LoadFontsEagerly then
    FFonts.LoadFacesOf(Sheet);
end;

procedure TDocumentLoader.SheetGoing(Sheet: TCssStyleSheet);
begin
  FFonts.ForgetSheet(Sheet);
end;

procedure TDocumentLoader.IconChanged(const Url: string; Image: TImage);
begin
  if Assigned(FOnIconChanged) then
    FOnIconChanged(Self, Url, Image)
  else
    Image.Free;
end;

procedure TDocumentLoader.LoadImportsOf(Owner: TElement; Sheet: TCssStyleSheet);
begin
  FStyleSheets.LoadImportsOf(Owner, Sheet, BaseUrl);
end;

procedure TDocumentLoader.LoadLazyImage(Element: TElement);
begin
  FImages.LoadLazyImage(Element);
end;

procedure TDocumentLoader.EnvironmentChanged;
begin
  FImages.EnvironmentChanged;
end;

end.
