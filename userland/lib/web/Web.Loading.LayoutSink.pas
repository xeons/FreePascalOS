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
  The resource sink that renders: what the loader delivers goes into
  the document's resources (Web.Layout.Resources), which styling and
  layout listen to, so a TWebPage and a TDocumentLayout show a fetched
  page with its style sheets, images and fonts.

    Sink := TLayoutResourceSink.Create;
    Page := TWebPage.Create(Network, Sink);
    Sink.AttachNavigable(Page.Navigable);
    Sink.SetViewport(WidthCss, HeightCss, PixelRatio);  // media queries, srcset

  - <link> sheets (their imports already hung on the rules) become the
    elements' sheets; a <style> sheet's imports are asked of the loader
    (OnImportsNeeded) and announced when in place.
  - <img> images become the elements' images with the natural size the
    loader computed (scaled down pixels, srcset densities).
  - url() images in style (backgrounds, list images, content) are
    fetched when the layout first asks for one (OnImageNeeded), no-cors
    with image sniffing through the active document's loader, decoded
    on the page thread and given under the URL text as written.
  - @font-face sources: TrueType, OpenType (TrueType or CFF outlines),
    collections, WOFF 1 and WOFF2 (unwrapped, Web.Text.Woff) are added
    to the process's font library under the rule's family, weight and
    style; the fonts made from styles pick their faces again and every
    layout measures text again.
  - Deliveries for a document that is no longer the navigable's active
    one are dropped (their objects freed).

  The web view calls DocumentGoing before it frees a document's layout
  and resources: url() fetches for it stop.
}
unit Web.Loading.LayoutSink;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Css.MediaQueries,
  Css.Stylesheets,
  Image.Model,
  Web.Dom,
  Web.Loading.ResourceSink,
  Web.Loading.BufferedFetches,
  Web.Navigation.Navigables;

type
  TLayoutResourceSink = class;

  { A url() image on its way. }
  TStyleImageFetch = class
  public
    Sink: TLayoutResourceSink;
    Document: TDocument;
    UrlText: string;
    Fetch: TBufferedFetch;
  end;

  TLayoutResourceSink = class(TResourceSink)
  private
    FNavigable: TNavigable;
    FEnvironment: TCssMediaEnvironment;
    FAttached: TDocument;
    FStyleImages: TList;
    FLoadedFontKeys: TStringList;
    { A child sink's frame view (owned). }
    FFrameView: TObject;
    function Accepts(Document: TDocument): Boolean;
    procedure Attach(Document: TDocument);
    procedure UrlImageNeeded(const Url, BaseUrl: string);
    procedure ImportsNeeded(Sheet: TCssStyleSheet; Owner: TElement);
    procedure StyleImageComplete(Fetch: TBufferedFetch; Success: Boolean);
    procedure CancelStyleImages(Document: TDocument);
  public
    constructor Create;
    destructor Destroy; override;
    { The navigable whose active document's loader fetches url()
      images and imports (nil: deliveries are taken for any document,
      and nothing is fetched). }
    procedure AttachNavigable(Navigable: TNavigable);
    { Hooks the document's resources (url() images, <style> imports);
      done on the first delivery anyway, and by the web view as soon as
      a document becomes active. }
    procedure PrepareDocument(Document: TDocument);
    { The document is going: its url() fetches stop, its resources are
      unhooked (the caller frees layout and resources after this). }
    procedure DocumentGoing(Document: TDocument);
    { The viewport in CSS pixels and the device pixel ratio (media
      queries of links, srcset and sizes); the loader chooses again. }
    procedure SetViewport(Width, Height, Ratio: Double);
    procedure SetDarkColorScheme(Dark: Boolean);
    procedure StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure StyleSheetRemoved(Owner: TElement); override;
    procedure ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo); override;
    procedure ImageFailed(Element: TElement); override;
    procedure ImageRemoved(Element: TElement); override;
    procedure FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
      const Url: string); override;
    procedure FontFailed(Rule: TCssFontFaceRule; const Family: string); override;
    function FontFormatSupported(const Format: string): Boolean; override;
    function MediaEnvironment: TCssMediaEnvironment; override;
    { A rendering sink for an iframe's navigable, with the frame view
      (Web.Frames.Views) that lays it out and paints it into the frame. }
    function CreateChildSink(Navigable: TObject): TResourceSink; override;
    function NavigableObserver: TObject; override;
    { url() images still being fetched. }
    function PendingStyleImageCount: Integer;
    property Navigable: TNavigable read FNavigable;
  end;

