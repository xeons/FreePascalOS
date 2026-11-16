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
  A PNG picture's compressed data, decompressed as it is read.

  A picture's data is one zlib stream cut into consecutive chunks of
  one kind: IDAT for the default image, fdAT (each starting with a
  four-byte sequence number) for an APNG frame. The chunks are fed to
  libcompression's TInflater straight from the file, one after
  another as it asks for more, and the decoder takes the lines as they
  come out; nothing is put together in memory first.

  Running out of chunks before the lines are all there is
  ImageErrorTruncated; data that does not decompress, or a stream that
  ends before the picture, is ImageErrorMalformed. Finish checks the
  end of the stream (its Adler-32) when that is there to be read;
  extra data after the picture is ignored, as libpng does (and not
  decompressed beyond MaximumExtraData, so a stream that expands
  without end costs nothing).
}
unit Image.Png.DataStream;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Png.Chunks,
  Compression.Errors,
  Compression.Formats,
  Compression.Inflater;

type
  TPngDataStream = class
  private
    FData: TBytes;
    FChunks: TPngChunkArray;
    FChunkCount: LongInt;
    FNextChunk: LongInt;
    FChunkType: LongWord;
    FInflater: TInflater;
    FStreamEnded: Boolean;
    FStarted: Boolean;
    function FeedNextChunk: Boolean;
    procedure Start;
  public
    { The data of the chunks of ChunkType (IDAT or fdAT) that follow
      one another from index FirstChunk of Chunks. }
    constructor Create(const Data: TBytes; constref List: TPngChunkList; FirstChunk: LongInt; ChunkType: LongWord);
    destructor Destroy; override;
    { Exactly Count bytes of decompressed data into Buffer. }
    procedure Read(Buffer: PByte; Count: PtrInt);
    { Reads to the end of the stream if its chunks are there. }
    procedure Finish;
    { The index of the first chunk after the picture's data (once all
      of it has been read). }
    property NextChunk: LongInt read FNextChunk;
  end;

implementation

const
  { The sequence number before an fdAT chunk's data. }
  FrameDataPrefix = 4;
  MaximumExtraData = 65536;

constructor TPngDataStream.Create(const Data: TBytes; constref List: TPngChunkList; FirstChunk: LongInt;
  ChunkType: LongWord);
begin
  inherited Create;
  FData := Data;
  FChunks := List.Chunks;
  FChunkCount := List.Count;
  FNextChunk := FirstChunk;
  FChunkType := ChunkType;
  FInflater := TInflater.Create(FormatZlib);
  FStreamEnded := False;
end;

destructor TPngDataStream.Destroy;
begin
  FInflater.Free;
  inherited Destroy;
end;

function TPngDataStream.FeedNextChunk: Boolean;
var
  Offset: PtrInt;
  Count: PtrInt;
begin
  while (FNextChunk < FChunkCount) and (FChunks[FNextChunk].ChunkType = FChunkType) do
  begin
    Offset := FChunks[FNextChunk].DataOffset;
    Count := FChunks[FNextChunk].DataLength;
    Inc(FNextChunk);
    if FChunkType = PngChunkFrameData then
    begin
      if Count < FrameDataPrefix then
        RaiseImageError(ImageErrorMalformed, 'fdAT chunk');
      Inc(Offset, FrameDataPrefix);
      Dec(Count, FrameDataPrefix);
    end;
    if Count > 0 then
    begin
      FInflater.SetInput(@FData[Offset], Count);
      Exit(True);
    end;
  end;
  Result := False;
end;

{ The first chunk with data goes in before anything is asked of the
  inflater. }
procedure TPngDataStream.Start;
begin
  FStarted := True;
  if not FeedNextChunk then
    RaiseImageError(ImageErrorTruncated, 'image data');
end;

procedure TPngDataStream.Read(Buffer: PByte; Count: PtrInt);
var
  Written: SizeInt;
  Outcome: TInflateResult;
begin
  if not FStarted then
    Start;
  while Count > 0 do
  begin
    if FStreamEnded then
      RaiseImageError(ImageErrorMalformed, 'the image data ends before the picture');
    Outcome := FInflater.Decompress(Buffer, Count, Written);
    Inc(Buffer, Written);
    Dec(Count, Written);
    case Outcome of
      InflateNeedsInput:
        if not FeedNextChunk then
          RaiseImageError(ImageErrorTruncated, 'image data');
      InflateFinished:
        FStreamEnded := True;
      InflateFailed:
        RaiseImageError(ImageErrorMalformed, 'image data: ' + CompressionErrorMessage(FInflater.Error));
    end;
  end;
end;

procedure TPngDataStream.Finish;
var
  Scratch: array[0..255] of Byte;
  Written: SizeInt;
  Outcome: TInflateResult;
  ExtraData: PtrInt;
begin
  if not FStarted then
    Start;
  ExtraData := 0;
  while not FStreamEnded and (ExtraData <= MaximumExtraData) do
  begin
    Outcome := FInflater.Decompress(@Scratch[0], SizeOf(Scratch), Written);
    Inc(ExtraData, Written);
    case Outcome of
      InflateNeedsInput:
        if not FeedNextChunk then
          Break;
      InflateFinished:
        FStreamEnded := True;
      InflateFailed:
        RaiseImageError(ImageErrorMalformed, 'image data: ' + CompressionErrorMessage(FInflater.Error));
    end;
  end;
  { Skip whatever data chunks remain unread. }
  while (FNextChunk < FChunkCount) and (FChunks[FNextChunk].ChunkType = FChunkType) do
    Inc(FNextChunk);
end;

end.
