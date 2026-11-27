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
  Surfaces: rectangles of pixels (Drawing.Colors' $AARRGGBB) in memory,
  Stride pixels from one line to the next. A surface either owns its
  pixels (CreateSurface: freed with FreeSurface) or describes memory
  that belongs to someone else (SurfaceOnPixels: a framebuffer, a
  shared buffer).
}
unit Drawing.Surfaces;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles;

type
  TSurface = record
    Pixels: PLongWord;
    Width: LongInt;
    Height: LongInt;
    { Pixels from the start of one line to the next. }
    Stride: LongInt;
    OwnsPixels: Boolean;
  end;
  PSurface = ^TSurface;

{ A surface of its own, every pixel Fill. False if out of memory or a
  size is not positive. }
function CreateSurface(out Surface: TSurface; Width, Height: LongInt; Fill: TColor): Boolean;
procedure FreeSurface(var Surface: TSurface);
{ A surface on Pixels, StrideBytes from line to line (a multiple of 4). }
function SurfaceOnPixels(Pixels: Pointer; Width, Height, StrideBytes: LongInt): TSurface;

function SurfaceBounds(const Surface: TSurface): TRectangle;
function SurfaceLine(const Surface: TSurface; Y: LongInt): PLongWord;
{ The pixel at (X, Y); transparent outside the surface. }
function GetSurfacePixel(const Surface: TSurface; X, Y: LongInt): TColor;
{ Sets the pixel at (X, Y) if it is on the surface (no blending). }
procedure SetSurfacePixel(const Surface: TSurface; X, Y: LongInt; Color: TColor);
{ Copies Source to the top left of Destination (as much as fits) with
  red and blue swapped: for displays that keep red in the low byte. }
procedure CopySurfaceSwappingRedAndBlue(const Source, Destination: TSurface);

implementation

function CreateSurface(out Surface: TSurface; Width, Height: LongInt; Fill: TColor): Boolean;
var
  Count: PtrUInt;
begin
  Surface.Pixels := nil;
  Surface.Width := 0;
  Surface.Height := 0;
  Surface.Stride := 0;
  Surface.OwnsPixels := False;
  if (Width <= 0) or (Height <= 0) then
    Exit(False);
  Count := PtrUInt(Width) * PtrUInt(Height);
  Surface.Pixels := GetMem(Count * SizeOf(LongWord));
  if Surface.Pixels = nil then
    Exit(False);
  FillDWord(Surface.Pixels^, Count, Fill);
  Surface.Width := Width;
  Surface.Height := Height;
  Surface.Stride := Width;
  Surface.OwnsPixels := True;
  Result := True;
end;

procedure FreeSurface(var Surface: TSurface);
begin
  if Surface.OwnsPixels and (Surface.Pixels <> nil) then
    FreeMem(Surface.Pixels);
  Surface.Pixels := nil;
  Surface.Width := 0;
  Surface.Height := 0;
  Surface.Stride := 0;
  Surface.OwnsPixels := False;
end;

function SurfaceOnPixels(Pixels: Pointer; Width, Height, StrideBytes: LongInt): TSurface;
begin
  Result.Pixels := PLongWord(Pixels);
  Result.Width := Width;
  Result.Height := Height;
  Result.Stride := StrideBytes div SizeOf(LongWord);
  Result.OwnsPixels := False;
end;

function SurfaceBounds(const Surface: TSurface): TRectangle;
begin
  Result := MakeRectangle(0, 0, Surface.Width, Surface.Height);
end;

function SurfaceLine(const Surface: TSurface; Y: LongInt): PLongWord;
begin
  Result := Surface.Pixels + PtrInt(Y) * Surface.Stride;
end;

function GetSurfacePixel(const Surface: TSurface; X, Y: LongInt): TColor;
begin
  if (X < 0) or (Y < 0) or (X >= Surface.Width) or (Y >= Surface.Height) then
    Exit(ColorTransparent);
  Result := SurfaceLine(Surface, Y)[X];
end;

procedure SetSurfacePixel(const Surface: TSurface; X, Y: LongInt; Color: TColor);
begin
  if (X < 0) or (Y < 0) or (X >= Surface.Width) or (Y >= Surface.Height) then
    Exit;
  SurfaceLine(Surface, Y)[X] := Color;
end;

procedure CopySurfaceSwappingRedAndBlue(const Source, Destination: TSurface);
var
  Width: LongInt;
  Height: LongInt;
  X: LongInt;
  Y: LongInt;
  SourceLine: PLongWord;
  TargetLine: PLongWord;
  Pixel: LongWord;
begin
  Width := Source.Width;
  if Destination.Width < Width then
    Width := Destination.Width;
  Height := Source.Height;
  if Destination.Height < Height then
    Height := Destination.Height;
  for Y := 0 to Height - 1 do
  begin
    SourceLine := SurfaceLine(Source, Y);
    TargetLine := SurfaceLine(Destination, Y);
    for X := 0 to Width - 1 do
    begin
      Pixel := SourceLine[X];
      TargetLine[X] := (Pixel and $FF00FF00) or ((Pixel and $FF) shl 16) or ((Pixel shr 16) and $FF);
    end;
  end;
end;

end.
