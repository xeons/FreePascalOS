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
  Bit rotation, byte order and wiping helpers shared by the algorithms.
}
unit Crypto.Bits;

{$mode objfpc}
{$pointermath on}

interface

function RotateLeft32(Value: LongWord; Count: Integer): LongWord; inline;
function RotateRight32(Value: LongWord; Count: Integer): LongWord; inline;
function RotateRight64(Value: QWord; Count: Integer): QWord; inline;

function LoadLittleEndian32(Bytes: PByte): LongWord;
function LoadBigEndian32(Bytes: PByte): LongWord;
function LoadLittleEndian64(Bytes: PByte): QWord;
function LoadBigEndian64(Bytes: PByte): QWord;
procedure StoreLittleEndian32(Bytes: PByte; Value: LongWord);
procedure StoreBigEndian32(Bytes: PByte; Value: LongWord);
procedure StoreLittleEndian64(Bytes: PByte; Value: QWord);
procedure StoreBigEndian64(Bytes: PByte; Value: QWord);

{ Overwrites secrets (keys, cipher states) with zeros. }
procedure WipeMemory(Destination: Pointer; ByteCount: PtrUInt);

{ Compares without stopping at the first difference, so the time taken
  does not reveal where two secrets differ. }
function ConstantTimeEqual(First, Second: PByte; ByteCount: PtrUInt): Boolean;

implementation

function RotateLeft32(Value: LongWord; Count: Integer): LongWord; inline;
begin
  Result := (Value shl Count) or (Value shr (32 - Count));
end;

function RotateRight32(Value: LongWord; Count: Integer): LongWord; inline;
begin
  Result := (Value shr Count) or (Value shl (32 - Count));
end;

function RotateRight64(Value: QWord; Count: Integer): QWord; inline;
begin
  Result := (Value shr Count) or (Value shl (64 - Count));
end;

function LoadLittleEndian32(Bytes: PByte): LongWord;
begin
  Result := LongWord(Bytes[0]) or (LongWord(Bytes[1]) shl 8) or
    (LongWord(Bytes[2]) shl 16) or (LongWord(Bytes[3]) shl 24);
end;

function LoadBigEndian32(Bytes: PByte): LongWord;
begin
  Result := (LongWord(Bytes[0]) shl 24) or (LongWord(Bytes[1]) shl 16) or
    (LongWord(Bytes[2]) shl 8) or LongWord(Bytes[3]);
end;

function LoadLittleEndian64(Bytes: PByte): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 7 downto 0 do
    Result := (Result shl 8) or Bytes[Index];
end;

function LoadBigEndian64(Bytes: PByte): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to 7 do
    Result := (Result shl 8) or Bytes[Index];
end;

procedure StoreLittleEndian32(Bytes: PByte; Value: LongWord);
begin
  Bytes[0] := Byte(Value);
  Bytes[1] := Byte(Value shr 8);
  Bytes[2] := Byte(Value shr 16);
  Bytes[3] := Byte(Value shr 24);
end;

procedure StoreBigEndian32(Bytes: PByte; Value: LongWord);
begin
  Bytes[0] := Byte(Value shr 24);
  Bytes[1] := Byte(Value shr 16);
  Bytes[2] := Byte(Value shr 8);
  Bytes[3] := Byte(Value);
end;

procedure StoreLittleEndian64(Bytes: PByte; Value: QWord);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    Bytes[Index] := Byte(Value shr (8 * Index));
end;

procedure StoreBigEndian64(Bytes: PByte; Value: QWord);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    Bytes[Index] := Byte(Value shr (8 * (7 - Index)));
end;

procedure WipeMemory(Destination: Pointer; ByteCount: PtrUInt);
var
  Bytes: PByte;
  Index: PtrUInt;
begin
  Bytes := PByte(Destination);
  Index := 0;
  while Index < ByteCount do
  begin
    Bytes[Index] := 0;
    Inc(Index);
  end;
end;

function ConstantTimeEqual(First, Second: PByte; ByteCount: PtrUInt): Boolean;
var
  Difference: Byte;
  Index: PtrUInt;
begin
  Difference := 0;
  Index := 0;
  while Index < ByteCount do
  begin
    Difference := Difference or (First[Index] xor Second[Index]);
    Inc(Index);
  end;
  Result := Difference = 0;
end;

end.
