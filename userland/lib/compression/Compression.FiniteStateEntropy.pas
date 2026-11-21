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
  Finite State Entropy decoding tables (RFC 8878 section 4.1).

  A distribution gives each symbol's share of 1 shl AccuracyLog states;
  -1 means "less than one", a single state at the end of the table that
  reads a whole new state. ReadFseDistribution reads one from its
  compact description (section 4.1.1); BuildFseTable spreads the
  symbols over the states and works out, for each state, how many bits
  to read for the next state and what to add to them (Baseline).

  Decoding a symbol: Entries[State].Symbol; then State :=
  Entries[State].Baseline + the next Entries[State].BitCount bits.
}
unit Compression.FiniteStateEntropy;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

const
  FseMaximumAccuracyLog = 9;
  FseMaximumSymbols = 256;

type
  TFseEntry = record
    Symbol: Byte;
    BitCount: Byte;
    Baseline: Word;
  end;

  TFseTable = record
    AccuracyLog: Integer;
    Entries: array[0..(1 shl FseMaximumAccuracyLog) - 1] of TFseEntry;
  end;
  PFseTable = ^TFseTable;

  TFseDistribution = record
    AccuracyLog: Integer;
    SymbolCount: Integer;
    Counts: array[0..FseMaximumSymbols - 1] of SmallInt;
  end;

{ Reads a distribution of at most MaximumSymbol + 1 symbols and
  MaximumAccuracyLog from Data (Size bytes available); Used is how many
  bytes it took. False if it is not a valid one. }
function ReadFseDistribution(Data: PByte; Size: SizeUInt; MaximumSymbol: Integer; MaximumAccuracyLog: Integer;
  out Distribution: TFseDistribution; out Used: SizeUInt): Boolean;

{ The distribution from a list of counts (the predefined ones). }
procedure SetFseDistribution(out Distribution: TFseDistribution; const Counts: array of SmallInt;
  AccuracyLog: Integer);

function BuildFseTable(const Distribution: TFseDistribution; out Table: TFseTable): Boolean;

{ The table of one symbol that every state decodes, reading no bits
  (RLE mode). }
procedure BuildFseRleTable(Symbol: Byte; out Table: TFseTable);

implementation

uses
  Compression.ZstdBitReaders;

const
  MinimumAccuracyLog = 5;

function HighestBit(Value: LongWord): Integer;
begin
  Result := -1;
  while Value <> 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

function ReadFseDistribution(Data: PByte; Size: SizeUInt; MaximumSymbol: Integer; MaximumAccuracyLog: Integer;
  out Distribution: TFseDistribution; out Used: SizeUInt): Boolean;
var
  Reader: TZstdForwardReader;
  Remaining: Integer;
  Threshold: Integer;
  BitCount: Integer;
  Symbol: Integer;
  PreviousWasZero: Boolean;
  Repeat2: Integer;
  Largest: Integer;
  Value: Integer;
  Count: Integer;
