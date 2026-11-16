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
  Decoding the chunked transfer coding (RFC 9112 section 7.1) as bytes
  arrive, in pieces of any size:

    chunk-size [; extensions] CRLF   data CRLF   ...   0 CRLF
    [trailer fields CRLF]   CRLF

  Sizes are hexadecimal (at most 15 digits, so they cannot overflow);
  extensions and trailers are skipped; a lone LF is taken for CRLF.
  Anything else fails the decoder.

  Plain Pascal, checked on the host by tools/WgetTest.
}
unit Wget.Chunks;

{$mode objfpc}
{$pointermath on}

interface

type
  TChunkState = (ChunkSize, ChunkExtension, ChunkSizeLineEnd, ChunkData, ChunkDataCarriageReturn,
    ChunkDataLineFeed, ChunkTrailerLineStart, ChunkTrailerLine, ChunkTrailerLineEnd, ChunkFinalLineEnd,
    ChunkDone, ChunkFailed);

  TChunkDecoder = record
    State: TChunkState;
    Remaining: QWord;
    SizeDigits: Integer;
  end;

procedure BeginChunkDecoder(out Decoder: TChunkDecoder);
{ Takes up to InputLength bytes (Consumed says how many), writing the
  data among them to Output (OutputLength bytes; Output needs room for
  InputLength). Stops at the end of the body. False on malformed input. }
function DecodeChunks(var Decoder: TChunkDecoder; Input: PByte; InputLength: PtrUInt; Output: PByte;
  out OutputLength: PtrUInt; out Consumed: PtrUInt): Boolean;
function ChunkDecoderFinished(constref Decoder: TChunkDecoder): Boolean;

implementation

procedure BeginChunkDecoder(out Decoder: TChunkDecoder);
begin
  Decoder.State := ChunkSize;
  Decoder.Remaining := 0;
  Decoder.SizeDigits := 0;
end;

function ChunkDecoderFinished(constref Decoder: TChunkDecoder): Boolean;
begin
  Result := Decoder.State = ChunkDone;
end;

function HexValue(Value: Byte): Integer;
begin
  case Chr(Value) of
    '0'..'9': Result := Value - Ord('0');
    'a'..'f': Result := Value - Ord('a') + 10;
    'A'..'F': Result := Value - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

{ After a size line: data, or the end of the chunks. }
procedure SizeLineEnded(var Decoder: TChunkDecoder);
begin
  if Decoder.Remaining = 0 then
    Decoder.State := ChunkTrailerLineStart
  else
    Decoder.State := ChunkData;
end;

function DecodeChunks(var Decoder: TChunkDecoder; Input: PByte; InputLength: PtrUInt; Output: PByte;
  out OutputLength: PtrUInt; out Consumed: PtrUInt): Boolean;
var
  Position: PtrUInt;
  Value: Byte;
  Digit: Integer;
  Take: PtrUInt;
begin
  OutputLength := 0;
  Position := 0;
  while (Position < InputLength) and (Decoder.State <> ChunkDone) and (Decoder.State <> ChunkFailed) do
  begin
    Value := Input[Position];
    case Decoder.State of
      ChunkSize:
        begin
          Digit := HexValue(Value);
          if Digit >= 0 then
          begin
            if Decoder.SizeDigits >= 15 then
              Decoder.State := ChunkFailed
            else
            begin
              Decoder.Remaining := Decoder.Remaining * 16 + QWord(Digit);
              Inc(Decoder.SizeDigits);
            end;
          end
          else if Decoder.SizeDigits = 0 then
            Decoder.State := ChunkFailed
          else if (Value = Ord(';')) or (Value = Ord(' ')) or (Value = 9) then
            Decoder.State := ChunkExtension
          else if Value = 13 then
            Decoder.State := ChunkSizeLineEnd
          else if Value = 10 then
            SizeLineEnded(Decoder)
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
      ChunkExtension:
        begin
          if Value = 13 then
            Decoder.State := ChunkSizeLineEnd
          else if Value = 10 then
            SizeLineEnded(Decoder);
          Inc(Position);
        end;
      ChunkSizeLineEnd:
        begin
          if Value = 10 then
            SizeLineEnded(Decoder)
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
      ChunkData:
        begin
          Take := InputLength - Position;
          if Take > Decoder.Remaining then
            Take := Decoder.Remaining;
          Move(Input[Position], Output[OutputLength], Take);
          OutputLength := OutputLength + Take;
          Position := Position + Take;
          Decoder.Remaining := Decoder.Remaining - Take;
          if Decoder.Remaining = 0 then
            Decoder.State := ChunkDataCarriageReturn;
        end;
      ChunkDataCarriageReturn:
        begin
          if Value = 13 then
            Decoder.State := ChunkDataLineFeed
          else if Value = 10 then
          begin
            Decoder.State := ChunkSize;
            Decoder.SizeDigits := 0;
          end
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
      ChunkDataLineFeed:
        begin
          if Value = 10 then
          begin
            Decoder.State := ChunkSize;
            Decoder.SizeDigits := 0;
          end
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
      ChunkTrailerLineStart:
        begin
          { An empty line ends the body; anything else is a trailer. }
          if Value = 13 then
            Decoder.State := ChunkFinalLineEnd
          else if Value = 10 then
            Decoder.State := ChunkDone
          else
            Decoder.State := ChunkTrailerLine;
          Inc(Position);
        end;
      ChunkTrailerLine:
        begin
          if Value = 13 then
            Decoder.State := ChunkTrailerLineEnd
          else if Value = 10 then
            Decoder.State := ChunkTrailerLineStart;
          Inc(Position);
        end;
      ChunkTrailerLineEnd:
        begin
          if Value = 10 then
            Decoder.State := ChunkTrailerLineStart
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
      ChunkFinalLineEnd:
        begin
          if Value = 10 then
            Decoder.State := ChunkDone
          else
            Decoder.State := ChunkFailed;
          Inc(Position);
        end;
    end;
  end;
  Consumed := Position;
  Result := Decoder.State <> ChunkFailed;
end;

end.
