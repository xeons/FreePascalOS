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
  The content of an xz file, decompressed into memory. libcompression's
  xz decoder (Compression.XzDecoder, the one the kernel unpacks RAM disks
  with) works on whole buffers: the file is read, its decompressed size
  taken from the index, and the stream decoded at once into a memory
  stream that can then be read and positioned freely. Bounded by
  MaximumXzSize, so a .tar.xz may be up to that size unpacked.

  XzHoldsTar tells a .tar.xz by content without decoding it: the xz
  magic and, for a file of up to 64 KiB, a decompressed size (from the
  index) that is a whole number of tar blocks; a larger xz file is taken
  for a .tar.xz by its magic, and opening it says so if it is not.
}
unit Archive.XzStreams;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils;

const
  MaximumXzSize = 512 * 1024 * 1024;

{ The decompressed data of the xz stream in Source (read whole). }
function DecompressXz(Source: TStream): TMemoryStream;
function XzHoldsTar(Stream: TStream): Boolean;
function StartsWithXzMagic(Stream: TStream): Boolean;

implementation

uses
  Compression.DecodeResults,
  Compression.LzmaDecoder,
  Compression.XzDecoder,
  Archive.Entries;

const
  TarBlockBytes = 512;
  { The index sits at the end: this much of the tail is enough to read
    the footer and a small index without reading the whole file. }
  TailBytes = 64 * 1024;

function ReadAll(Source: TStream): TBytes;
var
  Size, Done, Got: Int64;
begin
  Result := nil;
  Source.Position := 0;
  Size := Source.Size;
  if Size > MaximumXzSize then
    raise EArchiveError.Create('The xz file is too large to decompress');
  SetLength(Result, Size);
  Done := 0;
  while Done < Size do
  begin
    Got := Source.Read(Result[Done], Size - Done);
    if Got <= 0 then
      raise EArchiveError.Create('The xz file could not be read whole');
    Inc(Done, Got);
  end;
end;

function DecompressXz(Source: TStream): TMemoryStream;
var
  Input: TBytes;
  Size: QWord;
  Outcome: TDecodeResult;
  Decoder: ^TLzmaDecoder;
begin
  Input := ReadAll(Source);
  if (Length(Input) = 0) or not IsXzStream(@Input[0], Length(Input)) then
    raise EArchiveError.Create('Not xz data');
  Outcome := XzUncompressedSize(@Input[0], Length(Input), Size);
  if Outcome <> DecodeSucceeded then
    raise EArchiveError.CreateFmt('Damaged xz data: %s', [string(DecodeResultText(Outcome))]);
  if Size > MaximumXzSize then
    raise EArchiveError.Create('The xz data is too large to decompress');
  Result := TMemoryStream.Create;
  New(Decoder);
  try
    try
      Result.SetSize(Int64(Size));
      if Size > 0 then
      begin
        Outcome := XzDecode(Decoder^, @Input[0], Length(Input), Result.Memory, Size);
        if Outcome <> DecodeSucceeded then
          raise EArchiveError.CreateFmt('Damaged xz data: %s', [string(DecodeResultText(Outcome))]);
      end;
      Result.Position := 0;
    except
      Result.Free;
      raise;
    end;
  finally
    Dispose(Decoder);
  end;
end;

function StartsWithXzMagic(Stream: TStream): Boolean;
var
  Head: array[0..XzMagicSize - 1] of Byte;
begin
  Stream.Position := 0;
  Result := (Stream.Read(Head, XzMagicSize) = XzMagicSize) and IsXzStream(@Head[0], XzMagicSize);
end;

function XzHoldsTar(Stream: TStream): Boolean;
var
  Data: TBytes;
  Size: QWord;
begin
  Result := False;
  if not StartsWithXzMagic(Stream) then
    Exit;
  if Stream.Size > MaximumXzSize then
    Exit;
  Data := nil;
  { The index is at the end; small files are read whole. }
  if Stream.Size > TailBytes then
    Exit(True);
  SetLength(Data, Stream.Size);
  Stream.Position := 0;
  if Stream.Read(Data[0], Length(Data)) <> Length(Data) then
    Exit;
  if XzUncompressedSize(@Data[0], Length(Data), Size) <> DecodeSucceeded then
    Exit;
  Result := (Size >= 2 * TarBlockBytes) and (Size mod TarBlockBytes = 0);
end;

end.