{ A @font-face weight descriptor as a number (the first of a range). }
function FontFaceWeight(const Text: string): Integer;
{ Whether a @font-face style descriptor asks for a slanted face. }
function FontFaceItalic(const Text: string): Boolean;

implementation

uses
  Url.Records,
  Url.Parser,
  Font.TrueType,
  Image.Errors,
  Image.Files,
  Image.StandardCodecs,
  Web.Fetch.Requests,
  Web.Loading.Documents,
  Web.Layout.Resources,
  Web.Text.Fonts,
  Web.Text.FontInstances,
  Web.Text.Woff,
  Web.Text.UnicodeRanges,
  Web.Frames.Views;

function FontFaceWeight(const Text: string): Integer;
var
  Words: TStringArray;
  First: string;
begin
  Result := 400;
  Words := LowerCase(Trim(Text)).Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(Words) = 0 then
    Exit;
  First := Words[0];
  if First = 'bold' then
    Result := 700
  else if (First = 'normal') or (First = 'auto') then
    Result := 400
  else
    Result := StrToIntDef(First, 400);
  if (Result < 1) or (Result > 1000) then
    Result := 400;
end;

function FontFaceItalic(const Text: string): Boolean;
var
  Lowered: string;
begin
  Lowered := LowerCase(Trim(Text));
  Result := (Pos('italic', Lowered) = 1) or (Pos('oblique', Lowered) = 1);
end;

constructor TLayoutResourceSink.Create;
begin
  inherited Create;
  FEnvironment := ScreenMediaEnvironment(1024, 768, 1);
  FStyleImages := TList.Create;
  FLoadedFontKeys := TStringList.Create;
  FLoadedFontKeys.Sorted := True;
  RegisterStandardImageCodecs;
end;

destructor TLayoutResourceSink.Destroy;
begin
  FFrameView.Free;
  CancelStyleImages(nil);
  FStyleImages.Free;
  FLoadedFontKeys.Free;
  inherited Destroy;
end;

procedure TLayoutResourceSink.AttachNavigable(Navigable: TNavigable);
begin
  FNavigable := Navigable;
end;

function TLayoutResourceSink.Accepts(Document: TDocument): Boolean;
begin
  if Document = nil then
    Exit(False);
  if FNavigable = nil then
    Exit(True);
  Result := Document = FNavigable.ActiveDocument;
end;

procedure TLayoutResourceSink.Attach(Document: TDocument);
var
  Resources: TDocumentResources;
begin
  if Document = FAttached then
    Exit;
  FAttached := Document;
  Resources := DocumentResourcesOf(Document);
  Resources.OnImageNeeded := @UrlImageNeeded;
  Resources.OnImportsNeeded := @ImportsNeeded;
end;

procedure TLayoutResourceSink.PrepareDocument(Document: TDocument);
begin
  if Document <> nil then
    Attach(Document);
end;

procedure TLayoutResourceSink.DocumentGoing(Document: TDocument);
var
  Resources: TDocumentResources;
begin
  CancelStyleImages(Document);
  if Document = FAttached then
  begin
    Resources := DocumentResourcesOf(Document);
    Resources.OnImageNeeded := nil;
    Resources.OnImportsNeeded := nil;
    FAttached := nil;
  end;
end;

procedure TLayoutResourceSink.SetViewport(Width, Height, Ratio: Double);
var
  Dark: Boolean;
begin
  if (FEnvironment.Width = Width) and (FEnvironment.Height = Height) and (FEnvironment.Resolution = Ratio) then
    Exit;
  Dark := FEnvironment.DarkColorScheme;
  FEnvironment := ScreenMediaEnvironment(Width, Height, Ratio);
  FEnvironment.DarkColorScheme := Dark;
  if (FNavigable <> nil) and (FNavigable.Loader <> nil) then
    FNavigable.Loader.EnvironmentChanged;
