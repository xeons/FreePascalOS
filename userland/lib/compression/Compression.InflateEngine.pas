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
  The decoder of raw deflate data (RFC 1951): stored, fixed and dynamic
  blocks, fed in pieces of any size.

  Input is the caller's (SetInput); it is read as far as it goes and
  must stay valid until InputRemaining is 0. Bits are gathered in a
  64-bit buffer, a byte at a time where the input is short and eight
  bytes at a time in the fast loop.

  Output goes into a history buffer of 96 KiB: 32 KiB of what came
  before, which matches refer back into, and 64 KiB of room. TakeOutput
  hands what is new to the caller; once all of it is taken and the room
  is used up, the last 32 KiB slide to the start. Decoding stops when
  the buffer is full and goes on once it has been taken.

  The decoder is a state machine that can stop anywhere input runs out:
  in a block header, the code lengths of a dynamic block, between the
  parts of a length and distance, or in the middle of a copy. While at
  least 8 bytes of input and a whole match's room are left, symbols are
  decoded by a tight loop that checks neither.

  Every distance is checked against the output so far, every symbol
  against its alphabet and every code against the rules of the format;
  the first error stops the decoder for good (Error says which).
}
unit Compression.InflateEngine;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.DeflateFormat,
  Compression.HuffmanDecoding;

const
  HistoryRoom = 65536;
  HistoryCapacity = WindowSize + HistoryRoom;

type
  TEngineOutcome = (
    EngineContinue,
    EngineNeedsInput,
    EngineBufferFull,
    EngineDone,
    EngineFailed
  );

  TEngineState = (
    StateBlockHeader,
    StateStoredLength,
    StateStoredCopy,
    StateDynamicCounts,
    StateCodeLengthCodeLengths,
    StateCodeLengths,
    StateCodes,
    StateLengthExtra,
    StateDistance,
    StateDistanceExtra,
    StateCopy,
    StateDone,
    StateFailed
  );

  TPeekOutcome = (PeekDecoded, PeekNeedsInput, PeekInvalid);

  TInflateEngine = class
  private
    FInput: PByte;
    FInputRemaining: SizeInt;
    FBits: QWord;
    FBitCount: Integer;

    FHistory: array[0..HistoryCapacity - 1] of Byte;
    FWritePosition: SizeInt;
    FTakenPosition: SizeInt;
    FTotalOutput: Int64;

    FState: TEngineState;
    FError: TCompressionError;
    FLastBlock: Boolean;
    FStoredRemaining: SizeInt;
    FLiteralLengthCount: Integer;
    FDistanceCount: Integer;
    FCodeLengthCount: Integer;
    FLengthIndex: Integer;
    FCodeLengthCodeLengths: array[0..CodeLengthSymbols - 1] of Byte;
    FCodeLengths: array[0..LiteralLengthSymbols + DistanceSymbols - 1] of Byte;
    FCopyLength: Integer;
    FCopyDistance: Integer;
    FSymbolIndex: Integer;

    FCodeLengthTable: TCodeLengthTable;
    FDynamicLiteralLengthTable: TLiteralLengthTable;
    FDynamicDistanceTable: TDistanceTable;
    FFixedLiteralLengthTable: TLiteralLengthTable;
    FFixedDistanceTable: TDistanceTable;
    FLiteralLengthTable: PDecodeEntry;
    FDistanceTable: PDecodeEntry;

    procedure BuildFixedTables;
    function Fail(Error: TCompressionError): TEngineOutcome;
    function PullByte: Boolean; inline;
    function NeedBits(Count: Integer): Boolean; inline;
    function TakeBits(Count: Integer): LongWord; inline;
    procedure DropBits(Count: Integer); inline;
    function PeekSymbol(Table: PDecodeEntry; RootBits: Integer; out Symbol: Integer;
      out CodeLength: Integer): TPeekOutcome;
    function DecodeSymbol(Table: PDecodeEntry; RootBits: Integer; out Symbol: Integer): TPeekOutcome;
    procedure MakeRoom;
    function RoomLeft: SizeInt; inline;
    procedure CopyMatch(Length: Integer; Distance: Integer);

    function DoBlockHeader: TEngineOutcome;
    function DoStoredLength: TEngineOutcome;
    function DoStoredCopy: TEngineOutcome;
    function DoDynamicCounts: TEngineOutcome;
    function DoCodeLengthCodeLengths: TEngineOutcome;
    function DoCodeLengths: TEngineOutcome;
    function FinishCodeLengths: TEngineOutcome;
    function DoCodes: TEngineOutcome;
    procedure DecodeCodesFast;
    function DoLengthExtra: TEngineOutcome;
    function DoDistance: TEngineOutcome;
    function DoDistanceExtra: TEngineOutcome;
    function DoCopy: TEngineOutcome;
  public
    constructor Create;
    { Back to the start, input and all. }
    procedure Reset;
    { Ready for a new stream that follows in the same input (the next
      gzip member): keeps the input and the bytes read ahead. }
    procedure StartStream;
    procedure SetInput(Data: PByte; Count: SizeInt);
    { Right after StartStream: the data seen as decoded just before the
      stream (a preset dictionary), which matches may refer back into.
      It is not output. }
    procedure SetDictionary(Data: PByte; Count: SizeInt);
    { Decodes until the input runs out, the buffer is full, the last
      block ends or an error is found. }
    function Decode: TEngineOutcome;
    { Copies up to Capacity new bytes to Output; returns how many. }
    function TakeOutput(Output: PByte; Capacity: SizeInt): SizeInt;
    { Bytes decoded but not taken yet. }
    function PendingOutput: SizeInt;
    { Reads a whole byte (after the stream: trailers, the next member);
      bits left over from the last block are dropped first. }
    function ReadByte(out Value: Byte): Boolean;
    { True if a byte is to be had without more input. }
    function HasInput: Boolean;
    { The input not used yet: what is left of it, and the whole bytes
      read ahead into the bit buffer (which came just before it). }
    function UnusedInput: SizeInt;

    property InputRemaining: SizeInt read FInputRemaining;
    property Error: TCompressionError read FError;
    property TotalOutput: Int64 read FTotalOutput;
  end;

