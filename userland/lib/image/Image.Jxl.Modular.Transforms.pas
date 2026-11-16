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
  JPEG XL's modular transforms (ISO/IEC 18181-1 annex I.3): reversible
  colour transforms (RCT: a permutation of three channels and one of
  seven integer transforms, YCoCg-R among them), palettes
  (Image.Jxl.Modular.Palette) and squeezes (Image.Jxl.Modular.Squeeze).

  A group header lists the transforms. As it is read each one changes
  the channel list ("meta" application) so the channels are decoded at
  the sizes they were coded at; once the channels are decoded the
  transforms are undone in reverse order.
}
unit Image.Jxl.Modular.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Weighted,
  Image.Jxl.Modular.Squeeze;

const
  JxlTransformRct = 0;
  JxlTransformPalette = 1;
  JxlTransformSqueeze = 2;

type
  TJxlTransform = record
    Kind: LongWord;
    BeginChannel: LongWord;
    RctType: LongWord;
    ChannelCount: LongWord;
    ColorCount: LongWord;
    DeltaCount: LongWord;
    Predictor: LongInt;
    Squeezes: TJxlSqueezeList;
  end;

  TJxlTransformList = array of TJxlTransform;

function ReadJxlTransform(Reader: TJxlBitReader): TJxlTransform;
{ Changes the channel list as Transform does (fills in default squeezes). }
procedure ApplyJxlTransformToChannels(Image: TJxlModularImage; var Transform: TJxlTransform);
{ Undoes Transform. }
procedure InvertJxlTransform(Image: TJxlModularImage; const Transform: TJxlTransform;
  const WeightedHeader: TJxlWeightedHeader);

implementation

uses
  Image.Jxl.Modular.Tree,
  Image.Jxl.Modular.Palette;

