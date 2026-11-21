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
  TZstdDecoder: Zstandard (RFC 8878) decompression, fed and taken in
  pieces of any size (the TStreamingDecoder contract).

  Frames follow one another and come out as one output; skippable
  frames are passed over. DecompressFinished means a frame has ended
  and no more input is at hand; more input may start another. Anything
  but a frame magic after a frame fails (CompressionErrorInvalidFrameHeader).

  A raw block is copied out as its bytes arrive; an RLE block at once;
  a compressed block (at most 128 KiB) is decoded when all of it is at
  hand, straight from the caller's piece when it holds the whole block,
  else gathered first. The output goes through a window that grows with
  the output up to the frame's window size (MaximumWindowSize bounds
  it; larger frames fail with CompressionErrorWindowTooLarge).

  The content checksum (XXH64) is checked when the frame has one, unless
  VerifyChecksum is turned off; the content size when the header gives
  it. Frames that need a dictionary are refused
  (CompressionErrorDictionaryNeeded).
}
unit Compression.ZstdDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Compression.Errors,
  Compression.StreamingDecoders,
  Compression.OutputWindows,
  Compression.XxHash64,
  Compression.ZstdFrames,
  Compression.ZstdLiterals,
  Compression.ZstdSequences;

const
  { As zstd's own decoder allows by default; RFC 8878 asks for 8 MiB. }
  ZstdDefaultMaximumWindow = 128 * 1024 * 1024;

type
  TZstdPhase = (ZstdPhaseMagic, ZstdPhaseFrameHeader, ZstdPhaseBlockHeader, ZstdPhaseBlockContent,
    ZstdPhaseChecksum, ZstdPhaseSkippableSize, ZstdPhaseSkipping, ZstdPhaseFrameEnd, ZstdPhaseFailed);

  TZstdDecoder = class(TStreamingDecoder)
  private
    FPhase: TZstdPhase;
    FInput: PByte;
    FInputCount: SizeInt;
    FInputPosition: SizeInt;
    FGathered: array[0..ZstdLargestFrameHeader - 1] of Byte;
    FGatheredCount: Integer;
    FFrame: TZstdFrameHeader;
    FFrameCount: Integer;
    FFrameStart: QWord;
    FWindowStarted: Boolean;
    FBlockMaximum: SizeUInt;
    FBlock: TZstdBlockHeader;
    FBlockBuffer: TBytes;
    FBlockFill: SizeUInt;
    FLiteralBuffer: TBytes;
    FSkipRemaining: QWord;
    FWindow: TOutputWindow;
    FHash: TXxHash64State;
    FVerifyChecksum: Boolean;
    FMaximumWindowSize: QWord;
    FDefaults: TZstdDefaultTables;
    FSequences: TZstdSequenceState;
    FLiterals: TZstdLiteralsState;
    function Fail(Code: TCompressionError): TDecompressResult;
    function InputAvailable: SizeInt; inline;
    function Gather(Needed: Integer): Boolean;
    function StartFrame: TCompressionError;
    function ReadBlockHeader: TCompressionError;
    procedure StartWindow;
    procedure HashOutput(First: QWord);
    function DecodeCompressedBlock(Data: PByte; Size: SizeUInt): TCompressionError;
    function ContinueBlock(out NeedsInput: Boolean): TCompressionError;
    procedure FinishBlock;
    function FinishFrame: TCompressionError;
  protected
    function GetFinished: Boolean; override;
    function GetInputRemaining: SizeInt; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset; override;
    procedure SetInput(Data: Pointer; Count: SizeInt); override;
    function Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult; override;

    property VerifyChecksum: Boolean read FVerifyChecksum write FVerifyChecksum;
    property MaximumWindowSize: QWord read FMaximumWindowSize write FMaximumWindowSize;
    { Zstandard frames begun so far (skippable ones not counted). }
    property FrameCount: Integer read FFrameCount;
  end;

implementation

constructor TZstdDecoder.Create;
begin
  inherited Create;
  FVerifyChecksum := True;
  FMaximumWindowSize := ZstdDefaultMaximumWindow;
  FWindow := TOutputWindow.Create;
  BuildZstdDefaultTables(FDefaults);
  SetLength(FLiteralBuffer, ZstdLargestBlock);
  Reset;
end;

destructor TZstdDecoder.Destroy;
begin
  FWindow.Free;
  inherited Destroy;
end;

procedure TZstdDecoder.Reset;
begin
  FPhase := ZstdPhaseMagic;
  FError := CompressionErrorNone;
  FTotalOutput := 0;
  FGatheredCount := 0;
  FFrameCount := 0;
  FWindowStarted := False;
  FInput := nil;
  FInputCount := 0;
  FInputPosition := 0;
  { Whatever was not taken of an earlier stream is dropped. }
  FWindow.Discard;
end;

procedure TZstdDecoder.SetInput(Data: Pointer; Count: SizeInt);
begin
  FInput := Data;
  FInputCount := Count;
  if FInputCount < 0 then
    FInputCount := 0;
  FInputPosition := 0;
end;

function TZstdDecoder.GetFinished: Boolean;
begin
  Result := FPhase = ZstdPhaseFrameEnd;
end;

function TZstdDecoder.GetInputRemaining: SizeInt;
begin
  Result := FInputCount - FInputPosition;
end;

function TZstdDecoder.InputAvailable: SizeInt;
begin
  Result := FInputCount - FInputPosition;
end;

function TZstdDecoder.Fail(Code: TCompressionError): TDecompressResult;
begin
  FError := Code;
  FPhase := ZstdPhaseFailed;
  Result := DecompressFailed;
end;

{ Moves input into FGathered until it holds Needed bytes. }
function TZstdDecoder.Gather(Needed: Integer): Boolean;
var
  Count: SizeInt;
begin
  Count := Needed - FGatheredCount;
  if Count > InputAvailable then
    Count := InputAvailable;
  if Count > 0 then
  begin
    Move(FInput[FInputPosition], FGathered[FGatheredCount], Count);
    Inc(FGatheredCount, Count);
    Inc(FInputPosition, Count);
  end;
  Result := FGatheredCount >= Needed;
end;

function TZstdDecoder.StartFrame: TCompressionError;
begin
  Result := ReadZstdFrameHeader(@FGathered[0], FFrame);
  if Result <> CompressionErrorNone then
    Exit;
  if FFrame.DictionaryId <> 0 then
    Exit(CompressionErrorDictionaryNeeded);
  if FFrame.WindowSize > FMaximumWindowSize then
    Exit(CompressionErrorWindowTooLarge);
  FBlockMaximum := ZstdLargestBlock;
  if FFrame.WindowSize < FBlockMaximum then
    FBlockMaximum := FFrame.WindowSize;
  FWindowStarted := False;
  StartZstdSequences(FSequences);
  FLiterals.HasTable := False;
  XxHash64Start(FHash, 0);
  Inc(FFrameCount);
end;

function TZstdDecoder.ReadBlockHeader: TCompressionError;
begin
  Result := CompressionErrorNone;
  FBlock := ReadZstdBlockHeader(@FGathered[0]);
  if FBlock.Kind > ZstdBlockCompressed then
    Exit(CompressionErrorCorruptBlock);
  if FBlock.Size > FBlockMaximum then
    Exit(CompressionErrorLengthBeyondBlock);
  FBlockFill := 0;
end;

{ The window of a new frame, once the last frame's output is taken. }
procedure TZstdDecoder.StartWindow;
begin
  if FWindowStarted then
    Exit;
  FWindow.Start(FFrame.WindowSize);
  FFrameStart := FWindow.Written;
  FWindowStarted := True;
end;

{ Hashes what the window holds from First on. }
procedure TZstdDecoder.HashOutput(First: QWord);
var
  Part1, Part2: PByte;
  Count1, Count2: SizeUInt;
begin
  if not (FFrame.HasChecksum and FVerifyChecksum) or (FWindow.Written = First) then
    Exit;
  FWindow.WrittenParts(First, FWindow.Written - First, Part1, Count1, Part2, Count2);
  XxHash64Update(FHash, Part1, Count1);
  if Count2 > 0 then
    XxHash64Update(FHash, Part2, Count2);
end;

function TZstdDecoder.DecodeCompressedBlock(Data: PByte; Size: SizeUInt): TCompressionError;
var
  First: QWord;
  Literals: PByte;
  LiteralCount: SizeUInt;
  SectionSize: SizeUInt;
begin
  FWindow.Reserve(FBlockMaximum);
  First := FWindow.Written;
  Result := ReadZstdLiterals(Data, Size, FBlockMaximum, FLiterals, @FLiteralBuffer[0], Literals, LiteralCount,
    SectionSize);
  if Result <> CompressionErrorNone then
    Exit;
  Result := DecodeZstdSequences(Data + SectionSize, Size - SectionSize, FSequences, FDefaults, Literals,
    LiteralCount, FWindow, FFrameStart, FFrame.WindowSize, FBlockMaximum);
  if Result = CompressionErrorNone then
    HashOutput(First);
end;

{ Takes what input there is for the block in hand; NeedsInput when the
  block wants more. Nothing is pending when it is called. }
function TZstdDecoder.ContinueBlock(out NeedsInput: Boolean): TCompressionError;
var
  Count: SizeUInt;
  First: QWord;
begin
  Result := CompressionErrorNone;
  NeedsInput := False;
  StartWindow;
  case FBlock.Kind of
    ZstdBlockRaw:
      begin
        Count := FBlock.Size - FBlockFill;
        if Count > SizeUInt(InputAvailable) then
          Count := InputAvailable;
        if (Count = 0) and (FBlockFill < FBlock.Size) then
        begin
          NeedsInput := True;
          Exit;
        end;
        FWindow.Reserve(Count);
        First := FWindow.Written;
        FWindow.PutBytes(FInput + FInputPosition, Count);
        HashOutput(First);
        Inc(FInputPosition, Count);
        Inc(FBlockFill, Count);
        NeedsInput := FBlockFill < FBlock.Size;
      end;
    ZstdBlockRle:
      begin
        if InputAvailable = 0 then
        begin
          NeedsInput := True;
          Exit;
        end;
        FWindow.Reserve(FBlock.Size);
        First := FWindow.Written;
        FWindow.PutRepeated(FInput[FInputPosition], FBlock.Size);
        HashOutput(First);
        Inc(FInputPosition);
      end;
  else
    begin
      if (FBlockFill = 0) and (SizeUInt(InputAvailable) >= FBlock.Size) then
      begin
        Result := DecodeCompressedBlock(FInput + FInputPosition, FBlock.Size);
        Inc(FInputPosition, FBlock.Size);
        Exit;
      end;
      if Length(FBlockBuffer) = 0 then
        SetLength(FBlockBuffer, ZstdLargestBlock);
      Count := FBlock.Size - FBlockFill;
      if Count > SizeUInt(InputAvailable) then
        Count := InputAvailable;
      if Count > 0 then
        Move(FInput[FInputPosition], FBlockBuffer[FBlockFill], Count);
      Inc(FInputPosition, Count);
      Inc(FBlockFill, Count);
      if FBlockFill < FBlock.Size then
      begin
        NeedsInput := True;
        Exit;
      end;
      Result := DecodeCompressedBlock(@FBlockBuffer[0], FBlock.Size);
    end;
  end;
end;

procedure TZstdDecoder.FinishBlock;
begin
  FGatheredCount := 0;
  if not FBlock.Last then
    FPhase := ZstdPhaseBlockHeader
  else if FFrame.HasChecksum then
    FPhase := ZstdPhaseChecksum
  else
    FPhase := ZstdPhaseFrameEnd;
end;

{ The checks at the end of a frame: its size, its checksum. }
function TZstdDecoder.FinishFrame: TCompressionError;
var
  Stored: LongWord;
begin
  Result := CompressionErrorNone;
  if FFrame.HasContentSize and (FWindow.Written - FFrameStart <> FFrame.ContentSize) then
    Exit(CompressionErrorLengthMismatch);
  if FFrame.HasChecksum and FVerifyChecksum then
  begin
    Stored := ReadLittleEndian32(@FGathered[0]);
    if Stored <> LongWord(XxHash64Finish(FHash) and $FFFFFFFF) then
      Exit(CompressionErrorChecksumMismatch);
  end;
end;

function TZstdDecoder.Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TDecompressResult;
var
  Magic: LongWord;
  Delivered: SizeUInt;
  Count: SizeUInt;
  NeedsInput: Boolean;
  Outcome: TCompressionError;
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
    case FPhase of
      ZstdPhaseMagic:
        begin
          if not Gather(ZstdMagicSize) then
            Exit(DecompressNeedsInput);
          Magic := ReadLittleEndian32(@FGathered[0]);
          FGatheredCount := 0;
          if Magic = ZstdFrameMagic then
            FPhase := ZstdPhaseFrameHeader
          else if (Magic and ZstdSkippableMagicMask) = ZstdSkippableMagic then
            FPhase := ZstdPhaseSkippableSize
          else
            Exit(Fail(CompressionErrorInvalidFrameHeader));
        end;
      ZstdPhaseFrameHeader:
        begin
          if not Gather(1) then
            Exit(DecompressNeedsInput);
          if not Gather(ZstdFrameHeaderSize(FGathered[0])) then
            Exit(DecompressNeedsInput);
          Outcome := StartFrame;
          if Outcome <> CompressionErrorNone then
            Exit(Fail(Outcome));
          FGatheredCount := 0;
          FPhase := ZstdPhaseBlockHeader;
        end;
      ZstdPhaseBlockHeader:
        begin
          if not Gather(ZstdBlockHeaderSize) then
            Exit(DecompressNeedsInput);
          Outcome := ReadBlockHeader;
          if Outcome <> CompressionErrorNone then
            Exit(Fail(Outcome));
          FGatheredCount := 0;
          FPhase := ZstdPhaseBlockContent;
        end;
      ZstdPhaseBlockContent:
        begin
          Outcome := ContinueBlock(NeedsInput);
          if Outcome <> CompressionErrorNone then
            Exit(Fail(Outcome));
          if not NeedsInput then
            FinishBlock
          else if FWindow.Pending = 0 then
            Exit(DecompressNeedsInput);
        end;
      ZstdPhaseChecksum:
        begin
          if not Gather(ZstdChecksumSize) then
            Exit(DecompressNeedsInput);
          FPhase := ZstdPhaseFrameEnd;
        end;
      ZstdPhaseSkippableSize:
        begin
          if not Gather(4) then
            Exit(DecompressNeedsInput);
          FSkipRemaining := ReadLittleEndian32(@FGathered[0]);
          FGatheredCount := 0;
          FPhase := ZstdPhaseSkipping;
        end;
      ZstdPhaseSkipping:
        begin
          Count := InputAvailable;
          if Count > FSkipRemaining then
            Count := FSkipRemaining;
          Inc(FInputPosition, Count);
          Dec(FSkipRemaining, Count);
          if FSkipRemaining > 0 then
            Exit(DecompressNeedsInput);
          { Not a frame to check: straight to its end. }
          FWindowStarted := False;
          FFrame.HasContentSize := False;
          FFrame.HasChecksum := False;
          FPhase := ZstdPhaseFrameEnd;
          FGatheredCount := 0;
        end;
      ZstdPhaseFrameEnd:
        begin
          if FWindowStarted or FFrame.HasChecksum then
          begin
            Outcome := FinishFrame;
            if Outcome <> CompressionErrorNone then
              Exit(Fail(Outcome));
            FWindowStarted := False;
            FFrame.HasContentSize := False;
            FFrame.HasChecksum := False;
          end;
          if InputAvailable = 0 then
            Exit(DecompressFinished);
          FGatheredCount := 0;
          FPhase := ZstdPhaseMagic;
        end;
    else
      Exit(DecompressFailed);
    end;
  until False;
end;

end.
