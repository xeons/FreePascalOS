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
  The errors of the compression library. The streaming classes report
  them as a code (TInflater.Error) and stop; the convenience functions
  and the stream adapters raise ECompressionError carrying the code.
  CompressionErrorMessage says what a code means.
}
unit Compression.Errors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TCompressionError = (
    CompressionErrorNone,
    { The deflate format (RFC 1951). }
    CompressionErrorInvalidBlockType,
    CompressionErrorStoredLengthMismatch,
    CompressionErrorTooManyCodes,
    CompressionErrorInvalidCodeLengths,
    CompressionErrorInvalidRepeat,
    CompressionErrorMissingEndOfBlock,
    CompressionErrorInvalidSymbol,
    CompressionErrorDistanceTooFar,
    CompressionErrorTruncated,
    { The zlib format (RFC 1950). }
    CompressionErrorInvalidZlibHeader,
    CompressionErrorUnsupportedMethod,
    CompressionErrorPresetDictionary,
    CompressionErrorAdlerMismatch,
    { The gzip format (RFC 1952). }
    CompressionErrorInvalidGzipHeader,
    CompressionErrorHeaderCrcMismatch,
    CompressionErrorCrcMismatch,
    CompressionErrorLengthMismatch,
    CompressionErrorTrailingData,
    { Use of the library. }
    CompressionErrorInvalidArgument,
    CompressionErrorOutputLimit,
    { Preset dictionaries (zlib). }
    CompressionErrorDictionaryMismatch
  );

  { Raised by the convenience layer: the code and its message. }
  ECompressionError = class(Exception)
  private
    FCode: TCompressionError;
  public
    constructor CreateCode(Code: TCompressionError);
    property Code: TCompressionError read FCode;
  end;

function CompressionErrorMessage(Error: TCompressionError): string;

implementation

constructor ECompressionError.CreateCode(Code: TCompressionError);
begin
  inherited Create(CompressionErrorMessage(Code));
  FCode := Code;
end;

function CompressionErrorMessage(Error: TCompressionError): string;
begin
  case Error of
    CompressionErrorNone: Result := 'success';
    CompressionErrorInvalidBlockType: Result := 'invalid block type';
    CompressionErrorStoredLengthMismatch: Result := 'stored block length does not match its complement';
    CompressionErrorTooManyCodes: Result := 'too many length or distance codes';
    CompressionErrorInvalidCodeLengths: Result := 'invalid Huffman code lengths';
    CompressionErrorInvalidRepeat: Result := 'invalid code length repeat';
    CompressionErrorMissingEndOfBlock: Result := 'the end of block code is missing';
    CompressionErrorInvalidSymbol: Result := 'invalid literal, length or distance code';
    CompressionErrorDistanceTooFar: Result := 'distance too far back';
    CompressionErrorTruncated: Result := 'unexpected end of compressed data';
    CompressionErrorInvalidZlibHeader: Result := 'invalid zlib header';
    CompressionErrorUnsupportedMethod: Result := 'unsupported compression method';
    CompressionErrorPresetDictionary: Result := 'a preset dictionary is needed';
    CompressionErrorAdlerMismatch: Result := 'Adler-32 checksum mismatch';
    CompressionErrorInvalidGzipHeader: Result := 'not in gzip format';
    CompressionErrorHeaderCrcMismatch: Result := 'gzip header checksum mismatch';
    CompressionErrorCrcMismatch: Result := 'CRC-32 checksum mismatch';
    CompressionErrorLengthMismatch: Result := 'uncompressed length mismatch';
    CompressionErrorTrailingData: Result := 'trailing data after the compressed data';
    CompressionErrorInvalidArgument: Result := 'invalid argument';
    CompressionErrorOutputLimit: Result := 'the decompressed data is larger than allowed';
    CompressionErrorDictionaryMismatch: Result := 'the preset dictionary is not the one the data needs';
  else
    Result := 'unknown error';
  end;
end;

end.
