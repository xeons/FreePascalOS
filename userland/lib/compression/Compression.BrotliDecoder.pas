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
  TBrotliDecoder: brotli (RFC 7932) decompression, fed and taken in
  pieces of any size (the TStreamingDecoder contract).

  The stream is decoded in steps small enough to read again whole: a
  header field, one prefix code, a context map, a block switch, a
  command (its insert and copy lengths), one literal, a distance. When
  the input runs out inside a step, the step is undone and the bytes it
  had begun on are kept (Compression.BrotliBitReader) until the next
  piece comes. Copies, dictionary words and uncompressed meta-blocks go
  out as far as the caller's buffer allows and carry on in the next
  call.

  The output goes through a window that grows with the output up to the
  stream's window size (at most 16 MiB). DecompressFinished comes after
  the last meta-block and its padding; what follows the stream is left
  alone (InputRemaining).
}
unit Compression.BrotliDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.HuffmanDecoding,
  Compression.StreamingDecoders,
  Compression.OutputWindows,
  Compression.BrotliBitReader,
  Compression.BrotliPrefixCodes,
  Compression.BrotliMetaBlocks,
  Compression.BrotliTransforms;

type
  TBrotliPhase = (BrotliPhaseStreamHeader, BrotliPhaseMetaBlockStart, BrotliPhaseMetadata, BrotliPhaseUncompressed,
    BrotliPhaseBlockTypes, BrotliPhaseDistanceParameters, BrotliPhaseLiteralContextMap,
    BrotliPhaseDistanceTreeCount, BrotliPhaseDistanceContextMap, BrotliPhaseTrees, BrotliPhaseCommand,
    BrotliPhaseLiterals, BrotliPhaseDistance, BrotliPhaseCopy, BrotliPhaseMetaBlockEnd, BrotliPhaseStreamEnd,
    BrotliPhaseFinished, BrotliPhaseFailed);

  { Why decoding stopped. }
  TBrotliStop = (BrotliStopNone, BrotliStopNeedsInput, BrotliStopBudget, BrotliStopFinished, BrotliStopFailed);

  TBrotliStep = function: TCompressionError of object;

  TBrotliDecoder = class(TStreamingDecoder)
  private
    FPhase: TBrotliPhase;
    FReader: TBrotliBitReader;
    FWindow: TOutputWindow;
    { The farthest a copy may reach back: (1 shl WBITS) - 16. }
    FWindowSize: LongWord;
    FMetaBlock: TBrotliMetaBlock;
    FTable: TBrotliTableBuffer;
    FLastMetaBlock: Boolean;
    { Bytes of the meta-block (or its metadata) still to come. }
    FMetaBlockRemaining: LongWord;
    FCategory: Integer;
    FCategoryStage: Integer;
    FTreeGroup: Integer;
    FInsertRemaining: LongWord;
    FCopyLength: LongWord;
    FImplicitDistance: Boolean;
    FDistance: LongWord;
    FCopyRemaining: LongWord;
    FCopyFromWord: Boolean;
    FWord: array[0..BrotliLongestTransformedWord - 1] of Byte;
    FWordPosition: Integer;
    { The last four distances, the last first. }
    FDistances: array[0..3] of LongInt;
    { What this call may still write. }
    FBudget: SizeUInt;
    function Fail(Code: TCompressionError): TDecompressResult;
    function Attempt(Step: TBrotliStep): TBrotliStop;
    function Run: TBrotliStop;
    function StepStreamHeader: TCompressionError;
    function StepMetaBlockStart: TCompressionError;
    function StepBlockTypes: TCompressionError;
    function StepDistanceParameters: TCompressionError;
    function StepLiteralContextMap: TCompressionError;
    function StepDistanceTreeCount: TCompressionError;
    function StepDistanceContextMap: TCompressionError;
    function StepTree: TCompressionError;
    function StepCommandSwitch: TCompressionError;
    function StepLiteralSwitch: TCompressionError;
    function StepDistanceSwitch: TCompressionError;
    function StepCommand: TCompressionError;
    function StepDistance: TCompressionError;
    function StepStreamEnd: TCompressionError;
    function SwitchCategory(Index: Integer): TCompressionError;
    procedure StartTrees;
    function ResolveCopy(PushDistance: Boolean): TCompressionError;
    function DecodeLiterals: TBrotliStop;
    function CopyOut: TBrotliStop;
    function SkipMetadata: TBrotliStop;
    function CopyUncompressed: TBrotliStop;
  protected
    function GetFinished: Boolean; override;
    function GetInputRemaining: SizeInt; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset; override;
    procedure SetInput(Data: Pointer; Count: SizeInt); override;
    function Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult; override;
  end;

