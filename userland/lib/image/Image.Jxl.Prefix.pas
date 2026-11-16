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
  JPEG XL's prefix codes (Brotli's, RFC 7932 section 3, with code
  lengths up to 15): a simple code of one to four symbols, or code
  lengths themselves prefix coded with the run length codes 16 (repeat
  the last length) and 17 (repeat zero).

  Codes are canonical: shorter codes first, equal lengths in symbol
  order, the first bit read being the code's most significant. A code
  of one symbol takes no bits. A table indexed by the next
  JxlPrefixTableBits bits (as read) gives the symbol and its length
  directly; longer codes are walked bit by bit from there.
}
unit Image.Jxl.Prefix;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader;

const
  JxlPrefixMaximumBits = 15;
  JxlPrefixTableBits = 9;

type
  TJxlPrefixCode = class
  private
    { Codes of each length, and the symbols sorted by (length, symbol). }
    FCounts: array[0..JxlPrefixMaximumBits] of LongInt;
    FSortedSymbols: array of Word;
    { Index in FSortedSymbols of each length's first code. }
    FFirstIndex: array[0..JxlPrefixMaximumBits] of LongInt;
    FSingleSymbol: LongInt;
    { Per value of the next JxlPrefixTableBits bits: symbol shl 4 or
      length, or 0 when the code is longer. }
    FTable: array of LongWord;
    procedure Build(const Lengths: array of Byte);
    function DecodeSlowly(Reader: TJxlBitReader): LongWord;
  public
    { Builds the code from code lengths (0: the symbol is not used).
      Raises ImageErrorMalformed unless the code is complete or a single
      symbol. }
    constructor CreateFromLengths(const Lengths: array of Byte);
    function ReadSymbol(Reader: TJxlBitReader): LongWord; inline;
  end;

{ Reads a prefix code over AlphabetSize symbols (2 or more). }
function ReadJxlPrefixCode(Reader: TJxlBitReader; AlphabetSize: LongInt): TJxlPrefixCode;

implementation

const
  CodeLengthCodeCount = 18;
  CodeLengthCodeOrder: array[0..CodeLengthCodeCount - 1] of Byte = (
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15);
  DefaultCodeLength = 8;
  RepeatPreviousCode = 16;
  { The fixed code of the code length code lengths, indexed by the next
    four bits: length in bits and value. }
  CodeLengthLengthBits: array[0..15] of Byte = (2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4);
  CodeLengthLengthValues: array[0..15] of Byte = (0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5);

procedure RaiseBadPrefixCode;
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad prefix code');
end;

{ Value's lowest Count bits in the opposite order. }
function ReverseBits(Value: LongWord; Count: LongInt): LongWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 1 to Count do
  begin
    Result := (Result shl 1) or (Value and 1);
    Value := Value shr 1;
  end;
end;

constructor TJxlPrefixCode.CreateFromLengths(const Lengths: array of Byte);
begin
  inherited Create;
  Build(Lengths);
end;

procedure TJxlPrefixCode.Build(const Lengths: array of Byte);
var
  Symbol: LongInt;
  Length: LongInt;
  Used: LongInt;
  Space: Int64;
  Position: array[0..JxlPrefixMaximumBits] of LongInt;
  Code: LongWord;
  Index: LongInt;
  Entry: LongWord;
  Fill: LongWord;
begin
  FillChar(FCounts, SizeOf(FCounts), 0);
  Used := 0;
  FSingleSymbol := -1;
  for Symbol := 0 to High(Lengths) do
  begin
    if Lengths[Symbol] > JxlPrefixMaximumBits then
      RaiseBadPrefixCode;
    if Lengths[Symbol] <> 0 then
    begin
      Inc(FCounts[Lengths[Symbol]]);
      Inc(Used);
      FSingleSymbol := Symbol;
    end;
  end;
  if Used = 0 then
    RaiseBadPrefixCode;
  if Used = 1 then
    Exit;
  FSingleSymbol := -1;
  Space := 0;
  for Length := 1 to JxlPrefixMaximumBits do
    Inc(Space, Int64(FCounts[Length]) shl (JxlPrefixMaximumBits - Length));
  if Space <> Int64(1) shl JxlPrefixMaximumBits then
    RaiseBadPrefixCode;
  SetLength(FSortedSymbols, Used);
  Index := 0;
  for Length := 1 to JxlPrefixMaximumBits do
  begin
    FFirstIndex[Length] := Index;
    Position[Length] := Index;
    Inc(Index, FCounts[Length]);
  end;
  for Symbol := 0 to High(Lengths) do
    if Lengths[Symbol] <> 0 then
    begin
      FSortedSymbols[Position[Lengths[Symbol]]] := Symbol;
      Inc(Position[Lengths[Symbol]]);
    end;
  { The table: walk the codes in canonical order. }
  SetLength(FTable, 1 shl JxlPrefixTableBits);
  FillDWord(FTable[0], System.Length(FTable), 0);
  Code := 0;
  Index := 0;
  for Length := 1 to JxlPrefixMaximumBits do
  begin
    for Symbol := 0 to FCounts[Length] - 1 do
    begin
      if Length <= JxlPrefixTableBits then
      begin
        Entry := (LongWord(FSortedSymbols[Index]) shl 4) or LongWord(Length);
        Fill := ReverseBits(Code, Length);
        while Fill < LongWord(1 shl JxlPrefixTableBits) do
        begin
          FTable[Fill] := Entry;
          Inc(Fill, LongWord(1) shl Length);
        end;
      end;
      Inc(Code);
      Inc(Index);
    end;
    Code := Code shl 1;
  end;
end;

function TJxlPrefixCode.DecodeSlowly(Reader: TJxlBitReader): LongWord;
var
  Bits: LongWord;
  Code: LongInt;
  First: LongInt;
  Length: LongInt;
begin
  Bits := Reader.PeekBits(JxlPrefixMaximumBits);
  Code := 0;
  First := 0;
  for Length := 1 to JxlPrefixMaximumBits do
  begin
    Code := Code or LongInt(Bits and 1);
    Bits := Bits shr 1;
    if Code - First < FCounts[Length] then
    begin
      Reader.SkipBits(Length);
      Exit(FSortedSymbols[FFirstIndex[Length] + Code - First]);
    end;
    First := (First + FCounts[Length]) shl 1;
    Code := Code shl 1;
  end;
  RaiseBadPrefixCode;
  Result := 0;
end;

function TJxlPrefixCode.ReadSymbol(Reader: TJxlBitReader): LongWord;
var
  Entry: LongWord;
begin
  if FSingleSymbol >= 0 then
    Exit(LongWord(FSingleSymbol));
  Entry := FTable[Reader.PeekBits(JxlPrefixTableBits)];
  if Entry <> 0 then
  begin
    Reader.SkipBits(Entry and 15);
    Exit(Entry shr 4);
  end;
  Result := DecodeSlowly(Reader);
end;

function ReadSimpleCode(Reader: TJxlBitReader; AlphabetSize: LongInt): TJxlPrefixCode;
var
  MaximumBits: LongInt;
  SymbolCount: LongInt;
  Symbols: array[0..3] of LongInt;
  Lengths: array of Byte;
  Index: LongInt;
  Other: LongInt;
begin
  MaximumBits := 0;
  while (1 shl MaximumBits) < AlphabetSize do
    Inc(MaximumBits);
  SymbolCount := LongInt(Reader.ReadBits(2)) + 1;
  for Index := 0 to SymbolCount - 1 do
  begin
    Symbols[Index] := LongInt(Reader.ReadBits(MaximumBits));
    if Symbols[Index] >= AlphabetSize then
      RaiseBadPrefixCode;
  end;
  for Index := 0 to SymbolCount - 2 do
    for Other := Index + 1 to SymbolCount - 1 do
      if Symbols[Index] = Symbols[Other] then
        RaiseBadPrefixCode;
  SetLength(Lengths, AlphabetSize);
  case SymbolCount of
    1:
      Lengths[Symbols[0]] := 1;
    2:
      begin
        Lengths[Symbols[0]] := 1;
        Lengths[Symbols[1]] := 1;
      end;
    3:
      begin
        Lengths[Symbols[0]] := 1;
        Lengths[Symbols[1]] := 2;
        Lengths[Symbols[2]] := 2;
      end;
  else
    if Reader.ReadBits(1) = 0 then
    begin
      for Index := 0 to 3 do
        Lengths[Symbols[Index]] := 2;
    end
    else
    begin
      Lengths[Symbols[0]] := 1;
      Lengths[Symbols[1]] := 2;
      Lengths[Symbols[2]] := 3;
      Lengths[Symbols[3]] := 3;
    end;
  end;
  Result := TJxlPrefixCode.CreateFromLengths(Lengths);
end;

procedure ReadCodeLengths(Reader: TJxlBitReader; const CodeLengthLengths: array of Byte;
  var Lengths: array of Byte);
var
  CodeLengthCode: TJxlPrefixCode;
  Symbol: LongInt;
  SymbolCount: LongInt;
  PreviousLength: Byte;
  RepeatCount: LongInt;
  RepeatLength: Byte;
  Space: LongInt;
  CodeLength: LongWord;
  ExtraBits: LongInt;
  OldRepeat: LongInt;
  RepeatDelta: LongInt;
  NewLength: Byte;
  Index: LongInt;
begin
  SymbolCount := Length(Lengths);
  CodeLengthCode := TJxlPrefixCode.CreateFromLengths(CodeLengthLengths);
  try
    Symbol := 0;
    PreviousLength := DefaultCodeLength;
    RepeatCount := 0;
    RepeatLength := 0;
    Space := 32768;
    while (Symbol < SymbolCount) and (Space > 0) do
    begin
      CodeLength := CodeLengthCode.ReadSymbol(Reader);
      if CodeLength < RepeatPreviousCode then
      begin
        RepeatCount := 0;
        Lengths[Symbol] := CodeLength;
        Inc(Symbol);
        if CodeLength <> 0 then
        begin
          PreviousLength := CodeLength;
          Dec(Space, 32768 shr CodeLength);
        end;
      end
      else
      begin
        ExtraBits := LongInt(CodeLength) - 14;
        NewLength := 0;
        if CodeLength = RepeatPreviousCode then
          NewLength := PreviousLength;
        if RepeatLength <> NewLength then
        begin
          RepeatCount := 0;
          RepeatLength := NewLength;
        end;
        OldRepeat := RepeatCount;
        if RepeatCount > 0 then
        begin
          Dec(RepeatCount, 2);
          RepeatCount := RepeatCount shl ExtraBits;
        end;
        Inc(RepeatCount, LongInt(Reader.ReadBits(ExtraBits)) + 3);
        RepeatDelta := RepeatCount - OldRepeat;
        if Symbol + RepeatDelta > SymbolCount then
          RaiseBadPrefixCode;
        for Index := Symbol to Symbol + RepeatDelta - 1 do
          Lengths[Index] := RepeatLength;
        Inc(Symbol, RepeatDelta);
        if RepeatLength <> 0 then
          Dec(Space, RepeatDelta shl (15 - RepeatLength));
      end;
    end;
    if Space <> 0 then
      RaiseBadPrefixCode;
  finally
    CodeLengthCode.Free;
  end;
end;

function ReadJxlPrefixCode(Reader: TJxlBitReader; AlphabetSize: LongInt): TJxlPrefixCode;
var
  SimpleOrSkip: LongWord;
  CodeLengthLengths: array[0..CodeLengthCodeCount - 1] of Byte;
  Lengths: array of Byte;
  Space: LongInt;
  CodeCount: LongInt;
  Index: LongInt;
  Peeked: LongWord;
  Value: Byte;
begin
  if (AlphabetSize < 2) or (AlphabetSize > 1 shl JxlPrefixMaximumBits) then
    RaiseBadPrefixCode;
  SimpleOrSkip := Reader.ReadBits(2);
  if SimpleOrSkip = 1 then
    Exit(ReadSimpleCode(Reader, AlphabetSize));
  FillChar(CodeLengthLengths, SizeOf(CodeLengthLengths), 0);
  Space := 32;
  CodeCount := 0;
  Index := LongInt(SimpleOrSkip);
  while (Index < CodeLengthCodeCount) and (Space > 0) do
  begin
    Peeked := Reader.PeekBits(4);
    Reader.SkipBits(CodeLengthLengthBits[Peeked]);
    Value := CodeLengthLengthValues[Peeked];
    CodeLengthLengths[CodeLengthCodeOrder[Index]] := Value;
    if Value <> 0 then
    begin
      Dec(Space, 32 shr Value);
      Inc(CodeCount);
    end;
    Inc(Index);
  end;
  if (CodeCount <> 1) and (Space <> 0) then
    RaiseBadPrefixCode;
  SetLength(Lengths, AlphabetSize);
  ReadCodeLengths(Reader, CodeLengthLengths, Lengths);
  Result := TJxlPrefixCode.CreateFromLengths(Lengths);
end;

end.
