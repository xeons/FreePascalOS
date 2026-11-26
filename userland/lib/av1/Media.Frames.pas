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
  Decoded video frames and audio buffers as the media libraries hand
  them to programs.

  This is a copy of libmedia's unit (userland/lib/media), kept identical
  to it so that libav1 builds until libmedia is merged; libmedia's copy
  is the one that stays (it also has ConvertFrameToBgra).
}
unit Media.Frames;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TPixelLayout = (pl420, pl422, pl444, plMonochrome);
  TVideoPlane = record
    Data: TBytes;        { samples: 1 byte each when BitDepth = 8, else 2 bytes little-endian }
    Stride: Integer;     { bytes per row }
    Width, Height: Integer;
  end;
  TVideoFrame = record
    Width, Height: Integer;          { display size }
    BitDepth: Integer;               { 8, 10 or 12 }
    Layout: TPixelLayout;
    Planes: array[0..2] of TVideoPlane;  { Y, U (Cb), V (Cr) }
    ColorPrimaries, TransferCharacteristics, MatrixCoefficients: Integer; { ITU-T H.273 codes }
    FullRange: Boolean;
    PresentationTime: Int64;         { in TimeBase units }
  end;
  TAudioBuffer = record
    SampleRate: Integer;
    Channels: Integer;
    Samples: array of Single;        { interleaved, -1..1 }
    PresentationTime: Int64;
  end;

implementation

end.