end;

procedure TLayoutResourceSink.SetDarkColorScheme(Dark: Boolean);
begin
  FEnvironment.DarkColorScheme := Dark;
end;

function TLayoutResourceSink.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := FEnvironment;
end;

function TLayoutResourceSink.CreateChildSink(Navigable: TObject): TResourceSink;
var
  Child: TLayoutResourceSink;
begin
  Child := TLayoutResourceSink.Create;
  Child.FEnvironment := ScreenMediaEnvironment(300, 150, FEnvironment.Resolution);
  Child.FEnvironment.DarkColorScheme := FEnvironment.DarkColorScheme;
  Child.AttachNavigable(TNavigable(Navigable));
  Child.FFrameView := TFrameView.Create(TNavigable(Navigable), Child);
  Result := Child;
end;

function TLayoutResourceSink.NavigableObserver: TObject;
begin
  if FFrameView = nil then
    Result := nil
  else
    Result := TFrameView(FFrameView).Observer;
end;

{ ---- style sheets ---- }

procedure TLayoutResourceSink.StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
  if not Accepts(Owner.OwnerDocument) then
  begin
    Sheet.Free;
    Exit;
  end;
  Attach(Owner.OwnerDocument);
  DocumentResourcesOf(Owner.OwnerDocument).SetElementStyleSheet(Owner, Sheet);
end;

procedure TLayoutResourceSink.StyleSheetRemoved(Owner: TElement);
begin
  if not Accepts(Owner.OwnerDocument) then
    Exit;
  DocumentResourcesOf(Owner.OwnerDocument).SetElementStyleSheet(Owner, nil);
end;

procedure TLayoutResourceSink.ImportsNeeded(Sheet: TCssStyleSheet; Owner: TElement);
begin
  if (FNavigable = nil) or (FNavigable.Loader = nil) or (FNavigable.Loader.Document <> Owner.OwnerDocument) then
    Exit;
  FNavigable.Loader.LoadImportsOf(Owner, Sheet);
end;

procedure TLayoutResourceSink.ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
  if not Accepts(Owner.OwnerDocument) then
    Exit;
  DocumentResourcesOf(Owner.OwnerDocument).StyleSheetsChanged;
end;

{ ---- element images ---- }

procedure TLayoutResourceSink.ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo);
var
  NaturalWidth, NaturalHeight: Single;
