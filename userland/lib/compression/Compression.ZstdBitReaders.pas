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
  The two ways Zstandard (RFC 8878) reads bits from a block in memory.

  TZstdBackwardReader: the Huffman and FSE bitstreams (sections 4.1 and
  4.2.2), written forward and read from the end: the last byte's highest
  set bit marks where the data ends, and each read takes the next bits
  down as a little-endian value. Reading past the start gives zeros and
  counts the bits as overflow (the Huffman weights stop on it; any other
  stream must end exactly at its start).

  TZstdForwardReader: an FSE table description (section 4.1.1), read
  from the first byte on, lowest bit first.
}
unit Compression.ZstdBitReaders;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$pointermath on}

interface

type
  TZstdBackwardReader = record
  private
    FData: PByte;
    { Bytes not loaded yet: FData[0] to FData[FPosition - 1]. }
    FPosition: SizeUInt;
    { The next bits to read are the highest FBitCount of the low bits. }
    FBits: QWord;
    FBitCount: Integer;
    FOverflow: QWord;
  public
    { False if Size is 0 or the last byte is 0 (it holds the end mark). }
    function Start(Data: PByte; Size: SizeUInt): Boolean;
    procedure Refill;
    { Count bits (0 to 56) as a number. }
    function ReadBits(Count: Integer): QWord; inline;
    function PeekBits(Count: Integer): QWord; inline;
    procedure SkipBits(Count: Integer); inline;
    { Every bit read, and no more. }
    function AtStart: Boolean;
    function Overflowed: Boolean; inline;
  end;

  TZstdForwardReader = record
  private
    FData: PByte;
    FSize: SizeUInt;
    FBitPosition: QWord;
  public
    procedure Start(Data: PByte; Size: SizeUInt);
    { Count bits (0 to 24); past the end they read as zeros. }
    function PeekBits(Count: Integer): LongWord;
    procedure SkipBits(Count: Integer); inline;
    function ReadBits(Count: Integer): LongWord;
    { Whole bytes used, a started byte counted. }
    function BytesUsed: SizeUInt;
    function Overrun: Boolean;
  end;

implementation

function HighestSetBit(Value: Byte): Integer;
begin
  Result := 7;
  while (Result > 0) and ((Value shr Result) and 1 = 0) do
    Dec(Result);
end;

procedure TZstdBackwardReader.Refill;
var
  Take: Integer;
  Word: QWord;
begin
  if FBitCount > 56 then
    Exit;
  if FPosition >= 8 then
  begin
    Take := (64 - FBitCount) shr 3;
    Word := LEtoN(PQWord(FData + FPosition - 8)^);
    if Take = 8 then
      FBits := Word
    else
      FBits := (FBits shl (8 * Take)) or (Word shr (64 - 8 * Take));
    Dec(FPosition, Take);
    Inc(FBitCount, 8 * Take);
    Exit;
  end;
  while (FBitCount <= 56) and (FPosition > 0) do
  begin
    Dec(FPosition);
    FBits := (FBits shl 8) or FData[FPosition];
    Inc(FBitCount, 8);
  end;
end;

function TZstdBackwardReader.PeekBits(Count: Integer): QWord;
begin
  if FBitCount < Count then
    Refill;
  if FBitCount >= Count then
    Result := (FBits shr (FBitCount - Count)) and ((QWord(1) shl Count) - 1)
  else
    Result := (FBits shl (Count - FBitCount)) and ((QWord(1) shl Count) - 1);
end;

procedure TZstdBackwardReader.SkipBits(Count: Integer);
begin
  if FBitCount >= Count then
    Dec(FBitCount, Count)
  else
  begin
    Inc(FOverflow, Count - FBitCount);
    FBitCount := 0;
  end;
end;

function TZstdBackwardReader.ReadBits(Count: Integer): QWord;
begin
  Result := PeekBits(Count);
  SkipBits(Count);
end;

function TZstdBackwardReader.Start(Data: PByte; Size: SizeUInt): Boolean;
var
  Last: Byte;
begin
  FData := Data;
  FPosition := Size;
  FBits := 0;
  FBitCount := 0;
  FOverflow := 0;
  Result := False;
  if Size = 0 then
    Exit;
  Last := Data[Size - 1];
  if Last = 0 then
    Exit;
  Refill;
  { The zeros above the end mark, and the mark itself. }
  SkipBits(8 - HighestSetBit(Last));
  Result := True;
end;

function TZstdBackwardReader.AtStart: Boolean;
begin
  Result := (FPosition = 0) and (FBitCount = 0) and (FOverflow = 0);
end;

function TZstdBackwardReader.Overflowed: Boolean;
begin
  Result := FOverflow > 0;
end;

procedure TZstdForwardReader.Start(Data: PByte; Size: SizeUInt);
begin
  FData := Data;
  FSize := Size;
  FBitPosition := 0;
end;

function TZstdForwardReader.PeekBits(Count: Integer): LongWord;
var
  ByteIndex: SizeUInt;
  Gathered: QWord;
  Shift: Integer;
begin
  ByteIndex := FBitPosition shr 3;
  Gathered := 0;
  Shift := 0;
  while (Shift < 32) and (ByteIndex < FSize) do
  begin
    Gathered := Gathered or (QWord(FData[ByteIndex]) shl Shift);
    Inc(ByteIndex);
    Inc(Shift, 8);
  end;
  Result := LongWord((Gathered shr (FBitPosition and 7)) and ((QWord(1) shl Count) - 1));
end;

procedure TZstdForwardReader.SkipBits(Count: Integer);
begin
  Inc(FBitPosition, Count);
end;

function TZstdForwardReader.ReadBits(Count: Integer): LongWord;
begin
  Result := PeekBits(Count);
  SkipBits(Count);
end;

function TZstdForwardReader.BytesUsed: SizeUInt;
begin
  Result := (FBitPosition + 7) shr 3;
end;

function TZstdForwardReader.Overrun: Boolean;
begin
  Result := FBitPosition > QWord(FSize) * 8;
end;

end.
