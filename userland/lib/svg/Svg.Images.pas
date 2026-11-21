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
  SVG as an image: TSvgImage, a scalable image (Image.Scalable) over an
  SVG document, and the SVG codec of libimage's registry, so whatever
  loads pictures through libimage (the web engine's <img>, CSS
  backgrounds and icons, the image viewer) reads SVG files too: a
  program that uses this unit has the codec registered when it starts.

  The image's own pixels are a rendering at its natural size (or the
  default object size, Image.Scalable); RenderedAt draws it again at
  any other size, the viewport stretched over it and a root without a
  viewBox given one from its width and height, as browsers draw SVG
  images.
}
unit Svg.Images;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs,
  Image.Scalable,
  Svg.Document;

type
  TSvgImage = class(TScalableImage)
  private
    FDocument: TSvgDocument;
    FViewportWidth: Double;
    FViewportHeight: Double;
    procedure Prepare(Document: TSvgDocument);
  protected
    procedure RenderBase; override;
  public
    { Takes Document. }
    constructor Create(Document: TSvgDocument);
    { The same, its own pixels left to be drawn when first asked for
      (RenderedAt at its size): for embedders that always draw at the
      size shown (inline SVG). }
    constructor CreateDeferred(Document: TSvgDocument);
    destructor Destroy; override;
    function Render(RenderWidth, RenderHeight: LongInt): TImage; override;
    property Document: TSvgDocument read FDocument;
  end;

  TSvgDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

procedure RegisterSvgImageCodec;
{ An SVG image of an SVG file (raises EImageError when it is not one). }
function DecodeSvgImage(const Data: TBytes): TImage;

implementation

uses
  Math,
  Drawing.Colors,
  Drawing.Surfaces,
  Image.Errors,
  Image.Surfaces,
  Svg.Xml,
  Svg.Renderer;

{ The largest side a natural rendering gets (bigger ones are drawn when
  asked for). }
const
  MaximumNaturalSide = 4096;

procedure RenderInto(Document: TSvgDocument; Image: TImage; ViewportWidth, ViewportHeight: Double);
var
  Surface: TSurface;
  Renderer: TSvgRenderer;
begin
  Surface := ImageSurface(Image);
  Renderer := TSvgRenderer.Create(Document);
  try
    Renderer.Render(Surface, ViewportWidth, ViewportHeight, True);
  finally
    Renderer.Free;
  end;
end;

procedure TSvgImage.Prepare(Document: TSvgDocument);
var
  ConcreteWidth, ConcreteHeight: Double;
  PixelWidth, PixelHeight: LongInt;
begin
  FDocument := Document;
  FHasNaturalWidth := Document.HasNaturalWidth;
  FHasNaturalHeight := Document.HasNaturalHeight;
  if FHasNaturalWidth then
    FNaturalWidth := Document.NaturalWidth;
  if FHasNaturalHeight then
    FNaturalHeight := Document.NaturalHeight;
  FNaturalRatio := Document.NaturalRatio;
  DefaultConcreteSize(FHasNaturalWidth, FHasNaturalHeight, FNaturalWidth, FNaturalHeight, FNaturalRatio,
    ConcreteWidth, ConcreteHeight);
  FViewportWidth := ConcreteWidth;
  FViewportHeight := ConcreteHeight;
  PixelWidth := Max(1, Min(MaximumNaturalSide, Round(ConcreteWidth)));
  PixelHeight := Max(1, Min(MaximumNaturalSide, Round(ConcreteHeight)));
  inherited Create(PixelWidth, PixelHeight);
  SourceFormatName := 'SVG';
  SourceHasAlpha := True;
end;

constructor TSvgImage.Create(Document: TSvgDocument);
begin
  Prepare(Document);
  RenderInto(FDocument, Self, FViewportWidth, FViewportHeight);
end;

constructor TSvgImage.CreateDeferred(Document: TSvgDocument);
begin
  Prepare(Document);
  FBaseRendered := False;
end;

procedure TSvgImage.RenderBase;
begin
  RenderInto(FDocument, Self, FViewportWidth, FViewportHeight);
end;

destructor TSvgImage.Destroy;
begin
  ClearRenderings;
  FDocument.Free;
  inherited Destroy;
end;

function TSvgImage.Render(RenderWidth, RenderHeight: LongInt): TImage;
var
  Scale: Double;
begin
  Result := TImage.Create(RenderWidth, RenderHeight);
  try
    { The viewport keeps the concrete width; its height follows the
      shape asked for. }
    Scale := RenderWidth / FViewportWidth;
    RenderInto(FDocument, Result, FViewportWidth, RenderHeight / Scale);
  except
    Result.Free;
    raise;
  end;
end;

function DecodeSvgImage(const Data: TBytes): TImage;
var
  Document: TSvgDocument;
begin
  try
    Document := LoadSvgDocument(Data);
  except
    on Error: ESvgError do
      RaiseImageError(ImageErrorMalformed, 'SVG: ' + Error.Message);
  end;
  Result := TSvgImage.Create(Document);
end;

class function TSvgDecoder.Format: TImageFormat;
begin
  Result := ImageFormatSvg;
end;

class function TSvgDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := LooksLikeSvg(Data);
end;

function TSvgDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeSvgImage(Data);
end;

procedure RegisterSvgImageCodec;
begin
  RegisterImageDecoder(TSvgDecoder);
end;

initialization
  RegisterSvgImageCodec;

end.
