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
  Telling an archive's format by its content, whatever its name.
}
unit Archive.Detection;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Readers;

function DetectFormat(Stream: TStream): TArchiveFormat;

implementation

uses
  Compression.Formats,
  Compression.Streams,
  Archive.RewindingStreams,
  Archive.XzStreams,
  Archive.TarFormat,
  Archive.ZipFormat,
  Archive.ZipEndRecord;

const
  { An empty tar is only end blocks: Python and GNU tar write 10240
    bytes of them. Larger runs of zeros are not taken for one. }
  LargestEmptyTar = 2 * 10240;

function ReadFully(Stream: TStream; var Buffer; Count: Integer): Integer;
var
  Done: Integer;
begin
  Result := 0;
  while Result < Count do
  begin
    Done := Stream.Read((PByte(@Buffer) + Result)^, Count - Result);
    if Done <= 0 then
      Break;
    Inc(Result, Done);
  end;
end;

function LooksLikeTar(const Block: TTarBlock; BlockLength: Integer; TotalSize: Int64): Boolean;
begin
  if BlockLength < TarBlockSize then
    Exit(False);
  if IsTarHeader(Block) then
    Exit(True);
  Result := BlockIsZero(Block) and (TotalSize >= 2 * TarBlockSize) and (TotalSize <= LargestEmptyTar) and
    (TotalSize mod TarBlockSize = 0);
end;

function GzipHoldsTar(Stream: TStream): Boolean;
var
  Decoder: TDecompressionStream;
  Block: TTarBlock;
  Got: Integer;
begin
  Result := False;
  Stream.Position := 0;
  Decoder := TDecompressionStream.Create(Stream, FormatGzip);
  try
    try
      FillChar(Block, SizeOf(Block), 0);
      Got := ReadFully(Decoder, Block, TarBlockSize);
      if Got < TarBlockSize then
        Exit;
      { An empty tar inside: only its zero blocks. }
      Result := IsTarHeader(Block) or BlockIsZero(Block);
    except
      Result := False;
    end;
  finally
    Decoder.Free;
  end;
end;

function ZstdHoldsTar(Stream: TStream): Boolean;
var
  Decoder: TRewindingDecoderStream;
  Block: TTarBlock;
begin
  Result := False;
  Decoder := TRewindingDecoderStream.Create(Stream, RewindingZstd);
  try
    try
      FillChar(Block, SizeOf(Block), 0);
      if ReadFully(Decoder, Block, TarBlockSize) < TarBlockSize then
        Exit;
      Result := IsTarHeader(Block) or BlockIsZero(Block);
    except
      Result := False;
    end;
  finally
    Decoder.Free;
  end;
end;

function DetectFormat(Stream: TStream): TArchiveFormat;
var
  Block: TTarBlock;
  Got: Integer;
  Signature: LongWord;
  ZipEnd: TZipEnd;
begin
  Result := ArchiveUnknown;
  FillChar(Block, SizeOf(Block), 0);
  Stream.Position := 0;
  Got := ReadFully(Stream, Block, TarBlockSize);
  if Got >= 4 then
  begin
    Signature := LongWord(Block[0]) or (LongWord(Block[1]) shl 8) or (LongWord(Block[2]) shl 16) or
      (LongWord(Block[3]) shl 24);
    if (Signature = LocalHeaderSignature) or (Signature = EndOfCentralDirectorySignature) then
      Exit(ArchiveZip);
    if (Block[0] = $1F) and (Block[1] = $8B) then
    begin
      if GzipHoldsTar(Stream) then
        Result := ArchiveTarGzip;
      Exit;
    end;
    if (Block[0] = $28) and (Block[1] = $B5) and (Block[2] = $2F) and (Block[3] = $FD) then
    begin
      if ZstdHoldsTar(Stream) then
        Result := ArchiveTarZstd;
      Exit;
    end;
    if (Got >= 6) and (Block[0] = $FD) and (Block[1] = $37) and (Block[2] = $7A) and (Block[3] = $58) then
    begin
      if XzHoldsTar(Stream) then
        Result := ArchiveTarXz;
      Exit;
    end;
  end;
  if LooksLikeTar(Block, Got, Stream.Size) then
    Exit(ArchiveTar);
  { A zip with something before it (a self-extracting one). }
  if FindZipEnd(Stream, ZipEnd) then
    Result := ArchiveZip;
end;

end.