implementation

const
  { The fast loop reads 8 bytes at a time; a length and distance pair
    takes at most 15 + 5 + 15 + 13 = 48 bits, a refill gives 56. }
  FastInputMargin = 8;

constructor TInflateEngine.Create;
begin
  inherited Create;
  BuildFixedTables;
  Reset;
end;

procedure TInflateEngine.BuildFixedTables;
var
  LiteralLengths: TLiteralLengthCodeLengths;
  DistanceLengths: TDistanceCodeLengths;
begin
  GetFixedLiteralLengthCodeLengths(LiteralLengths);
  GetFixedDistanceCodeLengths(DistanceLengths);
  BuildDecodeTable(@LiteralLengths[0], LiteralLengthSymbols, LiteralLengthRootBits, @FFixedLiteralLengthTable[0],
    LiteralLengthTableSize, CodeKindSymbols);
  BuildDecodeTable(@DistanceLengths[0], DistanceSymbols, DistanceRootBits, @FFixedDistanceTable[0],
    DistanceTableSize, CodeKindSymbols);
end;

procedure TInflateEngine.SetInput(Data: PByte; Count: SizeInt);
begin
  FInput := Data;
  FInputRemaining := Count;
end;

procedure TInflateEngine.SetDictionary(Data: PByte; Count: SizeInt);
begin
  if (FWritePosition <> 0) or (Count <= 0) then
    Exit;
  if Count > WindowSize then
  begin
    Inc(Data, Count - WindowSize);
    Count := WindowSize;
  end;
  Move(Data^, FHistory[0], Count);
  FWritePosition := Count;
  FTakenPosition := Count;
end;

