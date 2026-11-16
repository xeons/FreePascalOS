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
  JPEG XL's entropy coding (ISO/IEC 18181-1 annex C).

  An entropy coded stream has a number of contexts. A context map
  clusters them onto histograms (a simple map of fixed width entries,
  or one entropy coded itself, optionally move-to-front); each
  histogram has a hybrid integer configuration (tokens below a split
  are values, larger tokens carry their top and bottom bits and say how
  many raw bits follow) and is coded either with prefix codes or with
  ANS (asymmetric numeral systems, a 32-bit state read at the start and
  checked at the end). LZ77 may be on: tokens from a minimum symbol up
  are copies of earlier values, of a length coded with a configuration
  of its own and a distance coded in the last context (with 120
  special two-dimensional distances when the stream is an image of a
  known width).

  TJxlEntropyCode holds what the stream's header says;
  TJxlSymbolReader decodes values from it, context by context.
}
unit Image.Jxl.Entropy;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Prefix,
  Image.Jxl.AnsHistograms;

type
  TJxlHybridUintConfig = record
    SplitExponent: LongWord;
    SplitToken: LongWord;
    MsbInToken: LongWord;
    LsbInToken: LongWord;
  end;

  TJxlEntropyCode = class
  private
    FLz77Enabled: Boolean;
    FLz77MinimumSymbol: LongWord;
    FLz77MinimumLength: LongWord;
    FLz77LengthConfig: TJxlHybridUintConfig;
    FContextMap: array of Byte;
    FHistogramCount: LongInt;
    FUsePrefixCodes: Boolean;
    FLogAlphabetSize: LongInt;
    FConfigs: array of TJxlHybridUintConfig;
    FPrefixCodes: array of TJxlPrefixCode;
    FAliasTables: array of TJxlAliasTable;
    function GetContextCount: LongInt;
    function GetCluster(Context: LongInt): LongInt;
  public
    destructor Destroy; override;
    property ContextCount: LongInt read GetContextCount;
    property HistogramCount: LongInt read FHistogramCount;
    { The histogram context Context is clustered onto. }
    property Cluster[Context: LongInt]: LongInt read GetCluster;
  end;

  TJxlSymbolReader = class
  private
    FCode: TJxlEntropyCode;
    FReader: TJxlBitReader;
    FState: LongWord;
    FLogEntrySize: LongInt;
    FEntrySizeMask: LongWord;
    FWindow: array of LongWord;
    FCopiesLeft: LongWord;
    FCopyPosition: QWord;
    FDecodedCount: QWord;
    FSpecialDistances: array of LongWord;
    FDistanceCluster: LongInt;
    function ReadToken(Cluster: LongInt): LongWord; inline;
    function ReadUintWithConfig(const Config: TJxlHybridUintConfig; Token: LongWord): LongWord; inline;
    function TakeCopiedValue: LongWord;
  public
    { A reader of a stream coded with Code, reading from Reader. With
      DistanceMultiplier (the image's width) LZ77 has the special
      distances. ANS's initial state is read here. }
    constructor Create(Code: TJxlEntropyCode; Reader: TJxlBitReader; DistanceMultiplier: LongWord = 0);
    { The next value of context Context. }
    function ReadUint(Context: LongInt): LongWord;
    { The next value of an already clustered context. }
    function ReadUintClustered(Cluster: LongInt): LongWord;
    { Raises ImageErrorMalformed unless ANS ended in its final state. }
    procedure CheckFinalState;
    property Reader: TJxlBitReader read FReader write FReader;
  end;

{ Reads the header of a stream of ContextCount contexts: LZ77, the
  context map, the configurations and the histograms. }
function ReadJxlEntropyCode(Reader: TJxlBitReader; ContextCount: LongInt;
  DisallowLz77: Boolean = False): TJxlEntropyCode;

{ Reads a context map (simple, or itself entropy coded, optionally
  move-to-front) into Map, whose length is the context count; returns
  the number of clusters. }
function ReadJxlContextMap(Reader: TJxlBitReader; var Map: array of Byte): LongInt;

{ Reads a hybrid integer configuration for an alphabet of
  2^LogAlphabetSize symbols. }
function ReadJxlHybridUintConfig(Reader: TJxlBitReader; LogAlphabetSize: LongInt): TJxlHybridUintConfig;

implementation

const
  Lz77WindowSize = 1 shl 20;
  Lz77WindowMask = Lz77WindowSize - 1;
  AnsSignature = $13;
  MaximumClusters = 256;
  SpecialDistanceCount = 120;
  SpecialDistances: array[0..SpecialDistanceCount * 2 - 1] of ShortInt = (
    0, 1, 1, 0, 1, 1, -1, 1, 0, 2, 2, 0, 1, 2, -1, 2,
    2, 1, -2, 1, 2, 2, -2, 2, 0, 3, 3, 0, 1, 3, -1, 3,
    3, 1, -3, 1, 2, 3, -2, 3, 3, 2, -3, 2, 0, 4, 4, 0,
    1, 4, -1, 4, 4, 1, -4, 1, 3, 3, -3, 3, 2, 4, -2, 4,
    4, 2, -4, 2, 0, 5, 3, 4, -3, 4, 4, 3, -4, 3, 5, 0,
    1, 5, -1, 5, 5, 1, -5, 1, 2, 5, -2, 5, 5, 2, -5, 2,
    4, 4, -4, 4, 3, 5, -3, 5, 5, 3, -5, 3, 0, 6, 6, 0,
    1, 6, -1, 6, 6, 1, -6, 1, 2, 6, -2, 6, 6, 2, -6, 2,
    4, 5, -4, 5, 5, 4, -5, 4, 3, 6, -3, 6, 6, 3, -6, 3,
    0, 7, 7, 0, 1, 7, -1, 7, 5, 5, -5, 5, 7, 1, -7, 1,
    4, 6, -4, 6, 6, 4, -6, 4, 2, 7, -2, 7, 7, 2, -7, 2,
    3, 7, -3, 7, 7, 3, -7, 3, 5, 6, -5, 6, 6, 5, -6, 5,
    8, 0, 4, 7, -4, 7, 7, 4, -7, 4, 8, 1, 8, 2, 6, 6,
    -6, 6, 8, 3, 5, 7, -5, 7, 7, 5, -7, 5, 8, 4, 6, 7,
    -6, 7, 7, 6, -7, 6, 8, 5, 7, 7, -7, 7, 8, 6, 8, 7);

procedure RaiseBadEntropyCode(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL: ' + Detail);
end;

{ The number of bits that hold values 0 to Value - 1 (ceil(log2)). }
function CeilLog2(Value: LongWord): LongInt;
begin
  Result := 0;
  while (QWord(1) shl Result) < Value do
    Inc(Result);
end;

function ReadJxlHybridUintConfig(Reader: TJxlBitReader; LogAlphabetSize: LongInt): TJxlHybridUintConfig;
var
  SplitExponent: LongWord;
  Msb: LongWord;
  Lsb: LongWord;
begin
  SplitExponent := Reader.ReadBits(CeilLog2(LogAlphabetSize + 1));
  Msb := 0;
  Lsb := 0;
  if SplitExponent <> LongWord(LogAlphabetSize) then
  begin
    Msb := Reader.ReadBits(CeilLog2(SplitExponent + 1));
    if Msb > SplitExponent then
      RaiseBadEntropyCode('bad hybrid integer configuration');
    Lsb := Reader.ReadBits(CeilLog2(SplitExponent - Msb + 1));
  end;
  if Lsb + Msb > SplitExponent then
    RaiseBadEntropyCode('bad hybrid integer configuration');
  Result.SplitExponent := SplitExponent;
  Result.SplitToken := LongWord(1) shl SplitExponent;
  Result.MsbInToken := Msb;
  Result.LsbInToken := Lsb;
end;

procedure InverseMoveToFront(var Values: array of Byte);
var
  Table: array[0..255] of Byte;
  Index: LongInt;
  Position: LongInt;
  Value: Byte;
begin
  for Index := 0 to 255 do
    Table[Index] := Index;
  for Index := 0 to High(Values) do
  begin
    Position := Values[Index];
    Value := Table[Position];
    Values[Index] := Value;
    while Position > 0 do
    begin
      Table[Position] := Table[Position - 1];
      Dec(Position);
    end;
    Table[0] := Value;
  end;
end;

function ReadJxlContextMap(Reader: TJxlBitReader; var Map: array of Byte): LongInt;
var
  BitsPerEntry: LongInt;
  Index: LongInt;
  UseMoveToFront: Boolean;
  MapCode: TJxlEntropyCode;
  MapReader: TJxlSymbolReader;
  Symbol: LongWord;
begin
  if Reader.ReadBool then
  begin
    BitsPerEntry := LongInt(Reader.ReadBits(2));
    for Index := 0 to High(Map) do
      Map[Index] := Reader.ReadBits(BitsPerEntry);
  end
  else
  begin
    UseMoveToFront := Reader.ReadBool;
    MapCode := ReadJxlEntropyCode(Reader, 1, Length(Map) <= 2);
    try
      MapReader := TJxlSymbolReader.Create(MapCode, Reader);
      try
        for Index := 0 to High(Map) do
        begin
          Symbol := MapReader.ReadUint(0);
          if Symbol >= MaximumClusters then
            RaiseBadEntropyCode('bad cluster in context map');
          Map[Index] := Symbol;
        end;
        MapReader.CheckFinalState;
      finally
        MapReader.Free;
      end;
    finally
      MapCode.Free;
    end;
    if UseMoveToFront then
      InverseMoveToFront(Map);
  end;
  Result := 0;
  for Index := 0 to High(Map) do
    if Map[Index] + 1 > Result then
      Result := Map[Index] + 1;
end;

procedure ReadHistograms(Reader: TJxlBitReader; Code: TJxlEntropyCode);
var
  Index: LongInt;
  AlphabetSizes: array of LongInt;
  MaximumAlphabetSize: LongInt;
  Counts: TJxlAnsCounts;
begin
  MaximumAlphabetSize := 1 shl Code.FLogAlphabetSize;
  if Code.FUsePrefixCodes then
  begin
    SetLength(Code.FPrefixCodes, Code.FHistogramCount);
    SetLength(AlphabetSizes, Code.FHistogramCount);
    for Index := 0 to Code.FHistogramCount - 1 do
    begin
      AlphabetSizes[Index] := ReadJxlVarLenUint16(Reader) + 1;
      if AlphabetSizes[Index] > MaximumAlphabetSize then
        RaiseBadEntropyCode('prefix code alphabet too large');
    end;
    for Index := 0 to Code.FHistogramCount - 1 do
      if AlphabetSizes[Index] > 1 then
        Code.FPrefixCodes[Index] := ReadJxlPrefixCode(Reader, AlphabetSizes[Index])
      else
        Code.FPrefixCodes[Index] := TJxlPrefixCode.CreateFromLengths([1]);
  end
  else
  begin
    SetLength(Code.FAliasTables, Code.FHistogramCount);
    for Index := 0 to Code.FHistogramCount - 1 do
    begin
      Counts := ReadJxlAnsCounts(Reader);
      if Length(Counts) > MaximumAlphabetSize then
      begin
        while (Length(Counts) > 0) and (Counts[High(Counts)] = 0) do
          SetLength(Counts, Length(Counts) - 1);
        if Length(Counts) > MaximumAlphabetSize then
          RaiseBadEntropyCode('ANS alphabet too large');
      end;
      Code.FAliasTables[Index] := BuildJxlAliasTable(Counts, Code.FLogAlphabetSize);
    end;
  end;
end;

function ReadJxlEntropyCode(Reader: TJxlBitReader; ContextCount: LongInt;
  DisallowLz77: Boolean): TJxlEntropyCode;
var
  Index: LongInt;
begin
  Result := TJxlEntropyCode.Create;
  try
    Result.FLz77Enabled := Reader.ReadBool;
    if Result.FLz77Enabled then
    begin
      if DisallowLz77 then
        RaiseBadEntropyCode('LZ77 where it is not allowed');
      Result.FLz77MinimumSymbol := Reader.ReadU32(JxlVal(224), JxlVal(512), JxlVal(4096), JxlBitsOffset(15, 8));
      Result.FLz77MinimumLength := Reader.ReadU32(JxlVal(3), JxlVal(4), JxlBitsOffset(2, 5), JxlBitsOffset(8, 9));
      Result.FLz77LengthConfig := ReadJxlHybridUintConfig(Reader, 8);
      Inc(ContextCount);
    end;
    if ContextCount < 1 then
      ContextCount := 1;
    SetLength(Result.FContextMap, ContextCount);
    Result.FHistogramCount := 1;
    if ContextCount > 1 then
      Result.FHistogramCount := ReadJxlContextMap(Reader, Result.FContextMap);
    Result.FUsePrefixCodes := Reader.ReadBool;
    if Result.FUsePrefixCodes then
      Result.FLogAlphabetSize := JxlPrefixMaximumBits
    else
      Result.FLogAlphabetSize := LongInt(Reader.ReadBits(2)) + 5;
    SetLength(Result.FConfigs, Result.FHistogramCount);
    for Index := 0 to Result.FHistogramCount - 1 do
      Result.FConfigs[Index] := ReadJxlHybridUintConfig(Reader, Result.FLogAlphabetSize);
    ReadHistograms(Reader, Result);
  except
    Result.Free;
    raise;
  end;
end;

destructor TJxlEntropyCode.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to High(FPrefixCodes) do
    FPrefixCodes[Index].Free;
  inherited Destroy;
end;

function TJxlEntropyCode.GetContextCount: LongInt;
begin
  Result := Length(FContextMap);
end;

function TJxlEntropyCode.GetCluster(Context: LongInt): LongInt;
begin
  Result := FContextMap[Context];
end;

constructor TJxlSymbolReader.Create(Code: TJxlEntropyCode; Reader: TJxlBitReader; DistanceMultiplier: LongWord);
var
  Index: LongInt;
  Distance: Int64;
begin
  inherited Create;
  FCode := Code;
  FReader := Reader;
  FState := LongWord(AnsSignature) shl 16;
  if not Code.FUsePrefixCodes then
  begin
    FState := Reader.ReadBits(32);
    FLogEntrySize := JxlAnsLogTableSize - Code.FLogAlphabetSize;
    FEntrySizeMask := (LongWord(1) shl FLogEntrySize) - 1;
  end;
  if Code.FLz77Enabled then
  begin
    SetLength(FWindow, Lz77WindowSize);
    FDistanceCluster := Code.FContextMap[High(Code.FContextMap)];
    if DistanceMultiplier <> 0 then
    begin
      SetLength(FSpecialDistances, SpecialDistanceCount);
      for Index := 0 to SpecialDistanceCount - 1 do
      begin
        Distance := SpecialDistances[Index * 2] + Int64(DistanceMultiplier) * SpecialDistances[Index * 2 + 1];
        if Distance < 1 then
          Distance := 1;
        if Distance > High(LongWord) then
          Distance := High(LongWord);
        FSpecialDistances[Index] := LongWord(Distance);
      end;
    end;
  end;
end;

function TJxlSymbolReader.ReadToken(Cluster: LongInt): LongWord;
var
  Entry: ^TJxlAliasEntry;
  Value: LongWord;
  Position: LongWord;
  Bucket: LongWord;
begin
  if FCode.FUsePrefixCodes then
    Exit(FCode.FPrefixCodes[Cluster].ReadSymbol(FReader));
  Value := FState and (JxlAnsTableSize - 1);
  Bucket := Value shr FLogEntrySize;
  Position := Value and FEntrySizeMask;
  Entry := @FCode.FAliasTables[Cluster][Bucket];
  if Position >= Entry^.Cutoff then
  begin
    Result := Entry^.RightValue;
    FState := Entry^.Frequency1 * (FState shr JxlAnsLogTableSize) + Entry^.Offset1 + Position;
  end
  else
  begin
    Result := Bucket;
    FState := Entry^.Frequency0 * (FState shr JxlAnsLogTableSize) + Position;
  end;
  if FState < (LongWord(1) shl 16) then
    FState := (FState shl 16) or FReader.ReadBits(16);
end;

function TJxlSymbolReader.ReadUintWithConfig(const Config: TJxlHybridUintConfig; Token: LongWord): LongWord;
var
  BitCount: LongWord;
  Low: LongWord;
  Bits: LongWord;
  High: QWord;
begin
  if Token < Config.SplitToken then
    Exit(Token);
  BitCount := Config.SplitExponent - (Config.MsbInToken + Config.LsbInToken)
    + ((Token - Config.SplitToken) shr (Config.MsbInToken + Config.LsbInToken));
  BitCount := BitCount and 31;
  Low := Token and ((LongWord(1) shl Config.LsbInToken) - 1);
  Token := Token shr Config.LsbInToken;
  Bits := FReader.ReadBits(BitCount);
  High := (Token and ((LongWord(1) shl Config.MsbInToken) - 1)) or (LongWord(1) shl Config.MsbInToken);
  Result := LongWord((((((High shl BitCount) or Bits) shl Config.LsbInToken) or Low)) and $FFFFFFFF);
end;

function TJxlSymbolReader.TakeCopiedValue: LongWord;
begin
  Result := FWindow[FCopyPosition and Lz77WindowMask];
  Inc(FCopyPosition);
  Dec(FCopiesLeft);
  FWindow[FDecodedCount and Lz77WindowMask] := Result;
  Inc(FDecodedCount);
end;

function TJxlSymbolReader.ReadUintClustered(Cluster: LongInt): LongWord;
var
  Token: LongWord;
  DistanceToken: LongWord;
  Distance: QWord;
  FillCount: QWord;
  CopyLength: QWord;
  Index: QWord;
begin
  if FCopiesLeft > 0 then
    Exit(TakeCopiedValue);
  Token := ReadToken(Cluster);
  if FCode.FLz77Enabled and (Token >= FCode.FLz77MinimumSymbol) then
  begin
    CopyLength := QWord(ReadUintWithConfig(FCode.FLz77LengthConfig, Token - FCode.FLz77MinimumSymbol))
      + FCode.FLz77MinimumLength;
    if CopyLength > High(LongWord) then
      RaiseBadEntropyCode('LZ77 copy too long');
    FCopiesLeft := LongWord(CopyLength);
    DistanceToken := ReadToken(FDistanceCluster);
    Distance := ReadUintWithConfig(FCode.FConfigs[FDistanceCluster], DistanceToken);
    if Distance < QWord(Length(FSpecialDistances)) then
      Distance := FSpecialDistances[Distance]
    else
      Distance := Distance + 1 - QWord(Length(FSpecialDistances));
    if Distance > FDecodedCount then
      Distance := FDecodedCount;
    if Distance > Lz77WindowSize then
      Distance := Lz77WindowSize;
    FCopyPosition := FDecodedCount - Distance;
    if Distance = 0 then
    begin
      FillCount := FCopiesLeft;
      if FillCount > Lz77WindowSize then
        FillCount := Lz77WindowSize;
      Index := 0;
      while Index < FillCount do
      begin
        FWindow[Index] := 0;
        Inc(Index);
      end;
    end;
    Exit(TakeCopiedValue);
  end;
  Result := ReadUintWithConfig(FCode.FConfigs[Cluster], Token);
  if FCode.FLz77Enabled then
  begin
    FWindow[FDecodedCount and Lz77WindowMask] := Result;
    Inc(FDecodedCount);
  end;
end;

function TJxlSymbolReader.ReadUint(Context: LongInt): LongWord;
begin
  Result := ReadUintClustered(FCode.FContextMap[Context]);
end;

procedure TJxlSymbolReader.CheckFinalState;
begin
  if (not FCode.FUsePrefixCodes) and (FState <> (LongWord(AnsSignature) shl 16)) then
    RaiseBadEntropyCode('ANS stream does not end in its final state');
end;

end.
