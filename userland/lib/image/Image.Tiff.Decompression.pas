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
  One strip or tile of a TIFF page decompressed: none, PackBits, LZW
  (new and old style), or deflate (compression 8, Adobe's, and 32946,
  the older number; both zlib streams, through libcompression).

  The chunk's bytes must lie inside the file (else ImageErrorTruncated);
  a chunk without a byte count runs to the end of the file. Fill order
  2 (bits from the lowest) is turned round first. The result is exactly
  the size the chunk's samples take; data that decodes to less leaves
  zeros, as libtiff does, and anything more is dropped. A deflate stream
  that is broken is ImageErrorMalformed.
}
unit Image.Tiff.Decompression;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Tiff.Tags,
  Image.Tiff.Pages;

{ The raw (still compressed) bytes of chunk Index. }
function TiffChunkBytes(const Data: TBytes; constref Page: TTiffPage; Index: LongInt): TBytes;
{ Chunk Index decompressed into ExpectedSize bytes. }
function DecompressTiffChunk(const Data: TBytes; constref Page: TTiffPage; Index: LongInt;
  ExpectedSize: PtrInt): TBytes;

implementation

uses
  Compression.Formats,
  Compression.Inflater,
  Image.Tiff.PackBits,
  Image.Tiff.Lzw;

function TiffChunkBytes(const Data: TBytes; constref Page: TTiffPage; Index: LongInt): TBytes;
var
  Offset: Int64;
  Count: Int64;
begin
  Offset := Page.ChunkOffsets[Index];
  Count := Page.ChunkByteCounts[Index];
  if (Offset < 0) or (Offset > Length(Data)) then
    RaiseImageError(ImageErrorTruncated, 'TIFF strip or tile outside the file');
  if Count = 0 then
    Count := Length(Data) - Offset;
  if (Count < 0) or (Count > Length(Data) - Offset) then
    RaiseImageError(ImageErrorTruncated, 'TIFF strip or tile outside the file');
  Result := Copy(Data, Offset, Count);
end;

function ReverseBits(Value: Byte): Byte;
var
  Bit: LongInt;
begin
  Result := 0;
  for Bit := 0 to 7 do
    if (Value and (1 shl Bit)) <> 0 then
      Result := Result or (1 shl (7 - Bit));
end;

procedure ReverseFillOrder(var Bytes: TBytes);
var
  Table: array[0..255] of Byte;
  Index: PtrInt;
begin
  for Index := 0 to 255 do
    Table[Index] := ReverseBits(Index);
  for Index := 0 to Length(Bytes) - 1 do
    Bytes[Index] := Table[Bytes[Index]];
end;

procedure Inflate(const Input: TBytes; var Output: TBytes);
var
  Inflater: TInflater;
  Written: SizeInt;
  Outcome: TInflateResult;
  Total: PtrInt;
begin
  if (Length(Input) = 0) or (Length(Output) = 0) then
    Exit;
  Inflater := TInflater.Create(FormatZlib);
  try
    Inflater.SetInput(@Input[0], Length(Input));
    Total := 0;
    repeat
      Outcome := Inflater.Decompress(@Output[Total], Length(Output) - Total, Written);
      Inc(Total, Written);
    until (Outcome <> InflateOutputFull) or (Total >= Length(Output));
    if Outcome = InflateFailed then
      RaiseImageError(ImageErrorMalformed, 'TIFF deflate data');
  finally
    Inflater.Free;
  end;
end;

function DecompressTiffChunk(const Data: TBytes; constref Page: TTiffPage; Index: LongInt;
  ExpectedSize: PtrInt): TBytes;
var
  Raw: TBytes;
  Count: PtrInt;
begin
  Raw := TiffChunkBytes(Data, Page, Index);
  if Page.FillOrder = TiffFillOrderLowestFirst then
    ReverseFillOrder(Raw);
  Result := nil;
  SetLength(Result, ExpectedSize);
  if ExpectedSize = 0 then
    Exit;
  FillChar(Result[0], ExpectedSize, 0);
  if Length(Raw) = 0 then
    Exit;
  case Page.Compression of
    TiffCompressionNone:
      begin
        Count := Length(Raw);
        if Count > ExpectedSize then
          Count := ExpectedSize;
        Move(Raw[0], Result[0], Count);
      end;
    TiffCompressionPackBits:
      UnpackBits(@Raw[0], Length(Raw), @Result[0], ExpectedSize);
    TiffCompressionLzw:
      DecodeTiffLzw(@Raw[0], Length(Raw), @Result[0], ExpectedSize);
    TiffCompressionAdobeDeflate, TiffCompressionDeflate:
      Inflate(Raw, Result);
  else
    RaiseImageError(ImageErrorUnsupported, 'TIFF compression ' + IntToStr(Page.Compression));
  end;
end;

end.
