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
  The compressor's blocks. TDeflateBlock collects a block's symbols
  (literals, and lengths with distances) and counts how often each code
  is used; WriteBlock then sends it the cheapest of three ways, worked
  out to the bit:

    dynamic  Huffman codes made for this block, sent in its header (the
             code lengths run-length coded with symbols 16, 17 and 18,
             and Huffman coded themselves)
    fixed    the codes of the standard (no header)
    stored   the bytes as they are, when the block's input is still at
             hand and nothing else is smaller (a stored block holds at
             most 65535 bytes, so long ones are sent as several)
}
unit Compression.DeflateBlocks;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.DeflateFormat,
  Compression.HuffmanEncoding,
  Compression.BitWriter;

const
  BlockSymbolCapacity = 32768;
  LongestStoredBlock = 65535;

type
  TDeflateBlock = class
  private
    FSymbols: array[0..BlockSymbolCapacity - 1] of LongWord;
    FCount: Integer;
    FLiteralLengthFrequencies: array[0..LiteralLengthSymbols - 1] of LongWord;
    FDistanceFrequencies: array[0..DistanceSymbols - 1] of LongWord;
  public
    constructor Create;
    procedure Clear;
    procedure AddLiteral(Value: Byte); inline;
    { A match of Length (3 to 258) bytes Distance (1 to 32768) back. }
    procedure AddMatch(Length: Integer; Distance: Integer);
    function IsFull: Boolean; inline;
    property Count: Integer read FCount;
  end;

{ Sends Block. RawData and RawLength are the input the block stands
  for; RawData is nil if it is no longer at hand. }
procedure WriteBlock(Writer: TBitWriter; Block: TDeflateBlock; RawData: PByte; RawLength: SizeInt; IsLast: Boolean);
{ Sends Data as stored blocks (one empty one if Count is 0). }
procedure WriteStoredBlocks(Writer: TBitWriter; Data: PByte; Count: SizeInt; IsLast: Boolean);

implementation

const
  MatchFlag = LongWord($80000000);

type
  TCodeLengthRun = record
    Symbol: Byte;
    ExtraValue: Byte;
  end;

  TDynamicHeader = record
    LiteralLengthLengths: array[0..LiteralLengthSymbols - 1] of Byte;
    DistanceLengths: array[0..DistanceSymbols - 1] of Byte;
    LiteralLengthCount: Integer;
    DistanceCount: Integer;
    Runs: array[0..LiteralLengthSymbols + DistanceSymbols - 1] of TCodeLengthRun;
    RunCount: Integer;
    CodeLengthFrequencies: array[0..CodeLengthSymbols - 1] of LongWord;
    CodeLengthLengths: array[0..CodeLengthSymbols - 1] of Byte;
    CodeLengthCodes: array[0..CodeLengthSymbols - 1] of Word;
    CodeLengthCount: Integer;
  end;

  TBlockCodes = record
    LiteralLengthLengths: array[0..LiteralLengthSymbols - 1] of Byte;
    LiteralLengthCodes: array[0..LiteralLengthSymbols - 1] of Word;
    DistanceLengths: array[0..DistanceSymbols - 1] of Byte;
    DistanceCodes: array[0..DistanceSymbols - 1] of Word;
  end;

var
  CodeTablesReady: Boolean = False;
  { length - 3 -> length code (0..28) }
  LengthCodeOf: array[0..255] of Byte;
  { distance - 1 -> distance code: below 256 directly, above by
    256 + (distance - 1) div 128 }
  DistanceCodeOf: array[0..511] of Byte;

procedure PrepareCodeTables;
var
  Code: Integer;
  Offset: Integer;
  Distance: Integer;
begin
  for Code := 0 to LengthCodeCount - 2 do
    for Offset := 0 to (1 shl LengthExtraBits[Code]) - 1 do
      LengthCodeOf[LengthBase[Code] - MinimumMatch + Offset] := Code;
  LengthCodeOf[MaximumMatch - MinimumMatch] := LengthCodeCount - 1;
  for Code := 0 to UsableDistanceSymbols - 1 do
    for Offset := 0 to (1 shl DistanceExtraBits[Code]) - 1 do
    begin
      Distance := DistanceBase[Code] + Offset - 1;
      if Distance < 256 then
        DistanceCodeOf[Distance] := Code
      else
        DistanceCodeOf[256 + (Distance shr 7)] := Code;
    end;
  CodeTablesReady := True;
end;

function DistanceCode(Distance: Integer): Integer; inline;
begin
  Dec(Distance);
  if Distance < 256 then
    Result := DistanceCodeOf[Distance]
  else
    Result := DistanceCodeOf[256 + (Distance shr 7)];
