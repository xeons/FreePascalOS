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
  The LZMA2 decoder: the chunks the xz format's blocks hold
  (Compression.XzDecoder), into a flat output buffer.

  A chunk starts with a control byte:
    $00         the end of the data
    $01, $02    stored bytes (with and without a dictionary reset): two
                bytes of size - 1 (big-endian), then the bytes
    $80..$FF    LZMA data: bits 0-4 and two bytes are its unpacked size
                - 1, two bytes its packed size - 1; bits 5-6 say what is
                reset first (1 the state, 2 the state and a properties
                byte that follows, 3 those and the dictionary)
  The first chunk resets the dictionary, and the first LZMA chunk after
  a dictionary reset brings properties. Each LZMA chunk is a range coded
  stream of its own that must end exactly at its packed size.
}
unit Compression.Lzma2Decoder;

{$mode objfpc}
{$pointermath on}
{$inline on}

interface

uses
  Compression.DecodeResults,
  Compression.LzmaDecoder;

{ Decodes the LZMA2 data at Input (InputSize bytes at most; InputUsed
  says how many it took, the end byte included) into Output from
  Position up to OutputSize, moving Position on. }
function DecodeLzma2(var Decoder: TLzmaDecoder; Input: PByte; InputSize: SizeUInt; out InputUsed: SizeUInt;
  Output: PByte; OutputSize: SizeUInt; var Position: SizeUInt): TDecodeResult;

implementation

uses
  Compression.RangeDecoder;

const
  ControlEnd = $00;
  ControlStoredWithReset = $01;
  ControlStored = $02;
  ControlLzma = $80;
  ControlLzmaStateReset = $A0;
  ControlLzmaNewProperties = $C0;
  ControlLzmaDictionaryReset = $E0;

type
  TChunkDecoding = record
    Input: PByte;
    InputSize: SizeUInt;
    Cursor: SizeUInt;
    Output: PByte;
    OutputSize: SizeUInt;
    DictionaryStart: SizeUInt;
  end;

function DecodeLzmaData(var Decoder: TLzmaDecoder; var Chunk: TChunkDecoding; Control: Byte;
  var NeedProperties: Boolean; var Position: SizeUInt): TDecodeResult;
var
  HeaderSize: SizeUInt;
  UnpackedSize: SizeUInt;
  PackedSize: SizeUInt;
  Header: PByte;
  Coder: TRangeDecoder;
begin
  HeaderSize := 4;
  if Control >= ControlLzmaNewProperties then
    HeaderSize := 5;
  if Chunk.InputSize - Chunk.Cursor < HeaderSize then
    Exit(DecodeTruncated);
  Header := Chunk.Input + Chunk.Cursor;
  UnpackedSize := (SizeUInt(Control and $1F) shl 16) + (SizeUInt(Header[0]) shl 8) + Header[1] + 1;
  PackedSize := (SizeUInt(Header[2]) shl 8) + Header[3] + 1;
  if Control >= ControlLzmaNewProperties then
  begin
    if not SetLzmaProperties(Decoder, Header[4]) then
      Exit(DecodeCorrupt);
    NeedProperties := False;
  end
  else if NeedProperties then
    Exit(DecodeCorrupt);
  Inc(Chunk.Cursor, HeaderSize);
  if Control >= ControlLzmaStateReset then
    ResetLzmaState(Decoder);

  if UnpackedSize > Chunk.OutputSize - Position then
    Exit(DecodeOutputTooSmall);
  if PackedSize > Chunk.InputSize - Chunk.Cursor then
    Exit(DecodeTruncated);
  if not StartRangeDecoder(Coder, Chunk.Input + Chunk.Cursor, PackedSize) then
    Exit(DecodeCorrupt);
  Result := DecodeLzmaChunk(Decoder, Coder, Chunk.Output, Chunk.DictionaryStart, Position,
    Position + UnpackedSize);
  if Result <> DecodeSucceeded then
    Exit;
  NormalizeRangeDecoder(Coder);
  if not RangeDecoderFinished(Coder) then
    Exit(DecodeCorrupt);
  Inc(Chunk.Cursor, PackedSize);
end;

function CopyStoredData(var Chunk: TChunkDecoding; var Position: SizeUInt): TDecodeResult;
var
  Size: SizeUInt;
begin
  if Chunk.InputSize - Chunk.Cursor < 2 then
    Exit(DecodeTruncated);
  Size := (SizeUInt(Chunk.Input[Chunk.Cursor]) shl 8) + Chunk.Input[Chunk.Cursor + 1] + 1;
  Inc(Chunk.Cursor, 2);
  if Size > Chunk.OutputSize - Position then
    Exit(DecodeOutputTooSmall);
  if Size > Chunk.InputSize - Chunk.Cursor then
    Exit(DecodeTruncated);
  Move(Chunk.Input[Chunk.Cursor], Chunk.Output[Position], Size);
  Inc(Chunk.Cursor, Size);
  Inc(Position, Size);
  Result := DecodeSucceeded;
end;

function DecodeLzma2(var Decoder: TLzmaDecoder; Input: PByte; InputSize: SizeUInt; out InputUsed: SizeUInt;
  Output: PByte; OutputSize: SizeUInt; var Position: SizeUInt): TDecodeResult;
var
  Chunk: TChunkDecoding;
  Control: Byte;
  NeedDictionaryReset: Boolean;
  NeedProperties: Boolean;
begin
  InputUsed := 0;
  Chunk.Input := Input;
  Chunk.InputSize := InputSize;
  Chunk.Cursor := 0;
  Chunk.Output := Output;
  Chunk.OutputSize := OutputSize;
  Chunk.DictionaryStart := Position;
  NeedDictionaryReset := True;
  NeedProperties := True;
  if Position > OutputSize then
    Exit(DecodeOutputTooSmall);
  repeat
    if Chunk.Cursor >= Chunk.InputSize then
      Exit(DecodeTruncated);
    Control := Chunk.Input[Chunk.Cursor];
    Inc(Chunk.Cursor);
    if Control = ControlEnd then
      Break;

    if (Control >= ControlLzmaDictionaryReset) or (Control = ControlStoredWithReset) then
    begin
      NeedDictionaryReset := False;
      NeedProperties := True;
      Chunk.DictionaryStart := Position;
    end
    else if NeedDictionaryReset then
      Exit(DecodeCorrupt);

    if Control >= ControlLzma then
      Result := DecodeLzmaData(Decoder, Chunk, Control, NeedProperties, Position)
    else if Control <= ControlStored then
      Result := CopyStoredData(Chunk, Position)
    else
      Result := DecodeCorrupt;
    if Result <> DecodeSucceeded then
      Exit;
  until False;
  InputUsed := Chunk.Cursor;
  Result := DecodeSucceeded;
end;

end.
