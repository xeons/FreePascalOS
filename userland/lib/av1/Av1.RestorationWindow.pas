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
  The samples a loop restoration filter reads around a block: the get
  source sample process (specification section 7.17.6) evaluated once
  for every position within 3 samples of the block, so that the filters
  read a plain array. Inside the block's stripe the samples come from
  UpscaledCdefFrame, above and below it from UpscaledCurrFrame (at most
  2 rows away), and positions past the plane's edges repeat the edge.
}
unit Av1.RestorationWindow;

{$mode objfpc}

interface

uses
  Av1.Picture;

const
  RestorationBlockMax = 64;          { largest block filtered at once }
  RestorationMargin = 3;
  RestorationWindowSize = RestorationBlockMax + 2 * RestorationMargin;

type
  { One block's sources and the filters' work arrays. }
  TRestorationScratch = class
  public
    { Window[ i ][ j ] = get_source_sample( x + j - 3, y + i - 3 ). }
    Window: array[0..RestorationWindowSize - 1, 0..RestorationWindowSize - 1] of Integer;
    { Box filter A and B, from -1: [ i + 1 ][ j + 1 ]. }
    BoxA, BoxB: array[0..RestorationBlockMax + 1, 0..RestorationBlockMax + 1] of Integer;
    Filtered: array[0..1, 0..RestorationBlockMax - 1, 0..RestorationBlockMax - 1] of Integer;
    Intermediate: array[0..RestorationBlockMax + 5, 0..RestorationBlockMax - 1] of Integer;
  end;

  { Where a block of one plane lies, and the limits of its sources. }
  TRestorationBlock = record
    Plane: Integer;
    X, Y, W, H: Integer;
    StripeStartY, StripeEndY: Integer;
    PlaneEndX, PlaneEndY: Integer;
  end;

{ Fills Scratch.Window for the block. }
procedure FillRestorationWindow(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  UpscaledCurrFrame, UpscaledCdefFrame: TPicture);

implementation

procedure FillRestorationWindow(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  UpscaledCurrFrame, UpscaledCdefFrame: TPicture);
var
  I, J, SampleX, SampleY: Integer;
  Row: PWord;
  ColumnIndex: array[0..RestorationWindowSize - 1] of Integer;
begin
  for J := 0 to Block.W + 2 * RestorationMargin - 1 do
  begin
    SampleX := Block.X + J - RestorationMargin;
    if SampleX > Block.PlaneEndX then
      SampleX := Block.PlaneEndX;
    if SampleX < 0 then
      SampleX := 0;
    ColumnIndex[J] := SampleX;
  end;
  for I := 0 to Block.H + 2 * RestorationMargin - 1 do
  begin
    SampleY := Block.Y + I - RestorationMargin;
    if SampleY > Block.PlaneEndY then
      SampleY := Block.PlaneEndY;
    if SampleY < 0 then
      SampleY := 0;
    if SampleY < Block.StripeStartY then
    begin
      if SampleY < Block.StripeStartY - 2 then
        SampleY := Block.StripeStartY - 2;
      Row := UpscaledCurrFrame.Row(Block.Plane, SampleY);
    end
    else if SampleY > Block.StripeEndY then
    begin
      if SampleY > Block.StripeEndY + 2 then
        SampleY := Block.StripeEndY + 2;
      Row := UpscaledCurrFrame.Row(Block.Plane, SampleY);
    end
    else
      Row := UpscaledCdefFrame.Row(Block.Plane, SampleY);
    for J := 0 to Block.W + 2 * RestorationMargin - 1 do
      Scratch.Window[I][J] := Row[ColumnIndex[J]];
  end;
end;

end.
