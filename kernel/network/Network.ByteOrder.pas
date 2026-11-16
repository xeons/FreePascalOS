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
  Reading and writing the big-endian ("network order") fields of
  protocol headers. Headers are handled as bytes at any alignment, so
  every access goes byte by byte.
}
unit Network.ByteOrder;

{$mode objfpc}
{$pointermath on}

interface

function ReadBigEndian16(Source: PByte): Word;
function ReadBigEndian32(Source: PByte): LongWord;
procedure WriteBigEndian16(Destination: PByte; Value: Word);
procedure WriteBigEndian32(Destination: PByte; Value: LongWord);

implementation

function ReadBigEndian16(Source: PByte): Word;
begin
  Result := (Word(Source[0]) shl 8) or Word(Source[1]);
end;

function ReadBigEndian32(Source: PByte): LongWord;
begin
  Result := (LongWord(Source[0]) shl 24) or (LongWord(Source[1]) shl 16) or
    (LongWord(Source[2]) shl 8) or LongWord(Source[3]);
end;

procedure WriteBigEndian16(Destination: PByte; Value: Word);
begin
  Destination[0] := Byte(Value shr 8);
  Destination[1] := Byte(Value);
end;

procedure WriteBigEndian32(Destination: PByte; Value: LongWord);
begin
  Destination[0] := Byte(Value shr 24);
  Destination[1] := Byte(Value shr 16);
  Destination[2] := Byte(Value shr 8);
  Destination[3] := Byte(Value);
end;

end.
