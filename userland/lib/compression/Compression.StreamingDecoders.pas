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
  TStreamingDecoder: what the streaming decompressors have in common, so
  a caller (HTTP's content decoding) can drive any of them the same way:

    Decoder.SetInput(@Chunk[0], Length(Chunk));
    repeat
      Outcome := Decoder.Decompress(@Buffer[0], Length(Buffer), Written);
      ... use Written bytes of Buffer ...
    until Outcome <> DecompressOutputFull;

  The contract is TInflater's: Decompress fills Output as far as it can
  and says why it stopped (DecompressNeedsInput: all input used, give
  the next piece; DecompressOutputFull: call again with more room;
  DecompressFinished; DecompressFailed: Error says why). The input must
  stay valid until it has been used up or the data has finished; a
  decoder that must look further ahead than the piece it was given keeps
  the few bytes it needs itself.

  The decoders: TInflatingDecoder (deflate, zlib, gzip through
  TInflater), TBrotliDecoder and TZstdDecoder.
}
unit Compression.StreamingDecoders;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Errors;

type
  TDecompressResult = (DecompressNeedsInput, DecompressOutputFull, DecompressFinished, DecompressFailed);

  TStreamingDecoder = class
  protected
    FError: TCompressionError;
    FTotalOutput: Int64;
    function GetFinished: Boolean; virtual; abstract;
    function GetInputRemaining: SizeInt; virtual; abstract;
  public
    { Back to the start of a new stream. }
    procedure Reset; virtual; abstract;
    procedure SetInput(Data: Pointer; Count: SizeInt); virtual; abstract;
    function Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult;
      virtual; abstract;

    { The data has ended (more input may still start another gzip member
      or zstd frame). }
    property Finished: Boolean read GetFinished;
    { Input not used yet (after the end of the data: what follows it). }
    property InputRemaining: SizeInt read GetInputRemaining;
    property Error: TCompressionError read FError;
    property TotalOutput: Int64 read FTotalOutput;
  end;

implementation

end.