implementation

uses
  Compression.BrotliTables,
  Compression.BrotliContextMaps,
  Compression.BrotliDictionary;

const
  { Distance codes 4 to 15: the last (4 to 9) or second last (10 to 15)
    distance and this added. }
  ShortCodeAdjustments: array[0..15] of LongInt = (0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3);

constructor TBrotliDecoder.Create;
begin
  inherited Create;
  FWindow := TOutputWindow.Create;
  Reset;
end;

destructor TBrotliDecoder.Destroy;
begin
  FWindow.Free;
  inherited Destroy;
end;

procedure TBrotliDecoder.Reset;
begin
  FPhase := BrotliPhaseStreamHeader;
  FError := CompressionErrorNone;
  FTotalOutput := 0;
  FReader.Reset;
  FWindow.Start(64);
  FWindowSize := 0;
  FLastMetaBlock := False;
  FMetaBlockRemaining := 0;
  FDistances[0] := 4;
  FDistances[1] := 11;
  FDistances[2] := 15;
  FDistances[3] := 16;
end;

procedure TBrotliDecoder.SetInput(Data: Pointer; Count: SizeInt);
begin
  FReader.SetInput(Data, Count);
end;

function TBrotliDecoder.GetFinished: Boolean;
begin
  Result := FPhase = BrotliPhaseFinished;
end;

function TBrotliDecoder.GetInputRemaining: SizeInt;
begin
  Result := FReader.BytesLeft;
end;

function TBrotliDecoder.Fail(Code: TCompressionError): TDecompressResult;
begin
  FError := Code;
  FPhase := BrotliPhaseFailed;
  Result := DecompressFailed;
end;

{ Runs one step; if the input ran out inside it, undoes it and keeps
  the bytes it had begun on. }
function TBrotliDecoder.Attempt(Step: TBrotliStep): TBrotliStop;
var
  Mark: TBrotliReaderMark;
  SavedPhase: TBrotliPhase;
  Code: TCompressionError;
begin
  Mark := FReader.Save;
  SavedPhase := FPhase;
  Code := Step();
  if FReader.Overrun then
  begin
    FReader.Restore(Mark);
    FReader.KeepUnread;
    FPhase := SavedPhase;
    Exit(BrotliStopNeedsInput);
  end;
  if Code <> CompressionErrorNone then
  begin
    FError := Code;
    FPhase := BrotliPhaseFailed;
    Exit(BrotliStopFailed);
  end;
  Result := BrotliStopNone;
end;

function TBrotliDecoder.StepStreamHeader: TCompressionError;
var
  WindowBits: Integer;
begin
  Result := ReadBrotliWindowBits(FReader, WindowBits);
  if FReader.Overrun or (Result <> CompressionErrorNone) then
    Exit;
  FWindow.Start(LongWord(1) shl WindowBits);
  FWindowSize := (LongWord(1) shl WindowBits) - 16;
  FPhase := BrotliPhaseMetaBlockStart;
end;

function TBrotliDecoder.StepMetaBlockStart: TCompressionError;
var
  Start: TBrotliMetaBlockStart;
begin
  Result := ReadBrotliMetaBlockStart(FReader, Start);
  if FReader.Overrun or (Result <> CompressionErrorNone) then
    Exit;
  FLastMetaBlock := Start.IsLast;
  FMetaBlockRemaining := Start.Length;
  if Start.EndsStream then
    FPhase := BrotliPhaseStreamEnd
  else if Start.IsMetadata then
    FPhase := BrotliPhaseMetadata
  else if Start.IsUncompressed then
    FPhase := BrotliPhaseUncompressed
  else
  begin
    FCategory := BrotliLiteralCategory;
    FCategoryStage := 0;
    FPhase := BrotliPhaseBlockTypes;
  end;
