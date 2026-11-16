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
  VP8L's prefix codes: canonical Huffman codes of up to 15 bits, read
  first bit first as deflate's are, and the table that decodes them.

  The table is looked up with the next RootBits bits. An entry holds a
  symbol and how many bits its code took; or, for codes longer than the
  root, where their subtable starts and how many bits (beyond the root)
  index it. A code of one symbol takes no bits at all.

  As libwebp, only complete codes are accepted (every bit pattern is
  some code), besides the code of a single symbol.
}
unit Image.WebP.PrefixCodes;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.WebP.LosslessBits;

const
  MaximumPrefixCodeLength = 15;
  PrefixRootBits = 8;
  CodeLengthRootBits = 7;

type
  TPrefixCode = record
    RootBits: LongInt;
    { Symbol (or subtable start) in the low 16 bits, code length (or
      root bits plus subtable bits) above. }
    Entries: array of LongWord;
  end;

{ Builds the code with Lengths[0..Count - 1]; False when they do not
  make a valid code. }
function BuildPrefixCode(const Lengths: array of LongInt; Count: LongInt; RootBits: LongInt;
  out Code: TPrefixCode): Boolean;
{ The next symbol. }
function ReadSymbol(constref Code: TPrefixCode; Reader: TLosslessBitReader): LongInt;

implementation

function ReverseBits(Value: LongWord; Count: LongInt): LongWord;
var
  Bit: LongInt;
begin
  Result := 0;
  for Bit := 1 to Count do
  begin
    Result := (Result shl 1) or (Value and 1);
    Value := Value shr 1;
  end;
end;

{ How many bits beyond the root the subtable needs whose first code
  has CodeLength, given the codes of each length still to be placed. }
function SubtableBits(const Remaining: array of LongInt; CodeLength, RootBits: LongInt): LongInt;
var
  Left: LongInt;
  CurrentLength: LongInt;
begin
  CurrentLength := CodeLength;
  Left := 1 shl (CurrentLength - RootBits);
  while CurrentLength < MaximumPrefixCodeLength do
  begin
    Dec(Left, Remaining[CurrentLength]);
    if Left <= 0 then
      Break;
    Inc(CurrentLength);
    Left := Left shl 1;
  end;
  Result := CurrentLength - RootBits;
end;

procedure SpreadEntry(var Code: TPrefixCode; First, Index, Step, Size: LongInt; Entry: LongWord);
begin
  while Index < Size do
  begin
    Code.Entries[First + Index] := Entry;
    Inc(Index, Step);
  end;
end;

function BuildPrefixCode(const Lengths: array of LongInt; Count: LongInt; RootBits: LongInt;
  out Code: TPrefixCode): Boolean;
var
  LengthCounts: array[0..MaximumPrefixCodeLength] of LongInt;
  Remaining: array[0..MaximumPrefixCodeLength] of LongInt;
  NextCode: array[0..MaximumPrefixCodeLength + 1] of LongWord;
  Offsets: array[0..MaximumPrefixCodeLength + 1] of LongInt;
  Sorted: array of LongInt;
  Symbol: LongInt;
  CodeLength: LongInt;
  UsedCount: LongInt;
  Left: Int64;
  Position: LongInt;
  RootSize: LongInt;
  Reversed: LongWord;
  CurrentPrefix: LongInt;
  Prefix: LongInt;
  SubtableStart: LongInt;
  SubtableSize: LongInt;
  ExtraBits: LongInt;
