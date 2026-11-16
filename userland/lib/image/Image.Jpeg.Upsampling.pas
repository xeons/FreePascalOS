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
  Bringing a subsampled component up to the picture's size, a line at a
  time.

  A component at full size is used as it is. Half width, half height or
  both (4:2:2, 4:4:0, 4:2:0) use the "fancy" triangle filter of the
  Independent JPEG Group's library, with its rounding, so the result is
  what libjpeg and libjpeg-turbo give by default: each output sample is
  3/4 of the nearest input sample and 1/4 of the next nearest (9/16,
  3/16, 3/16, 1/16 in both directions); at the edges the edge sample
  goes on. Other whole ratios (4:1:1...) repeat samples, and factors that
  do not divide take the sample under each output sample.

  UpsampleLine gives the line Y of the picture in a component; the
  pointer is into the component's plane or into Buffer, which must hold
  UpsampleBufferSize bytes.
}
unit Image.Jpeg.Upsampling;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jpeg.Frames;

function UpsampleBufferSize(constref Frame: TJpegFrame): PtrInt;
function UpsampleLine(constref Frame: TJpegFrame; constref Component: TJpegComponent; Y: LongInt;
  Buffer: PByte): PByte;

implementation

function UpsampleBufferSize(constref Frame: TJpegFrame): PtrInt;
begin
  Result := PtrInt(Frame.McusPerLine) * 8 * Frame.MaximumHorizontalFactor + 32;
end;

function ComponentLine(constref Component: TJpegComponent; Row: LongInt): PByte; inline;
begin
  if Row < 0 then
    Row := 0
  else if Row >= Component.Height then
    Row := Component.Height - 1;
  Result := @Component.Plane[PtrInt(Row) * Component.PlaneStride];
end;

{ Twice as wide: libjpeg's h2v1_fancy_upsample. }
procedure UpsampleHorizontally(Input: PByte; Width: LongInt; Output: PByte);
var
  Column: LongInt;
  Current: LongInt;
begin
  Current := Input[0];
  Output[0] := Current;
  Output[1] := (Current * 3 + Input[1] + 2) shr 2;
  for Column := 1 to Width - 2 do
  begin
    Current := Input[Column] * 3;
    Output[2 * Column] := (Current + Input[Column - 1] + 1) shr 2;
    Output[2 * Column + 1] := (Current + Input[Column + 1] + 2) shr 2;
  end;
  Current := Input[Width - 1];
  Output[2 * Width - 2] := (Current * 3 + Input[Width - 2] + 1) shr 2;
  Output[2 * Width - 1] := Current;
end;

{ Twice as high: libjpeg-turbo's h1v2_fancy_upsample. }
procedure UpsampleVertically(Nearer, Further: PByte; Width: LongInt; Bias: LongInt; Output: PByte);
var
  Column: LongInt;
begin
  for Column := 0 to Width - 1 do
    Output[Column] := (Nearer[Column] * 3 + Further[Column] + Bias) shr 2;
end;

{ Twice as wide and high: libjpeg's h2v2_fancy_upsample. }
procedure UpsampleBoth(Nearer, Further: PByte; Width: LongInt; Output: PByte);
var
  Column: LongInt;
  ThisSum: LongInt;
  LastSum: LongInt;
  NextSum: LongInt;
begin
  ThisSum := Nearer[0] * 3 + Further[0];
  NextSum := Nearer[1] * 3 + Further[1];
  Output[0] := (ThisSum * 4 + 8) shr 4;
  Output[1] := (ThisSum * 3 + NextSum + 7) shr 4;
  LastSum := ThisSum;
  ThisSum := NextSum;
  for Column := 1 to Width - 2 do
  begin
    NextSum := Nearer[Column + 1] * 3 + Further[Column + 1];
    Output[2 * Column] := (ThisSum * 3 + LastSum + 8) shr 4;
    Output[2 * Column + 1] := (ThisSum * 3 + NextSum + 7) shr 4;
    LastSum := ThisSum;
    ThisSum := NextSum;
  end;
  Output[2 * Width - 2] := (ThisSum * 3 + LastSum + 8) shr 4;
  Output[2 * Width - 1] := (ThisSum * 4 + 7) shr 4;
end;

procedure RepeatSamples(Input: PByte; HorizontalRatio, Count: LongInt; Output: PByte);
var
  Column: LongInt;
begin
  for Column := 0 to Count - 1 do
    Output[Column] := Input[Column div HorizontalRatio];
end;

procedure NearestSamples(constref Frame: TJpegFrame; constref Component: TJpegComponent; Input: PByte;
  Output: PByte);
var
  Column: LongInt;
begin
  for Column := 0 to Frame.Width - 1 do
    Output[Column] := Input[(Column * Component.HorizontalFactor) div Frame.MaximumHorizontalFactor];
end;

function UpsampleLine(constref Frame: TJpegFrame; constref Component: TJpegComponent; Y: LongInt;
  Buffer: PByte): PByte;
var
  HorizontalRatio: LongInt;
  VerticalRatio: LongInt;
  Row: LongInt;
  Neighbour: LongInt;
  Bias: LongInt;
begin
  if (Frame.MaximumHorizontalFactor mod Component.HorizontalFactor <> 0) or
    (Frame.MaximumVerticalFactor mod Component.VerticalFactor <> 0) then
  begin
    Row := (Y * Component.VerticalFactor) div Frame.MaximumVerticalFactor;
    NearestSamples(Frame, Component, ComponentLine(Component, Row), Buffer);
    Exit(Buffer);
  end;
  HorizontalRatio := Frame.MaximumHorizontalFactor div Component.HorizontalFactor;
  VerticalRatio := Frame.MaximumVerticalFactor div Component.VerticalFactor;
  Row := Y div VerticalRatio;
  if (HorizontalRatio = 1) and (VerticalRatio = 1) then
    Exit(ComponentLine(Component, Row));
  Result := Buffer;
  if (HorizontalRatio = 2) and (VerticalRatio = 1) and (Component.Width > 2) then
    UpsampleHorizontally(ComponentLine(Component, Row), Component.Width, Buffer)
  else if (HorizontalRatio = 1) and (VerticalRatio = 2) then
  begin
    if Y mod 2 = 0 then
    begin
      Neighbour := Row - 1;
      Bias := 1;
    end
    else
    begin
      Neighbour := Row + 1;
      Bias := 2;
    end;
    UpsampleVertically(ComponentLine(Component, Row), ComponentLine(Component, Neighbour), Component.Width, Bias,
      Buffer);
  end
  else if (HorizontalRatio = 2) and (VerticalRatio = 2) and (Component.Width > 2) then
  begin
    if Y mod 2 = 0 then
      Neighbour := Row - 1
    else
      Neighbour := Row + 1;
    UpsampleBoth(ComponentLine(Component, Row), ComponentLine(Component, Neighbour), Component.Width, Buffer);
  end
  else
    RepeatSamples(ComponentLine(Component, Row), HorizontalRatio, Frame.Width, Buffer);
end;

end.
