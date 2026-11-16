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
  Compressing and decompressing whole arrays in one call:

    Packed := CompressZlib(Data);
    Data := DecompressZlib(Packed);

  Decompression is strict: the data must be whole (else
  CompressionErrorTruncated) and nothing may follow it (else
  CompressionErrorTrailingData); errors raise ECompressionError.
  MaximumSize, if not 0, bounds the decompressed size
  (CompressionErrorOutputLimit), against data made to expand without
  end.
}
unit Compression.Buffers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.Formats,
  Compression.Inflater,
  Compression.Deflater;

function CompressBuffer(Data: PByte; Count: SizeInt; Format: TCompressionFormat;
  Level: Integer = CompressionLevelDefault): TBytes;
function DecompressBuffer(Data: PByte; Count: SizeInt; Format: TCompressionFormat;
  MaximumSize: Int64 = 0): TBytes;

function CompressBytes(const Data: TBytes; Format: TCompressionFormat;
  Level: Integer = CompressionLevelDefault): TBytes;
function DecompressBytes(const Data: TBytes; Format: TCompressionFormat; MaximumSize: Int64 = 0): TBytes;

function CompressZlib(const Data: TBytes; Level: Integer = CompressionLevelDefault): TBytes;
function DecompressZlib(const Data: TBytes; MaximumSize: Int64 = 0): TBytes;
function CompressGzip(const Data: TBytes; Level: Integer = CompressionLevelDefault): TBytes;
function DecompressGzip(const Data: TBytes; MaximumSize: Int64 = 0): TBytes;
function CompressRaw(const Data: TBytes; Level: Integer = CompressionLevelDefault): TBytes;
function DecompressRaw(const Data: TBytes; MaximumSize: Int64 = 0): TBytes;

implementation

const
  SmallestOutput = 4096;

function CompressBuffer(Data: PByte; Count: SizeInt; Format: TCompressionFormat; Level: Integer): TBytes;
var
  Deflater: TDeflater;
  Used: SizeInt;
  Written: SizeInt;
begin
  Result := nil;
  SetLength(Result, Count div 2 + SmallestOutput);
  Used := 0;
  Deflater := TDeflater.Create(Format, Level);
  try
    Deflater.SetInput(Data, Count);
    while Deflater.Compress(@Result[Used], Length(Result) - Used, Written, True) <> DeflateFinished do
    begin
      Inc(Used, Written);
      SetLength(Result, 2 * Length(Result));
    end;
    Inc(Used, Written);
  finally
    Deflater.Free;
  end;
  SetLength(Result, Used);
end;

function DecompressBuffer(Data: PByte; Count: SizeInt; Format: TCompressionFormat; MaximumSize: Int64): TBytes;
var
  Inflater: TInflater;
  Used: SizeInt;
  Written: SizeInt;
  Outcome: TInflateResult;
  NewSize: Int64;
begin
  Result := nil;
  NewSize := 4 * Int64(Count) + SmallestOutput;
  if (MaximumSize > 0) and (NewSize > MaximumSize + 1) then
    NewSize := MaximumSize + 1;
  SetLength(Result, NewSize);
  Used := 0;
  Inflater := TInflater.Create(Format);
  try
    Inflater.SetInput(Data, Count);
    repeat
      Outcome := Inflater.Decompress(@Result[Used], Length(Result) - Used, Written);
      Inc(Used, Written);
      if (MaximumSize > 0) and (Used > MaximumSize) then
        raise ECompressionError.CreateCode(CompressionErrorOutputLimit);
      case Outcome of
        InflateOutputFull:
          begin
            NewSize := 2 * Int64(Length(Result));
            if (MaximumSize > 0) and (NewSize > MaximumSize + 1) then
              NewSize := MaximumSize + 1;
            SetLength(Result, NewSize);
          end;
        InflateNeedsInput:
          raise ECompressionError.CreateCode(CompressionErrorTruncated);
        InflateFailed:
          raise ECompressionError.CreateCode(Inflater.Error);
      end;
    until Outcome = InflateFinished;
    if Inflater.InputRemaining > 0 then
      raise ECompressionError.CreateCode(CompressionErrorTrailingData);
  finally
    Inflater.Free;
  end;
  SetLength(Result, Used);
end;

function CompressBytes(const Data: TBytes; Format: TCompressionFormat; Level: Integer): TBytes;
begin
  Result := CompressBuffer(PByte(Data), Length(Data), Format, Level);
end;

function DecompressBytes(const Data: TBytes; Format: TCompressionFormat; MaximumSize: Int64): TBytes;
begin
  Result := DecompressBuffer(PByte(Data), Length(Data), Format, MaximumSize);
end;

function CompressZlib(const Data: TBytes; Level: Integer): TBytes;
begin
  Result := CompressBytes(Data, FormatZlib, Level);
end;

function DecompressZlib(const Data: TBytes; MaximumSize: Int64): TBytes;
begin
  Result := DecompressBytes(Data, FormatZlib, MaximumSize);
end;

function CompressGzip(const Data: TBytes; Level: Integer): TBytes;
begin
  Result := CompressBytes(Data, FormatGzip, Level);
end;

function DecompressGzip(const Data: TBytes; MaximumSize: Int64): TBytes;
begin
  Result := DecompressBytes(Data, FormatGzip, MaximumSize);
end;

function CompressRaw(const Data: TBytes; Level: Integer): TBytes;
begin
  Result := CompressBytes(Data, FormatRaw, Level);
end;

function DecompressRaw(const Data: TBytes; MaximumSize: Int64): TBytes;
begin
  Result := DecompressBytes(Data, FormatRaw, MaximumSize);
end;

end.