function TInflateEngine.Fail(Error: TCompressionError): TEngineOutcome;
begin
  FError := Error;
  FState := StateFailed;
  Result := EngineFailed;
end;

function TInflateEngine.PullByte: Boolean;
begin
  Result := FInputRemaining > 0;
  if Result then
  begin
    FBits := FBits or (QWord(FInput^) shl FBitCount);
    Inc(FBitCount, 8);
    Inc(FInput);
    Dec(FInputRemaining);
  end;
end;

function TInflateEngine.NeedBits(Count: Integer): Boolean;
begin
  while FBitCount < Count do
    if not PullByte then
    begin
      Result := False;
      Exit;
    end;
  Result := True;
end;

function TInflateEngine.TakeBits(Count: Integer): LongWord;
begin
  Result := LongWord(FBits and ((QWord(1) shl Count) - 1));
  FBits := FBits shr Count;
  Dec(FBitCount, Count);
end;

procedure TInflateEngine.DropBits(Count: Integer);
begin
  FBits := FBits shr Count;
  Dec(FBitCount, Count);
end;

procedure TInflateEngine.Reset;
begin
  FInput := nil;
  FInputRemaining := 0;
  FBits := 0;
  FBitCount := 0;
  StartStream;
end;

procedure TInflateEngine.StartStream;
begin
  DropBits(FBitCount and 7);
  FWritePosition := 0;
  FTakenPosition := 0;
  FTotalOutput := 0;
  FState := StateBlockHeader;
  FError := CompressionErrorNone;
  FLastBlock := False;
  FStoredRemaining := 0;
  FCopyLength := 0;
  FCopyDistance := 0;
  FLiteralLengthTable := @FFixedLiteralLengthTable[0];
  FDistanceTable := @FFixedDistanceTable[0];
end;

{ Finds the next symbol without taking its bits; reads more input while
  the bits at hand cannot tell. }
function TInflateEngine.PeekSymbol(Table: PDecodeEntry; RootBits: Integer; out Symbol: Integer;
  out CodeLength: Integer): TPeekOutcome;
var
  Entry: TDecodeEntry;
  SubtableIndex: LongWord;
begin
  Symbol := 0;
  CodeLength := 0;
  repeat
    Entry := Table[FBits and ((QWord(1) shl RootBits) - 1)];
    CodeLength := EntryLength(Entry);
    if EntryKind(Entry) = EntryKindLink then
    begin
      SubtableIndex := LongWord(FBits shr RootBits) and ((LongWord(1) shl EntrySubtableBits(Entry)) - 1);
      Entry := Table[EntryValue(Entry) + Integer(SubtableIndex)];
      CodeLength := RootBits + EntryLength(Entry);
    end;
    if CodeLength <= FBitCount then
    begin
      if EntryKind(Entry) = EntryKindInvalid then
        Result := PeekInvalid
      else
      begin
        Symbol := EntryValue(Entry);
        Result := PeekDecoded;
      end;
      Exit;
    end;
  until not PullByte;
  Result := PeekNeedsInput;
end;

function TInflateEngine.DecodeSymbol(Table: PDecodeEntry; RootBits: Integer; out Symbol: Integer): TPeekOutcome;
var
  CodeLength: Integer;
begin
  Result := PeekSymbol(Table, RootBits, Symbol, CodeLength);
  if Result = PeekDecoded then
    DropBits(CodeLength);
end;

function TInflateEngine.RoomLeft: SizeInt;
begin
  Result := HistoryCapacity - FWritePosition;
end;

procedure TInflateEngine.MakeRoom;
begin
  if (FTakenPosition = FWritePosition) and (FWritePosition > WindowSize) and (RoomLeft < MaximumMatch) then
  begin
    Move(FHistory[FWritePosition - WindowSize], FHistory[0], WindowSize);
    FWritePosition := WindowSize;
    FTakenPosition := WindowSize;
  end;
end;

