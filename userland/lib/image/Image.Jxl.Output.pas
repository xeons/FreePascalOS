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
  A rendered JPEG XL canvas as libimage pixels: each sample clamped to
  0..1 and brought to 8 bits. Integer samples of B bits are first put
  back on their own scale (exact, the float error being far below half
  a step) and then rounded as libimage rounds 16-bit PNG samples,
  (V x 255 + (2^B - 1) div 2) div (2^B - 1), so a lossless image comes
  out exactly; floating point samples are rounded directly. The first
  alpha extra channel is the alpha; premultiplied ("associated") alpha
  is divided out, libimage's colours being straight.
}
unit Image.Jxl.Output;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Model,
  Image.Jxl.Headers,
  Image.Jxl.Planes;

{ A new image of Planes (three colour planes then the extra channels,
  all Width x Height). }
function JxlPlanesToImage(const Planes: TJxlPlaneSet; const Metadata: TJxlImageMetadata): TImage;

implementation

type
  TSampleScale = record
    IsInteger: Boolean;
    Maximum: Int64;
  end;

function ScaleOf(const BitDepth: TJxlBitDepth; XybEncoded: Boolean): TSampleScale;
begin
  Result.IsInteger := (not BitDepth.FloatSample) and (not XybEncoded) and (BitDepth.BitsPerSample >= 1) and
    (BitDepth.BitsPerSample <= 24);
  if Result.IsInteger then
    Result.Maximum := (Int64(1) shl BitDepth.BitsPerSample) - 1
  else
    Result.Maximum := 255;
end;

function ToByte(Value: Single; const Scale: TSampleScale): Byte; inline;
var
  Level: Int64;
begin
  if not (Value > 0) then
    Exit(0);
  if Value >= 1 then
    Exit(255);
  if not Scale.IsInteger then
    Exit(Byte(Trunc(Value * 255 + 0.5)));
  Level := Trunc(Value * Scale.Maximum + 0.5);
  Result := Byte((Level * 255 + Scale.Maximum div 2) div Scale.Maximum);
end;

function JxlPlanesToImage(const Planes: TJxlPlaneSet; const Metadata: TJxlImageMetadata): TImage;
var
  Width: LongInt;
  Height: LongInt;
  AlphaIndex: LongInt;
  ColorScale: TSampleScale;
  AlphaScale: TSampleScale;
  Premultiplied: Boolean;
  X: LongInt;
  Y: LongInt;
  Line: PLongWord;
  Red: PSingle;
  Green: PSingle;
  Blue: PSingle;
  AlphaRow: PSingle;
  Alpha: Single;
  RedValue: Single;
  GreenValue: Single;
  BlueValue: Single;
  AlphaByte: LongWord;
begin
  Width := Planes[0].Width;
  Height := Planes[0].Height;
  Result := TImage.Create(Width, Height);
  try
    AlphaIndex := JxlAlphaChannelIndex(Metadata);
    if (AlphaIndex >= 0) and (3 + AlphaIndex > High(Planes)) then
      AlphaIndex := -1;
    ColorScale := ScaleOf(Metadata.BitDepth, Metadata.XybEncoded);
    Premultiplied := False;
    if AlphaIndex >= 0 then
    begin
      AlphaScale := ScaleOf(Metadata.ExtraChannels[AlphaIndex].BitDepth, False);
      Premultiplied := Metadata.ExtraChannels[AlphaIndex].AlphaAssociated;
    end;
    for Y := 0 to Height - 1 do
    begin
      Line := Result.Line(Y);
      Red := Planes[0].Row(Y);
      Green := Planes[1].Row(Y);
      Blue := Planes[2].Row(Y);
      AlphaRow := nil;
      if AlphaIndex >= 0 then
        AlphaRow := Planes[3 + AlphaIndex].Row(Y);
      for X := 0 to Width - 1 do
      begin
        RedValue := Red[X];
        GreenValue := Green[X];
        BlueValue := Blue[X];
        AlphaByte := 255;
        if AlphaRow <> nil then
        begin
          Alpha := AlphaRow[X];
          AlphaByte := ToByte(Alpha, AlphaScale);
          if Premultiplied and (Alpha > 0) then
          begin
            RedValue := RedValue / Alpha;
            GreenValue := GreenValue / Alpha;
            BlueValue := BlueValue / Alpha;
          end;
        end;
        Line[X] := (AlphaByte shl 24) or (LongWord(ToByte(RedValue, ColorScale)) shl 16) or
          (LongWord(ToByte(GreenValue, ColorScale)) shl 8) or LongWord(ToByte(BlueValue, ColorScale));
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
