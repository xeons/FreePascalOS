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
  Zstandard frames (RFC 8878 section 3.1): the magic numbers, the frame
  header after the magic (a descriptor byte saying which fields follow:
  the window descriptor, a dictionary id, the content size) and the
  three byte block header.
}
unit Compression.ZstdFrames;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors;

const
  ZstdFrameMagic = $FD2FB528;
  { Skippable frames: any magic from $184D2A50 to $184D2A5F. }
  ZstdSkippableMagic = $184D2A50;
  ZstdSkippableMagicMask = $FFFFFFF0;
  ZstdMagicSize = 4;
  ZstdLargestFrameHeader = 14;
  ZstdBlockHeaderSize = 3;
  ZstdChecksumSize = 4;
  ZstdLargestBlock = 128 * 1024;

  ZstdBlockRaw = 0;
  ZstdBlockRle = 1;
  ZstdBlockCompressed = 2;

type
  TZstdFrameHeader = record
    WindowSize: QWord;
    HasContentSize: Boolean;
    ContentSize: QWord;
    HasChecksum: Boolean;
    DictionaryId: LongWord;
  end;

  TZstdBlockHeader = record
    Last: Boolean;
    Kind: Integer;
    Size: SizeUInt;
  end;

{ The size of the frame header that starts with Descriptor, the
  descriptor included. }
function ZstdFrameHeaderSize(Descriptor: Byte): Integer;

{ Reads the frame header at Data (ZstdFrameHeaderSize bytes). }
function ReadZstdFrameHeader(Data: PByte; out Header: TZstdFrameHeader): TCompressionError;

function ReadZstdBlockHeader(Data: PByte): TZstdBlockHeader;

function ReadLittleEndian32(Data: PByte): LongWord;

implementation

const
  ReservedBit = $08;
  SingleSegmentBit = $20;
  ChecksumBit = $04;

function ReadLittleEndian32(Data: PByte): LongWord;
begin
  Result := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or
    (LongWord(Data[3]) shl 24);
end;

function ReadLittleEndian(Data: PByte; Count: Integer): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := Count - 1 downto 0 do
    Result := (Result shl 8) or Data[Index];
end;

function DictionaryIdSize(Descriptor: Byte): Integer;
const
  Sizes: array[0..3] of Integer = (0, 1, 2, 4);
begin
  Result := Sizes[Descriptor and 3];
end;

function ContentSizeSize(Descriptor: Byte): Integer;
begin
  case Descriptor shr 6 of
    0:
      if (Descriptor and SingleSegmentBit) <> 0 then
        Result := 1
      else
        Result := 0;
    1: Result := 2;
    2: Result := 4;
  else
    Result := 8;
  end;
end;

function ZstdFrameHeaderSize(Descriptor: Byte): Integer;
begin
  Result := 1 + DictionaryIdSize(Descriptor) + ContentSizeSize(Descriptor);
  if (Descriptor and SingleSegmentBit) = 0 then
    Inc(Result);
end;

function ReadZstdFrameHeader(Data: PByte; out Header: TZstdFrameHeader): TCompressionError;
var
  Descriptor: Byte;
  Position: Integer;
  WindowDescriptor: Byte;
  WindowLog: Integer;
  WindowBase: QWord;
  Size: Integer;
begin
  Header.WindowSize := 0;
  Header.HasContentSize := False;
  Header.ContentSize := 0;
  Header.HasChecksum := False;
  Header.DictionaryId := 0;
  Descriptor := Data[0];
  if (Descriptor and ReservedBit) <> 0 then
    Exit(CompressionErrorInvalidFrameHeader);
  Header.HasChecksum := (Descriptor and ChecksumBit) <> 0;
  Position := 1;
  if (Descriptor and SingleSegmentBit) = 0 then
  begin
    WindowDescriptor := Data[Position];
    Inc(Position);
    WindowLog := 10 + (WindowDescriptor shr 3);
    WindowBase := QWord(1) shl WindowLog;
    Header.WindowSize := WindowBase + (WindowBase div 8) * (WindowDescriptor and 7);
  end;
  Size := DictionaryIdSize(Descriptor);
  Header.DictionaryId := LongWord(ReadLittleEndian(Data + Position, Size));
  Inc(Position, Size);
  Size := ContentSizeSize(Descriptor);
  if Size > 0 then
  begin
    Header.HasContentSize := True;
    Header.ContentSize := ReadLittleEndian(Data + Position, Size);
    if Size = 2 then
      Inc(Header.ContentSize, 256);
  end;
  if (Descriptor and SingleSegmentBit) <> 0 then
    Header.WindowSize := Header.ContentSize;
  Result := CompressionErrorNone;
end;

function ReadZstdBlockHeader(Data: PByte): TZstdBlockHeader;
var
  Value: LongWord;
begin
  Value := LongWord(Data[0]) or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16);
  Result.Last := (Value and 1) <> 0;
  Result.Kind := (Value shr 1) and 3;
  Result.Size := Value shr 3;
end;

end.
