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
  TBrotliBitReader: the bits of a brotli stream (lowest bit of each byte
  first, RFC 7932 section 1.5.1), taken from input given in pieces.

  The decoder reads in steps (a prefix code, a command, a literal) that
  must be read whole. A step starts with Save; a read past the input
  sets Overrun and gives zeros, and the decoder then Restores the mark
  and calls KeepUnread, which moves the bytes not yet used (fewer than
  one step takes) into the reader's own carry, so the caller's piece is
  free; the step is read again when more input has come. Bytes come
  from the carry first, then from the caller's piece, without copying
  the piece.
}
unit Compression.BrotliBitReader;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$pointermath on}

interface

uses
  SysUtils,
  Compression.HuffmanDecoding;

const
  { The longest prefix code (RFC 7932 section 3.5). }
  BrotliLongestCode = 15;
  { Refills keep at least this many bits when the input has them. }
  BrotliRefillThreshold = 56;

type
  TBrotliReaderMark = record
    Bits: QWord;
    BitCount: Integer;
    CarryPosition: SizeInt;
    InputPosition: SizeInt;
  end;

  TBrotliBitReader = record
  private
    { The next bits to read are the lowest FBitCount; the rest are 0. }
    FBits: QWord;
    FBitCount: Integer;
    FCarry: TBytes;
    FCarryLength: SizeInt;
    FCarryPosition: SizeInt;
    FInput: PByte;
    FInputLength: SizeInt;
    FInputPosition: SizeInt;
    procedure RefillSlowly;
  public
    { A read went past the input since the last Save. }
    Overrun: Boolean;
    procedure Reset;
    procedure SetInput(Data: PByte; Count: SizeInt);
    procedure Refill; inline;
    function ReadBits(Count: Integer): LongWord; inline;
    { The symbol of the prefix code whose table (root bits RootBits)
      starts at Table. }
    function ReadSymbol(Table: PDecodeEntry; RootBits: Integer): Integer; inline;
    function Save: TBrotliReaderMark; inline;
    procedure Restore(const Mark: TBrotliReaderMark); inline;
    { After a Restore: keeps the bytes not used yet, let go of the
      caller's piece. }
    procedure KeepUnread;
    { Drops the bits up to the next byte boundary; False if any is 1. }
    function SkipToByteBoundary: Boolean;
    { At a byte boundary: copies up to Count bytes to Target (skips them
      when Target is nil); the count. }
    function TakeBytes(Target: PByte; Count: SizeInt): SizeInt;
    { Whole bytes not used yet, held or in the caller's piece. }
    function BytesLeft: SizeInt;
    { Bytes of the caller's piece not taken in yet. }
    function InputLeft: SizeInt;
  end;

implementation

procedure TBrotliBitReader.Reset;
begin
  FBits := 0;
  FBitCount := 0;
  FCarryLength := 0;
  FCarryPosition := 0;
  FInput := nil;
  FInputLength := 0;
  FInputPosition := 0;
  Overrun := False;
end;

procedure TBrotliBitReader.SetInput(Data: PByte; Count: SizeInt);
begin
  FInput := Data;
  FInputLength := Count;
  if FInputLength < 0 then
    FInputLength := 0;
  FInputPosition := 0;
end;

procedure TBrotliBitReader.RefillSlowly;
var
  Next: Byte;
begin
  while FBitCount <= BrotliRefillThreshold do
  begin
    if FCarryPosition < FCarryLength then
    begin
      Next := FCarry[FCarryPosition];
      Inc(FCarryPosition);
    end
    else if FInputPosition < FInputLength then
    begin
      Next := FInput[FInputPosition];
      Inc(FInputPosition);
    end
    else
      Exit;
    FBits := FBits or (QWord(Next) shl FBitCount);
    Inc(FBitCount, 8);
  end;
end;

procedure TBrotliBitReader.Refill;
var
  Take: Integer;
  Word: QWord;
begin
  if FBitCount > BrotliRefillThreshold then
    Exit;
  if (FCarryPosition >= FCarryLength) and (FInputLength - FInputPosition >= 8) then
  begin
    { Whole bytes from one unaligned load. }
    Take := (64 - FBitCount) shr 3;
    Word := LEtoN(PQWord(FInput + FInputPosition)^);
    if Take < 8 then
      Word := Word and ((QWord(1) shl (8 * Take)) - 1);
    FBits := FBits or (Word shl FBitCount);
    Inc(FBitCount, 8 * Take);
    Inc(FInputPosition, Take);
  end
  else
    RefillSlowly;
end;

function TBrotliBitReader.ReadBits(Count: Integer): LongWord;
begin
  if FBitCount < Count then
  begin
    Refill;
    if FBitCount < Count then
    begin
      Overrun := True;
      FBits := 0;
      FBitCount := 0;
      Exit(0);
    end;
  end;
  Result := LongWord(FBits and ((QWord(1) shl Count) - 1));
  FBits := FBits shr Count;
  Dec(FBitCount, Count);
end;

function TBrotliBitReader.ReadSymbol(Table: PDecodeEntry; RootBits: Integer): Integer;
var
  Entry: TDecodeEntry;
  Length: Integer;
begin
  if FBitCount < BrotliLongestCode then
    Refill;
  Entry := Table[FBits and ((QWord(1) shl RootBits) - 1)];
  if EntryKind(Entry) = EntryKindLink then
  begin
    Entry := Table[EntryValue(Entry) + ((FBits shr RootBits) and ((QWord(1) shl EntrySubtableBits(Entry)) - 1))];
    Length := RootBits + EntryLength(Entry);
  end
  else
    Length := EntryLength(Entry);
  if Length > FBitCount then
  begin
    Overrun := True;
    FBits := 0;
    FBitCount := 0;
    Exit(0);
  end;
  FBits := FBits shr Length;
  Dec(FBitCount, Length);
  Result := EntryValue(Entry);
end;

function TBrotliBitReader.Save: TBrotliReaderMark;
begin
  Overrun := False;
  Result.Bits := FBits;
  Result.BitCount := FBitCount;
  Result.CarryPosition := FCarryPosition;
  Result.InputPosition := FInputPosition;
end;

procedure TBrotliBitReader.Restore(const Mark: TBrotliReaderMark);
begin
  FBits := Mark.Bits;
  FBitCount := Mark.BitCount;
  FCarryPosition := Mark.CarryPosition;
  FInputPosition := Mark.InputPosition;
  Overrun := False;
end;

procedure TBrotliBitReader.KeepUnread;
var
  Held: SizeInt;
  FromInput: SizeInt;
begin
  Held := FCarryLength - FCarryPosition;
  FromInput := FInputLength - FInputPosition;
  if (Held > 0) and (FCarryPosition > 0) then
    Move(FCarry[FCarryPosition], FCarry[0], Held);
  if Length(FCarry) < Held + FromInput then
    SetLength(FCarry, 2 * (Held + FromInput) + 64);
  if FromInput > 0 then
    Move(FInput[FInputPosition], FCarry[Held], FromInput);
  FCarryLength := Held + FromInput;
  FCarryPosition := 0;
  FInput := nil;
  FInputLength := 0;
  FInputPosition := 0;
end;

function TBrotliBitReader.SkipToByteBoundary: Boolean;
var
  Padding: Integer;
begin
  Padding := FBitCount and 7;
  Result := ReadBits(Padding) = 0;
end;

function TBrotliBitReader.TakeBytes(Target: PByte; Count: SizeInt): SizeInt;
var
  Chunk: SizeInt;
begin
  Result := 0;
  { First what the bit buffer holds (whole bytes at a boundary). }
  while (Result < Count) and (FBitCount >= 8) do
  begin
    if Target <> nil then
      Target[Result] := Byte(FBits);
    FBits := FBits shr 8;
    Dec(FBitCount, 8);
    Inc(Result);
  end;
  Chunk := FCarryLength - FCarryPosition;
  if Chunk > Count - Result then
    Chunk := Count - Result;
  if Chunk > 0 then
  begin
    if Target <> nil then
      Move(FCarry[FCarryPosition], Target[Result], Chunk);
    Inc(FCarryPosition, Chunk);
    Inc(Result, Chunk);
  end;
  Chunk := FInputLength - FInputPosition;
  if Chunk > Count - Result then
    Chunk := Count - Result;
  if Chunk > 0 then
  begin
    if Target <> nil then
      Move(FInput[FInputPosition], Target[Result], Chunk);
    Inc(FInputPosition, Chunk);
    Inc(Result, Chunk);
  end;
end;

function TBrotliBitReader.BytesLeft: SizeInt;
begin
  Result := FBitCount div 8 + (FCarryLength - FCarryPosition) + (FInputLength - FInputPosition);
end;

function TBrotliBitReader.InputLeft: SizeInt;
begin
  Result := FInputLength - FInputPosition;
end;

end.