end;

{ One stage of a block category: its number of types, then (with more
  than one) its two codes and its first count. }
function TBrotliDecoder.StepBlockTypes: TCompressionError;
var
  Category: ^TBrotliBlockCategory;
  Count: LongWord;
  NextCategory: Boolean;
begin
  Result := CompressionErrorNone;
  Category := @FMetaBlock.Categories[FCategory];
  NextCategory := False;
  case FCategoryStage of
    0:
      begin
        Count := ReadBrotliTypeCount(FReader);
        if FReader.Overrun then
          Exit;
        StartBlockCategory(Category^, Count);
        if Count >= 2 then
          FCategoryStage := 1
        else
          NextCategory := True;
      end;
    1:
      begin
        Result := ReadCategoryTypeCode(FReader, Category^, FTable);
        if FReader.Overrun or (Result <> CompressionErrorNone) then
          Exit;
        FCategoryStage := 2;
      end;
    2:
      begin
        Result := ReadCategoryCountCode(FReader, Category^, FTable);
        if FReader.Overrun or (Result <> CompressionErrorNone) then
          Exit;
        FCategoryStage := 3;
      end;
  else
    begin
      Count := ReadBlockCount(FReader, Category^);
      if FReader.Overrun then
        Exit;
      Category^.Remaining := Count;
      NextCategory := True;
    end;
  end;
  if NextCategory then
  begin
    Inc(FCategory);
    FCategoryStage := 0;
    if FCategory > BrotliDistanceCategory then
      FPhase := BrotliPhaseDistanceParameters;
  end;
end;

function TBrotliDecoder.StepDistanceParameters: TCompressionError;
var
  Size: Integer;
begin
  Result := CompressionErrorNone;
  ReadDistanceParameters(FReader, FMetaBlock);
  if FReader.Overrun then
    Exit;
  Size := BrotliLiteralContexts * FMetaBlock.Categories[BrotliLiteralCategory].TypeCount;
  if Length(FMetaBlock.LiteralContextMap) < Size then
    SetLength(FMetaBlock.LiteralContextMap, Size);
  if FMetaBlock.LiteralTreeCount >= 2 then
    FPhase := BrotliPhaseLiteralContextMap
  else
  begin
    FillChar(FMetaBlock.LiteralContextMap[0], Size, 0);
    FPhase := BrotliPhaseDistanceTreeCount;
  end;
end;

function TBrotliDecoder.StepLiteralContextMap: TCompressionError;
begin
  Result := ReadBrotliContextMap(FReader, FMetaBlock.LiteralTreeCount,
    BrotliLiteralContexts * FMetaBlock.Categories[BrotliLiteralCategory].TypeCount,
    @FMetaBlock.LiteralContextMap[0], FTable);
  if FReader.Overrun or (Result <> CompressionErrorNone) then
    Exit;
  FPhase := BrotliPhaseDistanceTreeCount;
end;

function TBrotliDecoder.StepDistanceTreeCount: TCompressionError;
var
  Size: Integer;
begin
  Result := CompressionErrorNone;
  FMetaBlock.DistanceTreeCount := ReadBrotliTypeCount(FReader);
  if FReader.Overrun then
    Exit;
  Size := BrotliDistanceContexts * FMetaBlock.Categories[BrotliDistanceCategory].TypeCount;
  if Length(FMetaBlock.DistanceContextMap) < Size then
    SetLength(FMetaBlock.DistanceContextMap, Size);
  if FMetaBlock.DistanceTreeCount >= 2 then
    FPhase := BrotliPhaseDistanceContextMap
  else
  begin
    FillChar(FMetaBlock.DistanceContextMap[0], Size, 0);
    StartTrees;
  end;
end;

function TBrotliDecoder.StepDistanceContextMap: TCompressionError;
begin
  Result := ReadBrotliContextMap(FReader, FMetaBlock.DistanceTreeCount,
    BrotliDistanceContexts * FMetaBlock.Categories[BrotliDistanceCategory].TypeCount,
    @FMetaBlock.DistanceContextMap[0], FTable);
  if FReader.Overrun or (Result <> CompressionErrorNone) then
    Exit;
  StartTrees;
