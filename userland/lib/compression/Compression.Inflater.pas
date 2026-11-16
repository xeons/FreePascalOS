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
  TInflater: decompression of raw deflate, zlib or gzip data, fed and
  taken in pieces of any size.

    Inflater := TInflater.Create(FormatZlib);
    Inflater.SetInput(@Chunk[0], Length(Chunk));
    repeat
      Outcome := Inflater.Decompress(@Buffer[0], Length(Buffer), Written);
      ... use Written bytes of Buffer ...
    until Outcome <> InflateOutputFull;

  Decompress fills Output as far as it can and says why it stopped:
  InflateNeedsInput (all input used; SetInput the next piece),
  InflateOutputFull (call again with more room), InflateFinished or
  InflateFailed (Error says why). The input must stay valid until it
  has been used up or the data has finished.

  The wrapper is checked as it goes: the zlib header and Adler-32, the
  gzip header (with its CRC if it has one), CRC-32 and length. A gzip
  stream may have several members, decompressed one after another as
  one output (ConcatenatedMembers, on by default); InflateFinished
  then means a member has ended and no more input is at hand, and more
  input may still start another. Anything but a member after a member
  is CompressionErrorTrailingData. After zlib and raw data the rest of
  the input is left alone (InputRemaining).

  SetDictionary gives the preset dictionary the data was compressed
  with: raw data always starts from it; zlib data uses it only when its
  header asks for one, and then the dictionary's Adler-32 must be the
  id in the header (CompressionErrorDictionaryMismatch). zlib data that
  needs a dictionary when none was given fails with
  CompressionErrorPresetDictionary; DictionaryId then says which one,
  so the caller can SetDictionary, Reset and start over.

  Flush points (empty stored blocks, from a sync or full flush) need
  nothing special: everything before one comes out as soon as the
  input up to it has been given.
}
unit Compression.Inflater;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.Formats,
  Compression.Checksums,
  Compression.ZlibFormat,
  Compression.GzipFormat,
  Compression.InflateEngine;

type
  TInflateResult = (InflateNeedsInput, InflateOutputFull, InflateFinished, InflateFailed);

  TInflaterState = (InflaterHeader, InflaterBody, InflaterTrailer, InflaterMemberEnd, InflaterFinished,
    InflaterFailed);

  TStepOutcome = (StepDone, StepNeedsInput, StepFailed);

  TInflater = class
  private
    FFormat: TCompressionFormat;
    FStreamFormat: TCompressionFormat;
    FEngine: TInflateEngine;
    FHeaderReader: TGzipHeaderReader;
    FState: TInflaterState;
    FError: TCompressionError;
    FConcatenatedMembers: Boolean;
    FMemberCount: Integer;
    FZlibMethodByte: Byte;
    FHeaderBytes: Integer;
    FTrailer: array[0..GzipTrailerSize - 1] of Byte;
    FTrailerBytes: Integer;
    FChecksum: LongWord;
    FMemberLength: LongWord;
    FTotalOutput: Int64;
    FDictionary: array of Byte;
    FDictionaryId: LongWord;
    FDictionaryWanted: Boolean;
    function Fail(Error: TCompressionError): TInflateResult;
    procedure StartMember;
    function ReadHeader: TStepOutcome;
    function ReadZlibHeaderByte(Value: Byte): TStepOutcome;
    function CheckDictionaryId: TStepOutcome;
    function ReadTrailer: TStepOutcome;
    function CheckTrailer: TCompressionError;
    procedure TakeFromEngine(Output: PByte; Capacity: SizeInt; var Written: SizeInt);
    function GetFinished: Boolean;
    function GetInputRemaining: SizeInt;
    function GetGzipHeader: TGzipHeader;
  public
    constructor Create(Format: TCompressionFormat = FormatZlib);
    destructor Destroy; override;
    { Back to the start of a new stream (the format stays). }
    procedure Reset;
    procedure SetInput(Data: Pointer; Count: SizeInt);
    { The preset dictionary (raw and zlib data); kept across Reset. }
    procedure SetDictionary(Data: Pointer; Count: SizeInt);
    function Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TInflateResult;

    property Format: TCompressionFormat read FFormat;
    { What the data turned out to be (FormatAutomatic before its header). }
    property StreamFormat: TCompressionFormat read FStreamFormat;
    { Input not used yet (after the end of the data: what follows it). }
    property InputRemaining: SizeInt read GetInputRemaining;
    property Finished: Boolean read GetFinished;
    property Error: TCompressionError read FError;
    property TotalOutput: Int64 read FTotalOutput;
    property ConcatenatedMembers: Boolean read FConcatenatedMembers write FConcatenatedMembers;
    { The header of the gzip member being (or last) decompressed. }
    property GzipHeader: TGzipHeader read GetGzipHeader;
    property MemberCount: Integer read FMemberCount;
    { The Adler-32 of the dictionary zlib data asked for (0 if none). }
    property DictionaryId: LongWord read FDictionaryId;
  end;

