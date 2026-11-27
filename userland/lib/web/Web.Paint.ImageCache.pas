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
  Images scaled to the size they are shown at, kept for the next paint.

  Smooth scaling weighs many source pixels for each one drawn; doing it
  once and copying the result on later paints (scrolling, animations
  elsewhere on the page) is what makes them cheap. A copy is kept by
  the image, its pixels' address and size, the part of it shown and the
  size shown at, in a cache of a few tens of megabytes, least recently
  used copies dropped first.

  An image's pixels can change in place (a canvas drawn into) and a new
  image can take a freed one's address; either way the document's
  display list is built again before the next paint. So a copy is
  trusted only for the list revision it was last checked at: on a new
  revision the source pixels' checksum is compared with the one the
  copy was made from (cheap next to scaling), and the copy is made again
  when they differ.
}
unit Web.Paint.ImageCache;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Rectangles, Drawing.Surfaces;

{ Whether a Width x Height copy is small enough to keep. }
function ScaledImageFits(Width, Height: LongInt): Boolean;
{ SourceRectangle of Source (the pixels of Image) smoothly scaled to
  Width x Height (Drawing.Scaling), from the cache or made now; the
  surface is the cache's, good until the next call. False when it does
  not fit (ScaledImageFits) or there is no memory. Revision: the
  display list's. }
function ScaledImage(Image: TObject; const Source: TSurface; const SourceRectangle: TRectangle; Width, Height: LongInt;
  Revision: LongWord; out Scaled: TSurface): Boolean;

implementation

uses
  Drawing.Canvas, Drawing.Scaling, Web.Paint.PaintCaches;

const
  ImageCacheBytes = 64 * 1024 * 1024;
  { The largest copy kept (pixels). }
  MaximumCopyPixels = 4 * 1024 * 1024;

type
  TScaledImageKey = packed record
    Image, Pixels: PtrUInt;
    SourceWidth, SourceHeight, SourceStride: LongInt;
    SourceLeft, SourceTop, SourceRight, SourceBottom: LongInt;
    Width, Height: LongInt;
  end;

var
  Cache: TPaintCache = nil;

function ScaledImageFits(Width, Height: LongInt): Boolean;
begin
  Result := (Width > 0) and (Height > 0) and (Int64(Width) * Height <= MaximumCopyPixels);
end;

{ A checksum of the pixels shown. }
function SourceFingerprint(const Source: TSurface; const Shown: TRectangle): QWord;
var
  Row: LongInt;
begin
  Result := 0;
  for Row := Shown.Top to Shown.Bottom - 1 do
    Result := RolQWord(Result, 7) xor HashBytes(PByte(SurfaceLine(Source, Row) + Shown.Left),
      PtrUInt(RectangleWidth(Shown)) * SizeOf(LongWord));
end;

procedure ScaleInto(Pixels: PLongWord; const Source: TSurface; const SourceRectangle: TRectangle;
  Width, Height: LongInt);
var
  Canvas: TCanvas;
begin
  BeginCanvas(Canvas, SurfaceOnPixels(Pixels, Width, Height, Width * SizeOf(LongWord)));
  DrawSurfaceScaled(Canvas, Source, SourceRectangle, MakeRectangle(0, 0, Width, Height), False);
end;

function ScaledImage(Image: TObject; const Source: TSurface; const SourceRectangle: TRectangle; Width, Height: LongInt;
  Revision: LongWord; out Scaled: TSurface): Boolean;
var
  Key: TScaledImageKey;
  Entry: PPaintCacheEntry;
  Shown: TRectangle;
  Fingerprint: QWord;
  Pixels: PLongWord;
begin
  Scaled := Default(TSurface);
  Result := False;
  if not ScaledImageFits(Width, Height) or
     not IntersectRectangles(SourceRectangle, SurfaceBounds(Source), Shown) then
    Exit;
  if Cache = nil then
    Cache := TPaintCache.Create(ImageCacheBytes);
  Key := Default(TScaledImageKey);
  Key.Image := PtrUInt(Image);
  Key.Pixels := PtrUInt(Source.Pixels);
  Key.SourceWidth := Source.Width;
  Key.SourceHeight := Source.Height;
  Key.SourceStride := Source.Stride;
  Key.SourceLeft := SourceRectangle.Left;
  Key.SourceTop := SourceRectangle.Top;
  Key.SourceRight := SourceRectangle.Right;
  Key.SourceBottom := SourceRectangle.Bottom;
  Key.Width := Width;
  Key.Height := Height;
  Entry := Cache.Find(Key, SizeOf(Key));
  if Entry = nil then
  begin
    Pixels := GetMem(PtrUInt(Width) * PtrUInt(Height) * SizeOf(LongWord));
    if Pixels = nil then
      Exit;
    ScaleInto(Pixels, Source, SourceRectangle, Width, Height);
    Entry := Cache.Add(Key, SizeOf(Key), Pixels, PtrUInt(Width) * PtrUInt(Height) * SizeOf(LongWord), Width, Height);
    if Entry = nil then
      Exit;
    Entry^.Fingerprint := SourceFingerprint(Source, Shown);
    Entry^.Revision := Revision;
  end
  else if Entry^.Revision <> Revision then
  begin
    { The list was built again: the pixels may have changed. }
    Fingerprint := SourceFingerprint(Source, Shown);
    if Fingerprint <> Entry^.Fingerprint then
    begin
      ScaleInto(PLongWord(Entry^.Data), Source, SourceRectangle, Width, Height);
      Entry^.Fingerprint := Fingerprint;
    end;
    Entry^.Revision := Revision;
  end;
  Scaled := SurfaceOnPixels(Entry^.Data, Width, Height, Width * SizeOf(LongWord));
  Result := True;
end;

finalization
  Cache.Free;
end.
