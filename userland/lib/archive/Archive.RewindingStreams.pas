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
  The decompressed content of a gzip file as a stream that can be
  positioned anywhere: forwards by decompressing and dropping what lies
  between, backwards by starting over from the beginning. Reading a
  .tar.gz in order (listing, then extracting everything) decompresses
  it once per pass.
}
unit Archive.RewindingStreams;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Compression.Formats,
  Compression.Streams;

type
  TRewindingGzipStream = class(TStream)
  private
    FSource: TStream;
    FOwnsSource: Boolean;
    FDecoder: TDecompressionStream;
    FPosition: Int64;
    procedure Restart;
    procedure SkipForward(Count: Int64);
  public
    constructor Create(Source: TStream; OwnsSource: Boolean = False);
    destructor Destroy; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    { soBeginning and soCurrent; soEnd is not supported (the size is
      not known without decompressing everything). }
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

implementation

uses
  Archive.Entries;

const
  SkipBufferSize = 65536;

constructor TRewindingGzipStream.Create(Source: TStream; OwnsSource: Boolean);
begin
  inherited Create;
  FSource := Source;
  FOwnsSource := OwnsSource;
  Restart;
end;

destructor TRewindingGzipStream.Destroy;
begin
  FDecoder.Free;
  if FOwnsSource then
    FSource.Free;
  inherited Destroy;
end;

procedure TRewindingGzipStream.Restart;
begin
  FreeAndNil(FDecoder);
  FSource.Position := 0;
  FDecoder := TDecompressionStream.Create(FSource, FormatGzip);
  FPosition := 0;
end;

function TRewindingGzipStream.Read(var Buffer; Count: LongInt): LongInt;
var
  Done: LongInt;
begin
  Result := 0;
  try
    while Result < Count do
    begin
      Done := FDecoder.Read((PByte(@Buffer) + Result)^, Count - Result);
      if Done <= 0 then
        Break;
      Inc(Result, Done);
    end;
  except
    on Error: EArchiveError do
      raise;
    on Error: Exception do
      raise EArchiveError.CreateFmt('Damaged gzip data: %s', [Error.Message]);
  end;
  Inc(FPosition, Result);
end;

function TRewindingGzipStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  raise EArchiveError.Create('A decompressing stream cannot be written');
  Result := 0;
end;

procedure TRewindingGzipStream.SkipForward(Count: Int64);
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

function TRewindingGzipStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
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

end.
