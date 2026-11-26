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
  The canvas objects as script sees them, shared by the bindings
  (Web.Bindings.Canvas) and the platform natives (Web.Script.NativeCanvas):
  the native objects of Path2D, TextMetrics and ImageData wrappers (an
  ImageData keeps its Uint8ClampedArray alive through its wrapper), the
  handles through which wrappers hold shared canvas objects (one wrapper
  per object while it lives), wrapping a context with the interface its
  surface calls for, and CanvasImageSource: the pixels of an img, a
  canvas, an OffscreenCanvas or an ImageBitmap, whether they can be used
  yet, and whether they are origin-clean.
}
unit Web.Canvas.ScriptObjects;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Heap,
  Image.Model,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Listeners,
  Web.Bindings.Context,
  Web.Canvas.Shared,
  Web.Canvas.Surfaces,
  Web.Canvas.Paths,
  Web.Canvas.Text,
  Web.Canvas.Context2D,
  Web.Canvas.Elements;

type
  TCanvasPath2D = class
  public
    Path: TCanvasPath;
    constructor Create;
  end;

  TCanvasTextMetrics = class
  public
    Measure: TCanvasTextMeasure;
  end;

  TCanvasImageData = class(TBindingTracedObject)
  public
    Width, Height: LongInt;
    { The Uint8ClampedArray. }
    Data: TJsValue;
    ColorSpace: string;
    procedure TraceValues(Tracer: TJsTracer); override;
    { The pixels' bytes; False when the buffer was detached. }
    function Bytes(out Pixels: PByte): Boolean;
  end;

  { The native object of an OffscreenCanvas wrapper (an event target). }
  TOffscreenCanvasHandle = class(TStandaloneEventTarget)
  public
    Canvas: TOffscreenCanvas;
    constructor Create(ACanvas: TOffscreenCanvas);
    destructor Destroy; override;
  end;

  TImageSourceState = (SourceUsable, SourceNotReady, SourceBroken);

{ The shared object behind a handle (nil for anything else). }
function SharedOf(Native: TObject): TCanvasSharedObject;
{ The wrapper of Shared (made when it has none), kept alive with
  OwnerWrapper when that is not undefined. }
function WrapShared(Context: TBindingContext; Shared: TCanvasSharedObject; InterfaceId: Integer;
  OwnerWrapper: TJsValue): TJsValue;
function WrapOffscreen(Context: TBindingContext; Canvas: TOffscreenCanvas): TJsValue;
{ A context's wrapper: CanvasRenderingContext2D, the offscreen one, or
  ImageBitmapRenderingContext, kept alive with its canvas. }
function WrapCanvasContext(Context: TBindingContext; Rendering: TCanvasContextBase): TJsValue;
{ The canvas element or OffscreenCanvas a context draws on (null when
  gone). }
function CanvasOfContext(Context: TBindingContext; Rendering: TCanvasContextBase): TJsValue;

{ A new ImageData of transparent black pixels (RangeError when too big). }
function NewImageData(Context: TBindingContext; Width, Height: LongInt; const ColorSpace: string;
  out ImageData: TCanvasImageData): TJsValue;

{ The pixels of a CanvasImageSource value's native object (Kind: the
  union member). Errors (a broken image, a detached bitmap, a canvas of
  no pixels) are raised as DOMExceptions. }
function CanvasImageSourceOf(Native: TObject; out Source: TCanvasImageSource): TImageSourceState;
{ The surface a canvas element or OffscreenCanvas native object draws
  on (nil for anything else; a detached offscreen canvas raises). }
function SurfaceOfNative(Native: TObject): TCanvasSurface;

implementation

uses
  Js.Objects,
  Js.ArrayBuffers,
  Js.Builtins.TypedArrays,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Web.Atoms,
  Web.Origins,
  Web.Dom.Exceptions,
  Web.Dom.ImageRequests,
  Web.Layout.Resources;

constructor TCanvasPath2D.Create;
begin
  inherited Create;
  ClearCanvasPath(Path);
end;

procedure TCanvasImageData.TraceValues(Tracer: TJsTracer);
begin
  Tracer.MarkValue(Data);
end;

function TCanvasImageData.Bytes(out Pixels: PByte): Boolean;
var
  Length_: SizeInt;
begin
  Pixels := nil;
  Result := BufferSourceBytes(Data, Pixels, Length_) and (Length_ >= SizeInt(Width) * Height * 4);
end;

