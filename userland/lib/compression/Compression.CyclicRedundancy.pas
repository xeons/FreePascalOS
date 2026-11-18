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
  The cyclic redundancy checks of the compressed formats:

    CRC-32 (IEEE 802.3; gzip, png, xz), eight bytes a step through eight
      tables ("slicing by eight")
    CRC-64 (ECMA-182, reflected; xz), a byte a step

  Both take the value of a previous call and return the finished value,
  so data can be fed in pieces: start with Crc32Initial or Crc64Initial.

  Plain Pascal without the runtime library's heap or strings, so the
  kernel compiles it too (Drivers.RamDisk unpacks its image with it).
}
unit Compression.CyclicRedundancy;

{$mode objfpc}
{$pointermath on}

interface

const
  Crc32Initial = LongWord(0);
  Crc64Initial = QWord(0);

function Crc32(Crc: LongWord; Data: PByte; Count: SizeInt): LongWord;
function Crc64(Crc: QWord; Data: PByte; Count: SizeInt): QWord;

implementation

const
  Crc32Polynomial = LongWord($EDB88320);
  Crc64Polynomial = QWord($C96C5795D7870F42);

var
  Crc32TablesReady: Boolean = False;
  Crc32Tables: array[0..7, 0..255] of LongWord;
  Crc64TableReady: Boolean = False;
  Crc64Table: array[0..255] of QWord;

procedure PrepareCrc32Tables;
var
  Index: Integer;
  Bit: Integer;
  Slice: Integer;
  Value: LongWord;
begin
  for Index := 0 to 255 do
  begin
    Value := Index;
    for Bit := 1 to 8 do
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor Crc32Polynomial
      else
        Value := Value shr 1;
    Crc32Tables[0, Index] := Value;
  end;
  for Slice := 1 to 7 do
    for Index := 0 to 255 do
    begin
      Value := Crc32Tables[Slice - 1, Index];
      Crc32Tables[Slice, Index] := (Value shr 8) xor Crc32Tables[0, Value and $FF];
    end;
  Crc32TablesReady := True;
end;

procedure PrepareCrc64Table;
var
  Index: Integer;
  Bit: Integer;
  Value: QWord;
begin
  for Index := 0 to 255 do
  begin
    Value := Index;
    for Bit := 1 to 8 do
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor Crc64Polynomial
      else
        Value := Value shr 1;
    Crc64Table[Index] := Value;
  end;
  Crc64TableReady := True;
end;

function Crc32(Crc: LongWord; Data: PByte; Count: SizeInt): LongWord;
var
  Value: LongWord;
  LowWord: LongWord;
  HighWord: LongWord;
begin
  if not Crc32TablesReady then
    PrepareCrc32Tables;
  Value := not Crc;
  while Count >= 8 do
  begin
    LowWord := PLongWord(Data)^ xor Value;
    HighWord := PLongWord(Data + 4)^;
    Value := Crc32Tables[7, LowWord and $FF] xor
      Crc32Tables[6, (LowWord shr 8) and $FF] xor
      Crc32Tables[5, (LowWord shr 16) and $FF] xor
      Crc32Tables[4, LowWord shr 24] xor
      Crc32Tables[3, HighWord and $FF] xor
      Crc32Tables[2, (HighWord shr 8) and $FF] xor
      Crc32Tables[1, (HighWord shr 16) and $FF] xor
      Crc32Tables[0, HighWord shr 24];
    Inc(Data, 8);
    Dec(Count, 8);
  end;
  while Count > 0 do
  begin
    Value := Crc32Tables[0, (Value xor Data^) and $FF] xor (Value shr 8);
    Inc(Data);
    Dec(Count);
  end;
  Result := not Value;
end;

function Crc64(Crc: QWord; Data: PByte; Count: SizeInt): QWord;
var
  Value: QWord;
begin
  if not Crc64TableReady then
    PrepareCrc64Table;
  Value := not Crc;
  while Count > 0 do
  begin
    Value := Crc64Table[(Value xor Data^) and $FF] xor (Value shr 8);
    Inc(Data);
    Dec(Count);
  end;
  Result := not Value;
end;

end.