begin
  Result := False;
  Code.RootBits := RootBits;
  Code.Entries := nil;
  RootSize := 1 shl RootBits;
  for CodeLength := 0 to MaximumPrefixCodeLength do
    LengthCounts[CodeLength] := 0;
  for Symbol := 0 to Count - 1 do
  begin
    if (Lengths[Symbol] < 0) or (Lengths[Symbol] > MaximumPrefixCodeLength) then
      Exit;
    Inc(LengthCounts[Lengths[Symbol]]);
  end;
  UsedCount := Count - LengthCounts[0];
  if UsedCount = 0 then
    Exit;
  SetLength(Code.Entries, RootSize);
  if UsedCount = 1 then
  begin
    for Symbol := 0 to Count - 1 do
      if Lengths[Symbol] > 0 then
        SpreadEntry(Code, 0, 0, 1, RootSize, LongWord(Symbol));
    Exit(True);
  end;

  Left := 1;
  for CodeLength := 1 to MaximumPrefixCodeLength do
  begin
    Left := Left * 2 - LengthCounts[CodeLength];
    if Left < 0 then
      Exit;
  end;
  if Left <> 0 then
    Exit;

  NextCode[1] := 0;
  for CodeLength := 1 to MaximumPrefixCodeLength do
    NextCode[CodeLength + 1] := (NextCode[CodeLength] + LongWord(LengthCounts[CodeLength])) shl 1;
  Offsets[1] := 0;
  for CodeLength := 1 to MaximumPrefixCodeLength do
    Offsets[CodeLength + 1] := Offsets[CodeLength] + LengthCounts[CodeLength];
  SetLength(Sorted, UsedCount);
  for Symbol := 0 to Count - 1 do
    if Lengths[Symbol] > 0 then
    begin
      Sorted[Offsets[Lengths[Symbol]]] := Symbol;
      Inc(Offsets[Lengths[Symbol]]);
    end;
  for CodeLength := 0 to MaximumPrefixCodeLength do
    Remaining[CodeLength] := LengthCounts[CodeLength];

  CurrentPrefix := -1;
  SubtableStart := 0;
  SubtableSize := 0;
  for Position := 0 to UsedCount - 1 do
  begin
    Symbol := Sorted[Position];
    CodeLength := Lengths[Symbol];
    Reversed := ReverseBits(NextCode[CodeLength], CodeLength);
    Inc(NextCode[CodeLength]);
    if CodeLength <= RootBits then
      SpreadEntry(Code, 0, Reversed, 1 shl CodeLength, RootSize, LongWord(Symbol) or (LongWord(CodeLength) shl 16))
    else
    begin
      Prefix := Reversed and LongWord(RootSize - 1);
      if Prefix <> CurrentPrefix then
      begin
        ExtraBits := SubtableBits(Remaining, CodeLength, RootBits);
        SubtableSize := 1 shl ExtraBits;
        SubtableStart := Length(Code.Entries);
        SetLength(Code.Entries, SubtableStart + SubtableSize);
        Code.Entries[Prefix] := LongWord(SubtableStart) or (LongWord(RootBits + ExtraBits) shl 16);
        CurrentPrefix := Prefix;
      end;
      SpreadEntry(Code, SubtableStart, Reversed shr RootBits, 1 shl (CodeLength - RootBits), SubtableSize,
        LongWord(Symbol) or (LongWord(CodeLength - RootBits) shl 16));
    end;
    Dec(Remaining[CodeLength]);
  end;
  Result := True;
end;

function ReadSymbol(constref Code: TPrefixCode; Reader: TLosslessBitReader): LongInt;
var
  Bits: LongWord;
  Entry: LongWord;
  EntryLength: LongInt;
begin
  Reader.Refill;
  Bits := Reader.PeekBits(MaximumPrefixCodeLength);
  Entry := Code.Entries[Bits and ((LongWord(1) shl Code.RootBits) - 1)];
  EntryLength := Entry shr 16;
  if EntryLength > Code.RootBits then
  begin
    Entry := Code.Entries[LongInt(Entry and $FFFF) +
      LongInt((Bits shr Code.RootBits) and ((LongWord(1) shl (EntryLength - Code.RootBits)) - 1))];
    Reader.SkipBits(Code.RootBits + LongInt(Entry shr 16));
  end
  else
    Reader.SkipBits(EntryLength);
  Result := Entry and $FFFF;
end;

end.