implementation

constructor TInflater.Create(Format: TCompressionFormat);
begin
  inherited Create;
  FFormat := Format;
  FConcatenatedMembers := True;
  FEngine := TInflateEngine.Create;
  FHeaderReader := TGzipHeaderReader.Create;
  Reset;
end;

destructor TInflater.Destroy;
begin
  FHeaderReader.Free;
  FEngine.Free;
  inherited Destroy;
end;

procedure TInflater.Reset;
begin
  FEngine.Reset;
  FError := CompressionErrorNone;
  FMemberCount := 0;
  FTotalOutput := 0;
  FStreamFormat := FFormat;
  StartMember;
end;

procedure TInflater.StartMember;
begin
  FEngine.StartStream;
  FHeaderReader.Reset;
  FHeaderBytes := 0;
  FTrailerBytes := 0;
  FDictionaryId := 0;
  FDictionaryWanted := (FStreamFormat = FormatRaw) and (Length(FDictionary) > 0);
  FMemberLength := 0;
  if FStreamFormat = FormatGzip then
    FChecksum := Crc32Initial
  else
    FChecksum := Adler32Initial;
  if FStreamFormat = FormatRaw then
    FState := InflaterBody
  else
    FState := InflaterHeader;
end;

procedure TInflater.SetInput(Data: Pointer; Count: SizeInt);
begin
  FEngine.SetInput(Data, Count);
end;

procedure TInflater.SetDictionary(Data: Pointer; Count: SizeInt);
begin
  if Count < 0 then
    Count := 0;
  FDictionary := nil;
  SetLength(FDictionary, Count);
  if Count > 0 then
    Move(Data^, FDictionary[0], Count);
  if (FStreamFormat = FormatRaw) and (FState = InflaterBody) and (FEngine.TotalOutput = 0) then
    FDictionaryWanted := Count > 0;
end;

function TInflater.GetFinished: Boolean;
begin
  Result := FState in [InflaterMemberEnd, InflaterFinished];
end;

function TInflater.GetInputRemaining: SizeInt;
begin
  Result := FEngine.UnusedInput;
end;

function TInflater.GetGzipHeader: TGzipHeader;
begin
  Result := FHeaderReader.Header;
end;

function TInflater.Fail(Error: TCompressionError): TInflateResult;
begin
  FError := Error;
  FState := InflaterFailed;
  Result := InflateFailed;
end;

{ The two header bytes, then the dictionary id if the header has one. }
function TInflater.ReadZlibHeaderByte(Value: Byte): TStepOutcome;
begin
  Result := StepNeedsInput;
  Inc(FHeaderBytes);
  if FHeaderBytes = 1 then
  begin
    FZlibMethodByte := Value;
    Exit;
  end;
  if FHeaderBytes = 2 then
  begin
    FError := CheckZlibHeader(FZlibMethodByte, Value, True);
    if FError <> CompressionErrorNone then
      Result := StepFailed
    else if ZlibHeaderHasDictionary(Value) then
      FDictionaryWanted := True
    else
      Result := StepDone;
    Exit;
  end;
  FDictionaryId := (FDictionaryId shl 8) or Value;
  if FHeaderBytes = ZlibHeaderSize + ZlibDictionaryIdSize then
    Result := CheckDictionaryId;
end;

function TInflater.CheckDictionaryId: TStepOutcome;
var
  Id: LongWord;
begin
  Result := StepFailed;
  if Length(FDictionary) = 0 then
  begin
    FError := CompressionErrorPresetDictionary;
    Exit;
  end;
  Id := Adler32(Adler32Initial, @FDictionary[0], Length(FDictionary));
  if Id <> FDictionaryId then
  begin
    FError := CompressionErrorDictionaryMismatch;
    Exit;
  end;
  Result := StepDone;
end;

function TInflater.ReadHeader: TStepOutcome;
var
  Value: Byte;
begin
  repeat
    if not FEngine.ReadByte(Value) then
    begin
      Result := StepNeedsInput;
      Exit;
    end;
    if FStreamFormat = FormatAutomatic then
    begin
      if Value = GzipFirstMagic then
        FStreamFormat := FormatGzip
      else
        FStreamFormat := FormatZlib;
      if FStreamFormat = FormatGzip then
        FChecksum := Crc32Initial;
    end;
    if FStreamFormat = FormatZlib then
      Result := ReadZlibHeaderByte(Value)
    else
      case FHeaderReader.Feed(Value) of
        GzipHeaderComplete: Result := StepDone;
        GzipHeaderInvalid:
          begin
            FError := FHeaderReader.Error;
            Result := StepFailed;
          end;
      else
        Result := StepNeedsInput;
      end;
  until Result <> StepNeedsInput;
end;

function TInflater.ReadTrailer: TStepOutcome;
var
  TrailerSize: Integer;
  Value: Byte;
