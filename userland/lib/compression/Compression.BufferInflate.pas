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
  Raw deflate data (RFC 1951) decoded in one call, all of the input in
  memory, into one flat output buffer.

  The streaming decoder (Compression.InflateEngine) keeps a 32 KiB
  history and stops wherever input or room runs out; with the whole
  output in one buffer neither is needed: matches copy from the output
  itself, and the bit reader pads the input with zeros, noting it, so
  the decoder never waits. It shares the Huffman tables
  (Compression.HuffmanDecoding) and the format's constants
  (Compression.DeflateFormat) with the streaming one.

  Every symbol and distance is checked; padding read beyond the input
  means it was cut short. Freestanding (the kernel compiles it); the
  caller provides the state record, some 10 KiB.
}
unit Compression.BufferInflate;

{$mode objfpc}
{$pointermath on}
{$inline on}

interface

uses
  Compression.DecodeResults,
  Compression.DeflateFormat,
  Compression.HuffmanDecoding;

type
  TBufferInflateState = record
    Input: PByte;
    InputEnd: PByte;
    Bits: QWord;
    BitCount: LongWord;
    { Zero bytes given to the bit buffer past the input's end. }
    PaddingBytes: LongWord;
    Output: PByte;
    OutputSize: SizeUInt;
    Position: SizeUInt;
    LiteralLengthTable: TLiteralLengthTable;
    DistanceTable: TDistanceTable;
    CodeLengthTable: TCodeLengthTable;
    CodeLengths: array[0..LiteralLengthSymbols + DistanceSymbols - 1] of Byte;
  end;

{ Decodes the deflate data at Input into Output (OutputSize bytes at
  most). InputUsed is where the data ended (the next whole byte),
  OutputUsed how much it made. }
function InflateIntoBuffer(var State: TBufferInflateState; Input: PByte; InputSize: SizeUInt;
  out InputUsed: SizeUInt; Output: PByte; OutputSize: SizeUInt; out OutputUsed: SizeUInt): TDecodeResult;

implementation

const
  { Past this much padding the data cannot be a cut-short stream that
    is still decoding (the widest read is under 8 bytes). }
  PaddingLimit = 16;

procedure FillBits(var State: TBufferInflateState; Count: LongWord); inline;
begin
  while State.BitCount < Count do
  begin
    if State.Input < State.InputEnd then
    begin
      State.Bits := State.Bits or (QWord(State.Input^) shl State.BitCount);
      Inc(State.Input);
    end
    else
      Inc(State.PaddingBytes);
    Inc(State.BitCount, 8);
  end;
end;

function TakeBits(var State: TBufferInflateState; Count: LongWord): LongWord; inline;
begin
  FillBits(State, Count);
  Result := LongWord(State.Bits and ((QWord(1) shl Count) - 1));
  State.Bits := State.Bits shr Count;
  Dec(State.BitCount, Count);
end;

function PaddingConsumed(const State: TBufferInflateState): Boolean;
begin
  Result := State.BitCount < State.PaddingBytes * 8;
end;

{ The next symbol of the code in Table; -1 for a code that is not in it. }
function DecodeSymbol(var State: TBufferInflateState; Table: PDecodeEntry; RootBits: LongWord): Integer;
var
  Entry: TDecodeEntry;
  Used: LongWord;
begin
  FillBits(State, MaximumCodeLength);
  Entry := Table[State.Bits and ((QWord(1) shl RootBits) - 1)];
  Used := 0;
  if EntryKind(Entry) = EntryKindLink then
  begin
    Used := RootBits;
    Entry := Table[EntryValue(Entry) + Integer((State.Bits shr RootBits) and
      ((QWord(1) shl EntrySubtableBits(Entry)) - 1))];
  end;
  if EntryKind(Entry) <> EntryKindSymbol then
    Exit(-1);
  Inc(Used, EntryLength(Entry));
  State.Bits := State.Bits shr Used;
  Dec(State.BitCount, Used);
  Result := EntryValue(Entry);
end;

function CopyStoredBlock(var State: TBufferInflateState): TDecodeResult;
var
  Length: LongWord;
  Complement: LongWord;
begin
  TakeBits(State, State.BitCount mod 8);
  Length := TakeBits(State, 16);
  Complement := TakeBits(State, 16);
  if PaddingConsumed(State) then
    Exit(DecodeTruncated);
  if Length <> (not Complement) and $FFFF then
    Exit(DecodeCorrupt);
  if Length > State.OutputSize - State.Position then
    Exit(DecodeOutputTooSmall);
  { Whole bytes still in the bit buffer first, then straight from the
    input. }
  while (Length > 0) and (State.BitCount >= 8) do
  begin
    State.Output[State.Position] := Byte(TakeBits(State, 8));
    Inc(State.Position);
    Dec(Length);
  end;
  if PaddingConsumed(State) or (Length > SizeUInt(State.InputEnd - State.Input)) then
    Exit(DecodeTruncated);
  Move(State.Input^, State.Output[State.Position], Length);
  Inc(State.Input, Length);
  Inc(State.Position, Length);
  Result := DecodeSucceeded;
end;

procedure BuildFixedTables(var State: TBufferInflateState);
var
  LiteralLengths: TLiteralLengthCodeLengths;
  Distances: TDistanceCodeLengths;
begin
  GetFixedLiteralLengthCodeLengths(LiteralLengths);
  GetFixedDistanceCodeLengths(Distances);
  BuildDecodeTable(@LiteralLengths[0], LiteralLengthSymbols, LiteralLengthRootBits, @State.LiteralLengthTable[0],
    LiteralLengthTableSize, CodeKindSymbols);
  BuildDecodeTable(@Distances[0], DistanceSymbols, DistanceRootBits, @State.DistanceTable[0], DistanceTableSize,
    CodeKindSymbols);
end;

{ The code lengths of a dynamic block, run-length coded with the code
  length code. }
function ReadCodeLengths(var State: TBufferInflateState; Total: Integer): TDecodeResult;
var
  Index: Integer;
  Symbol: Integer;
  Repeated: Byte;
  RepeatCount: LongWord;
begin
  Index := 0;
  while Index < Total do
  begin
    Symbol := DecodeSymbol(State, @State.CodeLengthTable[0], CodeLengthRootBits);
    if Symbol < 0 then
      Exit(DecodeCorrupt);
    if Symbol < RepeatPreviousSymbol then
    begin
      State.CodeLengths[Index] := Symbol;
      Inc(Index);
      Continue;
    end;
    Repeated := 0;
    case Symbol of
      RepeatPreviousSymbol:
        begin
          if Index = 0 then
            Exit(DecodeCorrupt);
          Repeated := State.CodeLengths[Index - 1];
          RepeatCount := 3 + TakeBits(State, 2);
        end;
      RepeatZeroShortSymbol:
        RepeatCount := 3 + TakeBits(State, 3);
    else
      RepeatCount := 11 + TakeBits(State, 7);
    end;
    if RepeatCount > LongWord(Total - Index) then
      Exit(DecodeCorrupt);
    while RepeatCount > 0 do
    begin
      State.CodeLengths[Index] := Repeated;
      Inc(Index);
      Dec(RepeatCount);
    end;
  end;
  Result := DecodeSucceeded;
end;

function BuildDynamicTables(var State: TBufferInflateState): TDecodeResult;
var
  LiteralLengthCount: Integer;
  DistanceCount: Integer;
  CodeLengthCount: Integer;
  Index: Integer;
  CodeLengthLengths: array[0..CodeLengthSymbols - 1] of Byte;
begin
  LiteralLengthCount := 257 + TakeBits(State, 5);
  DistanceCount := 1 + TakeBits(State, 5);
  CodeLengthCount := 4 + TakeBits(State, 4);
  if (LiteralLengthCount > UsableLiteralLengthSymbols) or (DistanceCount > UsableDistanceSymbols) then
    Exit(DecodeCorrupt);
  for Index := 0 to CodeLengthSymbols - 1 do
    CodeLengthLengths[Index] := 0;
  for Index := 0 to CodeLengthCount - 1 do
    CodeLengthLengths[CodeLengthOrder[Index]] := TakeBits(State, 3);
  if not BuildDecodeTable(@CodeLengthLengths[0], CodeLengthSymbols, CodeLengthRootBits,
     @State.CodeLengthTable[0], CodeLengthTableSize, CodeKindCodeLengths) then
    Exit(DecodeCorrupt);
  Result := ReadCodeLengths(State, LiteralLengthCount + DistanceCount);
  if Result <> DecodeSucceeded then
    Exit;
  if State.CodeLengths[EndOfBlockSymbol] = 0 then
    Exit(DecodeCorrupt);
  if (not BuildDecodeTable(@State.CodeLengths[0], LiteralLengthCount, LiteralLengthRootBits,
      @State.LiteralLengthTable[0], LiteralLengthTableSize, CodeKindSymbols)) or
     (not BuildDecodeTable(@State.CodeLengths[LiteralLengthCount], DistanceCount, DistanceRootBits,
      @State.DistanceTable[0], DistanceTableSize, CodeKindSymbols)) then
    Exit(DecodeCorrupt);
  Result := DecodeSucceeded;
end;

{ The literals and matches of a fixed or dynamic block, to its end. }
function DecodeCodes(var State: TBufferInflateState): TDecodeResult;
var
  Symbol: Integer;
  Length: SizeUInt;
  Distance: SizeUInt;
  Source: PByte;
  Destination: PByte;
  Finish: PByte;
begin
  repeat
    if State.PaddingBytes > PaddingLimit then
      Exit(DecodeTruncated);
    Symbol := DecodeSymbol(State, @State.LiteralLengthTable[0], LiteralLengthRootBits);
    if Symbol < 0 then
      Exit(DecodeCorrupt);
    if Symbol < EndOfBlockSymbol then
    begin
      if State.Position >= State.OutputSize then
        Exit(DecodeOutputTooSmall);
      State.Output[State.Position] := Byte(Symbol);
      Inc(State.Position);
      Continue;
    end;
    if Symbol = EndOfBlockSymbol then
      Exit(DecodeSucceeded);
    Dec(Symbol, FirstLengthSymbol);
    if Symbol >= LengthCodeCount then
      Exit(DecodeCorrupt);
    Length := LengthBase[Symbol] + TakeBits(State, LengthExtraBits[Symbol]);

    Symbol := DecodeSymbol(State, @State.DistanceTable[0], DistanceRootBits);
    if (Symbol < 0) or (Symbol >= UsableDistanceSymbols) then
      Exit(DecodeCorrupt);
    Distance := DistanceBase[Symbol] + TakeBits(State, DistanceExtraBits[Symbol]);
    if Distance > State.Position then
      Exit(DecodeCorrupt);
    if Length > State.OutputSize - State.Position then
      Exit(DecodeOutputTooSmall);
    Destination := State.Output + State.Position;
    Source := Destination - Distance;
    Finish := Destination + Length;
    while Destination < Finish do
    begin
      Destination^ := Source^;
      Inc(Destination);
      Inc(Source);
    end;
    Inc(State.Position, Length);
  until False;
end;

function InflateIntoBuffer(var State: TBufferInflateState; Input: PByte; InputSize: SizeUInt;
  out InputUsed: SizeUInt; Output: PByte; OutputSize: SizeUInt; out OutputUsed: SizeUInt): TDecodeResult;
var
  LastBlock: Boolean;
  BlockType: LongWord;
begin
  State.Input := Input;
  State.InputEnd := Input + InputSize;
  State.Bits := 0;
  State.BitCount := 0;
  State.PaddingBytes := 0;
  State.Output := Output;
  State.OutputSize := OutputSize;
  State.Position := 0;
  repeat
    LastBlock := TakeBits(State, 1) = 1;
    BlockType := TakeBits(State, 2);
    case BlockType of
      BlockStored:
        Result := CopyStoredBlock(State);
      BlockFixed:
        begin
          BuildFixedTables(State);
          Result := DecodeCodes(State);
        end;
      BlockDynamic:
        begin
          Result := BuildDynamicTables(State);
          if Result = DecodeSucceeded then
            Result := DecodeCodes(State);
        end;
    else
      Result := DecodeCorrupt;
    end;
    if (Result <> DecodeSucceeded) and (State.PaddingBytes > 0) then
      Result := DecodeTruncated;
    if Result <> DecodeSucceeded then
      Break;
    if PaddingConsumed(State) then
      Result := DecodeTruncated;
  until LastBlock or (Result <> DecodeSucceeded);
  { The bytes the bit buffer holds whole were not used (none of the
    padding was, on success). }
  InputUsed := SizeUInt(State.Input - Input);
  if Result = DecodeSucceeded then
    Dec(InputUsed, State.BitCount div 8 - State.PaddingBytes);
  OutputUsed := State.Position;
end;

end.