constructor TOffscreenCanvasHandle.Create(ACanvas: TOffscreenCanvas);
begin
  inherited Create;
  Canvas := ACanvas;
  Canvas.Retain;
end;

destructor TOffscreenCanvasHandle.Destroy;
begin
  if Canvas <> nil then
  begin
    Canvas.ScriptWrapper := nil;
    ReleaseShared(Canvas);
  end;
  inherited Destroy;
end;

function SharedOf(Native: TObject): TCanvasSharedObject;
begin
  Result := nil;
  if Native is TCanvasObjectHandle then
    Result := TCanvasObjectHandle(Native).Target
  else if Native is TOffscreenCanvasHandle then
    Result := TOffscreenCanvasHandle(Native).Canvas;
end;

function WrapShared(Context: TBindingContext; Shared: TCanvasSharedObject; InterfaceId: Integer;
  OwnerWrapper: TJsValue): TJsValue;
begin
  if Shared = nil then
    Exit(JsNull);
  if Shared.ScriptWrapper <> nil then
    Exit(JsObjectValue(TBindingWrapper(Shared.ScriptWrapper)));
  Result := Context.WrapObject(TCanvasObjectHandle.Create(Shared), InterfaceId, True, OwnerWrapper);
  Shared.ScriptWrapper := TBindingWrapper(JsAsObject(Result));
end;

function WrapOffscreen(Context: TBindingContext; Canvas: TOffscreenCanvas): TJsValue;
begin
  if Canvas = nil then
    Exit(JsNull);
  if Canvas.ScriptWrapper <> nil then
    Exit(JsObjectValue(TBindingWrapper(Canvas.ScriptWrapper)));
  Result := Context.WrapObject(TOffscreenCanvasHandle.Create(Canvas), InterfaceOffscreenCanvas, True, JsUndefined);
  Canvas.ScriptWrapper := TBindingWrapper(JsAsObject(Result));
end;

function CanvasOfContext(Context: TBindingContext; Rendering: TCanvasContextBase): TJsValue;
var
  Surface: TCanvasSurface;
begin
  Surface := Rendering.Surface;
  if Surface is TCanvasElementSurface then
    Result := Context.WrapNode(TCanvasElementSurface(Surface).Element)
  else if Surface is TOffscreenCanvas then
    Result := WrapOffscreen(Context, TOffscreenCanvas(Surface))
  else
    Result := JsNull;
end;

function WrapCanvasContext(Context: TBindingContext; Rendering: TCanvasContextBase): TJsValue;
var
  InterfaceId: Integer;
begin
  if Rendering = nil then
    Exit(JsNull);
  if Rendering is TBitmapRendererContext then
    InterfaceId := InterfaceImageBitmapRenderingContext
  else if Rendering.Surface is TOffscreenCanvas then
    InterfaceId := InterfaceOffscreenCanvasRenderingContext2D
  else
    InterfaceId := InterfaceCanvasRenderingContext2D;
  Result := WrapShared(Context, Rendering, InterfaceId, CanvasOfContext(Context, Rendering));
end;

function NewImageData(Context: TBindingContext; Width, Height: LongInt; const ColorSpace: string;
  out ImageData: TCanvasImageData): TJsValue;
var
  Data: TJsTypedArray;
  Mark: Integer;
  Count: Int64;
begin
  ImageData := nil;
  Count := Int64(Width) * Height * 4;
  if (Width <= 0) or (Height <= 0) or (Count > MaximumArrayBufferLength) then
    raise EBindingRangeError.Create('The ImageData is too large');
  Data := NewTypedArray(Context.Engine.Realm, taUint8Clamped, Count);
  if Data = nil then
    raise EBindingPendingException.Create('');
  Mark := Context.Engine.Runtime.PushRoot(JsObjectValue(Data));
  try
    ImageData := TCanvasImageData.Create;
    ImageData.Width := Width;
    ImageData.Height := Height;
    ImageData.Data := JsObjectValue(Data);
    ImageData.ColorSpace := ColorSpace;
    Result := Context.WrapObject(ImageData, InterfaceImageData, True, JsUndefined);
  finally
    Context.Engine.Runtime.PopRoots(Mark);
  end;
end;

{ Whether an img's image can be read by script: same origin, data: or
  blob:, or fetched with CORS (the crossorigin attribute; a failed check
  leaves the image broken). }
function ImageOriginClean(Element: TElement; const Url: string): Boolean;
var
  Parsed: TUrlRecord;
