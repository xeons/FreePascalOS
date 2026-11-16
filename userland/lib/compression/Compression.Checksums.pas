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
  The checksums of the zlib and gzip formats:

    Adler-32 (RFC 1950), summed in runs of 5552 bytes so that the sums
    are reduced modulo 65521 only once a run
    CRC-32 (IEEE 802.3, RFC 1952), eight bytes a step through eight
    tables ("slicing by eight")

  Both take the value of a previous call and return the finished value,
  so data can be fed in pieces: start with Adler32Initial or
  Crc32Initial. Png chunk CRCs are the same CRC-32.
}
unit Compression.Checksums;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

const
  Adler32Initial = LongWord(1);
  Crc32Initial = LongWord(0);

function Adler32(Adler: LongWord; Data: PByte; Count: SizeInt): LongWord;
function Crc32(Crc: LongWord; Data: PByte; Count: SizeInt): LongWord;

{ The checksum of a whole array. }
function Adler32OfBytes(const Data: TBytes): LongWord;
function Crc32OfBytes(const Data: TBytes): LongWord;

implementation

const
  AdlerModulus = 65521;
  { The most bytes that can be summed before the second sum can
    overflow 32 bits. }
  AdlerRunLength = 5552;
  Crc32Polynomial = LongWord($EDB88320);

var
  CrcTablesReady: Boolean = False;
  CrcTables: array[0..7, 0..255] of LongWord;

procedure PrepareCrcTables;
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
    CrcTables[0, Index] := Value;
  end;
  for Slice := 1 to 7 do
    for Index := 0 to 255 do
    begin
      Value := CrcTables[Slice - 1, Index];
      CrcTables[Slice, Index] := (Value shr 8) xor CrcTables[0, Value and $FF];
    end;
  CrcTablesReady := True;
end;

function Crc32(Crc: LongWord; Data: PByte; Count: SizeInt): LongWord;
var
  Value: LongWord;
  LowWord: LongWord;
  HighWord: LongWord;
begin
  if not CrcTablesReady then
    PrepareCrcTables;
  Value := not Crc;
  while Count >= 8 do
  begin
    LowWord := PLongWord(Data)^ xor Value;
    HighWord := PLongWord(Data + 4)^;
    Value := CrcTables[7, LowWord and $FF] xor
      CrcTables[6, (LowWord shr 8) and $FF] xor
      CrcTables[5, (LowWord shr 16) and $FF] xor
      CrcTables[4, LowWord shr 24] xor
      CrcTables[3, HighWord and $FF] xor
      CrcTables[2, (HighWord shr 8) and $FF] xor
      CrcTables[1, (HighWord shr 16) and $FF] xor
      CrcTables[0, HighWord shr 24];
    Inc(Data, 8);
    Dec(Count, 8);
  end;
  while Count > 0 do
  begin
    Value := CrcTables[0, (Value xor Data^) and $FF] xor (Value shr 8);
    Inc(Data);
    Dec(Count);
  end;
  Result := not Value;
end;

function Adler32(Adler: LongWord; Data: PByte; Count: SizeInt): LongWord;
var
  FirstSum: LongWord;
  SecondSum: LongWord;
  RunLength: SizeInt;
begin
  FirstSum := Adler and $FFFF;
  SecondSum := Adler shr 16;
  while Count > 0 do
  begin
    RunLength := Count;
    if RunLength > AdlerRunLength then
      RunLength := AdlerRunLength;
    Dec(Count, RunLength);
    while RunLength >= 4 do
    begin
      Inc(FirstSum, Data[0]);
      Inc(SecondSum, FirstSum);
      Inc(FirstSum, Data[1]);
      Inc(SecondSum, FirstSum);
      Inc(FirstSum, Data[2]);
      Inc(SecondSum, FirstSum);
      Inc(FirstSum, Data[3]);
      Inc(SecondSum, FirstSum);
      Inc(Data, 4);
      Dec(RunLength, 4);
    end;
    while RunLength > 0 do
    begin
      Inc(FirstSum, Data^);
      Inc(SecondSum, FirstSum);
      Inc(Data);
      Dec(RunLength);
    end;
    FirstSum := FirstSum mod AdlerModulus;
    SecondSum := SecondSum mod AdlerModulus;
  end;
  Result := (SecondSum shl 16) or FirstSum;
end;

function Adler32OfBytes(const Data: TBytes): LongWord;
begin
  Result := Adler32(Adler32Initial, PByte(Data), Length(Data));
end;

function Crc32OfBytes(const Data: TBytes): LongWord;
begin
  Result := Crc32(Crc32Initial, PByte(Data), Length(Data));
end;

end.