end;

procedure TBrotliDecoder.StartTrees;
begin
  StartTreeGroup(FMetaBlock.LiteralTrees, BrotliLiteralAlphabet, FMetaBlock.LiteralTreeCount);
  StartTreeGroup(FMetaBlock.CommandTrees, BrotliCommandAlphabet,
    FMetaBlock.Categories[BrotliCommandCategory].TypeCount);
  StartTreeGroup(FMetaBlock.DistanceTrees, FMetaBlock.DistanceAlphabet, FMetaBlock.DistanceTreeCount);
  FTreeGroup := 0;
  FPhase := BrotliPhaseTrees;
end;

{ One prefix code of the literal, command or distance trees. }
function TBrotliDecoder.StepTree: TCompressionError;
var
  Group: ^TBrotliTreeGroup;
  Used: Integer;
begin
  case FTreeGroup of
    0: Group := @FMetaBlock.LiteralTrees;
    1: Group := @FMetaBlock.CommandTrees;
  else
    Group := @FMetaBlock.DistanceTrees;
  end;
  Result := ReadBrotliPrefixCode(FReader, Group^.AlphabetSize, FTable, Used);
  if FReader.Overrun or (Result <> CompressionErrorNone) then
    Exit;
  AddTree(Group^, FTable, Used);
  if Group^.Count = Group^.TreeCount then
  begin
    Inc(FTreeGroup);
    if FTreeGroup > 2 then
      FPhase := BrotliPhaseCommand;
  end;
end;

function TBrotliDecoder.SwitchCategory(Index: Integer): TCompressionError;
var
  Category: ^TBrotliBlockCategory;
begin
  Category := @FMetaBlock.Categories[Index];
  if Category^.TypeCount = 1 then
  begin
    Category^.Remaining := BrotliEndlessBlock;
    Exit(CompressionErrorNone);
  end;
  Result := ReadBlockSwitch(FReader, Category^);
end;

function TBrotliDecoder.StepCommandSwitch: TCompressionError;
begin
  Result := SwitchCategory(BrotliCommandCategory);
end;

function TBrotliDecoder.StepLiteralSwitch: TCompressionError;
begin
  Result := SwitchCategory(BrotliLiteralCategory);
end;

function TBrotliDecoder.StepDistanceSwitch: TCompressionError;
begin
  Result := SwitchCategory(BrotliDistanceCategory);
end;

function TBrotliDecoder.StepCommand: TCompressionError;
var
  Category: ^TBrotliBlockCategory;
  Command: ^TBrotliCommand;
  InsertLength: LongWord;
  CopyLength: LongWord;
begin
  Result := CompressionErrorNone;
  Category := @FMetaBlock.Categories[BrotliCommandCategory];
  Command := @BrotliCommands[FReader.ReadSymbol(TreeTable(FMetaBlock.CommandTrees, Category^.CurrentType),
    BrotliRootBits)];
  InsertLength := Command^.InsertBase + FReader.ReadBits(Command^.InsertExtraBits);
  CopyLength := Command^.CopyBase + FReader.ReadBits(Command^.CopyExtraBits);
  if FReader.Overrun then
    Exit;
  Dec(Category^.Remaining);
  if InsertLength > FMetaBlockRemaining then
    Exit(CompressionErrorLengthBeyondBlock);
  FInsertRemaining := InsertLength;
  FCopyLength := CopyLength;
  FImplicitDistance := Command^.ImplicitDistance;
  FPhase := BrotliPhaseLiterals;
end;

function TBrotliDecoder.StepDistance: TCompressionError;
var
  Category: ^TBrotliBlockCategory;
  Context: LongWord;
  Code: Integer;
  ExtraBits: Integer;
  Extra: LongWord;
  Relative: Integer;
  HighPart: Integer;
  LowPart: Integer;
  Offset: Int64;
  Distance: Int64;