function TInflateEngine.TakeOutput(Output: PByte; Capacity: SizeInt): SizeInt;
begin
  Result := FWritePosition - FTakenPosition;
  if Result > Capacity then
    Result := Capacity;
  if Result > 0 then
  begin
    Move(FHistory[FTakenPosition], Output^, Result);
    Inc(FTakenPosition, Result);
  end;
  MakeRoom;
end;

function TInflateEngine.PendingOutput: SizeInt;
begin
  Result := FWritePosition - FTakenPosition;
end;

function TInflateEngine.HasInput: Boolean;
begin
  Result := (FBitCount >= 8) or (FInputRemaining > 0);
end;

function TInflateEngine.UnusedInput: SizeInt;
begin
  Result := FInputRemaining + FBitCount shr 3;
end;

function TInflateEngine.ReadByte(out Value: Byte): Boolean;
begin
  DropBits(FBitCount and 7);
  if FBitCount >= 8 then
  begin
    Value := Byte(TakeBits(8));
    Result := True;
  end
  else if FInputRemaining > 0 then
  begin
    Value := FInput^;
    Inc(FInput);
    Dec(FInputRemaining);
    Result := True;
  end
  else
  begin
    Value := 0;
    Result := False;
  end;
end;

{ Copies a match within the history: forwards byte by byte when it
  overlaps what it copies (a run), in one move when it does not. }
procedure TInflateEngine.CopyMatch(Length: Integer; Distance: Integer);
var
  Target: PByte;
  Source: PByte;
  Index: Integer;
begin
  Target := @FHistory[FWritePosition];
  Source := Target - Distance;
  if Distance >= Length then
    Move(Source^, Target^, Length)
  else
    for Index := 0 to Length - 1 do
      Target[Index] := Source[Index];
  Inc(FWritePosition, Length);
  Inc(FTotalOutput, Length);
end;

function TInflateEngine.Decode: TEngineOutcome;
begin
  MakeRoom;
  repeat
    case FState of
      StateBlockHeader: Result := DoBlockHeader;
      StateStoredLength: Result := DoStoredLength;
      StateStoredCopy: Result := DoStoredCopy;
      StateDynamicCounts: Result := DoDynamicCounts;
      StateCodeLengthCodeLengths: Result := DoCodeLengthCodeLengths;
      StateCodeLengths: Result := DoCodeLengths;
      StateCodes: Result := DoCodes;
      StateLengthExtra: Result := DoLengthExtra;
      StateDistance: Result := DoDistance;
      StateDistanceExtra: Result := DoDistanceExtra;
      StateCopy: Result := DoCopy;
      StateDone: Result := EngineDone;
    else
      Result := EngineFailed;
    end;
  until Result <> EngineContinue;
end;

{ Each step returns EngineContinue when its state is finished and the
  next one is to run; anything else stops Decode. }

function TInflateEngine.DoBlockHeader: TEngineOutcome;
var
  BlockType: LongWord;
begin
  if FLastBlock then
  begin
    DropBits(FBitCount and 7);
    FState := StateDone;
    Result := EngineContinue;
    Exit;
  end;
  if not NeedBits(3) then
  begin
    Result := EngineNeedsInput;
    Exit;
  end;
  FLastBlock := TakeBits(1) = 1;
  BlockType := TakeBits(2);
  case BlockType of
    BlockStored:
      begin
        DropBits(FBitCount and 7);
        FState := StateStoredLength;
      end;
    BlockFixed:
      begin
        FLiteralLengthTable := @FFixedLiteralLengthTable[0];
        FDistanceTable := @FFixedDistanceTable[0];
        FState := StateCodes;
      end;
    BlockDynamic:
      FState := StateDynamicCounts;
  else
    begin
      Result := Fail(CompressionErrorInvalidBlockType);
      Exit;
    end;
  end;
  Result := EngineContinue;
end;

function TInflateEngine.DoStoredLength: TEngineOutcome;
var
  Length: LongWord;
  Complement: LongWord;
