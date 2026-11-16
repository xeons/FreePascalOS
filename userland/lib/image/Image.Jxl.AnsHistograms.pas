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
  The histograms of JPEG XL's asymmetric numeral system (ANS) coding,
  and the alias table a state is decoded with.

  A histogram's counts add up to 4096 (12 bits of precision). It is
  stored as one or two symbols, as a flat histogram, or as the base 2
  logarithm of each count (a fixed prefix code, with a run length code
  for repeats), the counts' lower bits as far as the shift asks, and
  the largest count left out (it is what makes the total 4096).

  The alias table splits the 4096 states into 2^LogAlphabetSize buckets
  of equal size; each bucket holds part of its own symbol and the rest
  of one other ("right") symbol, so a state is decoded with a lookup.
  It is built exactly as libjxl builds it, since the encoder's states
  depend on it.
}
unit Image.Jxl.AnsHistograms;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader;

const
  JxlAnsLogTableSize = 12;
  JxlAnsTableSize = 1 shl JxlAnsLogTableSize;

type
  TJxlAliasEntry = record
    Cutoff: LongWord;
    RightValue: LongWord;
    Offset1: LongWord;
    Frequency0: LongWord;
    Frequency1: LongWord;
  end;

  TJxlAliasTable = array of TJxlAliasEntry;

  TJxlAnsCounts = array of LongInt;