begin
  Result := False;
  Used := 0;
  FillChar(Distribution, SizeOf(Distribution), 0);
  if Size = 0 then
    Exit;
  Reader.Start(Data, Size);
  Distribution.AccuracyLog := Reader.ReadBits(4) + MinimumAccuracyLog;
  if Distribution.AccuracyLog > MaximumAccuracyLog then
    Exit;
  { Remaining counts the probability left, plus one. }
  Remaining := (1 shl Distribution.AccuracyLog) + 1;
  Threshold := 1 shl Distribution.AccuracyLog;
  BitCount := Distribution.AccuracyLog + 1;
  Symbol := 0;
  PreviousWasZero := False;
  while (Remaining > 1) and (Symbol <= MaximumSymbol) do
  begin
    if PreviousWasZero then
    begin
      { How many more zeros: two bits at a time while they are 3. }
      repeat
        Repeat2 := Reader.ReadBits(2);
        Inc(Symbol, Repeat2);
        if Reader.Overrun then
          Exit;
      until Repeat2 <> 3;
      if Symbol > MaximumSymbol then
        Exit;
    end;
    { Values below Largest take one bit fewer. }
    Largest := 2 * Threshold - 1 - Remaining;
    Value := Reader.PeekBits(BitCount - 1);
    if Value < Largest then
      Reader.SkipBits(BitCount - 1)
    else
    begin
      Value := Reader.PeekBits(BitCount);
      if Value >= Threshold then
        Dec(Value, Largest);
      Reader.SkipBits(BitCount);
    end;
    Count := Value - 1;
    if Count < 0 then
      Dec(Remaining)
    else
      Dec(Remaining, Count);
    Distribution.Counts[Symbol] := Count;
    Inc(Symbol);
    PreviousWasZero := Count = 0;
    while Remaining < Threshold do
    begin
      Dec(BitCount);
      Threshold := Threshold shr 1;
    end;
    if Reader.Overrun then
      Exit;
  end;
  if (Remaining <> 1) or Reader.Overrun then
    Exit;
  Distribution.SymbolCount := Symbol;
  Used := Reader.BytesUsed;
  Result := True;
end;

procedure SetFseDistribution(out Distribution: TFseDistribution; const Counts: array of SmallInt;
  AccuracyLog: Integer);
var
  Index: Integer;
begin
  FillChar(Distribution, SizeOf(Distribution), 0);
  Distribution.AccuracyLog := AccuracyLog;
  Distribution.SymbolCount := Length(Counts);
  for Index := 0 to High(Counts) do
    Distribution.Counts[Index] := Counts[Index];
end;

function BuildFseTable(const Distribution: TFseDistribution; out Table: TFseTable): Boolean;
var
  TableSize: Integer;
  HighThreshold: Integer;
  Step: Integer;
  Mask: Integer;
  Position: Integer;
  Symbol: Integer;
  Index: Integer;
  State: Integer;
  NextState: array[0..FseMaximumSymbols - 1] of Integer;
  Next: Integer;
  BitCount: Integer;
begin
  Result := False;
  Table.AccuracyLog := Distribution.AccuracyLog;
  TableSize := 1 shl Distribution.AccuracyLog;
  HighThreshold := TableSize - 1;
  { "Less than one" symbols take the last states. }
  for Symbol := 0 to Distribution.SymbolCount - 1 do
    if Distribution.Counts[Symbol] = -1 then
    begin
      if HighThreshold < 0 then
        Exit;
      Table.Entries[HighThreshold].Symbol := Symbol;
      Dec(HighThreshold);
      NextState[Symbol] := 1;
    end
    else
      NextState[Symbol] := Distribution.Counts[Symbol];

  { The rest spread over the table, skipping the states taken. }
  Step := (TableSize shr 1) + (TableSize shr 3) + 3;
  Mask := TableSize - 1;
  Position := 0;
  for Symbol := 0 to Distribution.SymbolCount - 1 do
    for Index := 1 to Distribution.Counts[Symbol] do
    begin
      Table.Entries[Position].Symbol := Symbol;
      repeat
        Position := (Position + Step) and Mask;
      until Position <= HighThreshold;
    end;
  if Position <> 0 then
    Exit;

  for State := 0 to TableSize - 1 do
  begin
    Symbol := Table.Entries[State].Symbol;
    Next := NextState[Symbol];
    Inc(NextState[Symbol]);
    BitCount := Distribution.AccuracyLog - HighestBit(Next);
    Table.Entries[State].BitCount := BitCount;
    Table.Entries[State].Baseline := (Next shl BitCount) - TableSize;
  end;
  Result := True;
end;

procedure BuildFseRleTable(Symbol: Byte; out Table: TFseTable);
begin
  Table.AccuracyLog := 0;
  Table.Entries[0].Symbol := Symbol;
  Table.Entries[0].BitCount := 0;
  Table.Entries[0].Baseline := 0;
end;

end.