begin
  if not NeedBits(32) then
  begin
    Result := EngineNeedsInput;
    Exit;
  end;
  Length := TakeBits(16);
  Complement := TakeBits(16);
  if Length <> (not Complement and $FFFF) then
  begin
    Result := Fail(CompressionErrorStoredLengthMismatch);
    Exit;
  end;
  FStoredRemaining := Length;
  FState := StateStoredCopy;
  Result := EngineContinue;
end;

function TInflateEngine.DoStoredCopy: TEngineOutcome;
var
  Count: SizeInt;
begin
  while FStoredRemaining > 0 do
  begin
    if RoomLeft = 0 then
    begin
      Result := EngineBufferFull;
      Exit;
    end;
    if FBitCount >= 8 then
    begin
      FHistory[FWritePosition] := Byte(TakeBits(8));
      Inc(FWritePosition);
      Inc(FTotalOutput);
      Dec(FStoredRemaining);
    end
    else if FInputRemaining = 0 then
    begin
      Result := EngineNeedsInput;
      Exit;
    end
    else
    begin
      Count := FStoredRemaining;
      if Count > FInputRemaining then
        Count := FInputRemaining;
      if Count > RoomLeft then
        Count := RoomLeft;
      Move(FInput^, FHistory[FWritePosition], Count);
      Inc(FInput, Count);
      Dec(FInputRemaining, Count);
      Inc(FWritePosition, Count);
      Inc(FTotalOutput, Count);
      Dec(FStoredRemaining, Count);
    end;
  end;
  FState := StateBlockHeader;
  Result := EngineContinue;
end;

function TInflateEngine.DoDynamicCounts: TEngineOutcome;
var
  Index: Integer;
begin
  if not NeedBits(14) then
  begin
    Result := EngineNeedsInput;
    Exit;
  end;
  FLiteralLengthCount := TakeBits(5) + 257;
  FDistanceCount := TakeBits(5) + 1;
  FCodeLengthCount := TakeBits(4) + 4;
  if (FLiteralLengthCount > UsableLiteralLengthSymbols) or (FDistanceCount > UsableDistanceSymbols) then
  begin
    Result := Fail(CompressionErrorTooManyCodes);
    Exit;
  end;
  for Index := 0 to CodeLengthSymbols - 1 do
    FCodeLengthCodeLengths[Index] := 0;
  FSymbolIndex := 0;
  FState := StateCodeLengthCodeLengths;
  Result := EngineContinue;
end;

function TInflateEngine.DoCodeLengthCodeLengths: TEngineOutcome;
begin
  while FSymbolIndex < FCodeLengthCount do
  begin
    if not NeedBits(3) then
    begin
      Result := EngineNeedsInput;
      Exit;
    end;
    FCodeLengthCodeLengths[CodeLengthOrder[FSymbolIndex]] := TakeBits(3);
    Inc(FSymbolIndex);
  end;
  if not BuildDecodeTable(@FCodeLengthCodeLengths[0], CodeLengthSymbols, CodeLengthRootBits, @FCodeLengthTable[0],
    CodeLengthTableSize, CodeKindCodeLengths) then
  begin
    Result := Fail(CompressionErrorInvalidCodeLengths);
    Exit;
  end;
  FSymbolIndex := 0;
  FState := StateCodeLengths;
  Result := EngineContinue;
end;

function TInflateEngine.DoCodeLengths: TEngineOutcome;
var
  Total: Integer;
  Symbol: Integer;
  CodeLength: Integer;
  ExtraBits: Integer;
  RepeatCount: Integer;
  RepeatedLength: Byte;
  Index: Integer;
