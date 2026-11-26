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
  The canvas element's bitmap (HTML Standard 4.12.5), OffscreenCanvas
  (4.12.5.3) and ImageBitmap (8.10).

  A canvas element gets its surface (TCanvasElementSurface, owned by
  the element: TNode.CanvasStateObject) with its first context or when
  its bitmap is needed; the width and height content attributes (the
  rules for non-negative integers, 300 by 150 by default) size it, and
  setting either resets the bitmap and the context. The surface is the
  element's image provider for the layout (Web.Layout.Resources): when
  the layout updates, a surface whose pixels changed copies them into
  the element's image, so the page shows them at its next frame without
  a copy per drawing call.

  transferControlToOffscreen makes an OffscreenCanvas whose bitmap the
  element then shows (a placeholder canvas): the offscreen canvas's
  changes mark the element's provider, which takes the offscreen pixels.
  Workers run on the window's thread here (Web.Script.NativeWorkers), so
  the offscreen canvas can be drawn on in a worker and still be read
  directly.

  An ImageBitmap holds its own copy of the pixels until close() or a
  transfer detaches it.
}
unit Web.Canvas.Elements;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Image.Model,
  Web.Dom,
  Web.Layout.Resources,
  Web.Canvas.Shared,
  Web.Canvas.Surfaces;

