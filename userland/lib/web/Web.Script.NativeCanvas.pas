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
  The natives behind platform/76-canvas.js (toBlob, convertToBlob,
  createImageBitmap, and the structured clone of canvas objects):

    natives.canvasEncode(canvas, type, quality, offscreen)
        [Uint8Array, type] of a canvas element's or OffscreenCanvas's
        bitmap, or null when it has no pixels (offscreen: IndexSizeError
        instead); SecurityError when it is not origin-clean
    natives.imageBitmapFrom(source, hasRect, sx, sy, sw, sh, resizeWidth,
        resizeHeight, flipY, pixelated)
        an ImageBitmap of an img, canvas, video, ImageBitmap,
        OffscreenCanvas or ImageData (resize 0: not resized)
    natives.imageBitmapFromBytes(bytes, hasRect, sx, ...)
        the same from an encoded image (a Blob's bytes)
    natives.cloneCanvasObject(value, transfer)
        the copy of an ImageData or ImageBitmap, the transferred
        ImageBitmap or OffscreenCanvas (transfer true; the original is
        detached), or undefined for anything else
    natives.detachCanvasObject(value)
        a listed transferable that was not reached by the clone is
        detached all the same
}
unit Web.Script.NativeCanvas;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineCanvasNatives(Context: TBindingContext; Natives: TJsObject);

