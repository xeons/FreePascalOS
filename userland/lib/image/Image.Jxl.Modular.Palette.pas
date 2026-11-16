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
  JPEG XL's palette transform (ISO/IEC 18181-1 annex I.3.3): several
  channels become one channel of indices and a meta channel holding the
  palette (one row per channel). Indices past the palette pick colours
  of two implicit colour cubes; negative ones pick from a fixed table
  of small deltas. The first DeltaCount entries are deltas: the value
  is the entry plus a prediction from the samples already rebuilt.
}
unit Image.Jxl.Modular.Palette;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.Modular.Channels,
  Image.Jxl.Modular.Weighted;

{ Changes the channel list as the palette does: channels BeginChannel
  to BeginChannel + ChannelCount - 1 become one, and the palette goes
  first. }
procedure ApplyJxlPaletteToChannels(Image: TJxlModularImage; BeginChannel, ChannelCount, ColorCount,
  DeltaCount: LongWord);
{ Undoes a palette. }
procedure InvertJxlPalette(Image: TJxlModularImage; BeginChannel, ColorCount, DeltaCount: LongWord;
  Predictor: LongInt; const WeightedHeader: TJxlWeightedHeader);

implementation

uses
  Image.Jxl.Modular.Tree,
  Image.Jxl.Modular.Predictors;

const
  LargeCube = 5;
  SmallCube = 4;
  SmallCubeBits = 2;
  LargeCubeOffset = SmallCube * SmallCube * SmallCube;
  DeltaPaletteSize = 72;
  DeltaPalette: array[0..DeltaPaletteSize - 1, 0..2] of LongInt = (
    (0, 0, 0), (4, 4, 4), (11, 0, 0), (0, 0, -13), (0, -12, 0), (-10, -10, -10),
    (-18, -18, -18), (-27, -27, -27), (-18, -18, 0), (0, 0, -32), (-32, 0, 0), (-37, -37, -37),
    (0, -32, -32), (24, 24, 45), (50, 50, 50), (-45, -24, -24), (-24, -45, -45), (0, -24, -24),
    (-34, -34, 0), (-24, 0, -24), (-45, -45, -24), (64, 64, 64), (-32, 0, -32), (0, -32, 0),
    (-32, 0, 32), (-24, -45, -24), (45, 24, 45), (24, -24, -45), (-45, -24, 24), (80, 80, 80),
    (64, 0, 0), (0, 0, -64), (0, -64, -64), (-24, -24, 45), (96, 96, 96), (64, 64, 0),
    (45, -24, -24), (34, -34, 0), (112, 112, 112), (24, -45, -45), (45, 45, -24), (0, -32, 32),
    (24, -24, 45), (0, 96, 96), (45, -24, 24), (24, -45, -24), (-24, -45, 24), (0, -64, 0),
    (96, 0, 0), (128, 128, 128), (64, 0, 64), (144, 144, 144), (96, 96, 0), (-36, -36, 36),
    (45, -24, -45), (45, -45, -24), (0, 0, -96), (0, 128, 128), (0, 96, 0), (45, 24, -45),
    (-128, 0, 0), (24, -45, 24), (-45, 24, -45), (64, 0, -64), (64, -64, -64), (96, 0, 96),
    (45, -45, 24), (24, 45, -45), (64, 64, -64), (128, 128, 0), (0, 0, -128), (-24, 45, -45));