begin
  Result := CompressionErrorNone;
  Category := @FMetaBlock.Categories[BrotliDistanceCategory];
  Context := FCopyLength - 2;
  if Context > 3 then
    Context := 3;
  Code := FReader.ReadSymbol(TreeTable(FMetaBlock.DistanceTrees,
    FMetaBlock.DistanceContextMap[Category^.CurrentType * BrotliDistanceContexts + Integer(Context)]),
    BrotliRootBits);
  ExtraBits := 0;
  Extra := 0;
  if Code >= 16 + FMetaBlock.DirectCodes then
  begin
    ExtraBits := 1 + ((Code - FMetaBlock.DirectCodes - 16) shr (FMetaBlock.PostfixBits + 1));
    Extra := FReader.ReadBits(ExtraBits);
  end;
  if FReader.Overrun then
    Exit;
  Dec(Category^.Remaining);
  if Code < 4 then
    Distance := FDistances[Code]
  else if Code < 10 then
    Distance := Int64(FDistances[0]) + ShortCodeAdjustments[Code]
  else if Code < 16 then
    Distance := Int64(FDistances[1]) + ShortCodeAdjustments[Code]
  else if Code < 16 + FMetaBlock.DirectCodes then
    Distance := Code - 15
  else
  begin
    Relative := Code - FMetaBlock.DirectCodes - 16;
    HighPart := Relative shr FMetaBlock.PostfixBits;
    LowPart := Relative and ((1 shl FMetaBlock.PostfixBits) - 1);
    Offset := (Int64(2 + (HighPart and 1)) shl ExtraBits) - 4;
    Distance := ((Offset + Extra) shl FMetaBlock.PostfixBits) + LowPart + FMetaBlock.DirectCodes + 1;
  end;
  if Distance <= 0 then
    Exit(CompressionErrorDistanceTooFar);
  FDistance := Distance;
  Result := ResolveCopy(Code <> 0);
end;

{ The copy of a command whose distance is known: back in the output, or
  a static dictionary word when it reaches past the start or the
  window. }
function TBrotliDecoder.ResolveCopy(PushDistance: Boolean): TCompressionError;
var
  MaximumDistance: QWord;
  WordId: QWord;
  WordBits: Integer;
  WordIndex: LongWord;
  Transform: QWord;
begin
  Result := CompressionErrorNone;
  MaximumDistance := FWindowSize;
  if FWindow.Written < MaximumDistance then
    MaximumDistance := FWindow.Written;
  if FDistance <= MaximumDistance then
  begin
    if PushDistance then
    begin
      FDistances[3] := FDistances[2];
      FDistances[2] := FDistances[1];
      FDistances[1] := FDistances[0];
      FDistances[0] := FDistance;
    end;
    if FCopyLength > FMetaBlockRemaining then
      Exit(CompressionErrorLengthBeyondBlock);
    FCopyRemaining := FCopyLength;
    FCopyFromWord := False;
    FPhase := BrotliPhaseCopy;
    Exit;
  end;
  if (FCopyLength < BrotliShortestWord) or (FCopyLength > BrotliLongestWord) then
    Exit(CompressionErrorInvalidDictionaryWord);
  WordId := FDistance - MaximumDistance - 1;
  WordBits := BrotliWordBits[FCopyLength];
  WordIndex := WordId and ((QWord(1) shl WordBits) - 1);
  Transform := WordId shr WordBits;
  if Transform >= BrotliTransformCount then
    Exit(CompressionErrorInvalidDictionaryWord);
  FCopyRemaining := TransformBrotliWord(@FWord[0], BrotliDictionaryWord(FCopyLength, WordIndex), FCopyLength,
    Transform);
  if FCopyRemaining > FMetaBlockRemaining then
    Exit(CompressionErrorLengthBeyondBlock);
  FWordPosition := 0;
  FCopyFromWord := True;
  FPhase := BrotliPhaseCopy;
end;

function TBrotliDecoder.StepStreamEnd: TCompressionError;
begin
  if not FReader.SkipToByteBoundary then
    Exit(CompressionErrorInvalidPadding);
  Result := CompressionErrorNone;
  FPhase := BrotliPhaseFinished;
end;

{ The literals of a command, each a step of its own. }
function TBrotliDecoder.DecodeLiterals: TBrotliStop;
var
  Category: ^TBrotliBlockCategory;
  Lookup: PByte;
  ContextMap: PByte;
  Chunk: SizeUInt;
  Done: SizeUInt;
  Previous1: Byte;
  Previous2: Byte;
  Mark: TBrotliReaderMark;
  Symbol: Integer;
  Stop: TBrotliStop;
