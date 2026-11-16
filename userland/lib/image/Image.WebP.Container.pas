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
  The WebP container: a RIFF file of form type WEBP whose chunks are a
  four character tag, a little-endian 32-bit size and the payload,
  padded to an even length.

  A simple file is one VP8 (lossy) or VP8L (lossless) chunk. An
  extended file starts with VP8X (flags and the canvas size, each side
  24 bits less one) and may carry ICCP (the colour profile), EXIF, XMP,
  and either one picture (ALPH, the alpha of a lossy picture, then VP8;
  or VP8L) or an animation: ANIM (the background colour and loop count)
  and ANMF frames, each an offset (in units of two pixels), a size, a
  duration, how it is disposed of and blended, and the frame's own
  ALPH/VP8 or VP8L chunks.

  The chunks are listed without copying (offsets into the file); a
  chunk that runs past the end of the file is "cut short", a RIFF size
  shorter than the file ends the list there.
}
unit Image.WebP.Container;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors;

const
  WebPFlagAnimation = $02;
  WebPFlagXmp = $04;
  WebPFlagExif = $08;
  WebPFlagAlpha = $10;
  WebPFlagIcc = $20;

  { ANMF's flags byte. }
  WebPFrameNoBlend = $01;
  WebPFrameDisposeBackground = $02;

  RiffHeaderLength = 12;
  ChunkHeaderLength = 8;
  ExtendedHeaderLength = 10;
  AnimationHeaderLength = 6;
  FrameHeaderLength = 16;

  { The chunk tags as they read little-endian. }
  ChunkTagLossy = Ord('V') or (Ord('P') shl 8) or (Ord('8') shl 16) or (Ord(' ') shl 24);
  ChunkTagLossless = Ord('V') or (Ord('P') shl 8) or (Ord('8') shl 16) or (Ord('L') shl 24);
  ChunkTagExtended = Ord('V') or (Ord('P') shl 8) or (Ord('8') shl 16) or (Ord('X') shl 24);
  ChunkTagAlpha = Ord('A') or (Ord('L') shl 8) or (Ord('P') shl 16) or (Ord('H') shl 24);
  ChunkTagAnimation = Ord('A') or (Ord('N') shl 8) or (Ord('I') shl 16) or (Ord('M') shl 24);
  ChunkTagFrame = Ord('A') or (Ord('N') shl 8) or (Ord('M') shl 16) or (Ord('F') shl 24);
  ChunkTagIcc = Ord('I') or (Ord('C') shl 8) or (Ord('C') shl 16) or (Ord('P') shl 24);
  ChunkTagExif = Ord('E') or (Ord('X') shl 8) or (Ord('I') shl 16) or (Ord('F') shl 24);
  ChunkTagXmp = Ord('X') or (Ord('M') shl 8) or (Ord('P') shl 16) or (Ord(' ') shl 24);

type
  TWebPChunk = record
    Tag: LongWord;
    { The payload's offset in the file and its size. }
    Start: PtrInt;
    Size: PtrInt;
  end;
  TWebPChunkList = array of TWebPChunk;

  TWebPExtendedHeader = record
    Flags: Byte;
    CanvasWidth: LongInt;
    CanvasHeight: LongInt;
  end;

  TWebPAnimationHeader = record
    { As stored: blue, green, red, alpha; that is $AARRGGBB. }
    BackgroundColor: LongWord;
    LoopCount: LongInt;
  end;

  TWebPFrameHeader = record
    Left: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    Duration: LongInt;
    Flags: Byte;
  end;

  { One picture's bitstreams: VP8 with an optional ALPH, or VP8L. }
  TWebPPictureChunks = record
    HasAlpha: Boolean;
    Alpha: TWebPChunk;
    Image: TWebPChunk;
    Lossless: Boolean;
  end;

function ChunkTag(const Name: string): LongWord;
function ChunkTagName(Tag: LongWord): string;

{ True when Data starts like a WebP file (RIFF, WEBP). }
function HasWebPSignature(const Data: TBytes): Boolean;

{ The chunks of the whole file. }
function ListWebPChunks(const Data: TBytes): TWebPChunkList;
{ The chunks inside Count bytes at Start (an ANMF's payload past its
  header). }
function ListChunksIn(const Data: TBytes; Start, Count: PtrInt): TWebPChunkList;

{ The index of the first chunk with Tag, or -1. }
function FindChunk(const Chunks: TWebPChunkList; Tag: LongWord): LongInt;

procedure ReadExtendedHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPExtendedHeader);
procedure ReadAnimationHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPAnimationHeader);
procedure ReadFrameHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPFrameHeader);

{ The picture among Chunks: the first VP8L, or the first VP8 and the
  ALPH before it. ImageErrorMalformed when there is none. }
function FindPictureChunks(const Chunks: TWebPChunkList): TWebPPictureChunks;

function ReadLong24(const Data: TBytes; Offset: PtrInt): LongInt;

implementation

function ChunkTag(const Name: string): LongWord;
begin
  Result := Ord(Name[1]) or (LongWord(Ord(Name[2])) shl 8) or (LongWord(Ord(Name[3])) shl 16) or
    (LongWord(Ord(Name[4])) shl 24);
end;

function ChunkTagName(Tag: LongWord): string;
begin
  Result := Chr(Tag and $FF) + Chr((Tag shr 8) and $FF) + Chr((Tag shr 16) and $FF) + Chr(Tag shr 24);
