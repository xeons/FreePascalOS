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
  JPEG XL's gaborish filter (ISO/IEC 18181-1 annex J.2): a 3 x 3
  convolution of each colour plane, symmetric (one weight for the
  centre, one for the four sides, one for the four corners, normalized
  to sum to 1), smoothing the edges between blocks; the encoder
  sharpened the picture with its inverse. Samples off the planes' edges
  are mirrored.
}
unit Image.Jxl.Gaborish;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.Planes,
  Image.Jxl.FrameHeader;

{ Filters planes 0 to 2 in place. }
procedure ApplyJxlGaborish(const Planes: TJxlPlaneSet; const Filter: TJxlLoopFilter);

implementation

procedure FilterPlane(Plane: TJxlPlane; CenterWeight, SideWeight, CornerWeight: Single);
var
  Source: TJxlPlane;
  X: LongInt;
  Y: LongInt;
  Above: PSingle;
  Middle: PSingle;
  Below: PSingle;
  Output: PSingle;
  Left: LongInt;
  Right: LongInt;
  Sides: Single;
  Corners: Single;
begin
  Source := Plane.Clone;
  try
    for Y := 0 to Plane.Height - 1 do
    begin
      Above := Source.Row(JxlMirror(Y - 1, Plane.Height));
      Middle := Source.Row(Y);
      Below := Source.Row(JxlMirror(Y + 1, Plane.Height));
      Output := Plane.Row(Y);
      for X := 0 to Plane.Width - 1 do
      begin
        Left := JxlMirror(X - 1, Plane.Width);
        Right := JxlMirror(X + 1, Plane.Width);
        Sides := (Middle[Left] + Middle[Right]) + (Above[X] + Below[X]);
        Corners := (Above[Left] + Above[Right]) + (Below[Left] + Below[Right]);
        Output[X] := Corners * CornerWeight + (Sides * SideWeight + Middle[X] * CenterWeight);
      end;
    end;
  finally
    Source.Free;
  end;
end;

procedure ApplyJxlGaborish(const Planes: TJxlPlaneSet; const Filter: TJxlLoopFilter);
var
  Channel: LongInt;
  Center: Single;
  Side: Single;
  Corner: Single;
  Normalizer: Single;
begin
  if (not Filter.Gaborish) or (Length(Planes) < 3) then
    Exit;
  for Channel := 0 to 2 do
  begin
    Center := 1;
    Side := Filter.GaborishWeights[Channel, 0];
    Corner := Filter.GaborishWeights[Channel, 1];
    Normalizer := 1.0 / (Center + 4 * (Side + Corner));
    FilterPlane(Planes[Channel], Center * Normalizer, Side * Normalizer, Corner * Normalizer);
  end;
end;

end.
