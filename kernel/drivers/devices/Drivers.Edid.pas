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
  EDID: what a display says about itself, here only its size.

  The base block is 128 bytes: a fixed header (00 FF FF FF FF FF FF 00),
  and bytes that add up to 0 modulo 256. Its first detailed timing
  descriptor (from byte 54) is the preferred mode: its pixel size and
  its picture's physical size in millimetres. Bytes 21 and 22 hold the
  physical size again in whole centimetres, for when the descriptor
  leaves it out.
}
unit Drivers.Edid;

{$mode objfpc}
{$pointermath on}

interface

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

implementation

uses
  Runtime.Memory;

const
  BlockSize = 128;
  FirstDescriptor = 54;
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

end.