begin
  Category := @FMetaBlock.Categories[BrotliLiteralCategory];
  while FInsertRemaining > 0 do
  begin
    if FBudget = 0 then
      Exit(BrotliStopBudget);
    if Category^.Remaining = 0 then
    begin
      Stop := Attempt(@StepLiteralSwitch);
      if Stop <> BrotliStopNone then
        Exit(Stop);
      Continue;
    end;
    Chunk := FInsertRemaining;
    if Chunk > FBudget then
      Chunk := FBudget;
    if Chunk > Category^.Remaining then
      Chunk := Category^.Remaining;
    FWindow.Reserve(Chunk);
    Lookup := @BrotliContextLookup[FMetaBlock.ContextModes[Category^.CurrentType], 0];
    ContextMap := @FMetaBlock.LiteralContextMap[Category^.CurrentType * BrotliLiteralContexts];
    Previous1 := FWindow.ByteBack(1);
    Previous2 := FWindow.ByteBack(2);
    Done := 0;
    Stop := BrotliStopNone;
    while Done < Chunk do
    begin
      Mark := FReader.Save;
      Symbol := FReader.ReadSymbol(TreeTable(FMetaBlock.LiteralTrees,
        ContextMap[Lookup[Previous1] or Lookup[256 + Previous2]]), BrotliRootBits);
      if FReader.Overrun then
      begin
        FReader.Restore(Mark);
        FReader.KeepUnread;
        Stop := BrotliStopNeedsInput;
        Break;
      end;
      FWindow.PutByte(Symbol);
      Previous2 := Previous1;
      Previous1 := Symbol;
      Inc(Done);
    end;
    Dec(FInsertRemaining, Done);
    Dec(FMetaBlockRemaining, Done);
    Dec(FBudget, Done);
    Dec(Category^.Remaining, Done);
    if Stop <> BrotliStopNone then
      Exit(Stop);
  end;

  if FMetaBlockRemaining = 0 then
    FPhase := BrotliPhaseMetaBlockEnd
  else if FImplicitDistance then
  begin
    FDistance := FDistances[0];
    FError := ResolveCopy(False);
    if FError <> CompressionErrorNone then
    begin
      FPhase := BrotliPhaseFailed;
      Exit(BrotliStopFailed);
    end;
  end
  else
    FPhase := BrotliPhaseDistance;
  Result := BrotliStopNone;
end;

{ The bytes of a copy or a dictionary word, as far as the budget goes. }
function TBrotliDecoder.CopyOut: TBrotliStop;
var
  Count: SizeUInt;
begin
  Count := FCopyRemaining;
  if Count > FBudget then
    Count := FBudget;
  if Count > 0 then
  begin
    FWindow.Reserve(Count);
    if FCopyFromWord then
    begin
      FWindow.PutBytes(@FWord[FWordPosition], Count);
      Inc(FWordPosition, Count);
    end
    else
      FWindow.CopyMatch(FDistance, Count);
    Dec(FCopyRemaining, Count);
    Dec(FMetaBlockRemaining, Count);
    Dec(FBudget, Count);
  end;
  if FCopyRemaining > 0 then
    Exit(BrotliStopBudget);
  if FMetaBlockRemaining = 0 then
    FPhase := BrotliPhaseMetaBlockEnd
  else
    FPhase := BrotliPhaseCommand;
  Result := BrotliStopNone;
end;

function TBrotliDecoder.SkipMetadata: TBrotliStop;
begin
  Dec(FMetaBlockRemaining, FReader.TakeBytes(nil, FMetaBlockRemaining));
  if FMetaBlockRemaining > 0 then
  begin
    FReader.KeepUnread;
    Exit(BrotliStopNeedsInput);
  end;
  FPhase := BrotliPhaseMetaBlockEnd;
  Result := BrotliStopNone;
end;

function TBrotliDecoder.CopyUncompressed: TBrotliStop;
var
  Count: SizeUInt;
  Available: SizeUInt;
  Target: PByte;
  Taken: SizeInt;
