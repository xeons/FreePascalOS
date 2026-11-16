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
  The zlib wrapper (RFC 1950): a two byte header (method deflate, the
  window size, a level hint, a check making it a multiple of 31) before
  the deflate data, and the Adler-32 of the uncompressed data after it,
  most significant byte first.
}
unit Compression.ZlibFormat;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Errors;

const
  ZlibHeaderSize = 2;
  ZlibTrailerSize = 4;

{ Checks a zlib header. }
function CheckZlibHeader(MethodByte: Byte; FlagsByte: Byte): TCompressionError;
{ The header for data compressed at Level (0 to 9). }
procedure MakeZlibHeader(Level: Integer; out MethodByte: Byte; out FlagsByte: Byte);

implementation

const
  DeflateMethod = 8;
  LargestWindowInfo = 7;
  PresetDictionaryFlag = $20;

function CheckZlibHeader(MethodByte: Byte; FlagsByte: Byte): TCompressionError;
begin
  if ((Word(MethodByte) shl 8) or FlagsByte) mod 31 <> 0 then
    Result := CompressionErrorInvalidZlibHeader
  else if (MethodByte and $0F) <> DeflateMethod then
    Result := CompressionErrorUnsupportedMethod
  else if (MethodByte shr 4) > LargestWindowInfo then
    Result := CompressionErrorInvalidZlibHeader
  else if (FlagsByte and PresetDictionaryFlag) <> 0 then
    Result := CompressionErrorPresetDictionary
  else
    Result := CompressionErrorNone;
end;

procedure MakeZlibHeader(Level: Integer; out MethodByte: Byte; out FlagsByte: Byte);
var
  LevelHint: Integer;
  Remainder: Integer;
begin
  MethodByte := (LargestWindowInfo shl 4) or DeflateMethod;
  if Level <= 1 then
    LevelHint := 0
  else if Level <= 5 then
    LevelHint := 1
  else if Level = 6 then
    LevelHint := 2
  else
    LevelHint := 3;
  FlagsByte := LevelHint shl 6;
  Remainder := ((Word(MethodByte) shl 8) or FlagsByte) mod 31;
  if Remainder <> 0 then
    FlagsByte := FlagsByte + (31 - Remainder);
end;

end.
