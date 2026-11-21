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
  A document's resources: what the loader hands to styling and layout.

  The loader (Web.Loading) fetches and decodes; this object only keeps
  the results and tells styling and layout that they changed:

  - style sheets: a <link rel=stylesheet>'s sheet (SetElementStyleSheet,
    parsed with libcss's ParseStyleSheet, given to this object, which
    frees it), and user sheets (AddUserStyleSheet). Imported sheets hang
    on their @import rules (TCssImportRule.StyleSheet); after filling
    them the loader calls StyleSheetsChanged. OnImportsNeeded asks for
    the imports of sheets made here (from <style> elements).
  - images: an element's own image (<img>, <input type=image>, <video
    poster>, <object>: SetElementImage, with the natural size the
    loader computed when the pixels were scaled down or have a density)
    and images named by url() in
    style (background-image, list-style-image, content: SetUrlImage, by
    the URL text as written, with the base it is relative to given in
    OnImageNeeded). Images are owned here.
  - frames: what an iframe (or frame) shows, a TEmbeddedContent its
    owner (Web.Frames.Views) sets and takes away (SetElementFrame; not
    owned here).

  DocumentResourcesOf(Document) finds (or makes) a document's object,
  so the loader and the layout need not know about each other.
}
unit Web.Layout.Resources;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Stylesheets, Image.Model, Web.Layout.EmbeddedContent;

