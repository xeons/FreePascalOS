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
  Checksums for detecting accidental changes (not for security):

    CRC-32 (IEEE 802.3, as in zip and gzip)
    CRC-32 POSIX (as printed by cksum: no reflection, the length mixed in)
    CRC-32C (Castagnoli, as in ext4 and iSCSI)
    the BSD and System V sums printed by sum

  CRC routines take the running value from a previous call, so data can
  be fed in pieces; start with the matching "Initial" constant.
}
unit Crypto.Checksums;

{$mode objfpc}
{$pointermath on}

interface

const
  Crc32Initial = LongWord($FFFFFFFF);
  Crc32cInitial = LongWord($FFFFFFFF);
  Crc32PosixInitial = LongWord(0);

{ IEEE CRC-32: Crc32Finish(Crc32Update(Crc32Initial, ...)). }
function Crc32Update(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
function Crc32Finish(Crc: LongWord): LongWord;

function Crc32cUpdate(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
function Crc32cFinish(Crc: LongWord): LongWord;

{ The cksum CRC: feed all data, then finish with the total length. }
function Crc32PosixUpdate(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
function Crc32PosixFinish(Crc: LongWord; TotalLength: QWord): LongWord;

{ BSD sum: a 16-bit rotating checksum. }
function BsdSumUpdate(Sum: Word; Data: PByte; Count: QWord): Word;
{ System V sum: add all bytes, fold to 16 bits at the end. }
function SystemVSumUpdate(Sum: QWord; Data: PByte; Count: QWord): QWord;
function SystemVSumFinish(Sum: QWord): Word;

implementation

var
  TablesReady: Boolean = False;
  ReflectedTable: array[0..255] of LongWord;      { IEEE, reflected }
  CastagnoliTable: array[0..255] of LongWord;     { CRC-32C, reflected }
  ForwardTable: array[0..255] of LongWord;        { IEEE, not reflected }

procedure PrepareTables;
var
  Index: LongWord;
  Bit: Integer;
  Value: LongWord;
begin
  for Index := 0 to 255 do
  begin
    Value := Index;
    for Bit := 1 to 8 do
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor $EDB88320
      else
        Value := Value shr 1;
    ReflectedTable[Index] := Value;

    Value := Index;
    for Bit := 1 to 8 do
      if (Value and 1) <> 0 then
        Value := (Value shr 1) xor $82F63B78
      else
        Value := Value shr 1;
    CastagnoliTable[Index] := Value;

    Value := Index shl 24;
    for Bit := 1 to 8 do
      if (Value and $80000000) <> 0 then
        Value := (Value shl 1) xor $04C11DB7
      else
        Value := Value shl 1;
    ForwardTable[Index] := Value;
  end;
  TablesReady := True;
end;

function ReflectedUpdate(const Table: array of LongWord; Crc: LongWord; Data: PByte; Count: QWord): LongWord;
var
  Index: QWord;
begin
  if not TablesReady then
    PrepareTables;
  Index := 0;
  while Index < Count do
  begin
    Crc := Table[(Crc xor Data[Index]) and $FF] xor (Crc shr 8);
    Inc(Index);
  end;
  Result := Crc;
end;

function Crc32Update(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
begin
  Result := ReflectedUpdate(ReflectedTable, Crc, Data, Count);
end;

function Crc32Finish(Crc: LongWord): LongWord;
begin
  Result := not Crc;
end;

function Crc32cUpdate(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
begin
  Result := ReflectedUpdate(CastagnoliTable, Crc, Data, Count);
end;

function Crc32cFinish(Crc: LongWord): LongWord;
begin
  Result := not Crc;
end;

function Crc32PosixUpdate(Crc: LongWord; Data: PByte; Count: QWord): LongWord;
var
  Index: QWord;
begin
  if not TablesReady then
    PrepareTables;
  Index := 0;
  while Index < Count do
  begin
    Crc := (Crc shl 8) xor ForwardTable[((Crc shr 24) xor Data[Index]) and $FF];
    Inc(Index);
  end;
  Result := Crc;
end;

function Crc32PosixFinish(Crc: LongWord; TotalLength: QWord): LongWord;
var
  LengthByte: Byte;
begin
  { The length goes in least significant byte first, without zeros. }
  while TotalLength > 0 do
  begin
    LengthByte := Byte(TotalLength and $FF);
    Crc := Crc32PosixUpdate(Crc, @LengthByte, 1);
    TotalLength := TotalLength shr 8;
  end;
  Result := not Crc;
end;

function BsdSumUpdate(Sum: Word; Data: PByte; Count: QWord): Word;
var
  Index: QWord;
begin
  Index := 0;
  while Index < Count do
  begin
    Sum := Word((Sum shr 1) or ((Sum and 1) shl 15));
    Sum := Word(Sum + Data[Index]);
    Inc(Index);
  end;
  Result := Sum;
end;

function SystemVSumUpdate(Sum: QWord; Data: PByte; Count: QWord): QWord;
var
  Index: QWord;
begin
  Index := 0;
  while Index < Count do
  begin
    Sum := Sum + Data[Index];
    Inc(Index);
  end;
  Result := Sum;
end;

function SystemVSumFinish(Sum: QWord): Word;
var
  Folded: QWord;
begin
  Folded := (Sum and $FFFF) + ((Sum shr 16) and $FFFF) + (Sum shr 32);
  Folded := (Folded and $FFFF) + (Folded shr 16);
  Result := Word(Folded);
end;

end.
