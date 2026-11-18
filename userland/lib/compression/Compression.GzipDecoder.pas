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
  A gzip member (RFC 1952) in memory decoded into a buffer of known
  size: the header (its optional fields skipped, its CRC-16 checked if
  present), the deflate data (Compression.BufferInflate) and the trailer
  (CRC-32 and size of the data, both checked).

  The size is known beforehand from the last four bytes (ISIZE, the size
  modulo 4 GiB), so the member must end the input; the caller may know
  the size otherwise (a larger image). Zero bytes after the member are
  taken as padding when the size came from elsewhere; anything else is
  refused. Freestanding (the kernel compiles it).
}
unit Compression.GzipDecoder;

{$mode objfpc}
{$pointermath on}

interface

uses
  Compression.DecodeResults,
  Compression.BufferInflate;

{ True if Input starts with the gzip magic. }
function IsGzipMember(Input: PByte; InputSize: SizeUInt): Boolean;

{ The size the trailer gives (ISIZE: modulo 4 GiB), read from the last
  four bytes of the input. }
function GzipUncompressedSize(Input: PByte; InputSize: SizeUInt; out Size: QWord): TDecodeResult;

{ Decodes the member into Output, which must be exactly its size. }
function GzipDecode(var State: TBufferInflateState; Input: PByte; InputSize: SizeUInt; Output: PByte;
  OutputSize: SizeUInt): TDecodeResult;

implementation

uses
  Compression.CyclicRedundancy;

const
  GzipMagic0 = $1F;
  GzipMagic1 = $8B;
  MethodDeflate = 8;
  FlagHeaderCrc = $02;
  FlagExtra = $04;
  FlagName = $08;
  FlagComment = $10;
  FlagReserved = $E0;
  FixedHeaderSize = 10;
  TrailerSize = 8;

function ReadLittleEndian32(Data: PByte): LongWord;
begin
  Result := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or
    (LongWord(Data[3]) shl 24);
end;

function IsGzipMember(Input: PByte; InputSize: SizeUInt): Boolean;
begin
  Result := (InputSize >= 2) and (Input[0] = GzipMagic0) and (Input[1] = GzipMagic1);
end;

function AllZero(Data: PByte; Size: SizeUInt): Boolean;
var
  Index: SizeUInt;
begin
  Result := False;
  Index := 0;
  while Index < Size do
  begin
    if Data[Index] <> 0 then
      Exit;
    Inc(Index);
  end;
  Result := True;
end;

function GzipUncompressedSize(Input: PByte; InputSize: SizeUInt; out Size: QWord): TDecodeResult;
begin
  Size := 0;
  if not IsGzipMember(Input, InputSize) then
    Exit(DecodeInvalidHeader);
  if InputSize < FixedHeaderSize + TrailerSize then
    Exit(DecodeTruncated);
  { The usual case: the member ends the input exactly. }
  Size := ReadLittleEndian32(Input + InputSize - 4);
  Result := DecodeSucceeded;
end;

{ Skips a zero-terminated field; False if the input ends first. }
function SkipText(Input: PByte; InputSize: SizeUInt; var Cursor: SizeUInt): Boolean;
begin
  while (Cursor < InputSize) and (Input[Cursor] <> 0) do
    Inc(Cursor);
  Result := Cursor < InputSize;
  Inc(Cursor);
end;

function ReadHeader(Input: PByte; InputSize: SizeUInt; out HeaderSize: SizeUInt): TDecodeResult;
var
  Flags: Byte;
  Cursor: SizeUInt;
  ExtraSize: SizeUInt;
  HeaderCrc: LongWord;
begin
  HeaderSize := 0;
  if not IsGzipMember(Input, InputSize) then
    Exit(DecodeInvalidHeader);
  if InputSize < FixedHeaderSize then
    Exit(DecodeTruncated);
  Flags := Input[3];
  if Input[2] <> MethodDeflate then
    Exit(DecodeUnsupported);
  if (Flags and FlagReserved) <> 0 then
    Exit(DecodeInvalidHeader);
  Cursor := FixedHeaderSize;
  if (Flags and FlagExtra) <> 0 then
  begin
    if InputSize - Cursor < 2 then
      Exit(DecodeTruncated);
    ExtraSize := SizeUInt(Input[Cursor]) or (SizeUInt(Input[Cursor + 1]) shl 8);
    Inc(Cursor, 2);
    if InputSize - Cursor < ExtraSize then
      Exit(DecodeTruncated);
    Inc(Cursor, ExtraSize);
  end;
  if ((Flags and FlagName) <> 0) and not SkipText(Input, InputSize, Cursor) then
    Exit(DecodeTruncated);
  if ((Flags and FlagComment) <> 0) and not SkipText(Input, InputSize, Cursor) then
    Exit(DecodeTruncated);
  if (Flags and FlagHeaderCrc) <> 0 then
  begin
    if InputSize - Cursor < 2 then
      Exit(DecodeTruncated);
    HeaderCrc := Crc32(Crc32Initial, Input, Cursor) and $FFFF;
    if HeaderCrc <> (LongWord(Input[Cursor]) or (LongWord(Input[Cursor + 1]) shl 8)) then
      Exit(DecodeChecksumMismatch);
    Inc(Cursor, 2);
  end;
  HeaderSize := Cursor;
  Result := DecodeSucceeded;
end;

function GzipDecode(var State: TBufferInflateState; Input: PByte; InputSize: SizeUInt; Output: PByte;
  OutputSize: SizeUInt): TDecodeResult;
var
  HeaderSize: SizeUInt;
  DataSize: SizeUInt;
  OutputUsed: SizeUInt;
  Trailer: PByte;
  Cursor: SizeUInt;
begin
  Result := ReadHeader(Input, InputSize, HeaderSize);
  if Result <> DecodeSucceeded then
    Exit;
  Result := InflateIntoBuffer(State, Input + HeaderSize, InputSize - HeaderSize, DataSize, Output, OutputSize,
    OutputUsed);
  if Result <> DecodeSucceeded then
    Exit;
  Cursor := HeaderSize + DataSize;
  if InputSize - Cursor < TrailerSize then
    Exit(DecodeTruncated);
  Trailer := Input + Cursor;
  if Crc32(Crc32Initial, Output, OutputUsed) <> ReadLittleEndian32(Trailer) then
    Exit(DecodeChecksumMismatch);
  if (ReadLittleEndian32(Trailer + 4) <> LongWord(OutputUsed and $FFFFFFFF)) or (OutputUsed <> OutputSize) then
    Exit(DecodeSizeMismatch);
  Inc(Cursor, TrailerSize);
  if not AllZero(Input + Cursor, InputSize - Cursor) then
    Exit(DecodeTrailingData);
  Result := DecodeSucceeded;
end;

end.
