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
  The tables of the JPEG standard's Annex K that encoders use: the
  example quantization tables for luminance and chrominance (natural
  order, for quality 50) and the typical Huffman tables (counts of codes
  of each length 1 to 16, then the symbols).

  ScaledQuantizationTable makes a table for a quality from 1 to 100 the
  way the Independent JPEG Group's library does, so quality 75 here is
  quality 75 there.
}
unit Image.Jpeg.StandardTables;

{$mode objfpc}
{$H+}

interface

uses
  Image.Jpeg.Frames;

const
  LuminanceQuantization: array[0..63] of Byte = (
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99);

  ChrominanceQuantization: array[0..63] of Byte = (
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99);

  LuminanceDcCounts: array[1..16] of Byte = (0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0);
  LuminanceDcSymbols: array[0..11] of Byte = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11);
  ChrominanceDcCounts: array[1..16] of Byte = (0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0);
  ChrominanceDcSymbols: array[0..11] of Byte = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11);

  LuminanceAcCounts: array[1..16] of Byte = (0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, $7D);
  LuminanceAcSymbols: array[0..161] of Byte = (
    $01, $02, $03, $00, $04, $11, $05, $12, $21, $31, $41, $06, $13, $51, $61, $07,
    $22, $71, $14, $32, $81, $91, $A1, $08, $23, $42, $B1, $C1, $15, $52, $D1, $F0,
    $24, $33, $62, $72, $82, $09, $0A, $16, $17, $18, $19, $1A, $25, $26, $27, $28,
    $29, $2A, $34, $35, $36, $37, $38, $39, $3A, $43, $44, $45, $46, $47, $48, $49,
    $4A, $53, $54, $55, $56, $57, $58, $59, $5A, $63, $64, $65, $66, $67, $68, $69,
    $6A, $73, $74, $75, $76, $77, $78, $79, $7A, $83, $84, $85, $86, $87, $88, $89,
    $8A, $92, $93, $94, $95, $96, $97, $98, $99, $9A, $A2, $A3, $A4, $A5, $A6, $A7,
    $A8, $A9, $AA, $B2, $B3, $B4, $B5, $B6, $B7, $B8, $B9, $BA, $C2, $C3, $C4, $C5,
    $C6, $C7, $C8, $C9, $CA, $D2, $D3, $D4, $D5, $D6, $D7, $D8, $D9, $DA, $E1, $E2,
    $E3, $E4, $E5, $E6, $E7, $E8, $E9, $EA, $F1, $F2, $F3, $F4, $F5, $F6, $F7, $F8,
    $F9, $FA);

  ChrominanceAcCounts: array[1..16] of Byte = (0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, $77);
  ChrominanceAcSymbols: array[0..161] of Byte = (
    $00, $01, $02, $03, $11, $04, $05, $21, $31, $06, $12, $41, $51, $07, $61, $71,
    $13, $22, $32, $81, $08, $14, $42, $91, $A1, $B1, $C1, $09, $23, $33, $52, $F0,
    $15, $62, $72, $D1, $0A, $16, $24, $34, $E1, $25, $F1, $17, $18, $19, $1A, $26,
    $27, $28, $29, $2A, $35, $36, $37, $38, $39, $3A, $43, $44, $45, $46, $47, $48,
    $49, $4A, $53, $54, $55, $56, $57, $58, $59, $5A, $63, $64, $65, $66, $67, $68,
    $69, $6A, $73, $74, $75, $76, $77, $78, $79, $7A, $82, $83, $84, $85, $86, $87,
    $88, $89, $8A, $92, $93, $94, $95, $96, $97, $98, $99, $9A, $A2, $A3, $A4, $A5,
    $A6, $A7, $A8, $A9, $AA, $B2, $B3, $B4, $B5, $B6, $B7, $B8, $B9, $BA, $C2, $C3,
    $C4, $C5, $C6, $C7, $C8, $C9, $CA, $D2, $D3, $D4, $D5, $D6, $D7, $D8, $D9, $DA,
    $E2, $E3, $E4, $E5, $E6, $E7, $E8, $E9, $EA, $F2, $F3, $F4, $F5, $F6, $F7, $F8,
    $F9, $FA);

{ Base (one of the tables above) scaled for Quality (1 to 100). }
function ScaledQuantizationTable(constref Base: array of Byte; Quality: LongInt): TJpegQuantizationTable;

implementation

function ScaledQuantizationTable(constref Base: array of Byte; Quality: LongInt): TJpegQuantizationTable;
var
  Scale: LongInt;
  Index: LongInt;
  Value: LongInt;
begin
  if Quality < 1 then
    Quality := 1
  else if Quality > 100 then
    Quality := 100;
  if Quality < 50 then
    Scale := 5000 div Quality
  else
    Scale := 200 - Quality * 2;
  for Index := 0 to 63 do
  begin
    Value := (Base[Index] * Scale + 50) div 100;
    if Value < 1 then
      Value := 1
    else if Value > 255 then
      Value := 255;
    Result[Index] := Value;
  end;
end;

end.