begin
  Total := FLiteralLengthCount + FDistanceCount;
  while FSymbolIndex < Total do
  begin
    case PeekSymbol(@FCodeLengthTable[0], CodeLengthRootBits, Symbol, CodeLength) of
      PeekNeedsInput:
        begin
          Result := EngineNeedsInput;
          Exit;
        end;
      PeekInvalid:
        begin
          Result := Fail(CompressionErrorInvalidCodeLengths);
          Exit;
        end;
    end;
    if Symbol < RepeatPreviousSymbol then
    begin
      DropBits(CodeLength);
      FCodeLengths[FSymbolIndex] := Symbol;
      Inc(FSymbolIndex);
      Continue;
    end;
    case Symbol of
      RepeatPreviousSymbol: ExtraBits := 2;
      RepeatZeroShortSymbol: ExtraBits := 3;
    else
      ExtraBits := 7;
    end;
    if not NeedBits(CodeLength + ExtraBits) then
    begin
      Result := EngineNeedsInput;
      Exit;
    end;
    DropBits(CodeLength);
    case Symbol of
      RepeatPreviousSymbol:
        begin
          if FSymbolIndex = 0 then
          begin
            Result := Fail(CompressionErrorInvalidRepeat);
            Exit;
          end;
          RepeatedLength := FCodeLengths[FSymbolIndex - 1];
          RepeatCount := 3 + Integer(TakeBits(2));
        end;
      RepeatZeroShortSymbol:
        begin
          RepeatedLength := 0;
          RepeatCount := 3 + Integer(TakeBits(3));
        end;
    else
      begin
        RepeatedLength := 0;
        RepeatCount := 11 + Integer(TakeBits(7));
      end;
    end;
    if FSymbolIndex + RepeatCount > Total then
    begin
      Result := Fail(CompressionErrorInvalidRepeat);
      Exit;
    end;
    for Index := FSymbolIndex to FSymbolIndex + RepeatCount - 1 do
      FCodeLengths[Index] := RepeatedLength;
    Inc(FSymbolIndex, RepeatCount);
  end;
  Result := FinishCodeLengths;
end;

function TInflateEngine.FinishCodeLengths: TEngineOutcome;
begin
  if FCodeLengths[EndOfBlockSymbol] = 0 then
  begin
    Result := Fail(CompressionErrorMissingEndOfBlock);
    Exit;
  end;
  if not BuildDecodeTable(@FCodeLengths[0], FLiteralLengthCount, LiteralLengthRootBits,
    @FDynamicLiteralLengthTable[0], LiteralLengthTableSize, CodeKindSymbols) then
  begin
    Result := Fail(CompressionErrorInvalidCodeLengths);
    Exit;
  end;
  if not BuildDecodeTable(@FCodeLengths[FLiteralLengthCount], FDistanceCount, DistanceRootBits,
    @FDynamicDistanceTable[0], DistanceTableSize, CodeKindSymbols) then
  begin
    Result := Fail(CompressionErrorInvalidCodeLengths);
    Exit;
  end;
  FLiteralLengthTable := @FDynamicLiteralLengthTable[0];
  FDistanceTable := @FDynamicDistanceTable[0];
  FState := StateCodes;
  Result := EngineContinue;
end;

{ The fast loop: decodes symbols while at least FastInputMargin bytes of
  input and a whole match's room are left. Leaves FState as it should go
  on (StateCodes, StateBlockHeader at the end of the block, or
  StateFailed). }
procedure TInflateEngine.DecodeCodesFast;
var
  Bits: QWord;
  BitCount: Integer;
  Input: PByte;
  InputEnd: PByte;
  InputStart: PByte;
  History: PByte;
  Output: PByte;
  OutputLimit: PByte;
  LiteralLengthTable: PDecodeEntry;
  DistanceTable: PDecodeEntry;
  Entry: TDecodeEntry;
  CodeLength: Integer;
  Symbol: Integer;
  Length: Integer;
  Distance: Integer;
  ExtraBits: Integer;
  Taken: Integer;
  GiveBack: SizeInt;
  Source: PByte;
  Index: Integer;