begin
  if Element.HasAttributeAtom(AtomCrossorigin) then
    Exit(True);
  if not ParseUrl(Url, Parsed) then
    Exit(False);
  if (Parsed.Scheme = 'data') or (Parsed.Scheme = 'blob') then
    Exit(True);
  Result := SameOrigin(OriginOfUrl(Parsed), DocumentOrigin(Element.NodeDocument));
end;

function ImageElementSource(Element: TElement; out Source: TCanvasImageSource): TImageSourceState;
var
  Request: TImageRequest;
  Image: TImage;
begin
  Request := FindImageRequest(Element);
  if (Request <> nil) and (Request.State = ImageRequestBroken) then
    RaiseDomError(InvalidStateError, 'The HTMLImageElement provided is in the ''broken'' state.');
  if (Request = nil) or (Request.State <> ImageRequestCompletelyAvailable) or (Element.NodeDocument = nil) then
    Exit(SourceNotReady);
  Image := DocumentResourcesOf(Element.NodeDocument).ElementImage(Element);
  if Image = nil then
    Exit(SourceNotReady);
  Source.Image := Image;
  Source.Width := Request.NaturalWidth;
  Source.Height := Request.NaturalHeight;
  if (Source.Width <= 0) or (Source.Height <= 0) then
  begin
    Source.Width := Image.Width;
    Source.Height := Image.Height;
  end;
  Source.OriginClean := ImageOriginClean(Element, Request.CurrentUrl);
  Result := SourceUsable;
end;

function SurfaceSource(Surface: TCanvasSurface; Image: TImage; out Source: TCanvasImageSource): TImageSourceState;
begin
  if (Image = nil) or (Image.Width = 0) or (Image.Height = 0) then
    RaiseDomError(InvalidStateError, 'The image argument is a canvas element with a width or height of 0.');
  Source.Image := Image;
  Source.Width := Image.Width;
  Source.Height := Image.Height;
  Source.OriginClean := Surface.OriginClean;
  Result := SourceUsable;
end;

function SurfaceOfNative(Native: TObject): TCanvasSurface;
begin
  Result := nil;
  if (Native is TElement) and TElement(Native).IsHtmlElement(AtomCanvas) then
    Result := CanvasSurfaceOf(TElement(Native))
  else if Native is TOffscreenCanvasHandle then
  begin
    if TOffscreenCanvasHandle(Native).Canvas.Detached then
      RaiseDomError(InvalidStateError, 'The OffscreenCanvas is detached.');
    Result := TOffscreenCanvasHandle(Native).Canvas;
  end;
end;

function CanvasImageSourceOf(Native: TObject; out Source: TCanvasImageSource): TImageSourceState;
var
  Shared: TCanvasSharedObject;
  Surface: TCanvasSurface;
begin
  Source := Default(TCanvasImageSource);
  Result := SourceNotReady;
  if Native is TElement then
  begin
    if TElement(Native).IsHtmlElement(AtomImg) then
      Exit(ImageElementSource(TElement(Native), Source));
    if TElement(Native).IsHtmlElement(AtomCanvas) then
    begin
      Surface := CanvasSurfaceOf(TElement(Native));
      Exit(SurfaceSource(Surface, TCanvasElementSurface(Surface).ShownBitmap, Source));
    end;
    if TElement(Native).IsHtmlElement(AtomVideo) then
      { No media play yet: readyState is HAVE_NOTHING, so nothing is
        drawn (the standard's rule for a video without a frame). }
      Exit(SourceNotReady);
    raise EBindingTypeError.Create('The provided value is not of type ''CanvasImageSource''');
  end;
  if Native is TOffscreenCanvasHandle then
  begin
    Surface := SurfaceOfNative(Native);
    Exit(SurfaceSource(Surface, Surface.Bitmap, Source));
  end;
  Shared := SharedOf(Native);
  if Shared is TCanvasImageBitmap then
  begin
    if TCanvasImageBitmap(Shared).Image = nil then
      RaiseDomError(InvalidStateError, 'The image source is detached');
    Source.Image := TCanvasImageBitmap(Shared).Image;
    Source.Width := Source.Image.Width;
    Source.Height := Source.Image.Height;
    Source.OriginClean := TCanvasImageBitmap(Shared).OriginClean;
    Exit(SourceUsable);
  end;
  raise EBindingTypeError.Create('The provided value is not of type ''CanvasImageSource''');
end;

end.
