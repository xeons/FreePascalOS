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
  A compressed image in memory (a RAM disk the boot loader brought,
  Drivers.RamDisk) told apart by its magic and decompressed whole into a
  buffer of its decompressed size:

    xz      FD 37 7A 58 5A 00   LZMA2, CRC-32 or CRC-64 checked
                                (Compression.XzDecoder)
    gzip    1F 8B               deflate, CRC-32 checked
                                (Compression.GzipDecoder)
    zstd    28 B5 2F FD         recognized, not decoded

  The size comes first (xz: its index; gzip: its trailer), so the
  caller allocates the output, then decompresses. Freestanding: the
  kernel compiles it, and the caller provides the workspace record.
}
unit Compression.MemoryImages;

{$mode objfpc}
{$pointermath on}

interface

uses
  Compression.DecodeResults,
  Compression.LzmaDecoder,
  Compression.BufferInflate;

type
  TCompressedImageKind = (
    ImageNotCompressed,
    ImageXz,
    ImageGzip,
    ImageZstandard
  );

  { What the decoders need besides the buffers, some 40 KiB. }
  TDecompressionWorkspace = record
    case TCompressedImageKind of
      ImageXz: (Lzma: TLzmaDecoder);
      ImageGzip: (Inflate: TBufferInflateState);
  end;

function DetectCompressedImage(Input: PByte; InputSize: SizeUInt): TCompressedImageKind;

function CompressedImageKindName(Kind: TCompressedImageKind): PChar;

{ The decompressed size the image states. }
function CompressedImageSize(Kind: TCompressedImageKind; Input: PByte; InputSize: SizeUInt;
  out Size: QWord): TDecodeResult;

{ Decompresses into Output, exactly the image's decompressed size. }
function DecompressImage(var Workspace: TDecompressionWorkspace; Kind: TCompressedImageKind; Input: PByte;
  InputSize: SizeUInt; Output: PByte; OutputSize: SizeUInt): TDecodeResult;

implementation

uses
  Compression.XzDecoder,
  Compression.GzipDecoder;

function IsZstandardFrame(Input: PByte; InputSize: SizeUInt): Boolean;
begin
  Result := (InputSize >= 4) and (Input[0] = $28) and (Input[1] = $B5) and (Input[2] = $2F) and
    (Input[3] = $FD);
end;

function DetectCompressedImage(Input: PByte; InputSize: SizeUInt): TCompressedImageKind;
begin
  if IsXzStream(Input, InputSize) then
    Result := ImageXz
  else if IsGzipMember(Input, InputSize) then
    Result := ImageGzip
  else if IsZstandardFrame(Input, InputSize) then
    Result := ImageZstandard
  else
    Result := ImageNotCompressed;
end;

function CompressedImageKindName(Kind: TCompressedImageKind): PChar;
begin
  case Kind of
    ImageXz: Result := 'xz';
    ImageGzip: Result := 'gzip';
    ImageZstandard: Result := 'zstd';
  else
    Result := 'uncompressed';
  end;
end;

function CompressedImageSize(Kind: TCompressedImageKind; Input: PByte; InputSize: SizeUInt;
  out Size: QWord): TDecodeResult;
begin
  Size := 0;
  case Kind of
    ImageXz: Result := XzUncompressedSize(Input, InputSize, Size);
    ImageGzip: Result := GzipUncompressedSize(Input, InputSize, Size);
    ImageZstandard: Result := DecodeUnsupported;
  else
    Size := InputSize;
    Result := DecodeSucceeded;
  end;
end;

function DecompressImage(var Workspace: TDecompressionWorkspace; Kind: TCompressedImageKind; Input: PByte;
  InputSize: SizeUInt; Output: PByte; OutputSize: SizeUInt): TDecodeResult;
begin
  case Kind of
    ImageXz: Result := XzDecode(Workspace.Lzma, Input, InputSize, Output, OutputSize);
    ImageGzip: Result := GzipDecode(Workspace.Inflate, Input, InputSize, Output, OutputSize);
  else
    Result := DecodeUnsupported;
  end;
end;

end.
