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
  JPEG XL's noise parameters (ISO/IEC 18181-1 annex J.4): eight points
  of a noise strength curve against intensity, 10 bits each, in the LF
  global section of frames with the noise flag.

  Noise synthesis (pseudo-random noise per group from a XorShift128+
  generator, convolved and added in proportion to the curve) is not
  done: ApplyJxlNoise leaves the planes as they are, so a frame with
  noise decodes without the grain the encoder asked to add.
}
unit Image.Jxl.Noise;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Jxl.BitReader,
  Image.Jxl.Planes,
  Image.Jxl.FrameHeader;

const
  JxlNoisePoints = 8;

type
  TJxlNoiseParameters = record
    Curve: array[0..JxlNoisePoints - 1] of Single;
  end;

function ReadJxlNoiseParameters(Reader: TJxlBitReader): TJxlNoiseParameters;
{ Adds the noise to the X, Y and B planes (not implemented: does
  nothing). }
procedure ApplyJxlNoise(const Planes: TJxlPlaneSet; const Parameters: TJxlNoiseParameters;
  const Frame: TJxlFrameHeader);

implementation

const
  NoisePrecision = 1024.0;

function ReadJxlNoiseParameters(Reader: TJxlBitReader): TJxlNoiseParameters;
var
  Index: LongInt;
begin
  for Index := 0 to JxlNoisePoints - 1 do
    Result.Curve[Index] := Reader.ReadBits(10) / NoisePrecision;
end;

procedure ApplyJxlNoise(const Planes: TJxlPlaneSet; const Parameters: TJxlNoiseParameters;
  const Frame: TJxlFrameHeader);
begin
end;

end.
