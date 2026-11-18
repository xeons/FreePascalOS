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
  The xz format (tukaani.org/xz/xz-file-format.txt), a whole stream in
  memory into a buffer of known size.

  A stream is a header (magic, flags naming the check, CRC-32), blocks,
  an index (each block's unpadded and uncompressed size) and a footer
  (CRC-32, the index's size, the flags again, "YZ"). Zero bytes may
  follow it in fours (stream padding); a second stream is not taken.

  XzUncompressedSize reads the footer and index alone, so the output can
  be allocated before decoding. XzDecode then decodes each block: its
  header (CRC-32 checked; one filter, LZMA2, is supported), its LZMA2
  data, its padding, and its check (none, CRC-32 or CRC-64; SHA-256 is
  refused), comparing every size with the block header and the index.

  Freestanding (the kernel compiles it).
}
unit Compression.XzDecoder;

{$mode objfpc}
{$pointermath on}

interface

uses
  Compression.DecodeResults,
  Compression.LzmaDecoder;

const
  XzMagicSize = 6;
  XzMagic: array[0..XzMagicSize - 1] of Byte = ($FD, $37, $7A, $58, $5A, $00);

{ True if Input starts with the xz magic. }
function IsXzStream(Input: PByte; InputSize: SizeUInt): Boolean;

{ The decompressed size, from the index. }
function XzUncompressedSize(Input: PByte; InputSize: SizeUInt; out Size: QWord): TDecodeResult;

{ Decodes the stream into Output, which must be exactly the size
  XzUncompressedSize gave. Decoder is the caller's workspace. }
function XzDecode(var Decoder: TLzmaDecoder; Input: PByte; InputSize: SizeUInt; Output: PByte;
  OutputSize: SizeUInt): TDecodeResult;

implementation

uses
  Compression.CyclicRedundancy,
  Compression.Lzma2Decoder;

const
  StreamHeaderSize = 12;
  StreamFooterSize = 12;
  FooterMagic0 = $59;
  FooterMagic1 = $5A;

  CheckNone = 0;
  CheckCrc32 = 1;
  CheckCrc64 = 4;
  CheckSha256 = 10;

  FilterLzma2 = $21;
  Lzma2DictionarySizeMaximum = 40;
  BlockFlagFilterCountMask = $03;
  BlockFlagReserved = $3C;
  BlockFlagCompressedSize = $40;
  BlockFlagUncompressedSize = $80;
  IndexIndicator = $00;
  VariableIntegerMaximumBytes = 9;

type
  TStreamLayout = record
    CheckKind: Byte;
    CheckSize: SizeUInt;
    { Where the index starts and how long it is (to the footer). }
    IndexStart: SizeUInt;
    IndexSize: SizeUInt;
  end;

  { A cursor over a part of the input. }
  TByteReader = record
    Data: PByte;
    Size: SizeUInt;
    Position: SizeUInt;
  end;

function IsXzStream(Input: PByte; InputSize: SizeUInt): Boolean;
var
  Index: Integer;
begin
  Result := False;
  if InputSize < XzMagicSize then
    Exit;
  for Index := 0 to XzMagicSize - 1 do
    if Input[Index] <> XzMagic[Index] then
      Exit;
  Result := True;
end;

function ReadLittleEndian32(Data: PByte): LongWord;
begin
  Result := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or
    (LongWord(Data[3]) shl 24);
end;

function ReadLittleEndian64(Data: PByte): QWord;
begin
  Result := QWord(ReadLittleEndian32(Data)) or (QWord(ReadLittleEndian32(Data + 4)) shl 32);
end;

function CheckSizeOf(CheckKind: Byte): SizeUInt;
begin
  { The sizes the format reserves for each group of four check ids. }
  case CheckKind of
    0: Result := 0;
    1..3: Result := 4;
    4..6: Result := 8;
    7..9: Result := 16;
    10..12: Result := 32;
  else
    Result := 64;
  end;
end;

{ A variable length integer: seven bits a byte, least significant first,
  the high bit set on all but the last; no needless zero bytes. }
function ReadVariableInteger(var Reader: TByteReader; out Value: QWord): Boolean;
var
  Index: Integer;
  Next: Byte;
begin
  Result := False;
  Value := 0;
  for Index := 0 to VariableIntegerMaximumBytes - 1 do
  begin
    if Reader.Position >= Reader.Size then
      Exit;
    Next := Reader.Data[Reader.Position];
    Inc(Reader.Position);
    Value := Value or (QWord(Next and $7F) shl (7 * Index));
    if (Next and $80) = 0 then
    begin
      Result := (Index = 0) or (Next <> 0);
      Exit;
    end;
  end;
end;

function ReadStreamFlags(Flags: PByte; out CheckKind: Byte): Boolean;
begin
  CheckKind := Flags[1] and $0F;
  Result := (Flags[0] = 0) and ((Flags[1] and $F0) = 0);
end;

{ The header at the start and the footer at the end (after the stream
  padding), which must agree. }
function ReadStreamLayout(Input: PByte; InputSize: SizeUInt; out Layout: TStreamLayout): TDecodeResult;
var
  StreamEnd: SizeUInt;
  Footer: PByte;
  HeaderCheck: Byte;
  FooterCheck: Byte;
  BackwardSize: QWord;
begin
  Layout.CheckKind := 0;
  Layout.CheckSize := 0;
  Layout.IndexStart := 0;
  Layout.IndexSize := 0;
  if not IsXzStream(Input, InputSize) then
    Exit(DecodeInvalidHeader);
  if InputSize < StreamHeaderSize + StreamFooterSize then
    Exit(DecodeTruncated);
  if Crc32(Crc32Initial, Input + XzMagicSize, 2) <> ReadLittleEndian32(Input + XzMagicSize + 2) then
    Exit(DecodeChecksumMismatch);
  if not ReadStreamFlags(Input + XzMagicSize, HeaderCheck) then
    Exit(DecodeUnsupported);

  { The footer ends in "YZ", so the zeros at the end are padding (the
    format wants them in fours; a boot loader may round differently). }
  StreamEnd := InputSize;
  while (StreamEnd > StreamHeaderSize) and (Input[StreamEnd - 1] = 0) do
    Dec(StreamEnd);
  if StreamEnd < StreamHeaderSize + StreamFooterSize then
    Exit(DecodeTruncated);
  Footer := Input + StreamEnd - StreamFooterSize;
  if (Footer[10] <> FooterMagic0) or (Footer[11] <> FooterMagic1) then
    Exit(DecodeTruncated);
  if Crc32(Crc32Initial, Footer + 4, 6) <> ReadLittleEndian32(Footer) then
    Exit(DecodeChecksumMismatch);
  if (not ReadStreamFlags(Footer + 8, FooterCheck)) or (FooterCheck <> HeaderCheck) then
    Exit(DecodeCorrupt);

  BackwardSize := (QWord(ReadLittleEndian32(Footer + 4)) + 1) * 4;
  if BackwardSize > StreamEnd - StreamHeaderSize - StreamFooterSize then
    Exit(DecodeCorrupt);
  Layout.CheckKind := HeaderCheck;
  Layout.CheckSize := CheckSizeOf(HeaderCheck);
  Layout.IndexSize := BackwardSize;
  Layout.IndexStart := StreamEnd - StreamFooterSize - BackwardSize;
  Result := DecodeSucceeded;
end;

{ Walks the index: its records' sizes summed, the padding zero, the
  CRC-32 right. RecordCount is how many blocks it lists. }
function ReadIndex(Input: PByte; const Layout: TStreamLayout; out RecordCount: QWord;
  out UnpaddedTotal: QWord; out UncompressedTotal: QWord): TDecodeResult;
var
  Reader: TByteReader;
  RecordIndex: QWord;
  Unpadded: QWord;
  Uncompressed: QWord;
begin
  RecordCount := 0;
  UnpaddedTotal := 0;
  UncompressedTotal := 0;
  Reader.Data := Input + Layout.IndexStart;
  Reader.Size := Layout.IndexSize - 4;
  Reader.Position := 0;
  if Crc32(Crc32Initial, Reader.Data, Reader.Size) <> ReadLittleEndian32(Reader.Data + Reader.Size) then
    Exit(DecodeChecksumMismatch);
  if (Reader.Size = 0) or (Reader.Data[0] <> IndexIndicator) then
    Exit(DecodeCorrupt);
  Reader.Position := 1;
  if not ReadVariableInteger(Reader, RecordCount) then
    Exit(DecodeCorrupt);
  RecordIndex := 0;
  while RecordIndex < RecordCount do
  begin
    if (not ReadVariableInteger(Reader, Unpadded)) or (not ReadVariableInteger(Reader, Uncompressed)) or
       (Unpadded = 0) then
      Exit(DecodeCorrupt);
    { Stays far from overflowing: the sizes are bounded by the input. }
    if (Unpadded > Layout.IndexStart) or (Uncompressed > High(QWord) div 2 - UncompressedTotal) then
      Exit(DecodeCorrupt);
    Inc(UnpaddedTotal, (Unpadded + 3) and not QWord(3));
    Inc(UncompressedTotal, Uncompressed);
    Inc(RecordIndex);
  end;
  while Reader.Position < Reader.Size do
  begin
    if Reader.Data[Reader.Position] <> 0 then
      Exit(DecodeCorrupt);
    Inc(Reader.Position);
  end;
  if Reader.Position mod 4 <> 0 then
    Exit(DecodeCorrupt);
  { The blocks fill the space between the header and the index. }
  if UnpaddedTotal <> Layout.IndexStart - StreamHeaderSize then
    Exit(DecodeCorrupt);
  Result := DecodeSucceeded;
end;

function XzUncompressedSize(Input: PByte; InputSize: SizeUInt; out Size: QWord): TDecodeResult;
var
  Layout: TStreamLayout;
  RecordCount: QWord;
  UnpaddedTotal: QWord;
begin
  Size := 0;
  Result := ReadStreamLayout(Input, InputSize, Layout);
  if Result = DecodeSucceeded then
    Result := ReadIndex(Input, Layout, RecordCount, UnpaddedTotal, Size);
end;

type
  TBlockHeader = record
    HeaderSize: SizeUInt;
    HasCompressedSize: Boolean;
    CompressedSize: QWord;
    HasUncompressedSize: Boolean;
    UncompressedSize: QWord;
  end;

function ReadBlockHeader(Data: PByte; Available: SizeUInt; out Header: TBlockHeader): TDecodeResult;
var
  Reader: TByteReader;
  Flags: Byte;
  FilterId: QWord;
  PropertiesSize: QWord;
begin
  Header.HeaderSize := 0;
  Header.HasCompressedSize := False;
  Header.CompressedSize := 0;
  Header.HasUncompressedSize := False;
  Header.UncompressedSize := 0;
  if Available < 1 then
    Exit(DecodeTruncated);
  if Data[0] = IndexIndicator then
    Exit(DecodeCorrupt);
  Header.HeaderSize := (SizeUInt(Data[0]) + 1) * 4;
  if Header.HeaderSize > Available then
    Exit(DecodeTruncated);
  if Crc32(Crc32Initial, Data, Header.HeaderSize - 4) <> ReadLittleEndian32(Data + Header.HeaderSize - 4) then
    Exit(DecodeChecksumMismatch);
  Reader.Data := Data;
  Reader.Size := Header.HeaderSize - 4;
  Reader.Position := 2;
  Flags := Data[1];
  if (Flags and BlockFlagReserved) <> 0 then
    Exit(DecodeUnsupported);
  { Only LZMA2 by itself: no BCJ or delta filter before it. }
  if (Flags and BlockFlagFilterCountMask) <> 0 then
    Exit(DecodeUnsupported);
  Header.HasCompressedSize := (Flags and BlockFlagCompressedSize) <> 0;
  if Header.HasCompressedSize and ((not ReadVariableInteger(Reader, Header.CompressedSize)) or
     (Header.CompressedSize = 0)) then
    Exit(DecodeCorrupt);
  Header.HasUncompressedSize := (Flags and BlockFlagUncompressedSize) <> 0;
  if Header.HasUncompressedSize and (not ReadVariableInteger(Reader, Header.UncompressedSize)) then
    Exit(DecodeCorrupt);
  if (not ReadVariableInteger(Reader, FilterId)) or (not ReadVariableInteger(Reader, PropertiesSize)) then
    Exit(DecodeCorrupt);
  if (FilterId <> FilterLzma2) or (PropertiesSize <> 1) then
    Exit(DecodeUnsupported);
  if (Reader.Position >= Reader.Size) or (Reader.Data[Reader.Position] > Lzma2DictionarySizeMaximum) then
    Exit(DecodeCorrupt);
  Inc(Reader.Position);
  while Reader.Position < Reader.Size do
  begin
    if Reader.Data[Reader.Position] <> 0 then
      Exit(DecodeUnsupported);
    Inc(Reader.Position);
  end;
  Result := DecodeSucceeded;
end;

function VerifyCheck(CheckKind: Byte; Check: PByte; Data: PByte; Size: SizeUInt): TDecodeResult;
begin
  Result := DecodeSucceeded;
  case CheckKind of
    CheckNone: ;
    CheckCrc32:
      if Crc32(Crc32Initial, Data, Size) <> ReadLittleEndian32(Check) then
        Result := DecodeChecksumMismatch;
    CheckCrc64:
      if Crc64(Crc64Initial, Data, Size) <> ReadLittleEndian64(Check) then
        Result := DecodeChecksumMismatch;
  else
    Result := DecodeUnsupported;
  end;
end;

{ One block at Input[Cursor], decoded at Output[Position]; both move on
  past it (its padding and check included). }
function DecodeBlock(var Decoder: TLzmaDecoder; Input: PByte; const Layout: TStreamLayout;
  var Cursor: SizeUInt; Output: PByte; OutputSize: SizeUInt; var Position: SizeUInt): TDecodeResult;
var
  Header: TBlockHeader;
  DataStart: SizeUInt;
  DataSize: SizeUInt;
  BlockOutputStart: SizeUInt;
begin
  Result := ReadBlockHeader(Input + Cursor, Layout.IndexStart - Cursor, Header);
  if Result <> DecodeSucceeded then
    Exit;
  DataStart := Cursor + Header.HeaderSize;
  BlockOutputStart := Position;
  Result := DecodeLzma2(Decoder, Input + DataStart, Layout.IndexStart - DataStart, DataSize, Output, OutputSize,
    Position);
  if Result <> DecodeSucceeded then
    Exit;
  if (Header.HasCompressedSize and (Header.CompressedSize <> DataSize)) or
     (Header.HasUncompressedSize and (Header.UncompressedSize <> Position - BlockOutputStart)) then
    Exit(DecodeSizeMismatch);
  Cursor := DataStart + DataSize;
  while Cursor mod 4 <> 0 do
  begin
    if (Cursor >= Layout.IndexStart) or (Input[Cursor] <> 0) then
      Exit(DecodeCorrupt);
    Inc(Cursor);
  end;
  if Layout.CheckSize > Layout.IndexStart - Cursor then
    Exit(DecodeTruncated);
  Result := VerifyCheck(Layout.CheckKind, Input + Cursor, Output + BlockOutputStart, Position - BlockOutputStart);
  Inc(Cursor, Layout.CheckSize);
end;

function XzDecode(var Decoder: TLzmaDecoder; Input: PByte; InputSize: SizeUInt; Output: PByte;
  OutputSize: SizeUInt): TDecodeResult;
var
  Layout: TStreamLayout;
  RecordCount: QWord;
  UnpaddedTotal: QWord;
  UncompressedTotal: QWord;
  BlockCount: QWord;
  Cursor: SizeUInt;
  Position: SizeUInt;
begin
  Result := ReadStreamLayout(Input, InputSize, Layout);
  if Result <> DecodeSucceeded then
    Exit;
  if (Layout.CheckKind <> CheckNone) and (Layout.CheckKind <> CheckCrc32) and (Layout.CheckKind <> CheckCrc64) then
    Exit(DecodeUnsupported);
  Result := ReadIndex(Input, Layout, RecordCount, UnpaddedTotal, UncompressedTotal);
  if Result <> DecodeSucceeded then
    Exit;
  if UncompressedTotal <> OutputSize then
    Exit(DecodeOutputTooSmall);

  Cursor := StreamHeaderSize;
  Position := 0;
  BlockCount := 0;
  while Cursor < Layout.IndexStart do
  begin
    Result := DecodeBlock(Decoder, Input, Layout, Cursor, Output, OutputSize, Position);
    if Result <> DecodeSucceeded then
      Exit;
    Inc(BlockCount);
  end;
  if (Cursor <> Layout.IndexStart) or (BlockCount <> RecordCount) or (Position <> OutputSize) then
    Exit(DecodeSizeMismatch);
  Result := DecodeSucceeded;
end;

end.