procedure RaiseBadTransform(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL transform: ' + Detail);
end;

function ReadJxlTransform(Reader: TJxlBitReader): TJxlTransform;
var
  Count: LongWord;
  Index: LongWord;
begin
  Result := Default(TJxlTransform);
  Result.Kind := Reader.ReadU32(JxlVal(0), JxlVal(1), JxlVal(2), JxlVal(3));
  if Result.Kind > JxlTransformSqueeze then
    RaiseBadTransform('unknown transform');
  if (Result.Kind = JxlTransformRct) or (Result.Kind = JxlTransformPalette) then
    Result.BeginChannel := Reader.ReadU32(JxlBits(3), JxlBitsOffset(6, 8), JxlBitsOffset(10, 72),
      JxlBitsOffset(13, 1096));
  if Result.Kind = JxlTransformRct then
  begin
    Result.RctType := Reader.ReadU32(JxlVal(6), JxlBits(2), JxlBitsOffset(4, 2), JxlBitsOffset(6, 10));
    if Result.RctType >= 42 then
      RaiseBadTransform('bad RCT type');
  end;
  if Result.Kind = JxlTransformPalette then
  begin
    Result.ChannelCount := Reader.ReadU32(JxlVal(1), JxlVal(3), JxlVal(4), JxlBitsOffset(13, 1));
    Result.ColorCount := Reader.ReadU32(JxlBitsOffset(8, 0), JxlBitsOffset(10, 256), JxlBitsOffset(12, 1280),
      JxlBitsOffset(16, 5376));
    Result.DeltaCount := Reader.ReadU32(JxlVal(0), JxlBitsOffset(8, 1), JxlBitsOffset(10, 257),
      JxlBitsOffset(16, 1281));
    Result.Predictor := LongInt(Reader.ReadBits(4));
    if Result.Predictor >= JxlPredictorCount then
      RaiseBadTransform('bad palette predictor');
  end;
  if Result.Kind = JxlTransformSqueeze then
  begin
    Count := Reader.ReadU32(JxlVal(0), JxlBitsOffset(4, 1), JxlBitsOffset(6, 9), JxlBitsOffset(8, 41));
    SetLength(Result.Squeezes, Count);
    for Index := 1 to Count do
      Result.Squeezes[Index - 1] := ReadJxlSqueezeParameters(Reader);
  end;
end;

procedure CheckRctChannels(Image: TJxlModularImage; First: LongWord);
var
  Index: LongInt;
begin
  if QWord(First) + 3 > QWord(Image.ChannelCount) then
    RaiseBadTransform('bad RCT channels');
  if (LongInt(First) < Image.MetaChannelCount) and (LongInt(First) + 2 >= Image.MetaChannelCount) then
    RaiseBadTransform('RCT of meta and other channels');
  for Index := LongInt(First) + 1 to LongInt(First) + 2 do
    if (Image[Index].Width <> Image[First].Width) or (Image[Index].Height <> Image[First].Height) or
      (Image[Index].HorizontalShift <> Image[First].HorizontalShift) or
      (Image[Index].VerticalShift <> Image[First].VerticalShift) then
      RaiseBadTransform('RCT of channels of different sizes');
end;

procedure ApplyJxlTransformToChannels(Image: TJxlModularImage; var Transform: TJxlTransform);
begin
  case Transform.Kind of
    JxlTransformRct:
      CheckRctChannels(Image, Transform.BeginChannel);
    JxlTransformPalette:
      ApplyJxlPaletteToChannels(Image, Transform.BeginChannel, Transform.ChannelCount, Transform.ColorCount,
        Transform.DeltaCount);
  else
    ApplyJxlSqueezeToChannels(Image, Transform.Squeezes);
  end;
end;

function Wrap32(Value: Int64): Int64; inline;
begin
  Result := LongInt(Value and $FFFFFFFF);
end;

{ Puts Channels[k] at position First + Outputs[k] by exchanging list
  entries (no channel is freed). }
procedure PlaceChannels(Image: TJxlModularImage; First: LongWord; const Channels: array of TJxlChannel;
  const Outputs: array of LongInt);
var
  Target: array[0..2] of TJxlChannel;
  Position: LongInt;
  Current: LongInt;
begin
  for Position := 0 to 2 do
    Target[Outputs[Position]] := Channels[Position];
  for Position := 0 to 2 do
    for Current := Position to 2 do
      if Image[First + LongWord(Current)] = Target[Position] then
      begin
        if Current <> Position then
          Image.ExchangeChannels(First + LongWord(Position), First + LongWord(Current));
        Break;
      end;
end;

procedure InvertRct(Image: TJxlModularImage; First, RctType: LongWord);
var
  Permutation: LongInt;
  Kind: LongInt;
  Channels: array[0..2] of TJxlChannel;
  Outputs: array[0..2] of LongInt;
  Count: PtrInt;
  Index: PtrInt;
  Line0: PLongInt;
  Line1: PLongInt;
  Line2: PLongInt;
  A: Int64;
  B: Int64;
  C: Int64;
  Temporary: Int64;
  Second: LongInt;
  Third: Boolean;
  Channel: LongInt;
begin
  if RctType = 0 then
    Exit;
  CheckRctChannels(Image, First);
  Permutation := RctType div 7;
  Kind := RctType mod 7;
  for Channel := 0 to 2 do
    Channels[Channel] := Image[First + LongWord(Channel)];
  if Kind <> 0 then
  begin
    Count := PtrInt(Channels[0].Width) * Channels[0].Height;
    Line0 := @Channels[0].Pixels[0];
    Line1 := @Channels[1].Pixels[0];
    Line2 := @Channels[2].Pixels[0];
    Second := Kind shr 1;
    Third := (Kind and 1) <> 0;
    for Index := 0 to Count - 1 do
    begin
      A := Line0[Index];
      B := Line1[Index];
      C := Line2[Index];
      if Kind = 6 then
      begin
        { YCoCg-R: A is Y, B is Co, C is Cg; out red, green, blue. }
        Temporary := Wrap32(A - SarInt64(C, 1));
        C := Wrap32(Temporary - SarInt64(B, 1));
        A := Wrap32(C + B);
        B := Wrap32(Line2[Index] + Temporary);
      end
      else
      begin
        if Third then
          C := Wrap32(C + A);
        if Second = 1 then
          B := Wrap32(B + A)
        else if Second = 2 then
          B := Wrap32(B + SarInt64(A + C, 1));
      end;
      Line0[Index] := LongInt(A);
      Line1[Index] := LongInt(B);
      Line2[Index] := LongInt(C);
    end;
  end;
  Outputs[0] := Permutation mod 3;
  Outputs[1] := (Permutation + 1 + Permutation div 3) mod 3;
  Outputs[2] := (Permutation + 2 - Permutation div 3) mod 3;
  if (Outputs[0] <> 0) or (Outputs[1] <> 1) or (Outputs[2] <> 2) then
    PlaceChannels(Image, First, Channels, Outputs);
end;

procedure InvertJxlTransform(Image: TJxlModularImage; const Transform: TJxlTransform;
  const WeightedHeader: TJxlWeightedHeader);
begin
  case Transform.Kind of
    JxlTransformRct:
      InvertRct(Image, Transform.BeginChannel, Transform.RctType);
    JxlTransformPalette:
      InvertJxlPalette(Image, Transform.BeginChannel, Transform.ColorCount, Transform.DeltaCount,
        Transform.Predictor, WeightedHeader);
  else
    InvertJxlSqueeze(Image, Transform.Squeezes);
  end;
end;

end.
