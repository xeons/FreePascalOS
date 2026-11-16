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
  The VP8L (lossless) decoder (RFC 9649), following libwebp so damaged
  streams are refused where it refuses them.

  A stream is a header (the signature $2F, width and height less one in
  14 bits each, whether alpha is used, a version of 0), then transforms
  (each at most once), then the entropy coded image. An entropy coded
  image may use a colour cache (recently seen colours, by a hash, of
  2^1 to 2^11 entries) and, for the main image only, a meta prefix code
  image whose pixels pick, per tile, one of several groups of five
  prefix codes (green with LZ77 lengths and cache indices, red, blue,
  alpha, distance). Pixels are literals, backward references (a length
  and a distance; small distance codes are 2-D neighbours) or cache
  hits. Sub-images (transform data, the meta image) are entropy coded
  images too, without transforms or meta codes.

  ALPH chunks hold the same stream without its header; the alpha is in
  the green channel.
}
unit Image.WebP.LosslessDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.WebP.LosslessBits,
  Image.WebP.PrefixCodes,
  Image.WebP.LosslessTransforms;

const
  LosslessSignature = $2F;
  LosslessHeaderLength = 5;

type
  TLosslessHeader = record
    Width: LongInt;
    Height: LongInt;
    AlphaUsed: Boolean;
  end;

{ The header of the VP8L stream of Size bytes at Data; False when it is
  not one. }
function ReadLosslessHeader(Data: PByte; Size: PtrInt; out Header: TLosslessHeader): Boolean;

{ Decodes the VP8L stream of Size bytes at Data into an image. }
function DecodeLosslessImage(Data: PByte; Size: PtrInt): TImage;