{ Reads one histogram's counts. }
function ReadJxlAnsCounts(Reader: TJxlBitReader): TJxlAnsCounts;
{ The alias table of Counts (adding up to 4096) with 2^LogAlphabetSize
  buckets. }
function BuildJxlAliasTable(const Counts: TJxlAnsCounts; LogAlphabetSize: LongInt): TJxlAliasTable;
{ U8 as the histograms code it: 0, or 2^n plus n bits. }
function ReadJxlVarLenUint8(Reader: TJxlBitReader): LongInt;
function ReadJxlVarLenUint16(Reader: TJxlBitReader): LongInt;

implementation

procedure RaiseBadHistogram;
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad ANS histogram');
end;

function ReadJxlVarLenUint8(Reader: TJxlBitReader): LongInt;
var
  Count: LongInt;
begin
  if Reader.ReadBits(1) = 0 then
    Exit(0);
  Count := LongInt(Reader.ReadBits(3));
  if Count = 0 then
    Exit(1);
  Result := LongInt(Reader.ReadBits(Count)) + (1 shl Count);
end;

function ReadJxlVarLenUint16(Reader: TJxlBitReader): LongInt;
var
  Count: LongInt;
begin
  if Reader.ReadBits(1) = 0 then
    Exit(0);
  Count := LongInt(Reader.ReadBits(4));
  if Count = 0 then
    Exit(1);
  Result := LongInt(Reader.ReadBits(Count)) + (1 shl Count);
end;

{ The logarithm code, indexed by the next seven bits: length in bits
  and the value (logarithm plus one; 13 is the run length symbol). }
procedure DecodeLogCount(Peeked: LongWord; out Bits: LongInt; out Value: LongInt);
begin
  case Peeked and 7 of
    0: begin Bits := 3; Value := 10; end;
    2: begin Bits := 3; Value := 7; end;
    4: begin Bits := 3; Value := 6; end;
    5: begin Bits := 3; Value := 8; end;
    6: begin Bits := 3; Value := 9; end;
    3:
      begin
        Bits := 4;
        if (Peeked and 8) = 0 then
          Value := 3
        else
          Value := 1;
      end;
    7:
      begin
        Bits := 4;
        if (Peeked and 8) = 0 then
          Value := 5
        else
          Value := 2;
      end;
  else
    { 1: the codes beginning with a 1 then two 0s }
    if (Peeked and 8) <> 0 then
    begin
      Bits := 4;
      Value := 4;
    end
    else if (Peeked and 16) <> 0 then
    begin
      Bits := 5;
      Value := 0;
    end
    else if (Peeked and 32) <> 0 then
    begin
      Bits := 6;
      Value := 11;
    end
    else if (Peeked and 64) <> 0 then
    begin
      Bits := 7;
      Value := 13;
    end
    else
    begin
      Bits := 7;
      Value := 12;
    end;
  end;
end;

function PopulationCountPrecision(LogCount, Shift: LongInt): LongInt;
begin
  Result := Shift - ((JxlAnsLogTableSize - LogCount) shr 1);
  if LogCount < Result then
    Result := LogCount;
  if Result < 0 then
    Result := 0;
end;

function FlatCounts(AlphabetSize: LongInt): TJxlAnsCounts;
var
  Index: LongInt;
  Each: LongInt;
  Remainder: LongInt;
begin
  SetLength(Result, AlphabetSize);
  Each := JxlAnsTableSize div AlphabetSize;
  Remainder := JxlAnsTableSize mod AlphabetSize;
  for Index := 0 to AlphabetSize - 1 do
  begin
    Result[Index] := Each;
    if Index < Remainder then
      Inc(Result[Index]);
  end;
end;

function ReadComplexCounts(Reader: TJxlBitReader): TJxlAnsCounts;
var
  Shift: LongInt;
  Log: LongInt;
  Length: LongInt;
  LogCounts: array of LongInt;
  Same: array of LongInt;
  OmitLog: LongInt;
  OmitPosition: LongInt;
  Index: LongInt;
  Bits: LongInt;
  Value: LongInt;
  RunLength: LongInt;
  Previous: LongInt;
  SameLeft: LongInt;
  Code: LongInt;
  BitCount: LongInt;
  Total: LongInt;
begin
  Log := 0;
  while Log < 3 do
  begin
    if Reader.ReadBits(1) = 0 then
      Break;
    Inc(Log);
  end;
  Shift := LongInt(Reader.ReadBits(Log) or (LongWord(1) shl Log)) - 1;
  if Shift > JxlAnsLogTableSize + 1 then
    RaiseBadHistogram;
  Length := ReadJxlVarLenUint8(Reader) + 3;
  { A dynamic array result may hold the caller's old array, so it is
    cleared before it is sized (the counts left out stay 0). }
  Result := nil;
  SetLength(Result, Length);
  SetLength(LogCounts, Length);
  SetLength(Same, Length);
  OmitLog := -1;
  OmitPosition := -1;
  Index := 0;
  while Index < Length do
  begin
    DecodeLogCount(Reader.PeekBits(7), Bits, Value);
    Reader.SkipBits(Bits);
    LogCounts[Index] := Value - 1;
    if LogCounts[Index] = JxlAnsLogTableSize then
    begin
      RunLength := ReadJxlVarLenUint8(Reader);
      Same[Index] := RunLength + 5;
      Inc(Index, RunLength + 4);
      Continue;
    end;
    if LogCounts[Index] > OmitLog then
    begin
      OmitLog := LogCounts[Index];
      OmitPosition := Index;
    end;
    Inc(Index);
  end;
  if OmitPosition < 0 then
    RaiseBadHistogram;
  if (OmitPosition + 1 < Length) and (LogCounts[OmitPosition + 1] = JxlAnsLogTableSize) then
    RaiseBadHistogram;
  Previous := 0;
  SameLeft := 0;
  Total := 0;
  for Index := 0 to Length - 1 do
  begin
    if Same[Index] <> 0 then
    begin
      SameLeft := Same[Index] - 1;
      if Index > 0 then
        Previous := Result[Index - 1]
      else
        Previous := 0;
    end;
    if SameLeft > 0 then
    begin
      Result[Index] := Previous;
      Dec(SameLeft);
    end
    else
    begin
      Code := LogCounts[Index];
      if (Index = OmitPosition) or (Code < 0) then
        Continue;
      if (Shift = 0) or (Code = 0) then
        Result[Index] := 1 shl Code
      else
      begin
        BitCount := PopulationCountPrecision(Code, Shift);
        Result[Index] := (1 shl Code) + LongInt(Reader.ReadBits(BitCount) shl (Code - BitCount));
      end;
    end;
    Inc(Total, Result[Index]);
    if Total > JxlAnsTableSize then
      RaiseBadHistogram;
  end;
  Result[OmitPosition] := JxlAnsTableSize - Total;
  if Result[OmitPosition] <= 0 then
    RaiseBadHistogram;
end;

function ReadJxlAnsCounts(Reader: TJxlBitReader): TJxlAnsCounts;
var
  SymbolCount: LongInt;
  Symbols: array[0..1] of LongInt;
  Index: LongInt;
  MaximumSymbol: LongInt;
begin
  if Reader.ReadBits(1) = 1 then
  begin
    SymbolCount := LongInt(Reader.ReadBits(1)) + 1;
    MaximumSymbol := 0;
    for Index := 0 to SymbolCount - 1 do
    begin
      Symbols[Index] := ReadJxlVarLenUint8(Reader);
      if Symbols[Index] > MaximumSymbol then
        MaximumSymbol := Symbols[Index];
    end;
    Result := nil;
    SetLength(Result, MaximumSymbol + 1);
    if SymbolCount = 1 then
      Result[Symbols[0]] := JxlAnsTableSize
    else
    begin
      if Symbols[0] = Symbols[1] then
        RaiseBadHistogram;
      Result[Symbols[0]] := LongInt(Reader.ReadBits(JxlAnsLogTableSize));
      Result[Symbols[1]] := JxlAnsTableSize - Result[Symbols[0]];
    end;
    Exit;
  end;
  if Reader.ReadBits(1) = 1 then
    Exit(FlatCounts(ReadJxlVarLenUint8(Reader) + 1));
  Result := ReadComplexCounts(Reader);
end;

function BuildJxlAliasTable(const Counts: TJxlAnsCounts; LogAlphabetSize: LongInt): TJxlAliasTable;
var
  Distribution: TJxlAnsCounts;
  TableSize: LongInt;
  EntrySize: LongInt;
  Symbol: LongInt;
  SingleSymbol: LongInt;
  Sum: LongInt;
  Cutoffs: array of LongInt;
  Underfull: array of LongInt;
  Overfull: array of LongInt;
  UnderfullCount: LongInt;
  OverfullCount: LongInt;
  OverfullIndex: LongInt;
  UnderfullIndex: LongInt;
  UnderfullBy: LongInt;
  Index: LongInt;
  Frequency0: LongInt;
  Frequency1: LongInt;
begin
  Distribution := Copy(Counts);
  while (Length(Distribution) > 0) and (Distribution[High(Distribution)] = 0) do
    SetLength(Distribution, Length(Distribution) - 1);
  if Length(Distribution) = 0 then
  begin
    SetLength(Distribution, 1);
    Distribution[0] := JxlAnsTableSize;
  end;
  TableSize := 1 shl LogAlphabetSize;
  if Length(Distribution) > TableSize then
    RaiseBadHistogram;
  EntrySize := JxlAnsTableSize shr LogAlphabetSize;
  SetLength(Result, TableSize);
  SingleSymbol := -1;
  Sum := 0;
  for Symbol := 0 to High(Distribution) do
  begin
    Inc(Sum, Distribution[Symbol]);
    if Distribution[Symbol] = JxlAnsTableSize then
      SingleSymbol := Symbol;
  end;
  if Sum <> JxlAnsTableSize then
    RaiseBadHistogram;
  if SingleSymbol >= 0 then
  begin
    for Index := 0 to TableSize - 1 do
    begin
      Result[Index].RightValue := LongWord(SingleSymbol);
      Result[Index].Cutoff := 0;
      Result[Index].Offset1 := LongWord(EntrySize * Index);
      Result[Index].Frequency0 := 0;
      Result[Index].Frequency1 := JxlAnsTableSize;
    end;
    Exit;
  end;
  SetLength(Cutoffs, TableSize);
  SetLength(Underfull, TableSize);
  SetLength(Overfull, TableSize);
  UnderfullCount := 0;
  OverfullCount := 0;
  for Index := 0 to TableSize - 1 do
  begin
    Result[Index].RightValue := 0;
    Result[Index].Offset1 := 0;
    if Index < Length(Distribution) then
      Cutoffs[Index] := Distribution[Index]
    else
      Cutoffs[Index] := 0;
    if Cutoffs[Index] > EntrySize then
    begin
      Overfull[OverfullCount] := Index;
      Inc(OverfullCount);
    end
    else if Cutoffs[Index] < EntrySize then
    begin
      Underfull[UnderfullCount] := Index;
      Inc(UnderfullCount);
    end;
  end;
  while OverfullCount > 0 do
  begin
    Dec(OverfullCount);
    OverfullIndex := Overfull[OverfullCount];
    if UnderfullCount = 0 then
      RaiseBadHistogram;
    Dec(UnderfullCount);
    UnderfullIndex := Underfull[UnderfullCount];
    UnderfullBy := EntrySize - Cutoffs[UnderfullIndex];
    Dec(Cutoffs[OverfullIndex], UnderfullBy);
    Result[UnderfullIndex].RightValue := LongWord(OverfullIndex);
    Result[UnderfullIndex].Offset1 := LongWord(Cutoffs[OverfullIndex]);
    if Cutoffs[OverfullIndex] < EntrySize then
    begin
      Underfull[UnderfullCount] := OverfullIndex;
      Inc(UnderfullCount);
    end
    else if Cutoffs[OverfullIndex] > EntrySize then
    begin
      Overfull[OverfullCount] := OverfullIndex;
      Inc(OverfullCount);
    end;
  end;
  for Index := 0 to TableSize - 1 do
  begin
    if Cutoffs[Index] = EntrySize then
    begin
      Result[Index].RightValue := LongWord(Index);
      Result[Index].Offset1 := 0;
      Result[Index].Cutoff := 0;
    end
    else
    begin
      Result[Index].Offset1 := LongWord(LongInt(Result[Index].Offset1) - Cutoffs[Index]);
      Result[Index].Cutoff := LongWord(Cutoffs[Index]);
    end;
    if Index < Length(Distribution) then
      Frequency0 := Distribution[Index]
    else
      Frequency0 := 0;
    if LongInt(Result[Index].RightValue) < Length(Distribution) then
      Frequency1 := Distribution[Result[Index].RightValue]
    else
      Frequency1 := 0;
    Result[Index].Frequency0 := LongWord(Frequency0);
    Result[Index].Frequency1 := LongWord(Frequency1);
  end;
end;

end.