type
  { rcFonts: the font library gained faces (@font-face): text is
    measured again. }
  TResourceChange = (rcStyleSheets, rcImages, rcFonts, rcFrames);

  TResourceListener = procedure(Change: TResourceChange) of object;
  { A url() image is wanted (once per URL text): Url as written, BaseUrl
    the URL it is relative to (the sheet's, else the document's). }
  TImageNeededEvent = procedure(const Url, BaseUrl: string) of object;
  { A sheet made from a <style> element has @import rules to load. }
  TImportsNeededEvent = procedure(Sheet: TCssStyleSheet; Owner: TElement) of object;

  TElementSheet = record
    Owner: TElement;
    Sheet: TCssStyleSheet;
  end;

  TElementImage = record
    Element: TElement;
    Image: TImage;
    { CSS pixels; 0 when the image's own size is its natural size. }
    NaturalWidth, NaturalHeight: Single;
  end;

  TElementFrame = record
    Element: TElement;
    Content: TEmbeddedContent;
  end;

  TUrlImage = record
    Url: string;
    Image: TImage;
    Requested: Boolean;
  end;

  TDocumentResources = class
  private
    FDocument: TDocument;
    FElementSheets: array of TElementSheet;
    FUserSheets: array of TCssStyleSheet;
    FElementImages: array of TElementImage;
    FUrlImages: array of TUrlImage;
    FFrames: array of TElementFrame;
    FListeners: array of TResourceListener;
    FOnImageNeeded: TImageNeededEvent;
    FOnImportsNeeded: TImportsNeededEvent;
    procedure Notify(Change: TResourceChange);
    function FindElementImage(Element: TElement): Integer;
    function FindUrlImage(const Url: string): Integer;
  public
    constructor Create(Document: TDocument);
    destructor Destroy; override;
    { The sheet of a <link> (or other owner); nil removes it. Takes Sheet. }
    procedure SetElementStyleSheet(Owner: TElement; Sheet: TCssStyleSheet);
    function ElementStyleSheet(Owner: TElement): TCssStyleSheet;
    { A user origin sheet (taken). }
    procedure AddUserStyleSheet(Sheet: TCssStyleSheet);
    function UserStyleSheetCount: Integer;
    function UserStyleSheet(Index: Integer): TCssStyleSheet;
    { Imported sheets were filled in. }
    procedure StyleSheetsChanged;
    { An element's image; nil removes it. Takes Image. }
    procedure SetElementImage(Element: TElement; Image: TImage); overload;
    { The same with the natural size in CSS pixels (a downscaled image,
      a srcset density). }
    procedure SetElementImage(Element: TElement; Image: TImage; NaturalWidth, NaturalHeight: Single); overload;
    function ElementImage(Element: TElement): TImage;
    { The natural size given with the element's image; False when none
      was given (the image's pixel size is its natural size). }
    function ElementImageNaturalSize(Element: TElement; out Width, Height: Single): Boolean;
    { What a frame element shows (nil: nothing); not taken. }
    procedure SetElementFrame(Element: TElement; Content: TEmbeddedContent);
    function ElementFrame(Element: TElement): TEmbeddedContent;
    function FrameCount: Integer;
    function FrameElementAt(Index: Integer): TElement;
    function FrameContentAt(Index: Integer): TEmbeddedContent;
    { The font library changed (web fonts): layouts measure text again. }
    procedure FontsChanged;
    { A url() image by its URL text; takes Image. }
    procedure SetUrlImage(const Url: string; Image: TImage);
    { The image for Url, nil (and asked for once) while it is missing. }
    function UrlImage(const Url, BaseUrl: string): TImage;
    { Styling and layout listen. }
    procedure AddListener(Listener: TResourceListener);
    procedure RemoveListener(Listener: TResourceListener);
    { For sheets made here (from <style>). }
    procedure RequestImports(Sheet: TCssStyleSheet; Owner: TElement);
    { Forget what belongs to an element that left the document. }
    procedure ElementRemoved(Element: TElement);
    property Document: TDocument read FDocument;
    property OnImageNeeded: TImageNeededEvent read FOnImageNeeded write FOnImageNeeded;
    property OnImportsNeeded: TImportsNeededEvent read FOnImportsNeeded write FOnImportsNeeded;
  end;

{ The document's resources, made when first asked for. }
function DocumentResourcesOf(Document: TDocument): TDocumentResources;
{ Frees the document's resources (when the document goes). }
procedure FreeDocumentResources(Document: TDocument);
{ Tells every document's listeners that the font library changed (the
  library is the process's, so every document measures again). }
procedure NotifyFontsChanged;

implementation

uses
  Web.Style.DocumentSheets;

var
  AllResources: array of TDocumentResources;

function DocumentResourcesOf(Document: TDocument): TDocumentResources;
var
  Index: Integer;
begin
  for Index := 0 to High(AllResources) do
    if AllResources[Index].Document = Document then
      Exit(AllResources[Index]);
  Result := TDocumentResources.Create(Document);
  SetLength(AllResources, Length(AllResources) + 1);
  AllResources[High(AllResources)] := Result;
end;

procedure FreeDocumentResources(Document: TDocument);
var
  Index: Integer;
begin
  for Index := 0 to High(AllResources) do
    if AllResources[Index].Document = Document then
    begin
      AllResources[Index].Free;
      AllResources[Index] := AllResources[High(AllResources)];
      SetLength(AllResources, Length(AllResources) - 1);
      Exit;
    end;
end;

procedure NotifyFontsChanged;
var
  Index: Integer;
begin
  for Index := 0 to High(AllResources) do
    AllResources[Index].FontsChanged;
end;

constructor TDocumentResources.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
end;

destructor TDocumentResources.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FElementSheets) do
    if ExistingDocumentSheets(FDocument) <> nil then
      ExistingDocumentSheets(FDocument).SetLinkSheet(FElementSheets[Index].Owner, nil);
  for Index := 0 to High(FElementSheets) do
    FElementSheets[Index].Sheet.Free;
  for Index := 0 to High(FUserSheets) do
    FUserSheets[Index].Free;
  for Index := 0 to High(FElementImages) do
    FElementImages[Index].Image.Free;
  for Index := 0 to High(FUrlImages) do
    FUrlImages[Index].Image.Free;
  inherited Destroy;
end;

procedure TDocumentResources.Notify(Change: TResourceChange);
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    FListeners[Index](Change);
end;

procedure TDocumentResources.SetElementStyleSheet(Owner: TElement; Sheet: TCssStyleSheet);
var
  Index: Integer;
begin
  DocumentSheetsOf(FDocument).SetLinkSheet(Owner, Sheet);
  for Index := 0 to High(FElementSheets) do
    if FElementSheets[Index].Owner = Owner then
    begin
      if FElementSheets[Index].Sheet <> Sheet then
        FElementSheets[Index].Sheet.Free;
      if Sheet = nil then
      begin
        FElementSheets[Index] := FElementSheets[High(FElementSheets)];
        SetLength(FElementSheets, Length(FElementSheets) - 1);
      end
      else
        FElementSheets[Index].Sheet := Sheet;
      Notify(rcStyleSheets);
      Exit;
    end;
  if Sheet = nil then
    Exit;
  SetLength(FElementSheets, Length(FElementSheets) + 1);
  FElementSheets[High(FElementSheets)].Owner := Owner;
  FElementSheets[High(FElementSheets)].Sheet := Sheet;
  Notify(rcStyleSheets);
end;

function TDocumentResources.ElementStyleSheet(Owner: TElement): TCssStyleSheet;
var
  Index: Integer;
begin
  for Index := 0 to High(FElementSheets) do
    if FElementSheets[Index].Owner = Owner then
      Exit(FElementSheets[Index].Sheet);
  Result := nil;
end;

procedure TDocumentResources.AddUserStyleSheet(Sheet: TCssStyleSheet);
begin
  SetLength(FUserSheets, Length(FUserSheets) + 1);
  FUserSheets[High(FUserSheets)] := Sheet;
  Notify(rcStyleSheets);
end;

function TDocumentResources.UserStyleSheetCount: Integer;
begin
  Result := Length(FUserSheets);
end;

function TDocumentResources.UserStyleSheet(Index: Integer): TCssStyleSheet;
begin
  Result := FUserSheets[Index];
end;

procedure TDocumentResources.StyleSheetsChanged;
begin
  Notify(rcStyleSheets);
end;

function TDocumentResources.FindElementImage(Element: TElement): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FElementImages) do
    if FElementImages[Index].Element = Element then
      Exit(Index);
  Result := -1;
end;

function TDocumentResources.FindUrlImage(const Url: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FUrlImages) do
    if FUrlImages[Index].Url = Url then
      Exit(Index);
  Result := -1;
end;

procedure TDocumentResources.SetElementImage(Element: TElement; Image: TImage);
begin
  SetElementImage(Element, Image, 0, 0);
end;

procedure TDocumentResources.SetElementImage(Element: TElement; Image: TImage; NaturalWidth, NaturalHeight: Single);
var
  Index: Integer;
begin
  Index := FindElementImage(Element);
  if Index >= 0 then
  begin
    if FElementImages[Index].Image <> Image then
      FElementImages[Index].Image.Free;
    if Image = nil then
    begin
      FElementImages[Index] := FElementImages[High(FElementImages)];
      SetLength(FElementImages, Length(FElementImages) - 1);
    end
    else
    begin
      FElementImages[Index].Image := Image;
      FElementImages[Index].NaturalWidth := NaturalWidth;
      FElementImages[Index].NaturalHeight := NaturalHeight;
    end;
  end
  else if Image <> nil then
  begin
    SetLength(FElementImages, Length(FElementImages) + 1);
    FElementImages[High(FElementImages)].Element := Element;
    FElementImages[High(FElementImages)].Image := Image;
    FElementImages[High(FElementImages)].NaturalWidth := NaturalWidth;
    FElementImages[High(FElementImages)].NaturalHeight := NaturalHeight;
  end;
  Notify(rcImages);
end;

function TDocumentResources.ElementImageNaturalSize(Element: TElement; out Width, Height: Single): Boolean;
var
  Index: Integer;
begin
  Width := 0;
  Height := 0;
  Index := FindElementImage(Element);
  if Index < 0 then
    Exit(False);
  Width := FElementImages[Index].NaturalWidth;
  Height := FElementImages[Index].NaturalHeight;
  Result := (Width > 0) and (Height > 0);
end;

procedure TDocumentResources.SetElementFrame(Element: TElement; Content: TEmbeddedContent);
var
  Index: Integer;
begin
  for Index := 0 to High(FFrames) do
    if FFrames[Index].Element = Element then
    begin
      if FFrames[Index].Content = Content then
        Exit;
      if Content = nil then
      begin
        FFrames[Index] := FFrames[High(FFrames)];
        SetLength(FFrames, Length(FFrames) - 1);
      end
      else
        FFrames[Index].Content := Content;
      Notify(rcFrames);
      Exit;
    end;
  if Content = nil then
    Exit;
  SetLength(FFrames, Length(FFrames) + 1);
  FFrames[High(FFrames)].Element := Element;
  FFrames[High(FFrames)].Content := Content;
  Notify(rcFrames);
end;

function TDocumentResources.ElementFrame(Element: TElement): TEmbeddedContent;
var
  Index: Integer;
begin
  for Index := 0 to High(FFrames) do
    if FFrames[Index].Element = Element then
      Exit(FFrames[Index].Content);
  Result := nil;
end;

function TDocumentResources.FrameCount: Integer;
begin
  Result := Length(FFrames);
end;

function TDocumentResources.FrameElementAt(Index: Integer): TElement;
begin
  Result := FFrames[Index].Element;
end;

function TDocumentResources.FrameContentAt(Index: Integer): TEmbeddedContent;
begin
  Result := FFrames[Index].Content;
end;

procedure TDocumentResources.FontsChanged;
begin
  Notify(rcFonts);
end;

function TDocumentResources.ElementImage(Element: TElement): TImage;
var
  Index: Integer;
begin
  Index := FindElementImage(Element);
  if Index < 0 then
    Result := nil
  else
    Result := FElementImages[Index].Image;
end;

procedure TDocumentResources.SetUrlImage(const Url: string; Image: TImage);
var
  Index: Integer;
begin
  Index := FindUrlImage(Url);
  if Index < 0 then
  begin
    SetLength(FUrlImages, Length(FUrlImages) + 1);
    Index := High(FUrlImages);
    FUrlImages[Index].Url := Url;
    FUrlImages[Index].Requested := True;
  end
  else if FUrlImages[Index].Image <> Image then
    FUrlImages[Index].Image.Free;
  FUrlImages[Index].Image := Image;
  Notify(rcImages);
end;

function TDocumentResources.UrlImage(const Url, BaseUrl: string): TImage;
var
  Index: Integer;
begin
  Index := FindUrlImage(Url);
  if Index >= 0 then
    Exit(FUrlImages[Index].Image);
  Result := nil;
  SetLength(FUrlImages, Length(FUrlImages) + 1);
  Index := High(FUrlImages);
  FUrlImages[Index].Url := Url;
  FUrlImages[Index].Requested := True;
  if Assigned(FOnImageNeeded) then
  begin
    FOnImageNeeded(Url, BaseUrl);
    { A loader that has it at hand gives it at once. }
    Index := FindUrlImage(Url);
    if Index >= 0 then
      Result := FUrlImages[Index].Image;
  end;
end;

procedure TDocumentResources.AddListener(Listener: TResourceListener);
begin
  SetLength(FListeners, Length(FListeners) + 1);
  FListeners[High(FListeners)] := Listener;
end;

procedure TDocumentResources.RemoveListener(Listener: TResourceListener);
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    if (TMethod(FListeners[Index]).Code = TMethod(Listener).Code) and
       (TMethod(FListeners[Index]).Data = TMethod(Listener).Data) then
    begin
      FListeners[Index] := FListeners[High(FListeners)];
      SetLength(FListeners, Length(FListeners) - 1);
      Exit;
    end;
end;

procedure TDocumentResources.RequestImports(Sheet: TCssStyleSheet; Owner: TElement);
begin
  if Assigned(FOnImportsNeeded) then
    FOnImportsNeeded(Sheet, Owner);
end;

procedure TDocumentResources.ElementRemoved(Element: TElement);
var
  Index: Integer;
begin
  Index := FindElementImage(Element);
  if Index >= 0 then
  begin
    FElementImages[Index].Image.Free;
    FElementImages[Index] := FElementImages[High(FElementImages)];
    SetLength(FElementImages, Length(FElementImages) - 1);
  end;
  for Index := 0 to High(FElementSheets) do
    if FElementSheets[Index].Owner = Element then
    begin
      DocumentSheetsOf(FDocument).SetLinkSheet(Element, nil);
      FElementSheets[Index].Sheet.Free;
      FElementSheets[Index] := FElementSheets[High(FElementSheets)];
      SetLength(FElementSheets, Length(FElementSheets) - 1);
      Exit;
    end;
end;

end.