{ Decodes a headerless stream (ALPH's) of Width x Height pixels; the
  caller frees the pixels with FreeMem. }
function DecodeLosslessPixels(Data: PByte; Size: PtrInt; Width, Height: LongInt): PLongWord;

implementation

const
  LiteralCodes = 256;
  LengthCodes = 24;
  DistanceCodes = 40;
  MaximumCacheBits = 11;
  CodeLengthCodes = 19;
  DefaultCodeLength = 8;
  PlaneCodes = 120;

  CodeLengthOrder: array[0..CodeLengthCodes - 1] of Byte = (
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

  { The 2-D neighbours of the first 120 distance codes: the high nibble
    the lines up, 8 less the low nibble the columns left. }
  CodeToPlane: array[0..PlaneCodes - 1] of Byte = (
    $18, $07, $17, $19, $28, $06, $27, $29, $16, $1A,
    $26, $2A, $38, $05, $37, $39, $15, $1B, $36, $3A,
    $25, $2B, $48, $04, $47, $49, $14, $1C, $35, $3B,
    $46, $4A, $24, $2C, $58, $45, $4B, $34, $3C, $03,
    $57, $59, $13, $1D, $56, $5A, $23, $2D, $44, $4C,
    $55, $5B, $33, $3D, $68, $02, $67, $69, $12, $1E,
    $66, $6A, $22, $2E, $54, $5C, $43, $4D, $65, $6B,
    $32, $3E, $78, $01, $77, $79, $53, $5D, $11, $1F,
    $64, $6C, $42, $4E, $76, $7A, $21, $2F, $75, $7B,
    $31, $3F, $63, $6D, $52, $5E, $00, $74, $7C, $41,
    $4F, $10, $20, $62, $6E, $30, $73, $7D, $51, $5F,
    $40, $72, $7E, $61, $6F, $50, $71, $7F, $60, $70);

  GreenCode = 0;
  RedCode = 1;
  BlueCode = 2;
  AlphaCode = 3;
  DistanceCode = 4;
  CodesPerGroup = 5;

type
  TPrefixCodeGroup = array[0..CodesPerGroup - 1] of TPrefixCode;

  { What an entropy coded image needs besides its pixels. }
  TEntropyCoding = record
    CacheBits: LongInt;
    MetaBits: LongInt;
    MetaWidth: LongInt;
    { The group of each tile (0 when there is no meta image). }
    MetaImage: TLongWordArray;
    Groups: array of TPrefixCodeGroup;
  end;

  TLosslessDecoder = class
  private
    FReader: TLosslessBitReader;
    FTransforms: array[0..3] of TLosslessTransform;
    FTransformCount: LongInt;
    FTransformsSeen: LongInt;
    procedure Fail(const Detail: string);
    procedure ReadCodeLengths(const CodeLengthLengths: array of LongInt; SymbolCount: LongInt;
      var Lengths: array of LongInt);
    procedure ReadPrefixCode(AlphabetSize: LongInt; var Lengths: array of LongInt; out Code: TPrefixCode);
    procedure ReadCoding(Width, Height: LongInt; IsMainImage: Boolean; out Coding: TEntropyCoding);
    procedure DecodePixels(Pixels: PLongWord; Width, Height: LongInt; constref Coding: TEntropyCoding);
    function DecodeSubimage(Width, Height: LongInt): TLongWordArray;
    procedure ReadTransform(var Width: LongInt; Height: LongInt);
    function UndoTransforms(Pixels: PLongWord; CodedWidth, Height: LongInt): PLongWord;
  public
    constructor Create(Data: PByte; Size: PtrInt);
    destructor Destroy; override;
    { The image of Width x Height after the transforms; the caller frees
      the pixels with FreeMem. }
    function DecodeImage(Width, Height: LongInt): PLongWord;
    property Reader: TLosslessBitReader read FReader;
  end;

function ReadLosslessHeader(Data: PByte; Size: PtrInt; out Header: TLosslessHeader): Boolean;
var
  Bits: QWord;
  Index: LongInt;
begin
  Header := Default(TLosslessHeader);
  if (Size < LosslessHeaderLength) or (Data[0] <> LosslessSignature) then
    Exit(False);
  Bits := 0;
  for Index := 1 to 4 do
    Bits := Bits or (QWord(Data[Index]) shl (8 * (Index - 1)));
  Header.Width := LongInt(Bits and $3FFF) + 1;
  Header.Height := LongInt((Bits shr 14) and $3FFF) + 1;
  Header.AlphaUsed := ((Bits shr 28) and 1) <> 0;
  Result := (Bits shr 29) = 0;
end;

constructor TLosslessDecoder.Create(Data: PByte; Size: PtrInt);
begin
  inherited Create;
  FReader := TLosslessBitReader.Create(Data, Size);
end;

destructor TLosslessDecoder.Destroy;
begin
  FReader.Free;
  inherited Destroy;
end;

procedure TLosslessDecoder.Fail(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'VP8L: ' + Detail);
end;

procedure TLosslessDecoder.ReadCodeLengths(const CodeLengthLengths: array of LongInt; SymbolCount: LongInt;
  var Lengths: array of LongInt);
var
  LengthCode: TPrefixCode;
  Symbol: LongInt;
  MaximumSymbol: LongInt;
  LengthBits: LongInt;
  CodeLength: LongInt;
  PreviousLength: LongInt;
  Repeats: LongInt;
  RepeatedLength: LongInt;
begin
  if not BuildPrefixCode(CodeLengthLengths, CodeLengthCodes, CodeLengthRootBits, LengthCode) then
    Fail('code length code');
  if FReader.ReadBit then
  begin
    LengthBits := 2 + 2 * LongInt(FReader.ReadBits(3));
    MaximumSymbol := 2 + LongInt(FReader.ReadBits(LengthBits));
    if MaximumSymbol > SymbolCount then
      Fail('code length count');
  end
  else
    MaximumSymbol := SymbolCount;
  PreviousLength := DefaultCodeLength;
  Symbol := 0;
  while Symbol < SymbolCount do
  begin
    if MaximumSymbol = 0 then
      Break;
    Dec(MaximumSymbol);
    CodeLength := ReadSymbol(LengthCode, FReader);
    if CodeLength < 16 then
    begin
      Lengths[Symbol] := CodeLength;
      Inc(Symbol);
      if CodeLength <> 0 then
        PreviousLength := CodeLength;
    end
    else
    begin
      case CodeLength of
        16: Repeats := 3 + LongInt(FReader.ReadBits(2));
        17: Repeats := 3 + LongInt(FReader.ReadBits(3));
      else
        Repeats := 11 + LongInt(FReader.ReadBits(7));
      end;
      if Symbol + Repeats > SymbolCount then
        Fail('code length repeat');
      if CodeLength = 16 then
        RepeatedLength := PreviousLength
      else
        RepeatedLength := 0;
      while Repeats > 0 do
      begin
        Lengths[Symbol] := RepeatedLength;
        Inc(Symbol);
        Dec(Repeats);
      end;
    end;
  end;
end;

procedure TLosslessDecoder.ReadPrefixCode(AlphabetSize: LongInt; var Lengths: array of LongInt;
  out Code: TPrefixCode);
var
  CodeLengthLengths: array[0..CodeLengthCodes - 1] of LongInt;
  SymbolCount: LongInt;
  Symbol: LongInt;
  CodeCount: LongInt;
  Index: LongInt;
begin
  for Index := 0 to AlphabetSize - 1 do
    Lengths[Index] := 0;
  if FReader.ReadBit then
  begin
    { A simple code: one or two symbols of up to 8 bits. }
    SymbolCount := LongInt(FReader.ReadBits(1)) + 1;
    if FReader.ReadBit then
      Symbol := FReader.ReadBits(8)
    else
      Symbol := FReader.ReadBits(1);
    if Symbol < AlphabetSize then
      Lengths[Symbol] := 1;
    if SymbolCount = 2 then
    begin
      Symbol := FReader.ReadBits(8);
      if Symbol < AlphabetSize then
        Lengths[Symbol] := 1;
    end;
  end
  else
  begin
    for Index := 0 to CodeLengthCodes - 1 do
      CodeLengthLengths[Index] := 0;
    CodeCount := LongInt(FReader.ReadBits(4)) + 4;
    for Index := 0 to CodeCount - 1 do
      CodeLengthLengths[CodeLengthOrder[Index]] := FReader.ReadBits(3);
    ReadCodeLengths(CodeLengthLengths, AlphabetSize, Lengths);
  end;
  if not BuildPrefixCode(Lengths, AlphabetSize, PrefixRootBits, Code) then
    Fail('prefix code');
end;

procedure TLosslessDecoder.ReadCoding(Width, Height: LongInt; IsMainImage: Boolean; out Coding: TEntropyCoding);
const
  AlphabetSizes: array[0..CodesPerGroup - 1] of LongInt = (
    LiteralCodes + LengthCodes, LiteralCodes, LiteralCodes, LiteralCodes, DistanceCodes);
var
  GroupCount: LongInt;
  UsedCount: LongInt;
  Mapping: array of LongInt;
  Lengths: array of LongInt;
  Index: LongInt;
  Group: LongInt;
  CodeIndex: LongInt;
  AlphabetSize: LongInt;
  Discarded: TPrefixCode;
begin
  Coding := Default(TEntropyCoding);
  if FReader.ReadBit then
  begin
    Coding.CacheBits := FReader.ReadBits(4);
    if (Coding.CacheBits < 1) or (Coding.CacheBits > MaximumCacheBits) then
      Fail('colour cache size');
  end;
  GroupCount := 1;
  Mapping := nil;
  if IsMainImage and FReader.ReadBit then
  begin
    Coding.MetaBits := LongInt(FReader.ReadBits(3)) + 2;
    Coding.MetaWidth := SubsampledSize(Width, Coding.MetaBits);
    Coding.MetaImage := DecodeSubimage(Coding.MetaWidth, SubsampledSize(Height, Coding.MetaBits));
    GroupCount := 0;
    for Index := 0 to High(Coding.MetaImage) do
    begin
      Group := (Coding.MetaImage[Index] shr 8) and $FFFF;
      Coding.MetaImage[Index] := Group;
      if Group >= GroupCount then
        GroupCount := Group + 1;
    end;
    { Only the groups some tile uses get tables; the others are read
      and dropped. }
    SetLength(Mapping, GroupCount);
    for Index := 0 to GroupCount - 1 do
      Mapping[Index] := -1;
    UsedCount := 0;
    for Index := 0 to High(Coding.MetaImage) do
    begin
      Group := Coding.MetaImage[Index];
      if Mapping[Group] < 0 then
      begin
        Mapping[Group] := UsedCount;
        Inc(UsedCount);
      end;
      Coding.MetaImage[Index] := Mapping[Group];
    end;
    SetLength(Coding.Groups, UsedCount);
  end
  else
    SetLength(Coding.Groups, 1);
  Lengths := nil;
  SetLength(Lengths, LiteralCodes + LengthCodes + (1 shl MaximumCacheBits));
  for Index := 0 to GroupCount - 1 do
    for CodeIndex := 0 to CodesPerGroup - 1 do
    begin
      AlphabetSize := AlphabetSizes[CodeIndex];
      if (CodeIndex = GreenCode) and (Coding.CacheBits > 0) then
        Inc(AlphabetSize, 1 shl Coding.CacheBits);
      if (Mapping <> nil) and (Mapping[Index] < 0) then
        ReadPrefixCode(AlphabetSize, Lengths, Discarded)
      else if Mapping <> nil then
        ReadPrefixCode(AlphabetSize, Lengths, Coding.Groups[Mapping[Index]][CodeIndex])
      else
        ReadPrefixCode(AlphabetSize, Lengths, Coding.Groups[Index][CodeIndex]);
    end;
end;

{ The value of a length or distance prefix symbol with its extra bits. }
function ReadPrefixedValue(Symbol: LongInt; Reader: TLosslessBitReader): LongInt;
var
  ExtraBits: LongInt;
  Offset: LongInt;
begin
  if Symbol < 4 then
    Exit(Symbol + 1);
  ExtraBits := (Symbol - 2) shr 1;
  Offset := (2 + (Symbol and 1)) shl ExtraBits;
  Result := Offset + LongInt(Reader.ReadBits(ExtraBits)) + 1;
end;

function PlaneCodeToDistance(Width, PlaneCode: LongInt): LongInt;
var
  DistanceCode: LongInt;
  LinesUp: LongInt;
  ColumnsLeft: LongInt;
begin
  if PlaneCode > PlaneCodes then
    Exit(PlaneCode - PlaneCodes);
  DistanceCode := CodeToPlane[PlaneCode - 1];
  LinesUp := DistanceCode shr 4;
  ColumnsLeft := 8 - (DistanceCode and $F);
  Result := LinesUp * Width + ColumnsLeft;
  if Result < 1 then
    Result := 1;
end;

function CacheIndex(Color: LongWord; CacheBits: LongInt): LongInt; inline;
begin
  Result := LongInt(LongWord((QWord(Color) * QWord($1E35A7BD)) and $FFFFFFFF) shr (32 - CacheBits));
end;

procedure TLosslessDecoder.DecodePixels(Pixels: PLongWord; Width, Height: LongInt; constref Coding: TEntropyCoding);
var
  Cache: array of LongWord;
  Position: PtrInt;
  Total: PtrInt;
  CachedUpTo: PtrInt;
  X: LongInt;
  Y: LongInt;
  GroupIndex: LongInt;
  Code: LongInt;
  Red: LongWord;
  Blue: LongWord;
  Alpha: LongWord;
  CopyLength: LongInt;
  Distance: LongInt;
  Index: LongInt;
  MetaMask: LongInt;
  CacheLimit: LongInt;

  procedure UpdateCache;
  begin
    while CachedUpTo < Position do
    begin
      Cache[CacheIndex(Pixels[CachedUpTo], Coding.CacheBits)] := Pixels[CachedUpTo];
      Inc(CachedUpTo);
    end;
  end;

  procedure SelectGroup;
  begin
    if Coding.MetaBits = 0 then
      GroupIndex := 0
    else
      GroupIndex := Coding.MetaImage[(Y shr Coding.MetaBits) * Coding.MetaWidth + (X shr Coding.MetaBits)];
  end;

begin
  Cache := nil;
  if Coding.CacheBits > 0 then
    SetLength(Cache, 1 shl Coding.CacheBits);
  CacheLimit := LiteralCodes + LengthCodes + Length(Cache);
  Total := PtrInt(Width) * Height;
  Position := 0;
  CachedUpTo := 0;
  X := 0;
  Y := 0;
  GroupIndex := 0;
  if Coding.MetaBits > 0 then
    MetaMask := (1 shl Coding.MetaBits) - 1
  else
    MetaMask := -1;
  SelectGroup;
  while Position < Total do
  begin
    if (X and MetaMask) = 0 then
      SelectGroup;
    Code := ReadSymbol(Coding.Groups[GroupIndex][GreenCode], FReader);
    if Code < LiteralCodes then
    begin
      Red := ReadSymbol(Coding.Groups[GroupIndex][RedCode], FReader);
      Blue := ReadSymbol(Coding.Groups[GroupIndex][BlueCode], FReader);
      Alpha := ReadSymbol(Coding.Groups[GroupIndex][AlphaCode], FReader);
      Pixels[Position] := (Alpha shl 24) or (Red shl 16) or (LongWord(Code) shl 8) or Blue;
      Inc(Position);
      Inc(X);
      if X >= Width then
      begin
        X := 0;
        Inc(Y);
        if Cache <> nil then
          UpdateCache;
      end;
    end
    else if Code < LiteralCodes + LengthCodes then
    begin
      CopyLength := ReadPrefixedValue(Code - LiteralCodes, FReader);
      Code := ReadSymbol(Coding.Groups[GroupIndex][DistanceCode], FReader);
      Distance := PlaneCodeToDistance(Width, ReadPrefixedValue(Code, FReader));
      if (Position < Distance) or (Total - Position < CopyLength) then
        Fail('backward reference out of the image');
      for Index := 0 to CopyLength - 1 do
        Pixels[Position + Index] := Pixels[Position + Index - Distance];
      Inc(Position, CopyLength);
      Inc(X, CopyLength);
      while X >= Width do
      begin
        Dec(X, Width);
        Inc(Y);
      end;
      if (X and MetaMask) <> 0 then
        SelectGroup;
      if Cache <> nil then
        UpdateCache;
    end
    else if Code < CacheLimit then
    begin
      UpdateCache;
      Pixels[Position] := Cache[Code - LiteralCodes - LengthCodes];
      Inc(Position);
      Inc(X);
      if X >= Width then
      begin
        X := 0;
        Inc(Y);
        UpdateCache;
      end;
    end
    else
      Fail('symbol');
  end;
end;

function TLosslessDecoder.DecodeSubimage(Width, Height: LongInt): TLongWordArray;
var
  Coding: TEntropyCoding;
begin
  ReadCoding(Width, Height, False, Coding);
  Result := nil;
  SetLength(Result, PtrInt(Width) * Height);
  DecodePixels(@Result[0], Width, Height, Coding);
end;

procedure TLosslessDecoder.ReadTransform(var Width: LongInt; Height: LongInt);
var
  Kind: LongInt;
  ColorCount: LongInt;
begin
  Kind := FReader.ReadBits(2);
  if (FTransformsSeen and (1 shl Kind)) <> 0 then
    Fail('transform repeated');
  FTransformsSeen := FTransformsSeen or (1 shl Kind);
  FTransforms[FTransformCount].Kind := Kind;
  FTransforms[FTransformCount].Width := Width;
  FTransforms[FTransformCount].Bits := 0;
  FTransforms[FTransformCount].Data := nil;
  case Kind of
    TransformPredictor, TransformColor:
      begin
        FTransforms[FTransformCount].Bits := LongInt(FReader.ReadBits(3)) + 2;
        FTransforms[FTransformCount].Data := DecodeSubimage(
          SubsampledSize(Width, FTransforms[FTransformCount].Bits),
          SubsampledSize(Height, FTransforms[FTransformCount].Bits));
      end;
    TransformColorIndexing:
      begin
        ColorCount := LongInt(FReader.ReadBits(8)) + 1;
        if ColorCount > 16 then
          FTransforms[FTransformCount].Bits := 0
        else if ColorCount > 4 then
          FTransforms[FTransformCount].Bits := 1
        else if ColorCount > 2 then
          FTransforms[FTransformCount].Bits := 2
        else
          FTransforms[FTransformCount].Bits := 3;
        Width := SubsampledSize(Width, FTransforms[FTransformCount].Bits);
        FTransforms[FTransformCount].Data := DecodeSubimage(ColorCount, 1);
        ExpandPalette(FTransforms[FTransformCount], ColorCount);
      end;
  end;
  Inc(FTransformCount);
end;

function TLosslessDecoder.UndoTransforms(Pixels: PLongWord; CodedWidth, Height: LongInt): PLongWord;
var
  Index: LongInt;
  Width: LongInt;
  Expanded: PLongWord;
begin
  Result := Pixels;
  Width := CodedWidth;
  Index := FTransformCount - 1;
  while Index >= 0 do
  begin
    case FTransforms[Index].Kind of
      TransformPredictor:
        UndoPredictor(Result, Width, Height, FTransforms[Index]);
      TransformColor:
        UndoColorTransform(Result, Width, Height, FTransforms[Index]);
      TransformSubtractGreen:
        UndoSubtractGreen(Result, PtrInt(Width) * Height);
      TransformColorIndexing:
        if FTransforms[Index].Bits = 0 then
          UndoColorIndexing(Result, Width, Height, FTransforms[Index], Result)
        else
        begin
          Expanded := GetMem(PtrUInt(FTransforms[Index].Width) * PtrUInt(Height) * SizeOf(LongWord));
          UndoColorIndexing(Result, Width, Height, FTransforms[Index], Expanded);
          FreeMem(Result);
          Result := Expanded;
          Width := FTransforms[Index].Width;
        end;
    end;
    Dec(Index);
  end;
end;

function TLosslessDecoder.DecodeImage(Width, Height: LongInt): PLongWord;
var
  CodedWidth: LongInt;
  Coding: TEntropyCoding;
  Pixels: PLongWord;
begin
  CheckImageSize(Width, Height);
  CodedWidth := Width;
  FTransformCount := 0;
  FTransformsSeen := 0;
  while FReader.ReadBit do
    ReadTransform(CodedWidth, Height);
  ReadCoding(CodedWidth, Height, True, Coding);
  Pixels := GetMem(PtrUInt(CodedWidth) * PtrUInt(Height) * SizeOf(LongWord));
  try
    DecodePixels(Pixels, CodedWidth, Height, Coding);
    Result := UndoTransforms(Pixels, CodedWidth, Height);
  except
    FreeMem(Pixels);
    raise;
  end;
end;

function DecodeLosslessPixels(Data: PByte; Size: PtrInt; Width, Height: LongInt): PLongWord;
var
  Decoder: TLosslessDecoder;
begin
  Decoder := TLosslessDecoder.Create(Data, Size);
  try
    Result := Decoder.DecodeImage(Width, Height);
  finally
    Decoder.Free;
  end;
end;

function DecodeLosslessImage(Data: PByte; Size: PtrInt): TImage;
var
  Header: TLosslessHeader;
  Pixels: PLongWord;
begin
  if not ReadLosslessHeader(Data, Size, Header) then
    RaiseImageError(ImageErrorMalformed, 'VP8L header');
  Pixels := DecodeLosslessPixels(Data + LosslessHeaderLength, Size - LosslessHeaderLength, Header.Width,
    Header.Height);
  try
    Result := TImage.CreateAdopting(Pixels, Header.Width, Header.Height);
  except
    FreeMem(Pixels);
    raise;
  end;
end;

end.
