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
  A PNG file's chunks.

  After the eight-byte signature a PNG file is a run of chunks: a
  32-bit big-endian length (at most 2^31 - 1), four letters naming the
  chunk, the data, and a CRC-32 of the letters and the data. A
  capital first letter makes a chunk critical (a decoder that does not
  know it must not show the picture); a small one ancillary.

  ReadPngChunks walks the file once and lists where every chunk's data
  is, without copying it, up to IEND. Every chunk's CRC is checked: a
  mismatch is ImageErrorMalformed, as are names that are not letters
  and lengths of 2^31 or more. A file cut short stops the list at the
  last whole chunk (Truncated says so); whether that matters is the
  decoder's affair, which knows what it still needed.

  WritePngChunk appends a chunk with its length and CRC.
}
unit Image.Png.Chunks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.ByteWriters;

const
  { The names as big-endian numbers ('IHDR' is $49484452). }
  PngChunkHeader = LongWord($49484452);          { IHDR }
  PngChunkPalette = LongWord($504C5445);         { PLTE }
  PngChunkImageData = LongWord($49444154);       { IDAT }
  PngChunkEnd = LongWord($49454E44);             { IEND }
  PngChunkTransparency = LongWord($74524E53);    { tRNS }
  PngChunkGamma = LongWord($67414D41);           { gAMA }
  PngChunkChromaticities = LongWord($6348524D);  { cHRM }
  PngChunkStandardRgb = LongWord($73524742);     { sRGB }
  PngChunkIccProfile = LongWord($69434350);      { iCCP }
  PngChunkText = LongWord($74455874);            { tEXt }
  PngChunkCompressedText = LongWord($7A545874);  { zTXt }
  PngChunkInternationalText = LongWord($69545874); { iTXt }
  PngChunkPhysicalSize = LongWord($70485973);    { pHYs }
  PngChunkTime = LongWord($74494D45);            { tIME }
  PngChunkExif = LongWord($65584966);            { eXIf }
  PngChunkAnimationControl = LongWord($6163544C); { acTL }
  PngChunkFrameControl = LongWord($6663544C);    { fcTL }
  PngChunkFrameData = LongWord($66644154);       { fdAT }

  PngLargestChunkLength = $7FFFFFFF;