type
  TCanvasElementSurface = class;
  TOffscreenCanvas = class;

  { The layout's view of a canvas: the pixels of the element's surface,
    or of the offscreen canvas it is the placeholder of. }
  TCanvasImageProvider = class(TElementImageProvider)
  public
    Owner: TCanvasElementSurface;
    Dirty: Boolean;
    function ImageChanged: Boolean; override;
    function HasImage: Boolean; override;
    function ProvideImage(Current: TImage; out NewImage: TImage): Boolean; override;
  end;

  TCanvasElementSurface = class(TCanvasSurface)
  private
    FElement: TElement;
    FProvider: TCanvasImageProvider;
    FRegisteredWith: TDocumentResources;
  public
    { The offscreen canvas the element shows (referenced). }
    Offscreen: TOffscreenCanvas;
    constructor Create(AElement: TElement);
    destructor Destroy; override;
    procedure Changed; override;
    { The pixels the element shows (its own, or its offscreen canvas's). }
    function ShownBitmap: TImage;
    property Element: TElement read FElement;
  end;

  TOffscreenCanvas = class(TCanvasSurface)
  public
    { The placeholder canvas element's surface (weak), nil when none. }
    Placeholder: TCanvasElementSurface;
    { Transferred to another realm or given as a placeholder's: no
      longer usable from here. }
    Detached: Boolean;
    destructor Destroy; override;
    procedure Changed; override;
  end;

  TCanvasImageBitmap = class(TCanvasSharedObject)
  public
    { nil once closed or transferred. }
    Image: TImage;
    OriginClean: Boolean;
    constructor Create(AImage: TImage; AOriginClean: Boolean);
    destructor Destroy; override;
    procedure Close;
  end;

  { ImageBitmapRenderingContext: the canvas shows the bitmaps given to it. }
  TBitmapRendererContext = class(TCanvasContextBase)
  public
    Alpha: Boolean;
    { Bitmap's pixels become the surface's and Bitmap is detached; nil
      shows transparent black of the surface's size. }
    procedure TransferFrom(Bitmap: TCanvasImageBitmap);
  end;

{ The canvas's surface, nil when it has none yet. }
function FindCanvasSurface(Element: TElement): TCanvasElementSurface;
{ The canvas's surface, made when missing. }
function CanvasSurfaceOf(Element: TElement): TCanvasElementSurface;
{ The bitmap size from the width and height attributes. }
procedure CanvasElementSize(Element: TElement; out Width, Height: LongInt);
{ The width or height attribute was set: the bitmap and context reset. }
procedure CanvasDimensionsChanged(Element: TElement);
{ A copy of the pixels a canvas shows (nil when it shows none). }
function CanvasElementImageCopy(Element: TElement): TImage;

implementation

uses
  SysUtils,
  Web.Atoms;

function ParseDimension(const Text: string; Default: LongInt): LongInt;
var
  Index: Integer;
  Value: Int64;
begin
  Index := 1;
  while (Index <= Length(Text)) and (Text[Index] in [#9, #10, #12, #13, ' ']) do
    Inc(Index);
  if (Index <= Length(Text)) and (Text[Index] = '+') then
    Inc(Index);
  if (Index > Length(Text)) or not (Text[Index] in ['0'..'9']) then
    Exit(Default);
  Value := 0;
  while (Index <= Length(Text)) and (Text[Index] in ['0'..'9']) do
  begin
    Value := Value * 10 + Ord(Text[Index]) - Ord('0');
    if Value > High(LongInt) then
      Exit(Default);
    Inc(Index);
  end;
  Result := Value;
end;

procedure CanvasElementSize(Element: TElement; out Width, Height: LongInt);
begin
  Width := 300;
  Height := 150;
  if Element.HasAttribute('width') then
    Width := ParseDimension(Element.GetAttribute('width'), 300);
  if Element.HasAttribute('height') then
    Height := ParseDimension(Element.GetAttribute('height'), 150);
end;

function FindCanvasSurface(Element: TElement): TCanvasElementSurface;
var
  State: TObject;
begin
  Result := nil;
  if Element = nil then
    Exit;
  State := Element.CanvasStateObject;
  if State is TCanvasElementSurface then
    Result := TCanvasElementSurface(State);
end;

function CanvasSurfaceOf(Element: TElement): TCanvasElementSurface;
begin
  Result := FindCanvasSurface(Element);
  if Result = nil then
  begin
    Result := TCanvasElementSurface.Create(Element);
    Element.SetCanvasStateObject(Result);
  end;
end;

procedure CanvasDimensionsChanged(Element: TElement);
var
  Surface: TCanvasElementSurface;
  Width, Height: LongInt;
begin
  Surface := FindCanvasSurface(Element);
  if (Surface = nil) or (Surface.Offscreen <> nil) then
    Exit;
  CanvasElementSize(Element, Width, Height);
  Surface.Resize(Width, Height);
end;

function CanvasElementImageCopy(Element: TElement): TImage;
var
  Surface: TCanvasElementSurface;
begin
  Result := nil;
  Surface := FindCanvasSurface(Element);
  if (Surface <> nil) and (Surface.ShownBitmap <> nil) then
    Result := Surface.ShownBitmap.Clone;
end;

{ TCanvasImageProvider }

function TCanvasImageProvider.ImageChanged: Boolean;
begin
  Result := Dirty;
end;

function TCanvasImageProvider.HasImage: Boolean;
begin
  Result := (Owner <> nil) and (Owner.ShownBitmap <> nil);
end;

function TCanvasImageProvider.ProvideImage(Current: TImage; out NewImage: TImage): Boolean;
var
  Shown: TImage;
begin
  Dirty := False;
  NewImage := nil;
  Shown := nil;
  if Owner <> nil then
    Shown := Owner.ShownBitmap;
  if (Shown <> nil) and (Current <> nil) and (Current.Width = Shown.Width) and (Current.Height = Shown.Height) then
  begin
    Move(Shown.Pixels^, Current.Pixels^, PtrUInt(Shown.Width) * PtrUInt(Shown.Height) * SizeOf(LongWord));
    Exit(False);
  end;
  if Shown <> nil then
    NewImage := Shown.Clone;
  Result := True;
end;

{ TCanvasElementSurface }

constructor TCanvasElementSurface.Create(AElement: TElement);
var
  BitmapWidth, BitmapHeight: LongInt;
begin
  FElement := AElement;
  FProvider := TCanvasImageProvider.Create;
  FProvider.Owner := Self;
  CanvasElementSize(AElement, BitmapWidth, BitmapHeight);
  inherited Create(BitmapWidth, BitmapHeight);
  if AElement.NodeDocument <> nil then
  begin
    FRegisteredWith := DocumentResourcesOf(AElement.NodeDocument);
    FRegisteredWith.SetElementImageProvider(AElement, FProvider);
  end;
end;

destructor TCanvasElementSurface.Destroy;
begin
  if Offscreen <> nil then
  begin
    Offscreen.Placeholder := nil;
    ReleaseShared(Offscreen);
  end;
  ForgetElementImageProvider(FProvider);
  FProvider.Owner := nil;
  FreeAndNil(FProvider);
  inherited Destroy;
end;

procedure TCanvasElementSurface.Changed;
begin
  if FProvider <> nil then
    FProvider.Dirty := True;
end;

function TCanvasElementSurface.ShownBitmap: TImage;
begin
  if Offscreen <> nil then
    Result := Offscreen.Bitmap
  else
    Result := Bitmap;
end;

{ TOffscreenCanvas }

destructor TOffscreenCanvas.Destroy;
begin
  if Placeholder <> nil then
  begin
    Placeholder.Offscreen := nil;
    Placeholder.Changed;
    Placeholder := nil;
  end;
  inherited Destroy;
end;

procedure TOffscreenCanvas.Changed;
begin
  if Placeholder <> nil then
    Placeholder.Changed;
end;

{ TBitmapRendererContext }

procedure TBitmapRendererContext.TransferFrom(Bitmap: TCanvasImageBitmap);
var
  Image: TImage;
  Index: PtrInt;
begin
  if Surface = nil then
    Exit;
  if (Bitmap = nil) or (Bitmap.Image = nil) then
  begin
    if (Surface.Width > 0) and (Surface.Height > 0) then
      Surface.AdoptBitmap(TImage.Create(Surface.Width, Surface.Height))
    else
      Surface.AdoptBitmap(nil);
    Exit;
  end;
  Image := Bitmap.Image;
  Bitmap.Image := nil;
  if not Alpha then
    for Index := 0 to PtrInt(Image.Width) * Image.Height - 1 do
      Image.Pixels[Index] := BlendColors(ColorBlack, Image.Pixels[Index]);
  if not Bitmap.OriginClean then
    Surface.OriginClean := False;
  Surface.AdoptBitmap(Image);
end;

{ TCanvasImageBitmap }

constructor TCanvasImageBitmap.Create(AImage: TImage; AOriginClean: Boolean);
begin
  inherited Create;
  Image := AImage;
  OriginClean := AOriginClean;
end;

destructor TCanvasImageBitmap.Destroy;
begin
  Image.Free;
  inherited Destroy;
end;

procedure TCanvasImageBitmap.Close;
begin
  FreeAndNil(Image);
end;

end.
