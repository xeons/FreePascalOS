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
  VP8 pictures: the three planes of a decoded frame, a whole number of
  macroblocks in size, surrounded by a border that repeats the edge
  pixels (32 for luma, 16 for chroma, as the reference decoder has it),
  so that motion vectors may point a little outside the picture.

  The decoder also uses the border while it reconstructs: the row above
  the picture holds 127, the column left of it 129 (RFC 6386 section
  12.2), and intra prediction finds them there.
}
unit Vp8.Pictures;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils, Media.Frames;

const
  LumaBorder = 32;
  ChromaBorder = 16;

type
  TVp8Plane = record
    Buffer: TBytes;
    Stride: LongInt;
    Width: LongInt;     { a whole number of macroblocks }
    Height: LongInt;
    Border: LongInt;
    Origin: PByte;      { the top left pixel }
  end;

  TVp8Picture = class
  public
    Planes: array[0..2] of TVp8Plane;
    { The size of the picture shown. }
    DisplayWidth, DisplayHeight: LongInt;
    constructor Create(Width, Height: LongInt);
    { Repeats the edge pixels into the border. }
    procedure ExtendBorders;
    { Repeats the left and right edge pixels of Rows rows from FirstRow
      of plane Index into the border. }
    procedure ExtendRows(Index, FirstRow, Rows: LongInt);
    { Repeats the top and bottom rows into the border. }
    procedure ExtendTopAndBottom;
    { The row above the picture becomes 127 (and 4 more pixels to the
      right, which the last macroblocks' 4x4 prediction reads). }
    procedure PrepareTopBorder;
    { Copies the shown part into Frame's planes (8-bit 4:2:0). }
    procedure CopyTo(var Frame: TVideoFrame);
  end;

implementation

procedure InitializePlane(out Plane: TVp8Plane; Width, Height, Border: LongInt);
begin
  Plane.Width := Width;
  Plane.Height := Height;
  Plane.Border := Border;
  Plane.Stride := Width + 2 * Border;
  Plane.Buffer := nil;
  SetLength(Plane.Buffer, Plane.Stride * (Height + 2 * Border));
  Plane.Origin := @Plane.Buffer[Border * Plane.Stride + Border];
end;

constructor TVp8Picture.Create(Width, Height: LongInt);
var
  AlignedWidth, AlignedHeight: LongInt;
begin
  inherited Create;
  DisplayWidth := Width;
  DisplayHeight := Height;
  AlignedWidth := (Width + 15) and not 15;
  AlignedHeight := (Height + 15) and not 15;
  InitializePlane(Planes[0], AlignedWidth, AlignedHeight, LumaBorder);
  InitializePlane(Planes[1], AlignedWidth div 2, AlignedHeight div 2, ChromaBorder);
  InitializePlane(Planes[2], AlignedWidth div 2, AlignedHeight div 2, ChromaBorder);
end;

procedure TVp8Picture.ExtendRows(Index, FirstRow, Rows: LongInt);
var
  Row: LongInt;
  Line: PByte;
begin
  with Planes[Index] do
    for Row := FirstRow to FirstRow + Rows - 1 do
    begin
      Line := Origin + Row * Stride;
      FillChar((Line - Border)^, Border, Line[0]);
      FillChar((Line + Width)^, Border, Line[Width - 1]);
    end;
end;

procedure TVp8Picture.ExtendTopAndBottom;
var
  Index, Row: LongInt;
  First, Last: PByte;
begin
  for Index := 0 to 2 do
    with Planes[Index] do
    begin
      First := Origin - Border;
      Last := First + (Height - 1) * Stride;
      for Row := 1 to Border do
      begin
        Move(First^, (First - Row * Stride)^, Stride);
        Move(Last^, (Last + Row * Stride)^, Stride);
      end;
    end;
end;

procedure TVp8Picture.ExtendBorders;
var
  Index: LongInt;
begin
  for Index := 0 to 2 do
    ExtendRows(Index, 0, Planes[Index].Height);
  ExtendTopAndBottom;
end;

procedure TVp8Picture.PrepareTopBorder;
var
  Index: LongInt;
begin
  for Index := 0 to 2 do
    with Planes[Index] do
      FillChar((Origin - Stride - 1)^, Width + 5, 127);
end;

procedure TVp8Picture.CopyTo(var Frame: TVideoFrame);
var
  Index, Row, PlaneWidth, PlaneHeight: LongInt;
begin
  Frame.Width := DisplayWidth;
  Frame.Height := DisplayHeight;
  Frame.BitDepth := 8;
  Frame.Layout := pl420;
  { VP8 is BT.601 with limited range (RFC 6386 section 9.2). }
  Frame.ColorPrimaries := 6;
  Frame.TransferCharacteristics := 6;
  Frame.MatrixCoefficients := 6;
  Frame.FullRange := False;
  for Index := 0 to 2 do
  begin
    if Index = 0 then
    begin
      PlaneWidth := DisplayWidth;
      PlaneHeight := DisplayHeight;
    end
    else
    begin
      PlaneWidth := (DisplayWidth + 1) div 2;
      PlaneHeight := (DisplayHeight + 1) div 2;
    end;
    Frame.Planes[Index].Width := PlaneWidth;
    Frame.Planes[Index].Height := PlaneHeight;
    Frame.Planes[Index].Stride := PlaneWidth;
    Frame.Planes[Index].Data := nil;
    SetLength(Frame.Planes[Index].Data, PlaneWidth * PlaneHeight);
    for Row := 0 to PlaneHeight - 1 do
      Move((Planes[Index].Origin + Row * Planes[Index].Stride)^,
        Frame.Planes[Index].Data[Row * PlaneWidth], PlaneWidth);
  end;
end;

end.