begin
  while FMetaBlockRemaining > 0 do
  begin
    if FBudget = 0 then
      Exit(BrotliStopBudget);
    Count := FMetaBlockRemaining;
    if Count > FBudget then
      Count := FBudget;
    FWindow.Reserve(Count);
    Target := FWindow.WriteRegion(Count, Available);
    Taken := FReader.TakeBytes(Target, Available);
    FWindow.Advance(Taken);
    Dec(FMetaBlockRemaining, Taken);
    Dec(FBudget, Taken);
    if Taken = 0 then
    begin
      FReader.KeepUnread;
      Exit(BrotliStopNeedsInput);
    end;
  end;
  FPhase := BrotliPhaseMetaBlockEnd;
  Result := BrotliStopNone;
end;

function TBrotliDecoder.Run: TBrotliStop;
begin
  repeat
    Result := BrotliStopNone;
    case FPhase of
      BrotliPhaseStreamHeader: Result := Attempt(@StepStreamHeader);
      BrotliPhaseMetaBlockStart: Result := Attempt(@StepMetaBlockStart);
      BrotliPhaseMetadata: Result := SkipMetadata;
      BrotliPhaseUncompressed: Result := CopyUncompressed;
      BrotliPhaseBlockTypes: Result := Attempt(@StepBlockTypes);
      BrotliPhaseDistanceParameters: Result := Attempt(@StepDistanceParameters);
      BrotliPhaseLiteralContextMap: Result := Attempt(@StepLiteralContextMap);
      BrotliPhaseDistanceTreeCount: Result := Attempt(@StepDistanceTreeCount);
      BrotliPhaseDistanceContextMap: Result := Attempt(@StepDistanceContextMap);
      BrotliPhaseTrees: Result := Attempt(@StepTree);
      BrotliPhaseCommand:
        if FMetaBlock.Categories[BrotliCommandCategory].Remaining = 0 then
          Result := Attempt(@StepCommandSwitch)
        else
          Result := Attempt(@StepCommand);
      BrotliPhaseLiterals: Result := DecodeLiterals;
      BrotliPhaseDistance:
        if FMetaBlock.Categories[BrotliDistanceCategory].Remaining = 0 then
          Result := Attempt(@StepDistanceSwitch)
        else
          Result := Attempt(@StepDistance);
      BrotliPhaseCopy: Result := CopyOut;
      BrotliPhaseMetaBlockEnd:
        if FLastMetaBlock then
          FPhase := BrotliPhaseStreamEnd
        else
          FPhase := BrotliPhaseMetaBlockStart;
      BrotliPhaseStreamEnd: Result := Attempt(@StepStreamEnd);
      BrotliPhaseFinished: Result := BrotliStopFinished;
    else
      Result := BrotliStopFailed;
    end;
  until Result <> BrotliStopNone;
end;

function TBrotliDecoder.Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult;
var
  Delivered: SizeUInt;
  Stop: TBrotliStop;
begin
  Written := 0;
  if (Capacity < 0) or ((Output = nil) and (Capacity > 0)) then
    Exit(Fail(CompressionErrorInvalidArgument));
  repeat
    if FWindow.Pending > 0 then
    begin
      Delivered := FWindow.Deliver(PByte(Output) + Written, Capacity - Written);
      Inc(Written, Delivered);
      Inc(FTotalOutput, Delivered);
      if FWindow.Pending > 0 then
        Exit(DecompressOutputFull);
    end;
    FBudget := Capacity - Written;
    if FBudget > FWindow.Space then
      FBudget := FWindow.Space;
    Stop := Run;
    Delivered := FWindow.Deliver(PByte(Output) + Written, Capacity - Written);
    Inc(Written, Delivered);
    Inc(FTotalOutput, Delivered);
    if FWindow.Pending > 0 then
      Exit(DecompressOutputFull);
    case Stop of
      BrotliStopNeedsInput: Exit(DecompressNeedsInput);
      BrotliStopFinished: Exit(DecompressFinished);
      BrotliStopFailed: Exit(DecompressFailed);
    else
      if Written = Capacity then
        Exit(DecompressOutputFull);
    end;
  until False;
end;

end.
