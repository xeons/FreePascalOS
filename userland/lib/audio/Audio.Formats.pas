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
  Sample formats: the kinds of samples the audio devices take (as in
  Abi.SystemCalls), their sizes, and writing samples in them.

  Values are passed as 32-bit samples (full scale is 2^31) or as floats
  between -1 and 1.
}
unit Audio.Formats;

{$mode objfpc}
{$pointermath on}

interface

const
  SampleUnsigned8 = 1;
  SampleSigned16 = 2;
  SampleSigned24 = 3;
  SampleSigned32 = 4;
  SampleFloat32 = 5;

function BytesPerSample(Kind: LongWord): LongWord;
function SampleKindIsValid(Kind: LongWord): Boolean;
{ The kind called Name (u8, s16, s24, s32, float); 0 if none. }
function SampleKindOfName(Name: PChar): LongWord;
function SampleKindName(Kind: LongWord): PChar;
{ Writes Value (-1 to 1, clipped) as one sample of Kind at Destination. }
procedure EncodeSample(Value: Single; Kind: LongWord; Destination: PByte);
{ Reads one sample of Kind at Source as -1 to 1. }
function DecodeSample(Kind: LongWord; Source: PByte): Single;

implementation

uses
  Runtime.Text;

function BytesPerSample(Kind: LongWord): LongWord;
begin
  case Kind of
    SampleUnsigned8: Result := 1;
    SampleSigned16: Result := 2;
    SampleSigned24: Result := 3;
  else
    Result := 4;
  end;
end;

function SampleKindIsValid(Kind: LongWord): Boolean;
begin
  Result := (Kind >= SampleUnsigned8) and (Kind <= SampleFloat32);
end;

function SampleKindOfName(Name: PChar): LongWord;
begin
  if TextIsEqual(Name, 'u8') then
    Result := SampleUnsigned8
  else if TextIsEqual(Name, 's16') then
    Result := SampleSigned16
  else if TextIsEqual(Name, 's24') then
    Result := SampleSigned24
  else if TextIsEqual(Name, 's32') then
    Result := SampleSigned32
  else if TextIsEqual(Name, 'float') then
    Result := SampleFloat32
  else
    Result := 0;
end;

function SampleKindName(Kind: LongWord): PChar;
begin
  case Kind of
    SampleUnsigned8: Result := 'u8';
    SampleSigned16: Result := 's16';
    SampleSigned24: Result := 's24';
    SampleSigned32: Result := 's32';
    SampleFloat32: Result := 'float';
  else
    Result := '?';
  end;
end;

procedure EncodeSample(Value: Single; Kind: LongWord; Destination: PByte);
var
  Scaled: Int64;
begin
  if Value > 1 then
    Value := 1
  else if Value < -1 then
    Value := -1;
  case Kind of
    SampleUnsigned8:
      Destination[0] := Byte(Round(Value * 127) + 128);
    SampleSigned16:
      PSmallInt(Destination)^ := SmallInt(Round(Value * 32767));
    SampleSigned24:
      begin
        Scaled := Round(Value * 8388607);
        Destination[0] := Byte(Scaled);
        Destination[1] := Byte(Scaled shr 8);
        Destination[2] := Byte(Scaled shr 16);
      end;
    SampleSigned32:
      PLongInt(Destination)^ := LongInt(Round(Value * 2147483647.0));
  else
    PSingle(Destination)^ := Value;
  end;
end;

function DecodeSample(Kind: LongWord; Source: PByte): Single;
begin
  case Kind of
    SampleUnsigned8: Result := (LongInt(Source[0]) - 128) / 128;
    SampleSigned16: Result := PSmallInt(Source)^ / 32768;
    SampleSigned24: Result := LongInt((LongWord(Source[0]) shl 8) or (LongWord(Source[1]) shl 16) or
      (LongWord(Source[2]) shl 24)) / 2147483648.0;
    SampleSigned32: Result := PLongInt(Source)^ / 2147483648.0;
  else
    Result := PSingle(Source)^;
  end;
end;

end.
