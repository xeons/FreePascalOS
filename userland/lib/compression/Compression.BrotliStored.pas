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
  Brotli (RFC 7932) without compression: a valid stream that keeps the
  data in uncompressed meta-blocks of at most 64 KiB, after a header for
  a 64 KiB window and before an empty last meta-block. Any brotli
  decoder reads it back; it is what CompressionStream("brotli") gives
  until there is a brotli encoder.
}
unit Compression.BrotliStored;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

function StoreAsBrotli(Data: PByte; Count: SizeInt): TBytes;

implementation

const
  MetaBlockLimit = 65536;

type
  TBitSink = record
    Output: TBytes;
    Used: SizeInt;
    Pending: LongWord;
    PendingBits: Integer;
  end;

procedure PutByte(var Sink: TBitSink; Value: Byte);
begin
  if Sink.Used = Length(Sink.Output) then
    SetLength(Sink.Output, 2 * Length(Sink.Output) + 16);
  Sink.Output[Sink.Used] := Value;
  Inc(Sink.Used);
end;

{ Count bits of Value, least significant first (brotli's bit order). }
procedure PutBits(var Sink: TBitSink; Value: LongWord; Count: Integer);
begin
  Sink.Pending := Sink.Pending or (Value shl Sink.PendingBits);
  Inc(Sink.PendingBits, Count);
  while Sink.PendingBits >= 8 do
  begin
    PutByte(Sink, Sink.Pending and $FF);
    Sink.Pending := Sink.Pending shr 8;
    Dec(Sink.PendingBits, 8);
  end;
end;

{ Zero bits up to the next byte boundary. }
procedure AlignToByte(var Sink: TBitSink);
begin
  if Sink.PendingBits > 0 then
    PutBits(Sink, 0, 8 - Sink.PendingBits);
end;

function StoreAsBrotli(Data: PByte; Count: SizeInt): TBytes;
var
  Sink: TBitSink;
  Offset, Piece: SizeInt;
begin
  Sink := Default(TBitSink);
  SetLength(Sink.Output, Count + Count div MetaBlockLimit * 4 + 16);
  { WBITS: a single 0 bit, a 64 KiB window. }
  PutBits(Sink, 0, 1);
  Offset := 0;
  while Offset < Count do
  begin
    Piece := Count - Offset;
    if Piece > MetaBlockLimit then
      Piece := MetaBlockLimit;
    PutBits(Sink, 0, 1);              { ISLAST }
    PutBits(Sink, 0, 2);              { MNIBBLES: four nibbles }
    PutBits(Sink, LongWord(Piece - 1), 16);   { MLEN - 1 }
    PutBits(Sink, 1, 1);              { ISUNCOMPRESSED }
    AlignToByte(Sink);
    if Sink.Used + Piece > Length(Sink.Output) then
      SetLength(Sink.Output, Sink.Used + Piece + 16);
    Move(Data[Offset], Sink.Output[Sink.Used], Piece);
    Inc(Sink.Used, Piece);
    Inc(Offset, Piece);
  end;
  PutBits(Sink, 1, 1);                { ISLAST }
  PutBits(Sink, 1, 1);                { ISLASTEMPTY }
  AlignToByte(Sink);
  SetLength(Sink.Output, Sink.Used);
  Result := Sink.Output;
end;

end.
