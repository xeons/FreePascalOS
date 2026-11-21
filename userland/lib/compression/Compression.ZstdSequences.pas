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
  The sequences section of a Zstandard compressed block (RFC 8878
  sections 3.1.1.3.2 to 3.1.1.5), decoded and carried out straight into
  the output window.

  The header gives the number of sequences and, for each of the literal
  length, offset and match length codes, where its FSE table comes from:
  the predefined distribution, one symbol (RLE), a distribution sent
  here, or the table the last block with sequences used (repeat). A
  backward bitstream then holds the three initial states and, for each
  sequence, the extra bits of its offset, match length and literal
  length, and the bits of the next states.

  Each sequence copies its literals from the literals section, then
  copies the match from Offset back. An offset value of 1 to 3 picks
  one of the three most recent offsets (shifted by one when the literal
  length is 0; the third is then the most recent minus one); the recent
  offsets are kept across the blocks of a frame.
}
unit Compression.ZstdSequences;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.FiniteStateEntropy,
  Compression.OutputWindows;

type
  TZstdDefaultTables = record
    LiteralLengths: TFseTable;
    Offsets: TFseTable;
    MatchLengths: TFseTable;
  end;

  TZstdSequenceState = record
    { Where tables sent in a block (or RLE ones) are built. }
    LiteralLengthStorage: TFseTable;
    OffsetStorage: TFseTable;
    MatchLengthStorage: TFseTable;
    { The tables in use: a default or a storage; nil before any. }
    LiteralLengths: PFseTable;
    Offsets: PFseTable;
    MatchLengths: PFseTable;
    RepeatOffsets: array[0..2] of SizeUInt;
  end;

procedure BuildZstdDefaultTables(out Tables: TZstdDefaultTables);

{ The state at the start of a frame. }
procedure StartZstdSequences(out State: TZstdSequenceState);

{ Decodes the section (Size bytes at Data) and writes the block's output
  to Window: the sequences with Literals (LiteralCount of them), then
  the literals left. FrameStart is Window.Written when the frame began;
  the block may write at most BlockMaximum bytes, for which Window has
  room. }
function DecodeZstdSequences(Data: PByte; Size: SizeUInt; var State: TZstdSequenceState;
  const Defaults: TZstdDefaultTables; Literals: PByte; LiteralCount: SizeUInt; Window: TOutputWindow;
  FrameStart: QWord; WindowSize: QWord; BlockMaximum: SizeUInt): TCompressionError;

implementation

uses
  Compression.ZstdBitReaders;

const
  MaximumLiteralLengthCode = 35;
  MaximumMatchLengthCode = 52;
  MaximumOffsetCode = 31;
  MaximumLengthAccuracyLog = 9;
  MaximumOffsetAccuracyLog = 8;

  ModePredefined = 0;
  ModeRle = 1;
  ModeCompressed = 2;
  ModeRepeat = 3;

  DefaultLiteralLengthCounts: array[0..35] of SmallInt = (
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1);
  DefaultLiteralLengthAccuracyLog = 6;

  DefaultMatchLengthCounts: array[0..52] of SmallInt = (
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1);
  DefaultMatchLengthAccuracyLog = 6;

  DefaultOffsetCounts: array[0..28] of SmallInt = (
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1);
  DefaultOffsetAccuracyLog = 5;

  LiteralLengthBaselines: array[0..MaximumLiteralLengthCode] of LongWord = (
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
    8192, 16384, 32768, 65536);
  LiteralLengthExtraBits: array[0..MaximumLiteralLengthCode] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
    13, 14, 15, 16);

  MatchLengthBaselines: array[0..MaximumMatchLengthCode] of LongWord = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
    35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
    4099, 8195, 16387, 32771, 65539);
  MatchLengthExtraBits: array[0..MaximumMatchLengthCode] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16);

procedure BuildZstdDefaultTables(out Tables: TZstdDefaultTables);
var
  Distribution: TFseDistribution;
begin
  SetFseDistribution(Distribution, DefaultLiteralLengthCounts, DefaultLiteralLengthAccuracyLog);
  BuildFseTable(Distribution, Tables.LiteralLengths);
  SetFseDistribution(Distribution, DefaultOffsetCounts, DefaultOffsetAccuracyLog);
  BuildFseTable(Distribution, Tables.Offsets);
  SetFseDistribution(Distribution, DefaultMatchLengthCounts, DefaultMatchLengthAccuracyLog);
  BuildFseTable(Distribution, Tables.MatchLengths);
