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
  Brotli's context maps (RFC 7932 section 7.3): for each block type and
  context, which prefix code (tree) decodes the next literal or
  distance.

  A map is sent as RLEMAX, a prefix code over the tree numbers and the
  run lengths of zeros, the values in that code, and a bit asking for
  an inverse move-to-front transform of the whole map.

  Like the prefix codes, a map is read to the end even past the input;
  the caller looks at the reader's Overrun first.
}
unit Compression.BrotliContextMaps;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.BrotliBitReader,
  Compression.BrotliPrefixCodes;

{ Reads a map of Size values below TreeCount into Map, using Table to
  build its code in. }
function ReadBrotliContextMap(var Reader: TBrotliBitReader; TreeCount: Integer; Size: Integer; Map: PByte;
  var Table: TBrotliTableBuffer): TCompressionError;

implementation

procedure InverseMoveToFront(Map: PByte; Size: Integer);
var
  Order: array[0..255] of Byte;
  Index: Integer;
  Position: Integer;
  Value: Byte;
begin
  for Index := 0 to 255 do
    Order[Index] := Index;
  for Index := 0 to Size - 1 do
  begin
    Position := Map[Index];
    Value := Order[Position];
    Map[Index] := Value;
    while Position > 0 do
    begin
      Order[Position] := Order[Position - 1];
      Dec(Position);
    end;
    Order[0] := Value;
  end;
end;

function ReadBrotliContextMap(var Reader: TBrotliBitReader; TreeCount: Integer; Size: Integer; Map: PByte;
  var Table: TBrotliTableBuffer): TCompressionError;
var
  RunLengthCodes: Integer;
  Used: Integer;
  Position: Integer;
  Code: Integer;
  RunLength: Integer;
begin
  RunLengthCodes := 0;
  if Reader.ReadBits(1) = 1 then
    RunLengthCodes := Reader.ReadBits(4) + 1;
  Result := ReadBrotliPrefixCode(Reader, TreeCount + RunLengthCodes, Table, Used);
  if (Result <> CompressionErrorNone) or Reader.Overrun then
    Exit;
  Result := CompressionErrorInvalidContextMap;
  Position := 0;
  while Position < Size do
  begin
    Code := Reader.ReadSymbol(@Table[0], BrotliRootBits);
    if Reader.Overrun then
      Exit;
    if Code = 0 then
    begin
      Map[Position] := 0;
      Inc(Position);
    end
    else if Code <= RunLengthCodes then
    begin
      RunLength := (1 shl Code) + Integer(Reader.ReadBits(Code));
      if Position + RunLength > Size then
        Exit;
      FillChar(Map[Position], RunLength, 0);
      Inc(Position, RunLength);
    end
    else
    begin
      Map[Position] := Code - RunLengthCodes;
      Inc(Position);
    end;
  end;
  if Reader.ReadBits(1) = 1 then
    InverseMoveToFront(Map, Size);
  Result := CompressionErrorNone;
end;

end.