begin
  Bits := FBits;
  BitCount := FBitCount;
  Input := FInput;
  InputStart := FInput;
  InputEnd := FInput + FInputRemaining;
  History := @FHistory[0];
  Output := History + FWritePosition;
  OutputLimit := History + HistoryCapacity - MaximumMatch;
  LiteralLengthTable := FLiteralLengthTable;
  DistanceTable := FDistanceTable;

  while (InputEnd - Input >= FastInputMargin) and (Output <= OutputLimit) do
  begin
    { Refill to at least 56 bits. }
    Bits := Bits or (PQWord(Input)^ shl BitCount);
    Taken := (63 - BitCount) shr 3;
    Inc(Input, Taken);
    BitCount := BitCount or 56;

    Entry := LiteralLengthTable[Bits and ((1 shl LiteralLengthRootBits) - 1)];
    if EntryKind(Entry) = EntryKindLink then
    begin
      Bits := Bits shr LiteralLengthRootBits;
      Dec(BitCount, LiteralLengthRootBits);
      Entry := LiteralLengthTable[EntryValue(Entry) + Integer(Bits and ((QWord(1) shl EntrySubtableBits(Entry)) - 1))];
    end;
    if EntryKind(Entry) = EntryKindInvalid then
    begin
      FError := CompressionErrorInvalidSymbol;
      FState := StateFailed;
      Break;
    end;
    CodeLength := EntryLength(Entry);
    Bits := Bits shr CodeLength;
    Dec(BitCount, CodeLength);
    Symbol := EntryValue(Entry);

    if Symbol < EndOfBlockSymbol then
    begin
      Output^ := Symbol;
      Inc(Output);
      Continue;
    end;
    if Symbol = EndOfBlockSymbol then
    begin
      FState := StateBlockHeader;
      Break;
    end;
    Symbol := Symbol - FirstLengthSymbol;
    if Symbol >= LengthCodeCount then
    begin
      FError := CompressionErrorInvalidSymbol;
      FState := StateFailed;
      Break;
    end;
    ExtraBits := LengthExtraBits[Symbol];
    Length := LengthBase[Symbol] + Integer(Bits and ((QWord(1) shl ExtraBits) - 1));
    Bits := Bits shr ExtraBits;
    Dec(BitCount, ExtraBits);

    Entry := DistanceTable[Bits and ((1 shl DistanceRootBits) - 1)];
    if EntryKind(Entry) = EntryKindLink then
    begin
      Bits := Bits shr DistanceRootBits;
      Dec(BitCount, DistanceRootBits);
      Entry := DistanceTable[EntryValue(Entry) + Integer(Bits and ((QWord(1) shl EntrySubtableBits(Entry)) - 1))];
    end;
    Symbol := EntryValue(Entry);
    if (EntryKind(Entry) = EntryKindInvalid) or (Symbol >= UsableDistanceSymbols) then
    begin
      FError := CompressionErrorInvalidSymbol;
      FState := StateFailed;
      Break;
    end;
    CodeLength := EntryLength(Entry);
    Bits := Bits shr CodeLength;
    Dec(BitCount, CodeLength);
    ExtraBits := DistanceExtraBits[Symbol];
    Distance := DistanceBase[Symbol] + Integer(Bits and ((QWord(1) shl ExtraBits) - 1));
    Bits := Bits shr ExtraBits;
    Dec(BitCount, ExtraBits);

    if Distance > Output - History then
    begin
      FError := CompressionErrorDistanceTooFar;
      FState := StateFailed;
      Break;
    end;
    Source := Output - Distance;
    if Distance >= Length then
      Move(Source^, Output^, Length)
    else
      for Index := 0 to Length - 1 do
        Output[Index] := Source[Index];
    Inc(Output, Length);
  end;

  { Whole bytes read ahead go back to the input, as far as they came
    from this piece of it. }
  GiveBack := BitCount shr 3;
  if GiveBack > Input - InputStart then
    GiveBack := Input - InputStart;
  Dec(Input, GiveBack);
  Dec(BitCount, GiveBack * 8);
  Bits := Bits and ((QWord(1) shl BitCount) - 1);

  FBits := Bits;
  FBitCount := BitCount;
  FInputRemaining := InputEnd - Input;
  FInput := Input;
  Inc(FTotalOutput, (Output - History) - FWritePosition);
  FWritePosition := Output - History;