end;

constructor TDeflateBlock.Create;
begin
  inherited Create;
  if not CodeTablesReady then
    PrepareCodeTables;
  Clear;
end;

procedure TDeflateBlock.Clear;
begin
  FCount := 0;
  FillChar(FLiteralLengthFrequencies, SizeOf(FLiteralLengthFrequencies), 0);
  FillChar(FDistanceFrequencies, SizeOf(FDistanceFrequencies), 0);
end;

procedure TDeflateBlock.AddLiteral(Value: Byte);
begin
  FSymbols[FCount] := Value;
  Inc(FCount);
  Inc(FLiteralLengthFrequencies[Value]);
end;

procedure TDeflateBlock.AddMatch(Length: Integer; Distance: Integer);
begin
  FSymbols[FCount] := MatchFlag or (LongWord(Length - MinimumMatch) shl 16) or LongWord(Distance - 1);
  Inc(FCount);
  Inc(FLiteralLengthFrequencies[FirstLengthSymbol + LengthCodeOf[Length - MinimumMatch]]);
  Inc(FDistanceFrequencies[DistanceCode(Distance)]);
end;

function TDeflateBlock.IsFull: Boolean;
begin
  Result := FCount >= BlockSymbolCapacity;
end;

{ The run-length coded code lengths of a dynamic header. }
procedure AddRun(var Header: TDynamicHeader; Symbol: Integer; ExtraValue: Integer);
begin
  Header.Runs[Header.RunCount].Symbol := Symbol;
  Header.Runs[Header.RunCount].ExtraValue := ExtraValue;
  Inc(Header.RunCount);
  Inc(Header.CodeLengthFrequencies[Symbol]);
end;

procedure EncodeCodeLengths(var Header: TDynamicHeader);
var
  AllLengths: array[0..LiteralLengthSymbols + DistanceSymbols - 1] of Byte;
  Total: Integer;
  Index: Integer;
  RunLength: Integer;
  Piece: Integer;
  Current: Byte;
begin
  Total := Header.LiteralLengthCount + Header.DistanceCount;
  Move(Header.LiteralLengthLengths[0], AllLengths[0], Header.LiteralLengthCount);
  Move(Header.DistanceLengths[0], AllLengths[Header.LiteralLengthCount], Header.DistanceCount);
  Header.RunCount := 0;
  FillChar(Header.CodeLengthFrequencies, SizeOf(Header.CodeLengthFrequencies), 0);
  Index := 0;
  while Index < Total do
  begin
    Current := AllLengths[Index];
    RunLength := 1;
    while (Index + RunLength < Total) and (AllLengths[Index + RunLength] = Current) do
      Inc(RunLength);
    Inc(Index, RunLength);
    if Current = 0 then
    begin
      while RunLength >= 11 do
      begin
        Piece := RunLength;
        if Piece > 138 then
          Piece := 138;
        AddRun(Header, RepeatZeroLongSymbol, Piece - 11);
        Dec(RunLength, Piece);
      end;
      if RunLength >= 3 then
      begin
        AddRun(Header, RepeatZeroShortSymbol, RunLength - 3);
        RunLength := 0;
      end;
    end
    else
    begin
      AddRun(Header, Current, 0);
      Dec(RunLength);
      while RunLength >= 3 do
      begin
        Piece := RunLength;
        if Piece > 6 then
          Piece := 6;
        AddRun(Header, RepeatPreviousSymbol, Piece - 3);
        Dec(RunLength, Piece);
      end;
    end;
    while RunLength > 0 do
    begin
      AddRun(Header, Current, 0);
      Dec(RunLength);
    end;
  end;
end;

function RunExtraBits(Symbol: Integer): Integer;
begin
  case Symbol of
    RepeatPreviousSymbol: Result := 2;
    RepeatZeroShortSymbol: Result := 3;
    RepeatZeroLongSymbol: Result := 7;
  else
    Result := 0;
  end;
end;

