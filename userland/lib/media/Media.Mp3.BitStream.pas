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
  Reading MPEG audio's bit fields, most significant bit first. Reading
  past Limit gives zeros (and Position past Limit says so), so broken
  frames are caught by the caller's checks rather than by reading
  outside the buffer.
}
unit Media.Mp3.BitStream;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TMp3BitStream = record
    Data: PByte;
    { In bits. }
    Position, Limit: Integer;
  end;

procedure InitBitStream(out Stream: TMp3BitStream; Data: PByte; ByteCount: Integer);
{ The next Count bits (1 to 24). }
function GetBits(var Stream: TMp3BitStream; Count: Integer): LongWord;

implementation

procedure InitBitStream(out Stream: TMp3BitStream; Data: PByte; ByteCount: Integer);
begin
  Stream.Data := Data;
  Stream.Position := 0;
  Stream.Limit := ByteCount * 8;
end;

function GetBits(var Stream: TMp3BitStream; Count: Integer): LongWord;
var
  Source: PByte;
  Value: QWord;
  Shift, Index, ByteCount: Integer;
begin
  if Stream.Position + Count > Stream.Limit then
  begin
    Stream.Position := Stream.Position + Count;
    Exit(0);
  end;
  Source := Stream.Data + (Stream.Position shr 3);
  Shift := Stream.Position and 7;
  ByteCount := (Shift + Count + 7) shr 3;
  Value := 0;
  for Index := 0 to ByteCount - 1 do
    Value := (Value shl 8) or Source[Index];
  Value := Value shr (ByteCount * 8 - Shift - Count);
  Result := LongWord(Value and ((QWord(1) shl Count) - 1));
  Stream.Position := Stream.Position + Count;
end;

end.
