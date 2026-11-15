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
  EDID: what a display says about itself: its size, and the modes it
  shows well.

  The base block is 128 bytes: a fixed header (00 FF FF FF FF FF FF 00),
  and bytes that add up to 0 modulo 256. Its first detailed timing
  descriptor (from byte 54) is the preferred mode: its pixel size and
  its picture's physical size in millimetres. Bytes 21 and 22 hold the
  physical size again in whole centimetres, for when the descriptor
  leaves it out.

  The modes: the established timings (bytes 35 to 37, a bit for each of
  a fixed set of old modes), the standard timings (eight pairs from byte
  38: the width in units of 8 pixels past 248, and the aspect ratio
  giving the height) and every detailed timing descriptor (four of 18
  bytes from byte 54; a pixel clock of 0 marks one that holds something
  else, such as the display's name).
}
unit Drivers.Edid;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.DisplayModes;

type
  TEdidSize = record
    { The preferred mode, 0 if not given. }
    PreferredWidth: LongWord;
    PreferredHeight: LongWord;
    { The picture's size, 0 if not given (a projector). }
    WidthMillimetres: LongWord;
    HeightMillimetres: LongWord;
  end;

{ True if Block (128 bytes) is a valid EDID base block. }
function ParseEdid(Block: PByte; out Size: TEdidSize): Boolean;
{ Adds the modes a valid base block lists to List (those the adapter can
  make). }
procedure AddEdidModes(Block: PByte; var List: TDisplayModeList);

implementation

uses
  Runtime.Memory;

const
  BlockSize = 128;
  FirstDescriptor = 54;
  DescriptorSize = 18;
  DescriptorCount = 4;
  EstablishedTimings = 35;
  FirstStandardTiming = 38;
  StandardTimingCount = 8;
  { Bit 7 of byte 35 first, down to bit 0 of byte 36 (then byte 37's
    bit 7, 1152x870). Interlaced 1024x768 is the same size as the rest. }
  EstablishedModeCount = 17;
  EstablishedModes: array[0..EstablishedModeCount - 1] of TDisplayMode = (
    (Width: 720; Height: 400), (Width: 720; Height: 400), (Width: 640; Height: 480),
    (Width: 640; Height: 480), (Width: 640; Height: 480), (Width: 640; Height: 480),
    (Width: 800; Height: 600), (Width: 800; Height: 600), (Width: 800; Height: 600),
    (Width: 800; Height: 600), (Width: 832; Height: 624), (Width: 1024; Height: 768),
    (Width: 1024; Height: 768), (Width: 1024; Height: 768), (Width: 1024; Height: 768),
    (Width: 1280; Height: 1024), (Width: 1152; Height: 870));
  HeaderBytes: array[0..7] of Byte = ($00, $FF, $FF, $FF, $FF, $FF, $FF, $00);

function ParseEdid(Block: PByte; out Size: TEdidSize): Boolean;
var
  Index: Integer;
  Sum: Byte;
  Descriptor: PByte;
begin
  ZeroMemory(@Size, SizeOf(Size));
  Result := False;
  if Block = nil then
    Exit;
  for Index := 0 to 7 do
    if Block[Index] <> HeaderBytes[Index] then
      Exit;
  Sum := 0;
  for Index := 0 to BlockSize - 1 do
    Sum := Byte(Sum + Block[Index]);
  if Sum <> 0 then
    Exit;
  Descriptor := Block + FirstDescriptor;
  { A pixel clock of 0 means the descriptor is not a timing. }
  if (Descriptor[0] <> 0) or (Descriptor[1] <> 0) then
  begin
    Size.PreferredWidth := Descriptor[2] or (LongWord(Descriptor[4] shr 4) shl 8);
    Size.PreferredHeight := Descriptor[5] or (LongWord(Descriptor[7] shr 4) shl 8);
    Size.WidthMillimetres := Descriptor[12] or (LongWord(Descriptor[14] shr 4) shl 8);
    Size.HeightMillimetres := Descriptor[13] or (LongWord(Descriptor[14] and $0F) shl 8);
  end;
  if (Size.WidthMillimetres = 0) or (Size.HeightMillimetres = 0) then
  begin
    Size.WidthMillimetres := LongWord(Block[21]) * 10;
    Size.HeightMillimetres := LongWord(Block[22]) * 10;
  end;
  Result := True;
end;

procedure AddEstablishedModes(Block: PByte; var List: TDisplayModeList);
var
  Index: LongInt;
  Bits: LongWord;
begin
  { The three bytes as one number, byte 35's bit 7 the highest. }
  Bits := (LongWord(Block[EstablishedTimings]) shl 16) or (LongWord(Block[EstablishedTimings + 1]) shl 8) or
    Block[EstablishedTimings + 2];
  for Index := 0 to EstablishedModeCount - 1 do
    if (Bits and (LongWord(1) shl (23 - Index))) <> 0 then
      AddDisplayMode(List, EstablishedModes[Index].Width, EstablishedModes[Index].Height);
end;

procedure AddStandardModes(Block: PByte; var List: TDisplayModeList);
const
  AspectSixteenByTen = 0;
  AspectFourByThree = 1;
  AspectFiveByFour = 2;
var
  Index: LongInt;
  First: Byte;
  Second: Byte;
  Width: LongWord;
  Height: LongWord;
begin
  for Index := 0 to StandardTimingCount - 1 do
  begin
    First := Block[FirstStandardTiming + 2 * Index];
    Second := Block[FirstStandardTiming + 2 * Index + 1];
    { 01 01 (or 00 00) marks an unused entry. }
    if (First <= 1) and (Second <= 1) then
      Continue;
    Width := (LongWord(First) + 31) * 8;
    case Second shr 6 of
      AspectSixteenByTen: Height := Width * 10 div 16;
      AspectFourByThree: Height := Width * 3 div 4;
      AspectFiveByFour: Height := Width * 4 div 5;
    else
      Height := Width * 9 div 16;
    end;
    AddDisplayMode(List, Width, Height);
  end;
end;

procedure AddDetailedModes(Block: PByte; var List: TDisplayModeList);
var
  Index: LongInt;
  Descriptor: PByte;
begin
  for Index := 0 to DescriptorCount - 1 do
  begin
    Descriptor := Block + FirstDescriptor + Index * DescriptorSize;
    if (Descriptor[0] = 0) and (Descriptor[1] = 0) then
      Continue;
    AddDisplayMode(List, Descriptor[2] or (LongWord(Descriptor[4] shr 4) shl 8),
      Descriptor[5] or (LongWord(Descriptor[7] shr 4) shl 8));
  end;
end;

procedure AddEdidModes(Block: PByte; var List: TDisplayModeList);
begin
  if Block = nil then
    Exit;
  AddDetailedModes(Block, List);
  AddStandardModes(Block, List);
  AddEstablishedModes(Block, List);
end;

end.