begin
  if FStreamFormat = FormatGzip then
    TrailerSize := GzipTrailerSize
  else
    TrailerSize := ZlibTrailerSize;
  while FTrailerBytes < TrailerSize do
  begin
    if not FEngine.ReadByte(Value) then
    begin
      Result := StepNeedsInput;
      Exit;
    end;
    FTrailer[FTrailerBytes] := Value;
    Inc(FTrailerBytes);
  end;
  FError := CheckTrailer;
  if FError = CompressionErrorNone then
    Result := StepDone
  else
    Result := StepFailed;
end;

function TInflater.CheckTrailer: TCompressionError;
var
  Stored: LongWord;
  StoredLength: LongWord;
begin
  Result := CompressionErrorNone;
  if FStreamFormat = FormatZlib then
  begin
    Stored := (LongWord(FTrailer[0]) shl 24) or (LongWord(FTrailer[1]) shl 16) or (LongWord(FTrailer[2]) shl 8) or
      FTrailer[3];
    if Stored <> FChecksum then
      Result := CompressionErrorAdlerMismatch;
    Exit;
  end;
  Stored := LongWord(FTrailer[0]) or (LongWord(FTrailer[1]) shl 8) or (LongWord(FTrailer[2]) shl 16) or
    (LongWord(FTrailer[3]) shl 24);
  StoredLength := LongWord(FTrailer[4]) or (LongWord(FTrailer[5]) shl 8) or (LongWord(FTrailer[6]) shl 16) or
    (LongWord(FTrailer[7]) shl 24);
  if Stored <> FChecksum then
    Result := CompressionErrorCrcMismatch
  else if StoredLength <> FMemberLength then
    Result := CompressionErrorLengthMismatch;
end;

procedure TInflater.TakeFromEngine(Output: PByte; Capacity: SizeInt; var Written: SizeInt);
var
  Count: SizeInt;
begin
  Count := FEngine.TakeOutput(Output + Written, Capacity - Written);
  if Count = 0 then
    Exit;
  case FStreamFormat of
    FormatZlib: FChecksum := Adler32(FChecksum, Output + Written, Count);
    FormatGzip: FChecksum := Crc32(FChecksum, Output + Written, Count);
  end;
  FMemberLength := FMemberLength + LongWord(Count);
  Inc(FTotalOutput, Count);
  Inc(Written, Count);
end;

function TInflater.Decompress(Output: Pointer; Capacity: SizeInt; out Written: SizeInt): TInflateResult;
var
  NextByte: Byte;
begin
  Written := 0;
  if (Capacity < 0) or ((Output = nil) and (Capacity > 0)) then
  begin
    Result := Fail(CompressionErrorInvalidArgument);
    Exit;
  end;
  repeat
    if FEngine.PendingOutput > 0 then
    begin
      TakeFromEngine(Output, Capacity, Written);
      if FEngine.PendingOutput > 0 then
      begin
        Result := InflateOutputFull;
        Exit;
      end;
    end;
    case FState of
      InflaterHeader:
        case ReadHeader of
          StepNeedsInput:
            begin
              Result := InflateNeedsInput;
              Exit;
            end;
          StepFailed:
            begin
              Result := Fail(FError);
              Exit;
            end;
        else
          begin
            Inc(FMemberCount);
            FState := InflaterBody;
          end;
        end;
      InflaterBody:
      begin
        if FDictionaryWanted then
        begin
          FEngine.SetDictionary(@FDictionary[0], Length(FDictionary));
          FDictionaryWanted := False;
        end;
        case FEngine.Decode of
          EngineNeedsInput:
            if FEngine.PendingOutput = 0 then
            begin
              Result := InflateNeedsInput;
              Exit;
            end;
          EngineDone:
            if FEngine.PendingOutput = 0 then
            begin
              if FStreamFormat = FormatRaw then
                FState := InflaterFinished
              else
                FState := InflaterTrailer;
            end;
          EngineFailed:
            begin
              Result := Fail(FEngine.Error);
              Exit;
            end;
        end;
      end;
      InflaterTrailer:
        case ReadTrailer of
          StepNeedsInput:
            begin
              Result := InflateNeedsInput;
              Exit;
            end;
          StepFailed:
            begin
              Result := Fail(FError);
              Exit;
            end;
        else
          if FStreamFormat = FormatGzip then
            FState := InflaterMemberEnd
          else
            FState := InflaterFinished;
        end;
      InflaterMemberEnd:
        begin
          if not FConcatenatedMembers or not FEngine.HasInput then
          begin
            Result := InflateFinished;
            Exit;
          end;
          FEngine.ReadByte(NextByte);
          if NextByte <> GzipFirstMagic then
          begin
            Result := Fail(CompressionErrorTrailingData);
            Exit;
          end;
          StartMember;
          FHeaderReader.Feed(NextByte);
        end;
      InflaterFinished:
        begin
          Result := InflateFinished;
          Exit;
        end;
    else
      begin
        Result := InflateFailed;
        Exit;
      end;
    end;
  until False;
end;

end.