end;

procedure StartZstdSequences(out State: TZstdSequenceState);
begin
  State.LiteralLengths := nil;
  State.Offsets := nil;
  State.MatchLengths := nil;
  State.RepeatOffsets[0] := 1;
  State.RepeatOffsets[1] := 4;
  State.RepeatOffsets[2] := 8;
end;

{ Points Current at the table Mode says, reading what it needs at
  Data[Position]. }
function SelectTable(Mode: Integer; Data: PByte; Size: SizeUInt; var Position: SizeUInt;
  Default: PFseTable; Storage: PFseTable; MaximumSymbol: Integer; MaximumAccuracyLog: Integer;
  var Current: PFseTable): Boolean;
var
  Distribution: TFseDistribution;
  Used: SizeUInt;
begin
  Result := False;
  case Mode of
    ModePredefined:
      Current := Default;
    ModeRle:
      begin
        if (Position >= Size) or (Data[Position] > MaximumSymbol) then
          Exit;
        BuildFseRleTable(Data[Position], Storage^);
        Inc(Position);
        Current := Storage;
      end;
    ModeCompressed:
      begin
        if not ReadFseDistribution(Data + Position, Size - Position, MaximumSymbol, MaximumAccuracyLog,
           Distribution, Used) then
          Exit;
        if not BuildFseTable(Distribution, Storage^) then
          Exit;
        Inc(Position, Used);
        Current := Storage;
      end;
  else
    if Current = nil then
      Exit;
  end;
  Result := True;
end;

function NextState(Table: PFseTable; State: Integer; var Reader: TZstdBackwardReader): Integer;
var
  Entry: ^TFseEntry;
begin
  Entry := @Table^.Entries[State];
  Result := Entry^.Baseline + Integer(Reader.ReadBits(Entry^.BitCount));
end;

{ The offset an offset value stands for, the recent offsets brought up
  to date. 0 for a recent offset that resolves to nothing. }
function ResolveOffset(var State: TZstdSequenceState; OffsetValue: QWord; LiteralLength: SizeUInt): SizeUInt;
var
  Index: Integer;
begin
  if OffsetValue > 3 then
  begin
    Result := OffsetValue - 3;
    State.RepeatOffsets[2] := State.RepeatOffsets[1];
    State.RepeatOffsets[1] := State.RepeatOffsets[0];
    State.RepeatOffsets[0] := Result;
    Exit;
  end;
  Index := OffsetValue - 1;
  if LiteralLength = 0 then
    Inc(Index);
  case Index of
    0: Result := State.RepeatOffsets[0];
    1:
      begin
        Result := State.RepeatOffsets[1];
        State.RepeatOffsets[1] := State.RepeatOffsets[0];
        State.RepeatOffsets[0] := Result;
      end;
    2:
      begin
        Result := State.RepeatOffsets[2];
        State.RepeatOffsets[2] := State.RepeatOffsets[1];
        State.RepeatOffsets[1] := State.RepeatOffsets[0];
        State.RepeatOffsets[0] := Result;
      end;
  else
    begin
      Result := State.RepeatOffsets[0] - 1;
      State.RepeatOffsets[2] := State.RepeatOffsets[1];
      State.RepeatOffsets[1] := State.RepeatOffsets[0];
      State.RepeatOffsets[0] := Result;
    end;
  end;
end;

function DecodeZstdSequences(Data: PByte; Size: SizeUInt; var State: TZstdSequenceState;
  const Defaults: TZstdDefaultTables; Literals: PByte; LiteralCount: SizeUInt; Window: TOutputWindow;
  FrameStart: QWord; WindowSize: QWord; BlockMaximum: SizeUInt): TCompressionError;
var
  Position: SizeUInt;
  SequenceCount: SizeUInt;
  Modes: Byte;
  Reader: TZstdBackwardReader;
  LiteralLengthTable: PFseTable;
  OffsetTable: PFseTable;
  MatchLengthTable: PFseTable;
  LiteralLengthState: Integer;
  OffsetState: Integer;
  MatchLengthState: Integer;
  Sequence: SizeUInt;
  Code: Integer;
  OffsetValue: QWord;
  MatchLength: SizeUInt;
  LiteralLength: SizeUInt;
  Offset: SizeUInt;
  BlockOutput: SizeUInt;