procedure PrepareDynamicHeader(var Header: TDynamicHeader; const Codes: TBlockCodes);
begin
  Move(Codes.LiteralLengthLengths, Header.LiteralLengthLengths, SizeOf(Header.LiteralLengthLengths));
  Move(Codes.DistanceLengths, Header.DistanceLengths, SizeOf(Header.DistanceLengths));
  Header.LiteralLengthCount := UsableLiteralLengthSymbols;
  while (Header.LiteralLengthCount > FirstLengthSymbol) and
    (Header.LiteralLengthLengths[Header.LiteralLengthCount - 1] = 0) do
    Dec(Header.LiteralLengthCount);
  Header.DistanceCount := UsableDistanceSymbols;
  while (Header.DistanceCount > 1) and (Header.DistanceLengths[Header.DistanceCount - 1] = 0) do
    Dec(Header.DistanceCount);
  EncodeCodeLengths(Header);
  BuildCodeLengths(@Header.CodeLengthFrequencies[0], CodeLengthSymbols, MaximumCodeLengthCodeLength,
    @Header.CodeLengthLengths[0]);
  BuildCanonicalCodes(@Header.CodeLengthLengths[0], CodeLengthSymbols, @Header.CodeLengthCodes[0]);
  Header.CodeLengthCount := CodeLengthSymbols;
  while (Header.CodeLengthCount > 4) and (Header.CodeLengthLengths[CodeLengthOrder[Header.CodeLengthCount - 1]] = 0) do
    Dec(Header.CodeLengthCount);
end;

function DynamicHeaderBits(const Header: TDynamicHeader): QWord;
var
  Index: Integer;
  Symbol: Integer;
begin
  Result := 5 + 5 + 4 + 3 * QWord(Header.CodeLengthCount);
  for Index := 0 to Header.RunCount - 1 do
  begin
    Symbol := Header.Runs[Index].Symbol;
    Inc(Result, Header.CodeLengthLengths[Symbol] + RunExtraBits(Symbol));
  end;
end;

