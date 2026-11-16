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
  What a JPEG decoding keeps while it reads a file: the frame (its size,
  its components with their sampling factors, the blocks and decoded
  samples of each), the quantization and Huffman tables as the file
  defines them, the restart interval, and what the markers said about
  colour, orientation, density and the ICC profile.

  A component's samples (Plane) cover whole MCUs, so every block an
  interleaved scan decodes has its place; Width x Height of it is the
  picture, the rest is the padding the encoder added. Progressive
  frames keep every block's coefficients (Coefficients, 64 a block in
  natural order) until the last scan; sequential frames turn each block
  into samples as it is decoded.

  ZigzagToNatural maps the order coefficients come in to their place in
  the 8 x 8 block; it has 16 more entries (all 63) so a malformed run
  can never index past it.
}
unit Image.Jpeg.Frames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Jpeg.Huffman;

const
  JpegMaximumComponents = 4;

  ZigzagToNatural: array[0..79] of Byte = (
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63, 63);

type
  { Natural order (row by row). }
  TJpegQuantizationTable = array[0..63] of LongInt;

  TJpegComponent = record
    Identifier: Byte;
    HorizontalFactor: LongInt;
    VerticalFactor: LongInt;
    QuantizationIndex: LongInt;
    { The table as it was at the component's first scan. }
    Quantization: TJpegQuantizationTable;
    QuantizationLatched: Boolean;
    DcTableIndex: LongInt;
    AcTableIndex: LongInt;
    { Samples of the picture in this component. }
    Width: LongInt;
    Height: LongInt;
    { Blocks a scan of this component alone covers. }
    BlocksPerLine: LongInt;
    BlocksPerColumn: LongInt;
    { Blocks kept: whole MCUs. }
    StoredBlocksPerLine: LongInt;
    StoredBlocksPerColumn: LongInt;
    Plane: array of Byte;
    PlaneStride: LongInt;
    Coefficients: array of SmallInt;
    DcPredictor: LongInt;
  end;

  TJpegFrame = record
    Defined: Boolean;
    Width: LongInt;
    Height: LongInt;
    Progressive: Boolean;
    ComponentCount: LongInt;
    Components: array[0..JpegMaximumComponents - 1] of TJpegComponent;
    MaximumHorizontalFactor: LongInt;
    MaximumVerticalFactor: LongInt;
    McusPerLine: LongInt;
    McusPerColumn: LongInt;
  end;

  TJpegScan = record
    ComponentCount: LongInt;
    { Indices into the frame's components. }
    ComponentIndices: array[0..JpegMaximumComponents - 1] of LongInt;
    SpectralStart: LongInt;
    SpectralEnd: LongInt;
    ApproximationHigh: LongInt;
    ApproximationLow: LongInt;
  end;

  TJpegIccChunk = record
    Present: Boolean;
    Data: TBytes;
  end;

  TJpegState = class
  public
    Data: TBytes;
    Frame: TJpegFrame;
    QuantizationTables: array[0..3] of TJpegQuantizationTable;
    QuantizationDefined: array[0..3] of Boolean;
    DcTables: array[0..3] of THuffmanTable;
    AcTables: array[0..3] of THuffmanTable;
    RestartInterval: LongInt;
    { Progressive: the end-of-band run left over. }
    EndOfBandRun: LongInt;
    HasJfif: Boolean;
    HasAdobe: Boolean;
    AdobeTransform: LongInt;
    ExifOrientation: LongInt;
    DensityUnits: LongInt;
    HorizontalDensity: LongInt;
    VerticalDensity: LongInt;
    IccChunks: array of TJpegIccChunk;
    ScansDecoded: LongInt;
    { A scan stopped early: the data ended or broke off. }
    DataEnded: Boolean;
  end;

implementation

end.