begin
  Result := CompressionErrorCorruptBlock;
  if Size < 1 then
    Exit;
  Position := 1;
  if Data[0] < 128 then
    SequenceCount := Data[0]
  else if Data[0] < 255 then
  begin
    if Size < 2 then
      Exit;
    SequenceCount := ((SizeUInt(Data[0]) - 128) shl 8) + Data[1];
    Position := 2;
  end
  else
  begin
    if Size < 3 then
      Exit;
    SequenceCount := SizeUInt(Data[1]) + (SizeUInt(Data[2]) shl 8) + $7F00;
    Position := 3;
  end;

  BlockOutput := 0;
  if SequenceCount > 0 then
  begin
    if Position >= Size then
      Exit;
    Modes := Data[Position];
    Inc(Position);
    if (Modes and 3) <> 0 then
      Exit;
    if not SelectTable(Modes shr 6, Data, Size, Position, @Defaults.LiteralLengths, @State.LiteralLengthStorage,
       MaximumLiteralLengthCode, MaximumLengthAccuracyLog, State.LiteralLengths) then
      Exit(CompressionErrorInvalidEntropyTable);
    if not SelectTable((Modes shr 4) and 3, Data, Size, Position, @Defaults.Offsets, @State.OffsetStorage,
       MaximumOffsetCode, MaximumOffsetAccuracyLog, State.Offsets) then
      Exit(CompressionErrorInvalidEntropyTable);
    if not SelectTable((Modes shr 2) and 3, Data, Size, Position, @Defaults.MatchLengths,
       @State.MatchLengthStorage, MaximumMatchLengthCode, MaximumLengthAccuracyLog, State.MatchLengths) then
      Exit(CompressionErrorInvalidEntropyTable);
    LiteralLengthTable := State.LiteralLengths;
    OffsetTable := State.Offsets;
    MatchLengthTable := State.MatchLengths;

    if not Reader.Start(Data + Position, Size - Position) then
      Exit;
    LiteralLengthState := Reader.ReadBits(LiteralLengthTable^.AccuracyLog);
    OffsetState := Reader.ReadBits(OffsetTable^.AccuracyLog);
    MatchLengthState := Reader.ReadBits(MatchLengthTable^.AccuracyLog);

    Sequence := 1;
    while Sequence <= SequenceCount do
    begin
      Code := OffsetTable^.Entries[OffsetState].Symbol;
      OffsetValue := (QWord(1) shl Code) + Reader.ReadBits(Code);
      Code := MatchLengthTable^.Entries[MatchLengthState].Symbol;
      MatchLength := MatchLengthBaselines[Code] + Reader.ReadBits(MatchLengthExtraBits[Code]);
      Code := LiteralLengthTable^.Entries[LiteralLengthState].Symbol;
      LiteralLength := LiteralLengthBaselines[Code] + Reader.ReadBits(LiteralLengthExtraBits[Code]);
      if Sequence < SequenceCount then
      begin
        LiteralLengthState := NextState(LiteralLengthTable, LiteralLengthState, Reader);
        MatchLengthState := NextState(MatchLengthTable, MatchLengthState, Reader);
        OffsetState := NextState(OffsetTable, OffsetState, Reader);
      end;
      if Reader.Overflowed then
        Exit;

      if (LiteralLength > LiteralCount) or (LiteralLength + MatchLength > BlockMaximum - BlockOutput) then
        Exit(CompressionErrorLengthBeyondBlock);
      Window.PutBytes(Literals, LiteralLength);
      Inc(Literals, LiteralLength);
      Dec(LiteralCount, LiteralLength);
      Offset := ResolveOffset(State, OffsetValue, LiteralLength);
      if (Offset = 0) or (Offset > Window.Written - FrameStart) or (Offset > WindowSize) then
        Exit(CompressionErrorDistanceTooFar);
      Window.CopyMatch(Offset, MatchLength);
      Inc(BlockOutput, LiteralLength + MatchLength);
      Inc(Sequence);
    end;
    if not Reader.AtStart then
      Exit;
  end;

  if LiteralCount > BlockMaximum - BlockOutput then
    Exit(CompressionErrorLengthBeyondBlock);
  Window.PutBytes(Literals, LiteralCount);
  Result := CompressionErrorNone;
end;

end.
