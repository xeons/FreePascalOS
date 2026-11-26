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
  The bit reading descriptors of the AV1 specification (section 4.10):
  f(n), uvlc(), le(n), leb128(), su(n) and ns(n), most significant bit
  first, over a block of bytes. Reading past the end raises EAv1Error.
}
unit Av1.BitReader;

{$mode objfpc}
{$H+}

interface

uses
  Av1.Common;

type
  TBitReader = record
    Data: PByte;
    Size: Integer;          { bytes }
    Position: Int64;        { bits from Data }
  end;

procedure InitializeBitReader(out Reader: TBitReader; Data: PByte; Size: Integer);
function ReadBits(var Reader: TBitReader; Count: Integer): LongWord;
function ReadBit(var Reader: TBitReader): Integer; inline;
function ReadFlag(var Reader: TBitReader): Boolean; inline;
function ReadUvlc(var Reader: TBitReader): LongWord;
function ReadLittleEndian(var Reader: TBitReader; Bytes: Integer): LongWord;
function ReadLeb128(var Reader: TBitReader): QWord;
function ReadSigned(var Reader: TBitReader; Bits: Integer): Integer;
function ReadNonSymmetric(var Reader: TBitReader; Count: LongWord): LongWord;
procedure AlignToByte(var Reader: TBitReader);
function BytePosition(const Reader: TBitReader): Integer;

implementation

procedure InitializeBitReader(out Reader: TBitReader; Data: PByte; Size: Integer);
begin
  Reader.Data := Data;
  Reader.Size := Size;
  Reader.Position := 0;
end;

function ReadBit(var Reader: TBitReader): Integer;
var
  ByteIndex: Int64;
begin
  ByteIndex := Reader.Position shr 3;
  if ByteIndex >= Reader.Size then
    RaiseAv1Error('header cut short');
  Result := (Reader.Data[ByteIndex] shr (7 - (Reader.Position and 7))) and 1;
  Inc(Reader.Position);
end;

function ReadFlag(var Reader: TBitReader): Boolean;
begin
  Result := ReadBit(Reader) <> 0;
end;

function ReadBits(var Reader: TBitReader; Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Count do
    Result := (Result shl 1) or LongWord(ReadBit(Reader));
end;

function ReadUvlc(var Reader: TBitReader): LongWord;
var
  LeadingZeros: Integer;
begin
  LeadingZeros := 0;
  while ReadBit(Reader) = 0 do
    Inc(LeadingZeros);
  if LeadingZeros >= 32 then
    Exit(High(LongWord));
  Result := ReadBits(Reader, LeadingZeros) + ((LongWord(1) shl LeadingZeros) - 1);
end;

function ReadLittleEndian(var Reader: TBitReader; Bytes: Integer): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Bytes - 1 do
    Result := Result or (ReadBits(Reader, 8) shl (Index * 8));
end;

function ReadLeb128(var Reader: TBitReader): QWord;
var
  Index: Integer;
  Value: LongWord;
begin
  Result := 0;
  for Index := 0 to 7 do
  begin
    Value := ReadBits(Reader, 8);
    Result := Result or (QWord(Value and $7F) shl (Index * 7));
    if (Value and $80) = 0 then
      Break;
  end;
end;

function ReadSigned(var Reader: TBitReader; Bits: Integer): Integer;
var
  Value, SignMask: Int64;
begin
  Value := ReadBits(Reader, Bits);
  SignMask := Int64(1) shl (Bits - 1);
  if (Value and SignMask) <> 0 then
    Value := Value - 2 * SignMask;
  Result := Value;
end;

function ReadNonSymmetric(var Reader: TBitReader; Count: LongWord): LongWord;
var
  Width: Integer;
  Threshold, Value: LongWord;
begin
  Width := FloorLog2(Count) + 1;
  Threshold := (LongWord(1) shl Width) - Count;
  Value := ReadBits(Reader, Width - 1);
  if Value < Threshold then
    Exit(Value);
  Result := (Value shl 1) - Threshold + LongWord(ReadBit(Reader));
end;

procedure AlignToByte(var Reader: TBitReader);
begin
  Reader.Position := (Reader.Position + 7) and not Int64(7);
end;

function BytePosition(const Reader: TBitReader): Integer;
begin
  Result := Reader.Position shr 3;
end;

end.
