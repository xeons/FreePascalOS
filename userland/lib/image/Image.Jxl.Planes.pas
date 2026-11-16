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
  Planes of floating point samples, what a JPEG XL frame is rendered
  into: three colour planes (XYB, YCbCr or the colour space's own
  channels, in the nominal range 0 to 1 once converted) and one per
  extra channel. A plane's lines follow each other with no gap.
}
unit Image.Jxl.Planes;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors;

type
  TJxlPlane = class
  public
    Width: LongInt;
    Height: LongInt;
    Samples: array of Single;
    { A Width x Height plane of zeros. }
    constructor Create(PlaneWidth, PlaneHeight: LongInt);
    function Row(Y: LongInt): PSingle; inline;
    { The sample at (X, Y) with coordinates outside mirrored (the edge
      sample repeated, then the ones inside: -1 is 0, -2 is 1). }
    function MirroredSample(X, Y: LongInt): Single;
    function Clone: TJxlPlane;
    procedure Fill(Value: Single);
  end;

  TJxlPlaneSet = array of TJxlPlane;

{ X mirrored into 0 to Size - 1 as libjxl's render pipeline does. }
function JxlMirror(X, Size: LongInt): LongInt;
procedure FreeJxlPlanes(var Planes: TJxlPlaneSet);
{ Raises ImageErrorTooLarge for a plane that cannot be allocated. }
procedure CheckJxlPlaneSize(Width, Height: Int64);

implementation

const
  MaximumPlaneSamples = Int64(256) * 1024 * 1024;

procedure CheckJxlPlaneSize(Width, Height: Int64);
begin
  if (Width < 0) or (Height < 0) or (Width * Height > MaximumPlaneSamples) then
    RaiseImageError(ImageErrorTooLarge, 'JPEG XL plane ' + IntToStr(Width) + ' x ' + IntToStr(Height));
end;

function JxlMirror(X, Size: LongInt): LongInt;
begin
  if Size <= 0 then
    Exit(0);
  while (X < 0) or (X >= Size) do
    if X < 0 then
      X := -X - 1
    else
      X := 2 * Size - 1 - X;
  Result := X;
end;

procedure FreeJxlPlanes(var Planes: TJxlPlaneSet);
var
  Index: LongInt;
begin
  for Index := 0 to High(Planes) do
    Planes[Index].Free;
  Planes := nil;
end;

constructor TJxlPlane.Create(PlaneWidth, PlaneHeight: LongInt);
begin
  inherited Create;
  CheckJxlPlaneSize(PlaneWidth, PlaneHeight);
  Width := PlaneWidth;
  Height := PlaneHeight;
  SetLength(Samples, Int64(PlaneWidth) * PlaneHeight + 1);
end;

function TJxlPlane.Row(Y: LongInt): PSingle;
begin
  Result := PSingle(@Samples[0]) + PtrInt(Y) * Width;
end;

function TJxlPlane.MirroredSample(X, Y: LongInt): Single;
begin
  Result := Samples[PtrInt(JxlMirror(Y, Height)) * Width + JxlMirror(X, Width)];
end;

function TJxlPlane.Clone: TJxlPlane;
begin
  Result := TJxlPlane.Create(0, 0);
  Result.Width := Width;
  Result.Height := Height;
  Result.Samples := Copy(Samples);
end;

procedure TJxlPlane.Fill(Value: Single);
var
  Index: PtrInt;
begin
  for Index := 0 to High(Samples) do
    Samples[Index] := Value;
end;

end.