begin
  if not Accepts(Element.OwnerDocument) then
  begin
    Image.Free;
    Exit;
  end;
  Attach(Element.OwnerDocument);
  NaturalWidth := 0;
  NaturalHeight := 0;
  { The natural size only when it is not the pixels' own. }
  if (Info.NaturalWidth > 0) and (Info.NaturalHeight > 0) and
     ((Abs(Info.NaturalWidth - Image.Width) > 0.01) or (Abs(Info.NaturalHeight - Image.Height) > 0.01)) then
  begin
    NaturalWidth := Info.NaturalWidth;
    NaturalHeight := Info.NaturalHeight;
  end;
  DocumentResourcesOf(Element.OwnerDocument).SetElementImage(Element, Image, NaturalWidth, NaturalHeight);
end;

procedure TLayoutResourceSink.ImageFailed(Element: TElement);
begin
  if not Accepts(Element.OwnerDocument) then
    Exit;
  DocumentResourcesOf(Element.OwnerDocument).SetElementImage(Element, nil);
end;

procedure TLayoutResourceSink.ImageRemoved(Element: TElement);
begin
  if not Accepts(Element.OwnerDocument) then
    Exit;
  DocumentResourcesOf(Element.OwnerDocument).SetElementImage(Element, nil);
end;

{ ---- url() images ---- }

procedure TLayoutResourceSink.UrlImageNeeded(const Url, BaseUrl: string);
var
  Loader: TDocumentLoader;
  Base, Target: TUrlRecord;
  Request: TFetchRequest;
  Pending: TStyleImageFetch;
  Resolved: Boolean;
begin
  if FNavigable = nil then
    Exit;
  Loader := FNavigable.Loader;
  if (Loader = nil) or (Loader.Document <> FAttached) then
    Exit;
  if (BaseUrl <> '') and ParseUrl(BaseUrl, Base) then
    Resolved := ParseUrl(Url, Base, Target)
  else
    Resolved := Loader.ResolveUrl(Url, Target);
  if not Resolved then
    Exit;
  Request := Loader.NewRequest(Target, DestinationImage, FetchModeNoCors, FetchCredentialsSameOrigin);
  Request.InitiatorType := 'css';
  Request.SniffContent := True;
  Pending := TStyleImageFetch.Create;
  Pending.Sink := Self;
  Pending.Document := FAttached;
  Pending.UrlText := Url;
  Pending.Fetch := TBufferedFetch.Create(@StyleImageComplete);
  Pending.Fetch.Data := Pending;
  FStyleImages.Add(Pending);
  Pending.Fetch.Start(Loader.Fetcher, Request, Loader);
end;

procedure TLayoutResourceSink.StyleImageComplete(Fetch: TBufferedFetch; Success: Boolean);
var
  Pending: TStyleImageFetch;
  Body: string;
  Bytes: TBytes;
  Image: TImage;
  Reason: TImageErrorReason;
begin
  Pending := TStyleImageFetch(Fetch.Data);
  FStyleImages.Remove(Pending);
  Body := Fetch.Body;
  Fetch.Free;
  try
    if not Success or (Body = '') or not Accepts(Pending.Document) then
      Exit;
    Bytes := nil;
    SetLength(Bytes, Length(Body));
    Move(Body[1], Bytes[0], Length(Body));
    if TryLoadImage(Bytes, Image, Reason, [ImageLoadApplyOrientation, ImageLoadConvertToSrgb]) then
      DocumentResourcesOf(Pending.Document).SetUrlImage(Pending.UrlText, Image);
  finally
    Pending.Free;
  end;
end;

procedure TLayoutResourceSink.CancelStyleImages(Document: TDocument);
var
  Index: Integer;
  Pending: TStyleImageFetch;
begin
  for Index := FStyleImages.Count - 1 downto 0 do
  begin
    Pending := TStyleImageFetch(FStyleImages[Index]);
    if (Document = nil) or (Pending.Document = Document) then
    begin
      FStyleImages.Delete(Index);
      Pending.Fetch.Cancel;
      Pending.Fetch.Free;
      Pending.Free;
    end;
  end;
end;

function TLayoutResourceSink.PendingStyleImageCount: Integer;
begin
  Result := FStyleImages.Count;
end;

{ ---- fonts ---- }

function TLayoutResourceSink.FontFormatSupported(const Format: string): Boolean;
begin
  Result := (Format = '') or (Format = 'truetype') or (Format = 'opentype') or (Format = 'woff') or
    (Format = 'woff2') or (Format = 'collection');
end;

procedure TLayoutResourceSink.FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
  const Url: string);
var
  Sfnt: TBytes;
  Font: TTrueTypeFont;
  Weight: Integer;
  Italic: Boolean;
  Key: string;
  Face: TFontFaceEntry;
begin
  Weight := FontFaceWeight(Rule.DescriptorText('font-weight'));
  Italic := FontFaceItalic(Rule.DescriptorText('font-style'));
  Key := LowerCase(Family) + '|' + IntToStr(Weight) + '|' + BoolToStr(Italic, True) + '|' + Url;
  if FLoadedFontKeys.IndexOf(Key) >= 0 then
    Exit;
  Sfnt := WebFontToSfnt(Data);
  if Sfnt = nil then
    Exit;
  Font := LoadTrueTypeFont(Sfnt);
  if Font = nil then
    Exit;
  FLoadedFontKeys.Add(Key);
  Face := TFontFaceEntry.CreateFromFont(LowerCase(Trim(Family)), Font, Weight, Italic);
  Face.Ranges := ParseUnicodeRanges(Rule.DescriptorText('unicode-range'));
  WebFontLibrary.AddFace(Face);
  if RefreshTextFonts then
    NotifyFontsChanged;
end;

procedure TLayoutResourceSink.FontFailed(Rule: TCssFontFaceRule; const Family: string);
begin
  { The family falls back to the next in the font-family list. }
end;

end.