end;

function TInflateEngine.DoCodes: TEngineOutcome;
var
  Symbol: Integer;
begin
  while True do
  begin
    if (FInputRemaining >= FastInputMargin) and (RoomLeft >= MaximumMatch) then
    begin
      DecodeCodesFast;
      if FState = StateFailed then
      begin
        Result := EngineFailed;
        Exit;
      end;
      if FState <> StateCodes then
      begin
        Result := EngineContinue;
        Exit;
      end;
    end;
    if RoomLeft = 0 then
    begin
      Result := EngineBufferFull;
      Exit;
    end;
    case DecodeSymbol(FLiteralLengthTable, LiteralLengthRootBits, Symbol) of
      PeekNeedsInput:
        begin
          Result := EngineNeedsInput;
          Exit;
        end;
      PeekInvalid:
        begin
          Result := Fail(CompressionErrorInvalidSymbol);
          Exit;
        end;
    end;
    if Symbol < EndOfBlockSymbol then
    begin
      FHistory[FWritePosition] := Symbol;
      Inc(FWritePosition);
      Inc(FTotalOutput);
    end
    else if Symbol = EndOfBlockSymbol then
    begin
      FState := StateBlockHeader;
      Result := EngineContinue;
      Exit;
    end
    else if Symbol - FirstLengthSymbol >= LengthCodeCount then
    begin
      Result := Fail(CompressionErrorInvalidSymbol);
      Exit;
    end
    else
    begin
      FLengthIndex := Symbol - FirstLengthSymbol;
      FState := StateLengthExtra;
      Result := EngineContinue;
      Exit;
    end;
  end;
end;

function TInflateEngine.DoLengthExtra: TEngineOutcome;
var
  ExtraBits: Integer;
begin
  ExtraBits := LengthExtraBits[FLengthIndex];
  if not NeedBits(ExtraBits) then
  begin
    Result := EngineNeedsInput;
    Exit;
  end;
  FCopyLength := LengthBase[FLengthIndex] + Integer(TakeBits(ExtraBits));
  FState := StateDistance;
  Result := EngineContinue;
end;

function TInflateEngine.DoDistance: TEngineOutcome;
var
  Symbol: Integer;
begin
  case DecodeSymbol(FDistanceTable, DistanceRootBits, Symbol) of
    PeekNeedsInput:
      begin
        Result := EngineNeedsInput;
        Exit;
      end;
    PeekInvalid:
      begin
        Result := Fail(CompressionErrorInvalidSymbol);
        Exit;
      end;
  end;
  if Symbol >= UsableDistanceSymbols then
  begin
    Result := Fail(CompressionErrorInvalidSymbol);
    Exit;
  end;
  FLengthIndex := Symbol;
  FState := StateDistanceExtra;
  Result := EngineContinue;
end;

function TInflateEngine.DoDistanceExtra: TEngineOutcome;
var
  ExtraBits: Integer;
begin
  ExtraBits := DistanceExtraBits[FLengthIndex];
  if not NeedBits(ExtraBits) then
  begin
    Result := EngineNeedsInput;
    Exit;
  end;
  FCopyDistance := DistanceBase[FLengthIndex] + Integer(TakeBits(ExtraBits));
  if FCopyDistance > FWritePosition then
  begin
    Result := Fail(CompressionErrorDistanceTooFar);
    Exit;
  end;
  FState := StateCopy;
  Result := EngineContinue;
end;

function TInflateEngine.DoCopy: TEngineOutcome;
var
  Count: Integer;
begin
  Count := FCopyLength;
  if Count > RoomLeft then
    Count := RoomLeft;
  if Count > 0 then
  begin
    CopyMatch(Count, FCopyDistance);
    Dec(FCopyLength, Count);
  end;
  if FCopyLength > 0 then
  begin
    Result := EngineBufferFull;
    Exit;
  end;
  FState := StateCodes;
  Result := EngineContinue;
end;

end.