procedure RaiseBadPalette(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL palette: ' + Detail);
end;

procedure CheckEqualChannels(Image: TJxlModularImage; First, Last: LongInt);
var
  Index: LongInt;
begin
  if (First < 0) or (Last >= Image.ChannelCount) or (Last < First) then
    RaiseBadPalette('bad channel range');
  if (First < Image.MetaChannelCount) and (Last >= Image.MetaChannelCount) then
    RaiseBadPalette('meta and other channels mixed');
  for Index := First + 1 to Last do
    if (Image[Index].Width <> Image[First].Width) or (Image[Index].Height <> Image[First].Height) or
      (Image[Index].HorizontalShift <> Image[First].HorizontalShift) or
      (Image[Index].VerticalShift <> Image[First].VerticalShift) then
      RaiseBadPalette('channels of different sizes');
end;

procedure ApplyJxlPaletteToChannels(Image: TJxlModularImage; BeginChannel, ChannelCount, ColorCount,
  DeltaCount: LongWord);
var
  First: LongInt;
  Last: LongInt;
  Palette: TJxlChannel;
begin
  if (ChannelCount = 0) or (QWord(BeginChannel) + ChannelCount > QWord(Image.ChannelCount)) then
    RaiseBadPalette('bad channel range');
  First := BeginChannel;
  Last := First + LongInt(ChannelCount) - 1;
  CheckEqualChannels(Image, First, Last);
  if First >= Image.MetaChannelCount then
    Inc(Image.MetaChannelCount)
  else
  begin
    if Last >= Image.MetaChannelCount then
      RaiseBadPalette('meta and other channels mixed');
    Image.MetaChannelCount := Image.MetaChannelCount + 2 - LongInt(ChannelCount);
  end;
  Image.DeleteChannels(First + 1, Last - First);
  Palette := TJxlChannel.Create(LongInt(ColorCount + DeltaCount), LongInt(ChannelCount), -1, -1);
  Image.InsertChannel(0, Palette);
end;

function ScaleCubeValue(Value: Int64; BitDepth: LongInt): LongInt;
begin
  Result := LongInt((QWord(Value) * ((QWord(1) shl BitDepth) - 1)) shr 2);
end;

function PaletteValue(Palette: TJxlChannel; Index: LongInt; Channel: LongInt; BitDepth: LongInt): LongInt;
var
  PaletteSize: LongInt;
  Position: LongInt;
  Shift: LongInt;
begin
  PaletteSize := Palette.Width;
  if Index < 0 then
  begin
    if Channel >= 3 then
      Exit(0);
    Position := -(Index + 1);
    Position := Position mod (1 + 2 * (DeltaPaletteSize - 1));
    Result := DeltaPalette[(Position + 1) shr 1, Channel];
    if (Position and 1) = 0 then
      Result := -Result;
    if BitDepth > 8 then
      Result := Result * (1 shl (BitDepth - 8));
    Exit;
  end;
  if (Index >= PaletteSize) and (Index < PaletteSize + LargeCubeOffset) then
  begin
    if Channel >= 3 then
      Exit(0);
    Position := Index - PaletteSize;
    Position := Position shr (Channel * SmallCubeBits);
    Shift := BitDepth - 3;
    if Shift < 0 then
      Shift := 0;
    Exit(ScaleCubeValue(Position mod SmallCube, BitDepth) + (1 shl Shift));
  end;
  if Index >= PaletteSize + LargeCubeOffset then
  begin
    if Channel >= 3 then
      Exit(0);
    Position := Index - PaletteSize - LargeCubeOffset;
    case Channel of
      1: Position := Position div LargeCube;
      2: Position := Position div (LargeCube * LargeCube);
    end;
    Exit(ScaleCubeValue(Position mod LargeCube, BitDepth));
  end;
  Result := Palette.Row(Channel)[Index];
end;

procedure InvertJxlPalette(Image: TJxlModularImage; BeginChannel, ColorCount, DeltaCount: LongWord;
  Predictor: LongInt; const WeightedHeader: TJxlWeightedHeader);
var
  Palette: TJxlChannel;
  ChannelCount: LongInt;
  IndexChannel: LongInt;
  Width: LongInt;
  Height: LongInt;
  BitDepth: LongInt;
  Channel: LongInt;
  Indices: array of LongInt;
  X: LongInt;
  Y: LongInt;
  Line: PLongInt;
  IndexLine: PLongInt;
  Index: LongInt;
  Entry: LongInt;
  Neighbours: TJxlNeighbours;
  Weighted: TJxlWeightedPredictor;
  WeightedPrediction: Int64;
  MaximumError: Int64;
  Output: TJxlChannel;
begin
  if Image.MetaChannelCount < 1 then
    RaiseBadPalette('no palette');
  Palette := Image[0];
  ChannelCount := Palette.Height;
  IndexChannel := LongInt(BeginChannel) + 1;
  if IndexChannel >= Image.ChannelCount then
    RaiseBadPalette('bad channel');
  if ChannelCount < 1 then
    RaiseBadPalette('empty palette');
  Width := Image[IndexChannel].Width;
  Height := Image[IndexChannel].Height;
  for Channel := 1 to ChannelCount - 1 do
    Image.InsertChannel(IndexChannel + 1, TJxlChannel.Create(Width, Height, Image[IndexChannel].HorizontalShift,
      Image[IndexChannel].VerticalShift));
  BitDepth := Image.BitDepth;
  if BitDepth > 24 then
    BitDepth := 24;
  if Width > 0 then
  begin
    Indices := Copy(Image[IndexChannel].Pixels);
    if (DeltaCount = 0) and (Predictor = JxlPredictorZero) then
    begin
      for Y := 0 to Height - 1 do
      begin
        IndexLine := PLongInt(@Indices[0]) + PtrInt(Y) * Width;
        for Channel := 0 to ChannelCount - 1 do
        begin
          Line := Image[IndexChannel + Channel].Row(Y);
          for X := 0 to Width - 1 do
          begin
            Index := IndexLine[X];
            if ChannelCount = 1 then
            begin
              if Index < 0 then
                Index := 0;
              if Index > Palette.Width - 1 then
                Index := Palette.Width - 1;
            end;
            Line[X] := PaletteValue(Palette, Index, Channel, BitDepth);
          end;
        end;
      end;
    end
    else
      for Channel := 0 to ChannelCount - 1 do
      begin
        Output := Image[IndexChannel + Channel];
        Weighted := nil;
        if Predictor = JxlPredictorWeighted then
          Weighted := TJxlWeightedPredictor.Create(WeightedHeader, Width);
        try
          for Y := 0 to Height - 1 do
          begin
            Line := Output.Row(Y);
            IndexLine := PLongInt(@Indices[0]) + PtrInt(Y) * Width;
            for X := 0 to Width - 1 do
            begin
              Index := IndexLine[X];
              Entry := PaletteValue(Palette, Index, Channel, BitDepth);
              GetJxlNeighbours(Line, Width, X, Y, Neighbours);
              WeightedPrediction := 0;
              if Weighted <> nil then
                WeightedPrediction := Weighted.Predict(X, Y, Neighbours.North, Neighbours.West,
                  Neighbours.NorthEast, Neighbours.NorthWest, Neighbours.NorthNorth, MaximumError);
              if Index < LongInt(DeltaCount) then
                Line[X] := LongInt((JxlPredict(Predictor, Neighbours, WeightedPrediction) + Entry) and $FFFFFFFF)
              else
                Line[X] := Entry;
              if Weighted <> nil then
                Weighted.Update(Line[X], X, Y);
            end;
          end;
        finally
          Weighted.Free;
        end;
      end;
  end;
  Dec(Image.MetaChannelCount);
  Image.DeleteChannels(0, 1);
end;

end.
