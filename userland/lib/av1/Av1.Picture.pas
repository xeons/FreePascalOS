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
  The decoder's pictures: three planes of 16-bit samples (8, 10 and
  12-bit streams alike), each with room past its visible size, since the
  decoding process writes whole blocks and superblocks reach past the
  frame's right and bottom edges.
}
unit Av1.Picture;

{$mode objfpc}

interface

type
  TPlane = record
    Samples: array of Word;
    Stride: Integer;                  { samples per row }
    Width, Height: Integer;           { the visible samples }
    AllocatedWidth, AllocatedHeight: Integer;
  end;
  PPlane = ^TPlane;

  TPicture = class
  public
    Planes: array[0..2] of TPlane;
    NumPlanes: Integer;
    BitDepth: Integer;
    SubsamplingX, SubsamplingY: Integer;
    { Planes for a Width by Height luma picture, with Padding samples of
      room (luma; halved for subsampled chroma) past the right and bottom. }
    constructor Create(Width, Height, ASubsamplingX, ASubsamplingY, ANumPlanes, ABitDepth,
      Padding: Integer);
    function Sample(Plane, X, Y: Integer): Integer; inline;
    function Row(Plane, Y: Integer): PWord; inline;
    procedure CopyFrom(Source: TPicture);
  end;

function AlignUp(Value, Alignment: Integer): Integer; inline;

implementation

function AlignUp(Value, Alignment: Integer): Integer;
begin
  Result := (Value + Alignment - 1) div Alignment * Alignment;
end;

constructor TPicture.Create(Width, Height, ASubsamplingX, ASubsamplingY, ANumPlanes, ABitDepth,
  Padding: Integer);
var
  PlaneIndex, SubX, SubY: Integer;
  Plane: PPlane;
begin
  inherited Create;
  NumPlanes := ANumPlanes;
  BitDepth := ABitDepth;
  SubsamplingX := ASubsamplingX;
  SubsamplingY := ASubsamplingY;
  for PlaneIndex := 0 to NumPlanes - 1 do
  begin
    if PlaneIndex = 0 then
    begin
      SubX := 0;
      SubY := 0;
    end
    else
    begin
      SubX := SubsamplingX;
      SubY := SubsamplingY;
    end;
    Plane := @Planes[PlaneIndex];
    Plane^.Width := (Width + SubX) shr SubX;
    Plane^.Height := (Height + SubY) shr SubY;
    Plane^.AllocatedWidth := AlignUp(Plane^.Width + (Padding shr SubX), 16);
    Plane^.AllocatedHeight := Plane^.Height + (Padding shr SubY);
    Plane^.Stride := Plane^.AllocatedWidth;
    SetLength(Plane^.Samples, Plane^.Stride * Plane^.AllocatedHeight);
  end;
end;

function TPicture.Sample(Plane, X, Y: Integer): Integer;
begin
  Result := Planes[Plane].Samples[Y * Planes[Plane].Stride + X];
end;

function TPicture.Row(Plane, Y: Integer): PWord;
begin
  Result := @Planes[Plane].Samples[Y * Planes[Plane].Stride];
end;

procedure TPicture.CopyFrom(Source: TPicture);
var
  PlaneIndex: Integer;
begin
  for PlaneIndex := 0 to NumPlanes - 1 do
    if Length(Planes[PlaneIndex].Samples) > 0 then
      Move(Source.Planes[PlaneIndex].Samples[0], Planes[PlaneIndex].Samples[0],
        Length(Planes[PlaneIndex].Samples) * SizeOf(Word));
end;

end.