end;

function ReadLong32(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  Result := Data[Offset] or (LongWord(Data[Offset + 1]) shl 8) or (LongWord(Data[Offset + 2]) shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

function ReadLong24(const Data: TBytes; Offset: PtrInt): LongInt;
begin
  Result := Data[Offset] or (LongInt(Data[Offset + 1]) shl 8) or (LongInt(Data[Offset + 2]) shl 16);
end;

function HasWebPSignature(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= RiffHeaderLength) and (Data[0] = Ord('R')) and (Data[1] = Ord('I')) and
    (Data[2] = Ord('F')) and (Data[3] = Ord('F')) and (Data[8] = Ord('W')) and (Data[9] = Ord('E')) and
    (Data[10] = Ord('B')) and (Data[11] = Ord('P'));
end;

function ListChunksIn(const Data: TBytes; Start, Count: PtrInt): TWebPChunkList;
var
  Position: PtrInt;
  Finish: PtrInt;
  Size: PtrInt;
  Chunk: TWebPChunk;
begin
  Result := nil;
  Position := Start;
  Finish := Start + Count;
  while Finish - Position >= ChunkHeaderLength do
  begin
    Chunk.Tag := ReadLong32(Data, Position);
    Size := ReadLong32(Data, Position + 4);
    Chunk.Start := Position + ChunkHeaderLength;
    Chunk.Size := Size;
    if Size > Finish - Chunk.Start then
      RaiseImageError(ImageErrorTruncated, 'WebP chunk ' + ChunkTagName(Chunk.Tag));
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Chunk;
    Position := Chunk.Start + Size + (Size and 1);
  end;
end;

function ListWebPChunks(const Data: TBytes): TWebPChunkList;
var
  RiffSize: Int64;
  Finish: Int64;
begin
  if not HasWebPSignature(Data) then
    RaiseImageError(ImageErrorUnknownFormat, 'not a WebP file');
  RiffSize := ReadLong32(Data, 4);
  if RiffSize < 4 then
    RaiseImageError(ImageErrorMalformed, 'RIFF size');
  Finish := RiffSize + 8;
  if Finish > Length(Data) then
    Finish := Length(Data);
  Result := ListChunksIn(Data, RiffHeaderLength, Finish - RiffHeaderLength);
  if Length(Result) = 0 then
    RaiseImageError(ImageErrorTruncated, 'WebP file without chunks');
end;

function FindChunk(const Chunks: TWebPChunkList; Tag: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Chunks) do
    if Chunks[Index].Tag = Tag then
      Exit(Index);
  Result := -1;
end;

procedure ReadExtendedHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPExtendedHeader);
begin
  if Chunk.Size < ExtendedHeaderLength then
    RaiseImageError(ImageErrorMalformed, 'VP8X chunk too short');
  Header.Flags := Data[Chunk.Start];
  Header.CanvasWidth := ReadLong24(Data, Chunk.Start + 4) + 1;
  Header.CanvasHeight := ReadLong24(Data, Chunk.Start + 7) + 1;
end;

procedure ReadAnimationHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPAnimationHeader);
begin
  if Chunk.Size < AnimationHeaderLength then
    RaiseImageError(ImageErrorMalformed, 'ANIM chunk too short');
  Header.BackgroundColor := ReadLong32(Data, Chunk.Start);
  Header.LoopCount := Data[Chunk.Start + 4] or (LongInt(Data[Chunk.Start + 5]) shl 8);
end;

procedure ReadFrameHeader(const Data: TBytes; constref Chunk: TWebPChunk; out Header: TWebPFrameHeader);
begin
  if Chunk.Size < FrameHeaderLength then
    RaiseImageError(ImageErrorMalformed, 'ANMF chunk too short');
  Header.Left := ReadLong24(Data, Chunk.Start) * 2;
  Header.Top := ReadLong24(Data, Chunk.Start + 3) * 2;
  Header.Width := ReadLong24(Data, Chunk.Start + 6) + 1;
  Header.Height := ReadLong24(Data, Chunk.Start + 9) + 1;
  Header.Duration := ReadLong24(Data, Chunk.Start + 12);
  Header.Flags := Data[Chunk.Start + 15];
end;

function FindPictureChunks(const Chunks: TWebPChunkList): TWebPPictureChunks;
var
  Index: LongInt;
  AlphaIndex: LongInt;
begin
  Result := Default(TWebPPictureChunks);
  AlphaIndex := -1;
  for Index := 0 to High(Chunks) do
  begin
    if Chunks[Index].Tag = ChunkTagAlpha then
    begin
      if AlphaIndex < 0 then
        AlphaIndex := Index;
    end
    else if Chunks[Index].Tag = ChunkTagLossless then
    begin
      Result.Image := Chunks[Index];
      Result.Lossless := True;
      Exit;
    end
    else if Chunks[Index].Tag = ChunkTagLossy then
    begin
      Result.Image := Chunks[Index];
      Result.Lossless := False;
      if AlphaIndex >= 0 then
      begin
        Result.HasAlpha := True;
        Result.Alpha := Chunks[AlphaIndex];
      end;
      Exit;
    end;
  end;
  RaiseImageError(ImageErrorMalformed, 'WebP without VP8 or VP8L data');
end;

end.
