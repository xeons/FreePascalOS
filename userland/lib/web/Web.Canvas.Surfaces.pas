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
  What a rendering context draws on: a canvas element's or an
  OffscreenCanvas's bitmap (libimage's TImage, $AARRGGBB not
  premultiplied, one pixel per coordinate unit), its origin-clean flag,
  and the one context it may have (2d or bitmaprenderer; getContext with
  another kind afterwards gives null). The surface owns its context; the
  context only points back, and loses the pointer if the surface goes
  first. Owners override Changed to show the new pixels (a canvas
  element's layout image) and CurrentColor for currentcolor.
}
unit Web.Canvas.Surfaces;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Image.Model,
  Web.Canvas.Shared;

type
  TCanvasContextKind = (ContextNone, Context2D, ContextBitmapRenderer);

  TCanvasSurface = class;

  { The base of the contexts. }
  TCanvasContextBase = class(TCanvasSharedObject)
  public
    Surface: TCanvasSurface;
    { The bitmap was made again (a new size): back to the default state. }
    procedure SurfaceReset; virtual;
  end;

  TCanvasSurface = class(TCanvasSharedObject)
  private
    FBitmap: TImage;
    FWidth, FHeight: LongInt;
    FContext: TCanvasContextBase;
    FContextKind: TCanvasContextKind;
  public
    OriginClean: Boolean;
    constructor Create(Width, Height: LongInt);
    destructor Destroy; override;
    { A new transparent (Opaque: opaque black) bitmap of that size; the
      context goes back to its default state. }
    procedure Resize(Width, Height: LongInt);
    { The bitmap is taken over (bitmaprenderer, a transfer). }
    procedure AdoptBitmap(Image: TImage);
    { Takes the context (with its reference). }
    procedure SetContext(Kind: TCanvasContextKind; Context: TCanvasContextBase);
    { The pixels changed. }
    procedure Changed; virtual;
    function CurrentColor: TColor; virtual;
    function Width: LongInt;
    function Height: LongInt;
    { nil while the surface has no pixels (a side of 0). }
    property Bitmap: TImage read FBitmap;
    property Context: TCanvasContextBase read FContext;
    property ContextKind: TCanvasContextKind read FContextKind;
  end;

const
  { Larger bitmaps are refused (as browsers limit canvas area). }
  MaximumCanvasSide = 32767;
  MaximumCanvasPixels = 268435456 div 4;

{ Whether a bitmap of that size can be made. }
function CanvasSizeAllowed(Width, Height: Int64): Boolean;

implementation

uses
  SysUtils;

procedure TCanvasContextBase.SurfaceReset;
begin
end;

function CanvasSizeAllowed(Width, Height: Int64): Boolean;
begin
  Result := (Width >= 0) and (Height >= 0) and (Width <= MaximumCanvasSide) and (Height <= MaximumCanvasSide) and
    (Width * Height <= MaximumCanvasPixels);
end;

constructor TCanvasSurface.Create(Width, Height: LongInt);
begin
  inherited Create;
  OriginClean := True;
  Resize(Width, Height);
end;

destructor TCanvasSurface.Destroy;
begin
  if FContext <> nil then
  begin
    FContext.Surface := nil;
    ReleaseShared(FContext);
  end;
  FBitmap.Free;
  inherited Destroy;
end;

procedure TCanvasSurface.Resize(Width, Height: LongInt);
begin
  if not CanvasSizeAllowed(Width, Height) then
  begin
    Width := 0;
    Height := 0;
  end;
  FWidth := Width;
  FHeight := Height;
  if (Width = 0) or (Height = 0) then
    FreeAndNil(FBitmap)
  else if (FBitmap = nil) or (FBitmap.Width <> Width) or (FBitmap.Height <> Height) then
  begin
    FBitmap.Free;
    FBitmap := TImage.Create(Width, Height);
  end
  else
    FBitmap.Fill(ColorTransparent);
  if FContext <> nil then
    FContext.SurfaceReset;
  Changed;
end;

procedure TCanvasSurface.AdoptBitmap(Image: TImage);
begin
  if Image = FBitmap then
    Exit;
  FBitmap.Free;
  FBitmap := Image;
  if Image <> nil then
  begin
    FWidth := Image.Width;
    FHeight := Image.Height;
  end;
  Changed;
end;

procedure TCanvasSurface.SetContext(Kind: TCanvasContextKind; Context: TCanvasContextBase);
begin
  if FContext <> nil then
  begin
    FContext.Surface := nil;
    ReleaseShared(FContext);
  end;
  FContext := Context;
  FContextKind := Kind;
  if Context <> nil then
    Context.Surface := Self;
end;

procedure TCanvasSurface.Changed;
begin
end;

function TCanvasSurface.CurrentColor: TColor;
begin
  Result := ColorBlack;
end;

function TCanvasSurface.Width: LongInt;
begin
  Result := FWidth;
end;

function TCanvasSurface.Height: LongInt;
begin
  Result := FHeight;
end;

end.
