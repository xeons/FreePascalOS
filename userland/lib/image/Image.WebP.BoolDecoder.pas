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
  VP8's boolean entropy decoder (RFC 6386 section 7): each bit comes
  with the probability, out of 256, that it is 0, and splits the range
  in proportion.

  The arithmetic is libwebp's: the range is kept less one, bytes come
  in as they are needed, and a sign bit (probability one half) is taken
  its own way, so every bit comes out as libwebp's does. Reading past
  the end gives zeros; EndOfData tells it happened (one byte past the
  end, as libwebp counts it).
}
unit Image.WebP.BoolDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TBoolDecoder = class
  private
    FData: PByte;
    FPosition: PtrInt;
    FSize: PtrInt;
    FValue: LongWord;
    FRange: LongWord;
    FBits: LongInt;
    FEndOfData: Boolean;
    procedure LoadByte;
  public
    { Decodes Size bytes at Data (which stay the caller's). }
    constructor Create(Data: PByte; Size: PtrInt);
    function ReadBit(Probability: LongInt): LongInt;
    { Count bits (probability one half), most significant first. }
    function ReadValue(Count: LongInt): LongInt;
    { Count bits, then a sign bit. }
    function ReadSignedValue(Count: LongInt): LongInt;
    { Value or -Value by a sign bit. }
    function ReadSigned(Value: LongInt): LongInt;
    property EndOfData: Boolean read FEndOfData;
  end;

implementation

{ The index of the highest bit set in Value (1 to 255). }
function HighestBit(Value: LongWord): LongInt; inline;
begin
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

constructor TBoolDecoder.Create(Data: PByte; Size: PtrInt);
begin
  inherited Create;
  FData := Data;
  FSize := Size;
  FPosition := 0;
  FRange := 255 - 1;
  FValue := 0;
  FBits := -8;
  FEndOfData := False;
  LoadByte;
end;

procedure TBoolDecoder.LoadByte;
begin
  if FPosition < FSize then
  begin
    Inc(FBits, 8);
    FValue := (FValue shl 8) or FData[FPosition];
    Inc(FPosition);
  end
  else if not FEndOfData then
  begin
    FValue := FValue shl 8;
    Inc(FBits, 8);
    FEndOfData := True;
  end
  else
    FBits := 0;
end;

function TBoolDecoder.ReadBit(Probability: LongInt): LongInt;
var
  Range: LongWord;
  Split: LongWord;
  Shift: LongInt;
begin
  Range := FRange;
  if FBits < 0 then
    LoadByte;
  Split := (Range * LongWord(Probability)) shr 8;
  if (FValue shr FBits) > Split then
  begin
    Range := Range - Split;
    FValue := FValue - ((Split + 1) shl FBits);
    Result := 1;
  end
  else
  begin
    Range := Split + 1;
    Result := 0;
  end;
  Shift := 7 xor HighestBit(Range);
  Range := Range shl Shift;
  Dec(FBits, Shift);
  FRange := Range - 1;
end;

function TBoolDecoder.ReadValue(Count: LongInt): LongInt;
begin
  Result := 0;
  while Count > 0 do
  begin
    Dec(Count);
    Result := Result or (ReadBit($80) shl Count);
  end;
end;

function TBoolDecoder.ReadSignedValue(Count: LongInt): LongInt;
begin
  Result := ReadValue(Count);
  if ReadBit($80) <> 0 then
    Result := -Result;
end;

function TBoolDecoder.ReadSigned(Value: LongInt): LongInt;
var
  Split: LongWord;
begin
  if FBits < 0 then
    LoadByte;
  Split := FRange shr 1;
  Dec(FBits);
  if (FValue shr (FBits + 1)) > Split then
  begin
    FRange := (FRange - 1) or 1;
    FValue := FValue - ((Split + 1) shl (FBits + 1));
    Result := -Value;
  end
  else
  begin
    FRange := FRange or 1;
    Result := Value;
  end;
end;

end.
