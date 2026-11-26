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
  Vorbis' bit packing (Vorbis I specification, section 2): bits are
  taken from each byte least significant first, and a value of N bits
  has its least significant bit first.

  Reading past the end of the packet does not fail: it gives zero bits
  and sets EndOfPacket, which the decoding steps check where the
  specification says what an early end means.
}
unit Media.Vorbis.BitReader;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TVorbisBitReader = record
    Data: PByte;
    ByteCount: Integer;
    { The next bit's position, in bits from the start. }
    BitPosition: Int64;
    EndOfPacket: Boolean;
  end;

procedure StartBitReader(out Reader: TVorbisBitReader; Data: PByte; ByteCount: Integer);
{ Count (0 to 32) bits as an unsigned value. }
function ReadBits(var Reader: TVorbisBitReader; Count: Integer): LongWord;
function ReadBit(var Reader: TVorbisBitReader): Boolean; inline;
{ The next Count (up to 32) bits without consuming them; zeros past the
  end. }
function PeekBits(var Reader: TVorbisBitReader; Count: Integer): LongWord; inline;
{ Consumes Count bits (EndOfPacket if that passes the end). }
procedure SkipBits(var Reader: TVorbisBitReader; Count: Integer); inline;
{ The number of bits needed for Value (ilog of the specification). }
function VorbisIntegerLog(Value: LongInt): Integer;

implementation

procedure StartBitReader(out Reader: TVorbisBitReader; Data: PByte; ByteCount: Integer);
begin
  Reader.Data := Data;
  Reader.ByteCount := ByteCount;
  Reader.BitPosition := 0;
  Reader.EndOfPacket := False;
end;

function PeekBits(var Reader: TVorbisBitReader; Count: Integer): LongWord;
var
  ByteIndex, Shift, Index: Integer;
  Window: QWord;
begin
  ByteIndex := Reader.BitPosition shr 3;
  Shift := Reader.BitPosition and 7;
  Window := 0;
  if ByteIndex + 5 <= Reader.ByteCount then
    Window := Reader.Data[ByteIndex] or (QWord(Reader.Data[ByteIndex + 1]) shl 8) or
      (QWord(Reader.Data[ByteIndex + 2]) shl 16) or (QWord(Reader.Data[ByteIndex + 3]) shl 24) or
      (QWord(Reader.Data[ByteIndex + 4]) shl 32)
  else
    for Index := 0 to 4 do
      if ByteIndex + Index < Reader.ByteCount then
        Window := Window or (QWord(Reader.Data[ByteIndex + Index]) shl (8 * Index));
  Result := LongWord((Window shr Shift) and ((QWord(1) shl Count) - 1));
end;

procedure SkipBits(var Reader: TVorbisBitReader; Count: Integer);
begin
  Inc(Reader.BitPosition, Count);
  if Reader.BitPosition > Int64(Reader.ByteCount) * 8 then
  begin
    Reader.BitPosition := Int64(Reader.ByteCount) * 8;
    Reader.EndOfPacket := True;
  end;
end;

function ReadBits(var Reader: TVorbisBitReader; Count: Integer): LongWord;
begin
  if Count <= 0 then
    Exit(0);
  Result := PeekBits(Reader, Count);
  SkipBits(Reader, Count);
  if Reader.EndOfPacket then
    Result := 0;
end;

function ReadBit(var Reader: TVorbisBitReader): Boolean;
begin
  Result := ReadBits(Reader, 1) <> 0;
end;

function VorbisIntegerLog(Value: LongInt): Integer;
begin
  Result := 0;
  while Value > 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

end.
