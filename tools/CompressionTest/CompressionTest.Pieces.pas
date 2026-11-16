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
  Driving TInflater and TDeflater the way a streaming caller does:
  input handed over in pieces, output taken in pieces, of fixed or
  varying sizes.
}
unit CompressionTest.Pieces;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.Formats,
  Compression.Inflater,
  Compression.Deflater,
  CompressionTest.Data;

type
  TPieceSizes = record
    { The largest input and output pieces; with Varying, each piece is
      1 to this many bytes, chosen by a generator. }
    InputPiece: Integer;
    OutputPiece: Integer;
    Varying: Boolean;
  end;

function Pieces(InputPiece: Integer; OutputPiece: Integer; Varying: Boolean): TPieceSizes;

{ Decompresses Compressed piece by piece; Error is what went wrong
  (CompressionErrorTruncated if the data stops early,
  CompressionErrorTrailingData if anything follows it). }
function DecompressInPieces(const Compressed: TBytes; Format: TCompressionFormat; const Sizes: TPieceSizes;
  out Error: TCompressionError): TBytes;
function CompressInPieces(const Data: TBytes; Format: TCompressionFormat; Level: Integer;
  const Sizes: TPieceSizes): TBytes;

implementation

function Pieces(InputPiece: Integer; OutputPiece: Integer; Varying: Boolean): TPieceSizes;
begin
  Result.InputPiece := InputPiece;
  Result.OutputPiece := OutputPiece;
  Result.Varying := Varying;
end;

function PieceSize(Largest: Integer; Varying: Boolean; var Generator: TNumberGenerator): Integer;
begin
  Result := Largest;
  if Varying then
    Result := 1 + Integer(NextNumber(Generator) mod LongWord(Largest));
end;

procedure AppendOutput(var Output: TBytes; var Used: Integer; Piece: PByte; Count: SizeInt);
begin
  if Count <= 0 then
    Exit;
  if Used + Count > Length(Output) then
    SetLength(Output, 2 * (Used + Count));
  Move(Piece^, Output[Used], Count);
  Inc(Used, Count);
end;

function DecompressInPieces(const Compressed: TBytes; Format: TCompressionFormat; const Sizes: TPieceSizes;
  out Error: TCompressionError): TBytes;
var
  Inflater: TInflater;
  Generator: TNumberGenerator;
  Piece: TBytes;
  Used: Integer;
  InputPosition: Integer;
  InputCount: Integer;
  OutputCount: Integer;
  Written: SizeInt;
  Outcome: TInflateResult;
  Done: Boolean;
begin
  Result := nil;
  Error := CompressionErrorNone;
  StartGenerator(Generator, 12345);
  Piece := nil;
  SetLength(Piece, Sizes.OutputPiece);
  Used := 0;
  InputPosition := 0;
  Inflater := TInflater.Create(Format);
  try
    Done := False;
    repeat
      OutputCount := PieceSize(Sizes.OutputPiece, Sizes.Varying, Generator);
      Outcome := Inflater.Decompress(@Piece[0], OutputCount, Written);
      AppendOutput(Result, Used, @Piece[0], Written);
      case Outcome of
        InflateNeedsInput, InflateFinished:
          if (Outcome = InflateFinished) and (Inflater.InputRemaining > 0) then
          begin
            Error := CompressionErrorTrailingData;
            Done := True;
          end
          else if InputPosition < Length(Compressed) then
          begin
            InputCount := PieceSize(Sizes.InputPiece, Sizes.Varying, Generator);
            if InputCount > Length(Compressed) - InputPosition then
              InputCount := Length(Compressed) - InputPosition;
            Inflater.SetInput(@Compressed[InputPosition], InputCount);
            Inc(InputPosition, InputCount);
          end
          else
          begin
            if Outcome = InflateNeedsInput then
              Error := CompressionErrorTruncated;
            Done := True;
          end;
        InflateFailed:
          begin
            Error := Inflater.Error;
            Done := True;
          end;
      end;
    until Done;
  finally
    Inflater.Free;
  end;
  SetLength(Result, Used);
end;

function CompressInPieces(const Data: TBytes; Format: TCompressionFormat; Level: Integer;
  const Sizes: TPieceSizes): TBytes;
var
  Deflater: TDeflater;
  Generator: TNumberGenerator;
  Piece: TBytes;
  Used: Integer;
  InputPosition: Integer;
  InputCount: Integer;
  OutputCount: Integer;
  Written: SizeInt;
  Outcome: TDeflateResult;
begin
  Result := nil;
  StartGenerator(Generator, 54321);
  Piece := nil;
  SetLength(Piece, Sizes.OutputPiece);
  Used := 0;
  InputPosition := 0;
  Deflater := TDeflater.Create(Format, Level);
  try
    repeat
      OutputCount := PieceSize(Sizes.OutputPiece, Sizes.Varying, Generator);
      Outcome := Deflater.Compress(@Piece[0], OutputCount, Written, InputPosition >= Length(Data));
      AppendOutput(Result, Used, @Piece[0], Written);
      if (Outcome = DeflateNeedsInput) and (InputPosition < Length(Data)) then
      begin
        InputCount := PieceSize(Sizes.InputPiece, Sizes.Varying, Generator);
        if InputCount > Length(Data) - InputPosition then
          InputCount := Length(Data) - InputPosition;
        Deflater.SetInput(@Data[InputPosition], InputCount);
        Inc(InputPosition, InputCount);
      end;
    until Outcome = DeflateFinished;
  finally
    Deflater.Free;
  end;
  SetLength(Result, Used);
end;

end.