implementation

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Functions,
  Js.Conversions,
  Js.ArrayBuffers,
  Js.Builtins.TypedArrays,
  Drawing.Colors,
  Image.Model,
  Image.Codecs,
  Image.StandardCodecs,
  Image.Scaling,
  Image.Orientation,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Bindings.Types,
  Web.Canvas.Shared,
  Web.Canvas.Surfaces,
  Web.Canvas.Context2D,
  Web.Canvas.Elements,
  Web.Canvas.Encoding,
  Web.Canvas.ScriptObjects;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function ArgNumber(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  if not ToDouble(Context.Engine.Realm, Arg(Args, Count, Index), Result) then
    raise EBindingPendingException.Create('');
end;

function ArgFlag(Args: PJsValueArray; Count, Index: Integer): Boolean;
begin
  Result := Arg(Args, Count, Index) = JsBoolean(True);
end;

{ The native object of a wrapper of any interface (nil for others). }
function NativeOf(Context: TBindingContext; Value: TJsValue): TObject;
var
  Wrapper: TBindingWrapper;
begin
  Result := nil;
  Wrapper := Context.WrapperOf(Value);
  if Wrapper <> nil then
    Result := TObject(Wrapper.NativeData);
end;

function BytesValue(Context: TBindingContext; const Bytes: TBytes): TJsValue;
var
  Data: TJsTypedArray;
begin
  Data := NewTypedArray(Context.Engine.Realm, taUint8, Length(Bytes));
  if Data = nil then
    raise EBindingPendingException.Create('');
  if Length(Bytes) > 0 then
    Move(Bytes[0], Data.ElementAddress(0)^, Length(Bytes));
  Result := JsObjectValue(Data);
end;

function NativeCanvasEncode(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Native: TObject;
  Surface: TCanvasSurface;
  Bitmap: TImage;
  Bytes: TBytes;
  ActualType, MimeType: string;
  Quality: Double;
  HasQuality, Offscreen: Boolean;
  Encoded, Pair: TJsValue;
  Mark: Integer;
begin
  Context := ContextOfRealm(R);
  try
    Native := NativeOf(Context, Arg(Args, ArgCount, 0));
    Surface := SurfaceOfNative(Native);
    if Surface = nil then
      raise EBindingTypeError.Create('Illegal invocation');
    Offscreen := ArgFlag(Args, ArgCount, 3);
    if Surface is TCanvasElementSurface then
      Bitmap := TCanvasElementSurface(Surface).ShownBitmap
    else
      Bitmap := Surface.Bitmap;
    if not Surface.OriginClean then
      RaiseDomError('SecurityError', 'Tainted canvases may not be exported.');
    if Bitmap = nil then
    begin
      if Offscreen then
        RaiseDomError(IndexSizeError, 'The canvas has no pixels.');
      Exit(JsNull);
    end;
    MimeType := 'image/png';
    if Arg(Args, ArgCount, 1) <> JsUndefined then
      MimeType := ValueToText(R, Arg(Args, ArgCount, 1));
    HasQuality := JsIsNumber(Arg(Args, ArgCount, 2));
    Quality := 0;
    if HasQuality then
      Quality := ArgNumber(Context, Args, ArgCount, 2);
    Bytes := EncodeCanvasBitmap(Bitmap, MimeType, HasQuality, Quality, ActualType);
    Encoded := BytesValue(Context, Bytes);
    Mark := Context.Engine.Runtime.PushRoot(Encoded);
    try
      Pair := Context.NewArray([Encoded, Context.TextValue(ActualType)]);
    finally
      Context.Engine.Runtime.PopRoots(Mark);
    end;
    Result := Pair;
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

type
  TBitmapOptions = record
    HasRect: Boolean;
    X, Y, Width, Height: Int64;
    ResizeWidth, ResizeHeight: Int64;
    FlipY, Pixelated: Boolean;
  end;

function ReadOptions(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TBitmapOptions;
begin
  Result.HasRect := ArgFlag(Args, ArgCount, 1);
  Result.X := Trunc(ArgNumber(Context, Args, ArgCount, 2));
  Result.Y := Trunc(ArgNumber(Context, Args, ArgCount, 3));
  Result.Width := Trunc(ArgNumber(Context, Args, ArgCount, 4));
  Result.Height := Trunc(ArgNumber(Context, Args, ArgCount, 5));
  Result.ResizeWidth := Trunc(ArgNumber(Context, Args, ArgCount, 6));
  Result.ResizeHeight := Trunc(ArgNumber(Context, Args, ArgCount, 7));
  Result.FlipY := ArgFlag(Args, ArgCount, 8);
  Result.Pixelated := ArgFlag(Args, ArgCount, 9);
end;

{ Source resized taking the nearest pixel (resizeQuality "pixelated"). }
function NearestImage(Source: TImage; Width, Height: LongInt): TImage;
var
  Row, Column: LongInt;
begin
  Result := TImage.Create(Width, Height);
  for Row := 0 to Height - 1 do
    for Column := 0 to Width - 1 do
      Result.Line(Row)[Column] := Source.Line(Int64(Row) * Source.Height div Height)[
        Int64(Column) * Source.Width div Width];
end;

{ The ImageBitmap's pixels: Source (its own size) cropped, resized and
  flipped as the options say. Source is not taken. }
function ShapedImage(Source: TImage; const Options: TBitmapOptions): TImage;
var
  X, Y, Width, Height, Row, Column, SourceX, SourceY: Int64;
  Cropped, Resized: TImage;
  OutputWidth, OutputHeight: Int64;
  Kept: array of TColor;
begin
  if Options.HasRect then
  begin
    X := Options.X;
    Y := Options.Y;
    Width := Options.Width;
    Height := Options.Height;
    if Width < 0 then
    begin
      X := X + Width;
      Width := -Width;
    end;
    if Height < 0 then
    begin
      Y := Y + Height;
      Height := -Height;
    end;
    if not ImageSizeAllowed(Width, Height) then
      RaiseDomError(InvalidStateError, 'The ImageBitmap would be too large.');
    Cropped := TImage.Create(Width, Height);
    for Row := 0 to Height - 1 do
    begin
      SourceY := Y + Row;
      if (SourceY < 0) or (SourceY >= Source.Height) then
        Continue;
      for Column := 0 to Width - 1 do
      begin
        SourceX := X + Column;
        if (SourceX >= 0) and (SourceX < Source.Width) then
          Cropped.Line(Row)[Column] := Source.Line(SourceY)[SourceX];
      end;
    end;
  end
  else
    Cropped := Source.Clone;
  OutputWidth := Cropped.Width;
  OutputHeight := Cropped.Height;
  if (Options.ResizeWidth > 0) and (Options.ResizeHeight > 0) then
  begin
    OutputWidth := Options.ResizeWidth;
    OutputHeight := Options.ResizeHeight;
  end
  else if Options.ResizeWidth > 0 then
  begin
    OutputWidth := Options.ResizeWidth;
    OutputHeight := Max(1, Ceil(Cropped.Height * Options.ResizeWidth / Cropped.Width));
  end
  else if Options.ResizeHeight > 0 then
  begin
    OutputHeight := Options.ResizeHeight;
    OutputWidth := Max(1, Ceil(Cropped.Width * Options.ResizeHeight / Cropped.Height));
  end;
  Result := Cropped;
  if (OutputWidth <> Cropped.Width) or (OutputHeight <> Cropped.Height) then
  begin
    if not ImageSizeAllowed(OutputWidth, OutputHeight) then
    begin
      Cropped.Free;
      RaiseDomError(InvalidStateError, 'The ImageBitmap would be too large.');
    end;
    if Options.Pixelated then
      Resized := NearestImage(Cropped, OutputWidth, OutputHeight)
    else
      Resized := ScaleImage(Cropped, OutputWidth, OutputHeight);
    Cropped.Free;
    Result := Resized;
  end;
  if Options.FlipY then
  begin
    Kept := nil;
    SetLength(Kept, Result.Width);
    for Row := 0 to Result.Height div 2 - 1 do
    begin
      Move(Result.Line(Row)^, Kept[0], Result.Width * SizeOf(TColor));
      Move(Result.Line(Result.Height - 1 - Row)^, Result.Line(Row)^, Result.Width * SizeOf(TColor));
      Move(Kept[0], Result.Line(Result.Height - 1 - Row)^, Result.Width * SizeOf(TColor));
    end;
  end;
end;

function WrapBitmap(Context: TBindingContext; Image: TImage; OriginClean: Boolean): TJsValue;
var
  Bitmap: TCanvasImageBitmap;
begin
  Bitmap := TCanvasImageBitmap.Create(Image, OriginClean);
  try
    Result := WrapShared(Context, Bitmap, InterfaceImageBitmap, JsUndefined);
  finally
    Bitmap.Release;
  end;
end;

{ ImageData's pixels as an image. }
function ImageDataImage(Data: TCanvasImageData): TImage;
var
  Pixels: PByte;
  Index: PtrInt;
begin
  if not Data.Bytes(Pixels) then
    RaiseDomError(InvalidStateError, 'The ImageData''s buffer is detached.');
  Result := TImage.Create(Data.Width, Data.Height);
  for Index := 0 to PtrInt(Data.Width) * Data.Height - 1 do
    if Pixels[Index * 4 + 3] <> 0 then
      Result.Pixels[Index] := ArgbColor(Pixels[Index * 4 + 3], Pixels[Index * 4], Pixels[Index * 4 + 1],
        Pixels[Index * 4 + 2]);
end;

{ The source at its own size, a copy the caller frees. }
function SourceImage(Native: TObject; out OriginClean: Boolean): TImage;
var
  Source: TCanvasImageSource;
  Width, Height: LongInt;
begin
  OriginClean := True;
  if Native is TCanvasImageData then
    Exit(ImageDataImage(TCanvasImageData(Native)));
  case CanvasImageSourceOf(Native, Source) of
    SourceNotReady:
      RaiseDomError(InvalidStateError, 'The source image is not available yet.');
  end;
  OriginClean := Source.OriginClean;
  Width := Max(1, Round(Source.Width));
  Height := Max(1, Round(Source.Height));
  if (Width = Source.Image.Width) and (Height = Source.Image.Height) then
    Result := Source.Image.Clone
  else
    Result := ScaleImage(Source.Image, Width, Height);
end;

function NativeImageBitmapFrom(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Source, Shaped: TImage;
  OriginClean: Boolean;
begin
  Context := ContextOfRealm(R);
  try
    Source := SourceImage(NativeOf(Context, Arg(Args, ArgCount, 0)), OriginClean);
    try
      Shaped := ShapedImage(Source, ReadOptions(Context, Args, ArgCount));
    finally
      Source.Free;
    end;
    Result := WrapBitmap(Context, Shaped, OriginClean);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeImageBitmapFromBytes(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Data: PByte;
  Length_: SizeInt;
  Bytes: TBytes;
  DecoderClass: TImageDecoderClass;
  Decoder: TImageDecoder;
  Decoded, Upright, Shaped: TImage;
begin
  Context := ContextOfRealm(R);
  try
    if not BufferSourceBytes(Arg(Args, ArgCount, 0), Data, Length_) or (Length_ = 0) then
      RaiseDomError(InvalidStateError, 'The source image could not be decoded.');
    Bytes := nil;
    SetLength(Bytes, Length_);
    Move(Data^, Bytes[0], Length_);
    RegisterStandardImageCodecs;
    DecoderClass := FindImageDecoder(Bytes);
    if DecoderClass = nil then
      RaiseDomError(InvalidStateError, 'The source image could not be decoded.');
    Decoded := nil;
    Decoder := DecoderClass.Create;
    try
      try
        Decoded := Decoder.Decode(Bytes);
      except
        on Exception do
          Decoded := nil;
      end;
    finally
      Decoder.Free;
    end;
    if Decoded = nil then
      RaiseDomError(InvalidStateError, 'The source image could not be decoded.');
    try
      Decoded.ConvertToSrgb;
      Upright := OrientedImage(Decoded);
    finally
      Decoded.Free;
    end;
    try
      Shaped := ShapedImage(Upright, ReadOptions(Context, Args, ArgCount));
    finally
      Upright.Free;
    end;
    Result := WrapBitmap(Context, Shaped, True);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function CloneImageData(Context: TBindingContext; Source: TCanvasImageData): TJsValue;
var
  Copy: TCanvasImageData;
  From, Into: PByte;
begin
  Result := NewImageData(Context, Source.Width, Source.Height, Source.ColorSpace, Copy);
  if not Source.Bytes(From) then
    RaiseDomError('DataCloneError', 'The ImageData''s buffer is detached.');
  if Copy.Bytes(Into) then
    Move(From^, Into^, PtrInt(Source.Width) * Source.Height * 4);
end;

function NativeCloneCanvasObject(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Native: TObject;
  Shared: TCanvasSharedObject;
  Transfer: Boolean;
  Bitmap: TCanvasImageBitmap;
  Image: TImage;
  Canvas, Moved: TOffscreenCanvas;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  try
    Native := NativeOf(Context, Arg(Args, ArgCount, 0));
    Transfer := ArgFlag(Args, ArgCount, 1);
    if Native is TCanvasImageData then
      Exit(CloneImageData(Context, TCanvasImageData(Native)));
    if Native is TOffscreenCanvasHandle then
    begin
      Canvas := TOffscreenCanvasHandle(Native).Canvas;
      if not Transfer or Canvas.Detached or (Canvas.ContextKind <> ContextNone) then
        RaiseDomError('DataCloneError', 'An OffscreenCanvas could not be cloned because it was detached or ' +
          'has a rendering context, or was not transferred.');
      { A new canvas of the same size takes over (and the placeholder,
        if any); the old one is left detached. }
      Moved := TOffscreenCanvas.Create(Canvas.Width, Canvas.Height);
      try
        Moved.OriginClean := Canvas.OriginClean;
        if Canvas.Placeholder <> nil then
        begin
          Moved.Placeholder := Canvas.Placeholder;
          Canvas.Placeholder := nil;
          Moved.Placeholder.Offscreen := TOffscreenCanvas(Moved.Retain);
          { The placeholder's reference to the old canvas. }
          Canvas.Release;
          Moved.Changed;
        end;
        Canvas.Detached := True;
        Result := WrapOffscreen(Context, Moved);
      finally
        Moved.Release;
      end;
      Exit;
    end;
    Shared := SharedOf(Native);
    if Shared is TCanvasImageBitmap then
    begin
      Bitmap := TCanvasImageBitmap(Shared);
      if Bitmap.Image = nil then
        RaiseDomError('DataCloneError', 'An ImageBitmap is detached and could not be cloned.');
      if Transfer then
      begin
        Image := Bitmap.Image;
        Bitmap.Image := nil;
      end
      else
        Image := Bitmap.Image.Clone;
      Exit(WrapBitmap(Context, Image, Bitmap.OriginClean));
    end;
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

function NativeDetachCanvasObject(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Native: TObject;
  Shared: TCanvasSharedObject;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  Native := NativeOf(Context, Arg(Args, ArgCount, 0));
  if Native is TOffscreenCanvasHandle then
  begin
    TOffscreenCanvasHandle(Native).Canvas.Detached := True;
    Exit;
  end;
  Shared := SharedOf(Native);
  if Shared is TCanvasImageBitmap then
    TCanvasImageBitmap(Shared).Close;
end;

procedure DefineCanvasNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'canvasEncode', @NativeCanvasEncode, 4);
  Context.Engine.DefineFunction(Natives, 'imageBitmapFrom', @NativeImageBitmapFrom, 10);
  Context.Engine.DefineFunction(Natives, 'imageBitmapFromBytes', @NativeImageBitmapFromBytes, 10);
  Context.Engine.DefineFunction(Natives, 'cloneCanvasObject', @NativeCloneCanvasObject, 2);
  Context.Engine.DefineFunction(Natives, 'detachCanvasObject', @NativeDetachCanvasObject, 1);
end;

end.
