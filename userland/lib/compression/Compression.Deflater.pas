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
  TDeflater: compression to raw deflate, zlib or gzip data, fed and
  taken in pieces of any size.

    Deflater := TDeflater.Create(FormatGzip, CompressionLevelBest);
    Deflater.SetInput(@Data[0], Length(Data));
    repeat
      Outcome := Deflater.Compress(@Buffer[0], Length(Buffer), Written, True);
      ... write Written bytes of Buffer ...
    until Outcome = DeflateFinished;

  Compress takes all the input it can and fills Output as far as it
  can: DeflateNeedsInput (all input taken; SetInput the next piece, or
  call with Finish once there is no more), DeflateOutputFull (call
  again with more room) or DeflateFinished (everything, the trailer
  included, is out). The input must stay valid until it has been taken
  (InputRemaining is 0).

  Set GzipHeader before the first Compress to give a gzip member a file
  name, time or comment.
}
unit Compression.Deflater;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Compression.Formats,
  Compression.Checksums,
  Compression.ZlibFormat,
  Compression.GzipFormat,
  Compression.BitWriter,
  Compression.DeflateEngine;

type
  TDeflateResult = (DeflateNeedsInput, DeflateOutputFull, DeflateFinished);

  TDeflaterStage = (DeflaterStart, DeflaterBody, DeflaterDone);

  TDeflater = class
  private
    FFormat: TCompressionFormat;
    FLevel: Integer;
    FWriter: TBitWriter;
    FEngine: TDeflateEngine;
    FStage: TDeflaterStage;
    FInput: PByte;
    FInputRemaining: SizeInt;
    FChecksum: LongWord;
    FTotalInput: Int64;
    FTotalOutput: Int64;
    FGzipHeader: TGzipHeader;
    procedure WriteHeader;
    procedure WriteTrailer;
    procedure TakeInput;
  public
    { FormatAutomatic compresses as zlib. Level is 0 to 9. }
    constructor Create(Format: TCompressionFormat = FormatZlib; Level: Integer = CompressionLevelDefault);
    destructor Destroy; override;
    { Ready for a new stream, with the same format and level. }
    procedure Reset;
    procedure SetInput(Data: Pointer; Count: SizeInt);
    function Compress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt; Finish: Boolean): TDeflateResult;

    property Format: TCompressionFormat read FFormat;
    property Level: Integer read FLevel;
    property InputRemaining: SizeInt read FInputRemaining;
    property TotalInput: Int64 read FTotalInput;
    property TotalOutput: Int64 read FTotalOutput;
    property GzipHeader: TGzipHeader read FGzipHeader write FGzipHeader;
  end;

implementation

constructor TDeflater.Create(Format: TCompressionFormat; Level: Integer);
begin
  inherited Create;
  if Format = FormatAutomatic then
    Format := FormatZlib;
  FFormat := Format;
  if Level < CompressionLevelStore then
    Level := CompressionLevelStore;
  if Level > CompressionLevelBest then
    Level := CompressionLevelBest;
  FLevel := Level;
  FGzipHeader := DefaultGzipHeader(Level);
  FWriter := TBitWriter.Create;
  FEngine := TDeflateEngine.Create(Level, FWriter);
  Reset;
end;

destructor TDeflater.Destroy;
begin
  FEngine.Free;
  FWriter.Free;
  inherited Destroy;
end;

procedure TDeflater.Reset;
begin
  FWriter.Reset;
  FEngine.Reset;
  FStage := DeflaterStart;
  FInput := nil;
  FInputRemaining := 0;
  FTotalInput := 0;
  FTotalOutput := 0;
  if FFormat = FormatGzip then
    FChecksum := Crc32Initial
  else
    FChecksum := Adler32Initial;
end;

procedure TDeflater.SetInput(Data: Pointer; Count: SizeInt);
begin
  FInput := Data;
  FInputRemaining := Count;
  if FInputRemaining < 0 then
    FInputRemaining := 0;
end;

procedure TDeflater.WriteHeader;
var
  MethodByte: Byte;
  FlagsByte: Byte;
  Header: TBytes;
begin
  case FFormat of
    FormatZlib:
      begin
        MakeZlibHeader(FLevel, MethodByte, FlagsByte);
        FWriter.WriteBits(MethodByte, 8);
        FWriter.WriteBits(FlagsByte, 8);
      end;
    FormatGzip:
      begin
        Header := BuildGzipHeader(FGzipHeader);
        FWriter.WriteBytes(PByte(Header), Length(Header));
      end;
  end;
end;

procedure TDeflater.WriteTrailer;
begin
  FWriter.AlignToByte;
  case FFormat of
    FormatZlib:
      begin
        FWriter.WriteBits(FChecksum shr 24, 8);
        FWriter.WriteBits((FChecksum shr 16) and $FF, 8);
        FWriter.WriteBits((FChecksum shr 8) and $FF, 8);
        FWriter.WriteBits(FChecksum and $FF, 8);
      end;
    FormatGzip:
      begin
        FWriter.WriteBits(FChecksum, 32);
        FWriter.WriteBits(LongWord(FTotalInput and $FFFFFFFF), 32);
      end;
  end;
  FWriter.AlignToByte;
end;

procedure TDeflater.TakeInput;
var
  Count: SizeInt;
begin
  Count := FEngine.Consume(FInput, FInputRemaining);
  if Count > 0 then
  begin
    case FFormat of
      FormatZlib: FChecksum := Adler32(FChecksum, FInput, Count);
      FormatGzip: FChecksum := Crc32(FChecksum, FInput, Count);
    end;
    Inc(FInput, Count);
    Dec(FInputRemaining, Count);
    Inc(FTotalInput, Count);
  end;
  FEngine.Process(False);
end;

function TDeflater.Compress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt; Finish: Boolean): TDeflateResult;
var
  Count: SizeInt;
begin
  Written := 0;
  if Capacity < 0 then
    Capacity := 0;
  repeat
    Count := FWriter.Take(PByte(Output) + Written, Capacity - Written);
    Inc(Written, Count);
    Inc(FTotalOutput, Count);
    if FWriter.Pending > 0 then
    begin
      Result := DeflateOutputFull;
      Exit;
    end;
    case FStage of
      DeflaterStart:
        begin
          WriteHeader;
          FStage := DeflaterBody;
        end;
      DeflaterBody:
        if FInputRemaining > 0 then
          TakeInput
        else if not Finish then
        begin
          Result := DeflateNeedsInput;
          Exit;
        end
        else
        begin
          FEngine.Finish;
          WriteTrailer;
          FStage := DeflaterDone;
        end;
    else
      begin
        Result := DeflateFinished;
        Exit;
      end;
    end;
  until False;
end;

end.
