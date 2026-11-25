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
  The decompressed content of a gzip or Zstandard file as a stream that
  can be positioned anywhere: forwards by decompressing and dropping
  what lies between, backwards by starting over from the beginning.
  Reading a .tar.gz or .tar.zst in order (listing, then extracting
  everything) decompresses it once per pass.

  Decompression goes through libcompression's streaming decoders
  (TStreamingDecoder: TInflatingDecoder for gzip, TZstdDecoder), fed
  from the source in pieces; several gzip members or zstd frames come
  out as one stream.
}
unit Archive.RewindingStreams;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Compression.StreamingDecoders;

type
  TRewindingCompression = (RewindingGzip, RewindingZstd);

  TRewindingDecoderStream = class(TStream)
  private
    FSource: TStream;
    FOwnsSource: Boolean;
    FCompression: TRewindingCompression;
    FDecoder: TStreamingDecoder;
    FInput: array of Byte;
    FNeedsInput: Boolean;
    FEnded: Boolean;
    FPosition: Int64;
    procedure Restart;
    procedure SkipForward(Count: Int64);
    function FillInput: Boolean;
    function CompressionName: string;
  public
    constructor Create(Source: TStream; Compression: TRewindingCompression; OwnsSource: Boolean = False);
    destructor Destroy; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    { soBeginning and soCurrent; soEnd is not supported (the size is
      not known without decompressing everything). }
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { The gzip one, as tar.gz reading has always used it. }
  TRewindingGzipStream = class(TRewindingDecoderStream)
  public
    constructor Create(Source: TStream; OwnsSource: Boolean = False);
  end;

implementation

uses
  Compression.Errors,
  Compression.Formats,
  Compression.InflatingDecoders,
  Compression.ZstdDecoder,
  Archive.Entries;

const
  InputBufferSize = 65536;
  SkipBufferSize = 65536;

constructor TRewindingDecoderStream.Create(Source: TStream; Compression: TRewindingCompression;
  OwnsSource: Boolean);
begin
  inherited Create;
  FSource := Source;
  FOwnsSource := OwnsSource;
  FCompression := Compression;
  SetLength(FInput, InputBufferSize);
  Restart;
end;

destructor TRewindingDecoderStream.Destroy;
begin
  FDecoder.Free;
  if FOwnsSource then
    FSource.Free;
  inherited Destroy;
end;

function TRewindingDecoderStream.CompressionName: string;
begin
  if FCompression = RewindingZstd then
    Result := 'Zstandard'
  else
    Result := 'gzip';
end;

procedure TRewindingDecoderStream.Restart;
begin
  FreeAndNil(FDecoder);
  FSource.Position := 0;
  if FCompression = RewindingZstd then
    FDecoder := TZstdDecoder.Create
  else
    FDecoder := TInflatingDecoder.Create(FormatGzip);
  FNeedsInput := True;
  FEnded := False;
  FPosition := 0;
end;

{ The next piece of the source into the decoder; False at its end. }
function TRewindingDecoderStream.FillInput: Boolean;
var
  Got: LongInt;
begin
  Got := FSource.Read(FInput[0], Length(FInput));
  Result := Got > 0;
  if Result then
  begin
    FDecoder.SetInput(@FInput[0], Got);
    FNeedsInput := False;
  end;
end;

function TRewindingDecoderStream.Read(var Buffer; Count: LongInt): LongInt;
var
  Written: SizeInt;
  Outcome: TDecompressResult;
begin
  Result := 0;
  while (Result < Count) and not FEnded do
  begin
    if FNeedsInput and not FillInput then
    begin
      if not FDecoder.Finished then
        raise EArchiveError.CreateFmt('Damaged %s data: it is cut short', [CompressionName]);
      FEnded := True;
      Break;
    end;
    Outcome := FDecoder.Decompress(PByte(@Buffer) + Result, Count - Result, Written);
    Inc(Result, Written);
    case Outcome of
      DecompressNeedsInput, DecompressFinished:
        FNeedsInput := FDecoder.InputRemaining = 0;
      DecompressFailed:
        raise EArchiveError.CreateFmt('Damaged %s data: %s',
          [CompressionName, CompressionErrorMessage(FDecoder.Error)]);
    end;
  end;
  Inc(FPosition, Result);
end;

function TRewindingDecoderStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  raise EArchiveError.Create('A decompressing stream cannot be written');
  Result := 0;
end;

procedure TRewindingDecoderStream.SkipForward(Count: Int64);
var
  Buffer: array of Byte;
  Piece, Got: LongInt;
begin
  Buffer := nil;
  SetLength(Buffer, SkipBufferSize);
  while Count > 0 do
  begin
    if Count > SkipBufferSize then
      Piece := SkipBufferSize
    else
      Piece := LongInt(Count);
    Got := Read(Buffer[0], Piece);
    if Got <= 0 then
      Break;
    Dec(Count, Got);
  end;
end;

function TRewindingDecoderStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  Target: Int64;
begin
  case Origin of
    soBeginning: Target := Offset;
    soCurrent: Target := FPosition + Offset;
  else
    raise EArchiveError.Create('A decompressing stream cannot seek from its end');
  end;
  if Target < 0 then
    Target := 0;
  if Target < FPosition then
    Restart;
  if Target > FPosition then
    SkipForward(Target - FPosition);
  Result := FPosition;
end;

constructor TRewindingGzipStream.Create(Source: TStream; OwnsSource: Boolean);
begin
  inherited Create(Source, RewindingGzip, OwnsSource);
end;

end.