type
  TPngChunk = record
    ChunkType: LongWord;
    { Where the chunk's data starts in the file, and its length. }
    DataOffset: PtrInt;
    DataLength: PtrInt;
  end;

  TPngChunkArray = array of TPngChunk;

  TPngChunkList = record
    Chunks: TPngChunkArray;
    Count: LongInt;
    { IEND was reached. }
    EndFound: Boolean;
    { The file stopped in the middle of a chunk (or before IEND). }
    Truncated: Boolean;
  end;

{ True when Data starts with the PNG signature. }
function HasPngSignature(const Data: TBytes): Boolean;
{ Every chunk of Data, a PNG file (ImageErrorUnknownFormat without the
  signature). }
function ReadPngChunks(const Data: TBytes): TPngChunkList;

function IsCriticalChunk(ChunkType: LongWord): Boolean;
{ 'IHDR' for PngChunkHeader. }
function PngChunkName(ChunkType: LongWord): string;

{ The big-endian numbers at Offset of a chunk's data; ImageErrorMalformed
  when they are not inside it. }
function ChunkLong(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): LongWord;
function ChunkWord(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): LongWord;
function ChunkByte(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): Byte;

{ Appends a chunk: length, name, Payload (Count bytes) and CRC. }
procedure WritePngChunk(Writer: TImageByteWriter; ChunkType: LongWord; Payload: PByte; Count: PtrInt);
procedure WritePngChunkBytes(Writer: TImageByteWriter; ChunkType: LongWord; const Payload: TBytes);
procedure WritePngSignature(Writer: TImageByteWriter);

implementation

uses
  Image.Codecs,
  Compression.Checksums;

function HasPngSignature(const Data: TBytes): Boolean;
var
  Index: LongInt;
begin
  if Length(Data) < Length(PngSignature) then
    Exit(False);
  for Index := 0 to High(PngSignature) do
    if Data[Index] <> PngSignature[Index] then
      Exit(False);
  Result := True;
end;

function IsCriticalChunk(ChunkType: LongWord): Boolean;
begin
  Result := ((ChunkType shr 24) and $20) = 0;
end;

function PngChunkName(ChunkType: LongWord): string;
begin
  Result := Chr(ChunkType shr 24) + Chr((ChunkType shr 16) and $FF) + Chr((ChunkType shr 8) and $FF) +
    Chr(ChunkType and $FF);
end;

function BigLongAt(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  Result := (LongWord(Data[Offset]) shl 24) or (LongWord(Data[Offset + 1]) shl 16) or
    (LongWord(Data[Offset + 2]) shl 8) or Data[Offset + 3];
end;

function IsLetter(Value: Byte): Boolean;
begin
  Result := ((Value >= Ord('A')) and (Value <= Ord('Z'))) or ((Value >= Ord('a')) and (Value <= Ord('z')));
end;

function ChunkNameIsLetters(ChunkType: LongWord): Boolean;
begin
  Result := IsLetter(ChunkType shr 24) and IsLetter((ChunkType shr 16) and $FF) and
    IsLetter((ChunkType shr 8) and $FF) and IsLetter(ChunkType and $FF);
end;

procedure AddChunk(var List: TPngChunkList; constref Chunk: TPngChunk);
begin
  if List.Count = Length(List.Chunks) then
    SetLength(List.Chunks, 2 * List.Count + 16);
  List.Chunks[List.Count] := Chunk;
  Inc(List.Count);
end;

function ReadPngChunks(const Data: TBytes): TPngChunkList;
var
  Position: PtrInt;
  Size: PtrInt;
  Chunk: TPngChunk;
  Length32: LongWord;
  StoredCrc: LongWord;
  ComputedCrc: LongWord;
begin
  Result := Default(TPngChunkList);
  if not HasPngSignature(Data) then
    RaiseImageError(ImageErrorUnknownFormat, 'not a PNG file');
  Size := Length(Data);
  Position := Length(PngSignature);
  while True do
  begin
    if Position + 8 > Size then
    begin
      Result.Truncated := True;
      Break;
    end;
    Length32 := BigLongAt(Data, Position);
    if Length32 > PngLargestChunkLength then
      RaiseImageError(ImageErrorMalformed, 'chunk length');
    Chunk.ChunkType := BigLongAt(Data, Position + 4);
    if not ChunkNameIsLetters(Chunk.ChunkType) then
      RaiseImageError(ImageErrorMalformed, 'chunk name');
    Chunk.DataOffset := Position + 8;
    Chunk.DataLength := Length32;
    if Chunk.DataLength + 4 > Size - Chunk.DataOffset then
    begin
      Result.Truncated := True;
      Break;
    end;
    StoredCrc := BigLongAt(Data, Chunk.DataOffset + Chunk.DataLength);
    ComputedCrc := Crc32(Crc32Initial, @Data[Position + 4], Chunk.DataLength + 4);
    if StoredCrc <> ComputedCrc then
      RaiseImageError(ImageErrorMalformed, 'CRC of the ' + PngChunkName(Chunk.ChunkType) + ' chunk');
    AddChunk(Result, Chunk);
    Position := Chunk.DataOffset + Chunk.DataLength + 4;
    if Chunk.ChunkType = PngChunkEnd then
    begin
      Result.EndFound := True;
      Break;
    end;
  end;
end;

procedure CheckInside(constref Chunk: TPngChunk; Offset, Count: PtrInt);
begin
  if (Offset < 0) or (Offset + Count > Chunk.DataLength) then
    RaiseImageError(ImageErrorMalformed, 'the ' + PngChunkName(Chunk.ChunkType) + ' chunk is too short');
end;

function ChunkLong(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): LongWord;
begin
  CheckInside(Chunk, Offset, 4);
  Result := BigLongAt(Data, Chunk.DataOffset + Offset);
end;

function ChunkWord(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): LongWord;
begin
  CheckInside(Chunk, Offset, 2);
  Result := (LongWord(Data[Chunk.DataOffset + Offset]) shl 8) or Data[Chunk.DataOffset + Offset + 1];
end;

function ChunkByte(const Data: TBytes; constref Chunk: TPngChunk; Offset: PtrInt): Byte;
begin
  CheckInside(Chunk, Offset, 1);
  Result := Data[Chunk.DataOffset + Offset];
end;

procedure WritePngSignature(Writer: TImageByteWriter);
begin
  Writer.WriteBuffer(PngSignature[0], Length(PngSignature));
end;

procedure WritePngChunk(Writer: TImageByteWriter; ChunkType: LongWord; Payload: PByte; Count: PtrInt);
var
  Name: array[0..3] of Byte;
  Crc: LongWord;
begin
  Name[0] := ChunkType shr 24;
  Name[1] := (ChunkType shr 16) and $FF;
  Name[2] := (ChunkType shr 8) and $FF;
  Name[3] := ChunkType and $FF;
  Writer.WriteLongBig(Count);
  Writer.WriteBuffer(Name[0], 4);
  Crc := Crc32(Crc32Initial, @Name[0], 4);
  if Count > 0 then
  begin
    Writer.WriteBuffer(Payload^, Count);
    Crc := Crc32(Crc, Payload, Count);
  end;
  Writer.WriteLongBig(Crc);
end;

procedure WritePngChunkBytes(Writer: TImageByteWriter; ChunkType: LongWord; const Payload: TBytes);
begin
  if Length(Payload) = 0 then
    WritePngChunk(Writer, ChunkType, nil, 0)
  else
    WritePngChunk(Writer, ChunkType, @Payload[0], Length(Payload));
end;

end.