{ The bits the block's symbols take with the given code lengths. }
function SymbolBits(Block: TDeflateBlock; LiteralLengthLengths: PByte; DistanceLengths: PByte): QWord;
var
  Symbol: Integer;
begin
  Result := 0;
  for Symbol := 0 to LiteralLengthSymbols - 1 do
    if Block.FLiteralLengthFrequencies[Symbol] > 0 then
    begin
      Inc(Result, QWord(Block.FLiteralLengthFrequencies[Symbol]) * LiteralLengthLengths[Symbol]);
      if Symbol >= FirstLengthSymbol then
        Inc(Result, QWord(Block.FLiteralLengthFrequencies[Symbol]) * LengthExtraBits[Symbol - FirstLengthSymbol]);
    end;
  for Symbol := 0 to UsableDistanceSymbols - 1 do
    if Block.FDistanceFrequencies[Symbol] > 0 then
      Inc(Result, QWord(Block.FDistanceFrequencies[Symbol]) * (DistanceLengths[Symbol] + DistanceExtraBits[Symbol]));
end;

function StoredBits(RawLength: SizeInt): QWord;
var
  Pieces: QWord;
begin
  Pieces := (RawLength + LongestStoredBlock - 1) div LongestStoredBlock;
  if Pieces = 0 then
    Pieces := 1;
  { Each piece: 3 header bits padded to a byte (at most 7 bits more for
    the first), then the length and its complement. }
  Result := 7 + Pieces * (8 + 32) + QWord(RawLength) * 8;
end;

procedure WriteDynamicHeader(Writer: TBitWriter; const Header: TDynamicHeader);
var
  Index: Integer;
  Symbol: Integer;
begin
  Writer.WriteBits(Header.LiteralLengthCount - FirstLengthSymbol, 5);
  Writer.WriteBits(Header.DistanceCount - 1, 5);
  Writer.WriteBits(Header.CodeLengthCount - 4, 4);
  for Index := 0 to Header.CodeLengthCount - 1 do
    Writer.WriteBits(Header.CodeLengthLengths[CodeLengthOrder[Index]], 3);
  for Index := 0 to Header.RunCount - 1 do
  begin
    Symbol := Header.Runs[Index].Symbol;
    Writer.WriteBits(Header.CodeLengthCodes[Symbol], Header.CodeLengthLengths[Symbol]);
    if RunExtraBits(Symbol) > 0 then
      Writer.WriteBits(Header.Runs[Index].ExtraValue, RunExtraBits(Symbol));
  end;
end;

procedure WriteSymbols(Writer: TBitWriter; Block: TDeflateBlock; const Codes: TBlockCodes);
var
  Index: Integer;
  Symbol: LongWord;
  LengthOffset: Integer;
  Distance: Integer;
  Code: Integer;
begin
  for Index := 0 to Block.FCount - 1 do
  begin
    Symbol := Block.FSymbols[Index];
    if (Symbol and MatchFlag) = 0 then
    begin
      Writer.WriteBits(Codes.LiteralLengthCodes[Symbol], Codes.LiteralLengthLengths[Symbol]);
      Continue;
    end;
    LengthOffset := (Symbol shr 16) and $FF;
    Code := LengthCodeOf[LengthOffset];
    Writer.WriteBits(Codes.LiteralLengthCodes[FirstLengthSymbol + Code],
      Codes.LiteralLengthLengths[FirstLengthSymbol + Code]);
    if LengthExtraBits[Code] > 0 then
      Writer.WriteBits(LengthOffset + MinimumMatch - LengthBase[Code], LengthExtraBits[Code]);
    Distance := (Symbol and $FFFF) + 1;
    Code := DistanceCode(Distance);
    Writer.WriteBits(Codes.DistanceCodes[Code], Codes.DistanceLengths[Code]);
    if DistanceExtraBits[Code] > 0 then
      Writer.WriteBits(Distance - DistanceBase[Code], DistanceExtraBits[Code]);
  end;
  Writer.WriteBits(Codes.LiteralLengthCodes[EndOfBlockSymbol], Codes.LiteralLengthLengths[EndOfBlockSymbol]);
end;

procedure WriteStoredBlocks(Writer: TBitWriter; Data: PByte; Count: SizeInt; IsLast: Boolean);
var
  Piece: SizeInt;
  LastPiece: Boolean;
begin
  repeat
    Piece := Count;
    if Piece > LongestStoredBlock then
      Piece := LongestStoredBlock;
    LastPiece := Piece = Count;
    Writer.WriteBits(Ord(IsLast and LastPiece) or (BlockStored shl 1), 3);
    Writer.AlignToByte;
    Writer.WriteBits(Piece, 16);
    Writer.WriteBits(not LongWord(Piece) and $FFFF, 16);
    Writer.WriteBytes(Data, Piece);
    Inc(Data, Piece);
    Dec(Count, Piece);
  until LastPiece;
end;

procedure WriteBlock(Writer: TBitWriter; Block: TDeflateBlock; RawData: PByte; RawLength: SizeInt; IsLast: Boolean);
var
  Header: TDynamicHeader;
  Dynamic: TBlockCodes;
  Fixed: TBlockCodes;
  DynamicCost: QWord;
  FixedCost: QWord;
  StoredCost: QWord;
begin
  Inc(Block.FLiteralLengthFrequencies[EndOfBlockSymbol]);

  BuildCodeLengths(@Block.FLiteralLengthFrequencies[0], LiteralLengthSymbols, MaximumCodeLength,
    @Dynamic.LiteralLengthLengths[0]);
  BuildCodeLengths(@Block.FDistanceFrequencies[0], DistanceSymbols, MaximumCodeLength, @Dynamic.DistanceLengths[0]);
  BuildCanonicalCodes(@Dynamic.LiteralLengthLengths[0], LiteralLengthSymbols, @Dynamic.LiteralLengthCodes[0]);
  BuildCanonicalCodes(@Dynamic.DistanceLengths[0], DistanceSymbols, @Dynamic.DistanceCodes[0]);
  PrepareDynamicHeader(Header, Dynamic);
  DynamicCost := 3 + DynamicHeaderBits(Header) + SymbolBits(Block, @Dynamic.LiteralLengthLengths[0],
    @Dynamic.DistanceLengths[0]);

  GetFixedLiteralLengthCodeLengths(Fixed.LiteralLengthLengths);
  GetFixedDistanceCodeLengths(Fixed.DistanceLengths);
  BuildCanonicalCodes(@Fixed.LiteralLengthLengths[0], LiteralLengthSymbols, @Fixed.LiteralLengthCodes[0]);
  BuildCanonicalCodes(@Fixed.DistanceLengths[0], DistanceSymbols, @Fixed.DistanceCodes[0]);
  FixedCost := 3 + SymbolBits(Block, @Fixed.LiteralLengthLengths[0], @Fixed.DistanceLengths[0]);

  if RawData <> nil then
    StoredCost := StoredBits(RawLength)
  else
    StoredCost := High(QWord);

  if (StoredCost <= FixedCost) and (StoredCost <= DynamicCost) then
    WriteStoredBlocks(Writer, RawData, RawLength, IsLast)
  else if FixedCost <= DynamicCost then
  begin
    Writer.WriteBits(Ord(IsLast) or (BlockFixed shl 1), 3);
    WriteSymbols(Writer, Block, Fixed);
  end
  else
  begin
    Writer.WriteBits(Ord(IsLast) or (BlockDynamic shl 1), 3);
    WriteDynamicHeader(Writer, Header);
    WriteSymbols(Writer, Block, Dynamic);
  end;
end;

end.
