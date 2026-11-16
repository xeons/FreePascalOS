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
  Streams over streams:

    TDecompressionStream  reads compressed data from a source stream and
                          is read as the decompressed data
    TCompressionStream    is written with data and writes it compressed
                          to a target stream; Finish (or freeing it)
                          ends the compressed data, Flush writes out
                          everything so far (a sync or full flush)

  Both go forwards only; Seek tells the position and nothing more.
  Damaged or cut off data raises ECompressionError. When the compressed
  data ends before the source does and the source can seek, the source
  is left just after it.
}
unit Compression.Streams;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Compression.Errors,
  Compression.Formats,
  Compression.Inflater,
  Compression.Deflater;

const
  StreamBufferSize = 65536;

type
  TDecompressionStream = class(TStream)
  private
    FSource: TStream;
    FOwnsSource: Boolean;
    FInflater: TInflater;
    FBuffer: array of Byte;
    FPosition: Int64;
    FFinished: Boolean;
    function RefillInput: Boolean;
    procedure ReturnUnusedInput;
  public
    constructor Create(Source: TStream; Format: TCompressionFormat = FormatAutomatic; OwnsSource: Boolean = False);
    destructor Destroy; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Inflater: TInflater read FInflater;
  end;

  TCompressionStream = class(TStream)
  private
    FTarget: TStream;
    FOwnsTarget: Boolean;
    FDeflater: TDeflater;
    FBuffer: array of Byte;
    FPosition: Int64;
    FFinished: Boolean;
    procedure WriteOutput(Written: SizeInt);
  public
    constructor Create(Target: TStream; Format: TCompressionFormat = FormatZlib;
      Level: Integer = CompressionLevelDefault; OwnsTarget: Boolean = False);
    { Finishes the compressed data if Finish was not called. }
    destructor Destroy; override;
    { Writes the rest of the compressed data and the trailer. }
    procedure Finish;
    { Writes out everything written so far, so that the reader can
      decompress all of it now; with Full, the reader can also start
      over from here. }
    procedure Flush(Full: Boolean = False);
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Deflater: TDeflater read FDeflater;
  end;

implementation

{ TDecompressionStream }

constructor TDecompressionStream.Create(Source: TStream; Format: TCompressionFormat; OwnsSource: Boolean);
begin
  inherited Create;
  FSource := Source;
  FOwnsSource := OwnsSource;
  FInflater := TInflater.Create(Format);
  SetLength(FBuffer, StreamBufferSize);
end;

destructor TDecompressionStream.Destroy;
begin
  FInflater.Free;
  if FOwnsSource then
    FSource.Free;
  inherited Destroy;
end;

function TDecompressionStream.RefillInput: Boolean;
var
  Count: LongInt;
begin
  Count := FSource.Read(FBuffer[0], Length(FBuffer));
  Result := Count > 0;
  if Result then
    FInflater.SetInput(@FBuffer[0], Count);
end;

procedure TDecompressionStream.ReturnUnusedInput;
begin
  if FInflater.InputRemaining = 0 then
    Exit;
  try
    FSource.Seek(-FInflater.InputRemaining, soCurrent);
  except
    on EStreamError do
      ;
  end;
end;

function TDecompressionStream.Read(var Buffer; Count: LongInt): LongInt;
var
  Output: PByte;
  Written: SizeInt;
begin
  Result := 0;
  Output := @Buffer;
  while (Result < Count) and not FFinished do
  begin
    case FInflater.Decompress(Output + Result, Count - Result, Written) of
      InflateNeedsInput:
        if not RefillInput then
        begin
          Inc(Result, Written);
          if FInflater.Finished then
            FFinished := True
          else
            raise ECompressionError.CreateCode(CompressionErrorTruncated);
          Break;
        end;
      InflateFinished:
        if (FInflater.InputRemaining > 0) or not RefillInput then
        begin
          FFinished := True;
          Inc(Result, Written);
          ReturnUnusedInput;
          Break;
        end;
      InflateFailed:
        raise ECompressionError.CreateCode(FInflater.Error);
    end;
    Inc(Result, Written);
  end;
  Inc(FPosition, Result);
end;

function TDecompressionStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  raise EStreamError.Create('a decompression stream cannot be written');
end;

function TDecompressionStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Result := FPosition
  else
    raise EStreamError.Create('a decompression stream cannot seek');
end;

{ TCompressionStream }

constructor TCompressionStream.Create(Target: TStream; Format: TCompressionFormat; Level: Integer;
  OwnsTarget: Boolean);
begin
  inherited Create;
  FTarget := Target;
  FOwnsTarget := OwnsTarget;
  FDeflater := TDeflater.Create(Format, Level);
  SetLength(FBuffer, StreamBufferSize);
end;

destructor TCompressionStream.Destroy;
begin
  try
    if not FFinished then
      Finish;
  finally
    FDeflater.Free;
    if FOwnsTarget then
      FTarget.Free;
    inherited Destroy;
  end;
end;

procedure TCompressionStream.WriteOutput(Written: SizeInt);
begin
  if Written > 0 then
    FTarget.WriteBuffer(FBuffer[0], Written);
end;

function TCompressionStream.Write(const Buffer; Count: LongInt): LongInt;
var
  Written: SizeInt;
begin
  if FFinished then
    raise EStreamError.Create('the compressed data has been finished');
  FDeflater.SetInput(@Buffer, Count);
  while FDeflater.Compress(@FBuffer[0], Length(FBuffer), Written, False) = DeflateOutputFull do
    WriteOutput(Written);
  WriteOutput(Written);
  Inc(FPosition, Count);
  Result := Count;
end;

procedure TCompressionStream.Finish;
var
  Written: SizeInt;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FDeflater.SetInput(nil, 0);
  while FDeflater.Compress(@FBuffer[0], Length(FBuffer), Written, True) <> DeflateFinished do
    WriteOutput(Written);
  WriteOutput(Written);
end;

procedure TCompressionStream.Flush(Full: Boolean);
var
  Written: SizeInt;
  Mode: TDeflateFlush;
begin
  if FFinished then
    Exit;
  if Full then
    Mode := FlushFull
  else
    Mode := FlushSync;
  FDeflater.SetInput(nil, 0);
  while FDeflater.Compress(@FBuffer[0], Length(FBuffer), Written, Mode) = DeflateOutputFull do
    WriteOutput(Written);
  WriteOutput(Written);
end;

function TCompressionStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := 0;
  raise EStreamError.Create('a compression stream cannot be read');
end;

function TCompressionStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Result := FPosition
  else
    raise EStreamError.Create('a compression stream cannot seek');
end;

end.
