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
  What a VP9 tile is decoded with besides the frame: its own boolean
  decoder, counts and left contexts, a scratch area for motion
  compensation and a transform block's coefficients; and the frame's
  above contexts (per column, so tiles side by side use disjoint parts
  of them).
}
unit Vp9.TileState;

{$mode objfpc}
{$H+}

interface

uses
  Video.BoolDecoder, Vp9.Probabilities, Vp9.InterPrediction, Vp9.FrameState;

type
  { The contexts above the blocks of a frame: whether each 4x4 column
    of each plane had coefficients, and each 8x8 column's partition. }
  TVp9AboveContexts = record
    Coefficients: array[0..2] of array of Byte;
    Partitions: array of Byte;
  end;
  PVp9AboveContexts = ^TVp9AboveContexts;

  TVp9TileState = class
  public
    Frame: PVp9FrameState;
    Above: PVp9AboveContexts;
    Decoder: TBoolDecoder;
    Counts: TVp9Counts;
    { @Counts when the frame counts, else nil. }
    CountsPointer: PVp9Counts;
    LeftCoefficients: array[0..2, 0..15] of Byte;
    LeftPartitions: array[0..7] of Byte;
    TileColumnStart, TileColumnEnd: LongInt;
    TileRowStart, TileRowEnd: LongInt;
    Scratch: TVp9PredictionScratch;
    Coefficients: array[0..32 * 32 - 1] of LongInt;
    constructor Create;
  end;

implementation

constructor TVp9TileState.Create;
begin
  inherited Create;
  FillChar(Coefficients, SizeOf(Coefficients), 0);
end;

end.
