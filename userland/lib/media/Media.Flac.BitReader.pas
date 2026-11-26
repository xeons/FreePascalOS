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
  Reading a FLAC frame's bits: most significant bit first, through a
  64-bit cache refilled a byte at a time, with the codes FLAC uses: plain
  and signed fields, unary counts and Rice codes (RFC 9639 section 9.2).

  Reading past the end gives zero bits and sets Overrun; the frame's
  CRC-16 or the checks after decoding catch that, so no read can go
  outside the data.
}
unit Media.Flac.BitReader;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TFlacBitReader = record
    Data: PByte;
    Size: Integer;
    { The next byte to load into the cache. }
    Position: Integer;
    Cache: QWord;
    { Bits in Cache, at its top. }
    CacheBits: Integer;
    Overrun: Boolean;
  end;

procedure StartBitReader(out Reader: TFlacBitReader; Data: PByte; Size: Integer);
{ Count (0 to 32) bits as an unsigned number. }
function ReadBits(var Reader: TFlacBitReader; Count: Integer): LongWord;
{ Count (1 to 33) bits as a two's complement number. }
function ReadSignedBits(var Reader: TFlacBitReader; Count: Integer): Int64;
{ The number of 0 bits before the next 1 bit (which is consumed). }
function ReadUnary(var Reader: TFlacBitReader): LongWord;
{ A Rice-coded signed value with parameter Parameter (zig-zag folded). }
function ReadRice(var Reader: TFlacBitReader; Parameter: Integer): LongInt; inline;
{ Skips to the next byte boundary. }
procedure AlignToByte(var Reader: TFlacBitReader);
{ The byte offset of the next bit, when on a byte boundary. }
function BytePosition(const Reader: TFlacBitReader): Integer;

implementation

procedure StartBitReader(out Reader: TFlacBitReader; Data: PByte; Size: Integer);
begin
  Reader.Data := Data;
  Reader.Size := Size;
  Reader.Position := 0;
  Reader.Cache := 0;
  Reader.CacheBits := 0;
  Reader.Overrun := False;
end;

procedure Refill(var Reader: TFlacBitReader); inline;
begin
  while Reader.CacheBits <= 56 do
  begin
    if Reader.Position < Reader.Size then
    begin
      Reader.Cache := Reader.Cache or (QWord(Reader.Data[Reader.Position]) shl (56 - Reader.CacheBits));
      Inc(Reader.Position);
    end
    else
    begin
      { Zeros past the end; counted so BytePosition stays right. }
      Inc(Reader.Position);
      if Reader.Position > Reader.Size + 8 then
        Reader.Overrun := True;
    end;
    Inc(Reader.CacheBits, 8);
  end;
end;

function ReadBits(var Reader: TFlacBitReader; Count: Integer): LongWord;
begin
  if Count = 0 then
    Exit(0);
  if Reader.CacheBits < Count then
    Refill(Reader);
  Result := LongWord(Reader.Cache shr (64 - Count));
  Reader.Cache := Reader.Cache shl Count;
  Dec(Reader.CacheBits, Count);
  if Reader.Position - Reader.CacheBits div 8 > Reader.Size then
    Reader.Overrun := True;
end;

function ReadSignedBits(var Reader: TFlacBitReader; Count: Integer): Int64;
var
  Raw: QWord;
begin
  if Count <= 32 then
    Raw := ReadBits(Reader, Count)
  else
  begin
    Raw := QWord(ReadBits(Reader, Count - 32)) shl 32;
    Raw := Raw or ReadBits(Reader, 32);
  end;
  if (Count < 64) and ((Raw shr (Count - 1)) and 1 <> 0) then
    Result := Int64(Raw) - (Int64(1) shl Count)
  else
    Result := Int64(Raw);
end;

function ReadUnary(var Reader: TFlacBitReader): LongWord;
var
  Zeros: Integer;
begin
  Result := 0;
  repeat
    if Reader.CacheBits = 0 then
    begin
      Refill(Reader);
      if Reader.Overrun then
        Exit;
    end;
    if Reader.Cache = 0 then
    begin
      Inc(Result, Reader.CacheBits);
      Reader.CacheBits := 0;
      Continue;
    end;
    Zeros := 63 - BsrQWord(Reader.Cache);
    if Zeros >= Reader.CacheBits then
    begin
      Inc(Result, Reader.CacheBits);
      Reader.Cache := 0;
      Reader.CacheBits := 0;
      Continue;
    end;
    Inc(Result, Zeros);
    Reader.Cache := Reader.Cache shl (Zeros + 1);
    Dec(Reader.CacheBits, Zeros + 1);
    Exit;
  until False;
end;

function ReadRice(var Reader: TFlacBitReader; Parameter: Integer): LongInt;
var
  Folded: LongWord;
begin
  Folded := (ReadUnary(Reader) shl Parameter) or ReadBits(Reader, Parameter);
  Result := LongInt(Folded shr 1) xor -LongInt(Folded and 1);
end;

procedure AlignToByte(var Reader: TFlacBitReader);
var
  Extra: Integer;
begin
  Extra := Reader.CacheBits and 7;
  Reader.Cache := Reader.Cache shl Extra;
  Dec(Reader.CacheBits, Extra);
end;

function BytePosition(const Reader: TFlacBitReader): Integer;
begin
  Result := Reader.Position - Reader.CacheBits div 8;
end;

end.
