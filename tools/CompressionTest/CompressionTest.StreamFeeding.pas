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
  Driving a TStreamingDecoder (brotli, zstd) the way HTTP's content
  decoding does: input handed over in pieces, output taken in pieces,
  of fixed or varying sizes; and naming how it ended the way the
  fixture manifest does.
}
unit CompressionTest.StreamFeeding;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.StreamingDecoders,
  CompressionTest.Data;

type
  TStreamEnding = record
    { ok, truncated, trailing, or the failure's name. }
    Outcome: string;
    Error: TCompressionError;
  end;

{ Decodes Input with Decoder (reset first): input pieces of at most
  InputPiece bytes and output pieces of at most OutputPiece, each of
  1 to that many when Varying. Gives up beyond 64 MiB of output. }
function DecodeInPieces(Decoder: TStreamingDecoder; const Input: TBytes; InputPiece: Integer; OutputPiece: Integer;
  Varying: Boolean; out Ending: TStreamEnding): TBytes;

{ The manifest's name of a failure. }
function FailureName(Error: TCompressionError): string;

implementation

const
  LargestOutput = 64 * 1024 * 1024;

function FailureName(Error: TCompressionError): string;
begin
  case Error of
    CompressionErrorChecksumMismatch: Result := 'checksum';
    CompressionErrorDictionaryNeeded: Result := 'dictionary';
    CompressionErrorWindowTooLarge, CompressionErrorInvalidWindowSize: Result := 'window';
    CompressionErrorInvalidFrameHeader: Result := 'frameheader';
    CompressionErrorInvalidPadding: Result := 'padding';
    CompressionErrorLengthMismatch: Result := 'size';
  else
    Result := 'corrupt';
  end;
end;

function PieceSize(Largest: Integer; Varying: Boolean; var Generator: TNumberGenerator): Integer;
begin
  Result := Largest;
  if Varying then
    Result := 1 + Integer(NextNumber(Generator) mod LongWord(Largest));
end;

function DecodeInPieces(Decoder: TStreamingDecoder; const Input: TBytes; InputPiece: Integer; OutputPiece: Integer;
  Varying: Boolean; out Ending: TStreamEnding): TBytes;
var
  Generator: TNumberGenerator;
  Piece: TBytes;
  Used: SizeInt;
  InputPosition: Integer;
  InputCount: Integer;
  OutputCount: Integer;
  Written: SizeInt;
  Outcome: TDecompressResult;
begin
  Result := nil;
  Ending.Outcome := '';
  Ending.Error := CompressionErrorNone;
  StartGenerator(Generator, 777);
  Piece := nil;
  SetLength(Piece, OutputPiece);
  Used := 0;
  InputPosition := 0;
  Decoder.Reset;
  repeat
    OutputCount := PieceSize(OutputPiece, Varying, Generator);
    Outcome := Decoder.Decompress(@Piece[0], OutputCount, Written);
    if Written > 0 then
    begin
      if Used + Written > Length(Result) then
        SetLength(Result, 2 * (Used + Written));
      Move(Piece[0], Result[Used], Written);
      Inc(Used, Written);
    end;
    if Used > LargestOutput then
    begin
      Ending.Outcome := 'too-large';
      Break;
    end;
    case Outcome of
      DecompressFailed:
        begin
          Ending.Error := Decoder.Error;
          Ending.Outcome := FailureName(Decoder.Error);
        end;
      DecompressNeedsInput, DecompressFinished:
        if (Outcome = DecompressFinished) and (Decoder.InputRemaining > 0) then
          { Finished with input left: what follows the data. }
          Ending.Outcome := 'trailing'
        else if InputPosition < Length(Input) then
        begin
          InputCount := PieceSize(InputPiece, Varying, Generator);
          if InputCount > Length(Input) - InputPosition then
            InputCount := Length(Input) - InputPosition;
          Decoder.SetInput(@Input[InputPosition], InputCount);
          Inc(InputPosition, InputCount);
        end
        else if Outcome = DecompressFinished then
          Ending.Outcome := 'ok'
        else
          Ending.Outcome := 'truncated';
    end;
  until Ending.Outcome <> '';
  SetLength(Result, Used);
end;

end.
