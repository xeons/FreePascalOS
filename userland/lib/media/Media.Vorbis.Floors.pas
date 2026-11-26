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
  Vorbis floors: the spectral envelope of each channel.

  Floor 1 (specification section 7) is a piecewise linear curve in a
  decibel scale through points whose X positions the setup gives and
  whose Y values each packet codes as offsets from the line through
  their neighbours; it is drawn with integer Bresenham steps and looked
  up in the inverse decibel table. Floor 0 (section 6, which no encoder
  has made since 2002, but streams may have it) is an LSP filter's
  amplitude response sampled on the Bark scale.

  Decoding a floor reads its packet data into a TFloorChannelData;
  synthesis then turns that into the curve the residue is multiplied by.
}
unit Media.Vorbis.Floors;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Vorbis.BitReader,
  Media.Vorbis.Codebooks;

type
  TVorbisCodebookList = array of TVorbisCodebook;

  { One channel's floor data from a packet. }
  TFloorChannelData = record
    YValues: array of Integer;
    Amplitude: Integer;
    Coefficients: array of Single;
  end;

  TVorbisFloor = class
  public
    procedure ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList); virtual; abstract;
    { Reads one channel's floor; False if the floor is unused (the
      channel is silent). }
    function Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
      var Data: TFloorChannelData): Boolean; virtual; abstract;
    { Writes the curve for a block of 2 * HalfSize samples at Curve
      (HalfSize values). }
    procedure Synthesize(const Data: TFloorChannelData; HalfSize: Integer; Curve: PSingle); virtual; abstract;
  end;

  TVorbisFloor0 = class(TVorbisFloor)
  private
    FOrder, FRate, FBarkMapSize, FAmplitudeBits, FAmplitudeOffset: Integer;
    FBooks: array of Integer;
    { The Bark maps for the two block sizes, made when first needed. }
    FMapSizes: array[0..1] of Integer;
    FMaps: array[0..1] of array of Integer;
    function MapFor(HalfSize: Integer): PInteger;
  public
    procedure ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList); override;
    function Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
      var Data: TFloorChannelData): Boolean; override;
    procedure Synthesize(const Data: TFloorChannelData; HalfSize: Integer; Curve: PSingle); override;
  end;

  TVorbisFloor1 = class(TVorbisFloor)
  private
    FPartitionClasses: array of Integer;
    FClassDimensions: array[0..15] of Integer;
    FClassSubclasses: array[0..15] of Integer;
    FClassMasterbooks: array[0..15] of Integer;
    FSubclassBooks: array[0..15, 0..7] of Integer;
    FMultiplier: Integer;
    FXList: array of Integer;
    { Each point's neighbours among the points before it, and the order
      of the points by X. }
    FLowNeighbour, FHighNeighbour: array of Integer;
    FSortedOrder: array of Integer;
    procedure PrepareNeighbours;
  public
    procedure ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList); override;
    function Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
      var Data: TFloorChannelData): Boolean; override;
    procedure Synthesize(const Data: TFloorChannelData; HalfSize: Integer; Curve: PSingle); override;
  end;

var
  { Floor 1's inverse decibel table (section 10.1). }
  InverseDecibelTable: array[0..255] of Single;

implementation

uses
  Math,
  Media.Errors;

{ TVorbisFloor0 }

procedure TVorbisFloor0.ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList);
var
  BookCount, Index: Integer;
begin
  FOrder := ReadBits(Reader, 8);
  FRate := ReadBits(Reader, 16);
  FBarkMapSize := ReadBits(Reader, 16);
  FAmplitudeBits := ReadBits(Reader, 6);
  FAmplitudeOffset := ReadBits(Reader, 8);
  BookCount := ReadBits(Reader, 4) + 1;
  SetLength(FBooks, BookCount);
  for Index := 0 to BookCount - 1 do
  begin
    FBooks[Index] := ReadBits(Reader, 8);
    if FBooks[Index] >= Length(Codebooks) then
      MediaFail('Vorbis floor 0 names a missing codebook');
  end;
  if (FOrder < 1) or (FRate < 1) or (FBarkMapSize < 1) then
    MediaFail('bad Vorbis floor 0');
end;

function TVorbisFloor0.Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
  var Data: TFloorChannelData): Boolean;
var
  BookNumber, Entry, Count, Index, Dimensions: Integer;
  Book: TVorbisCodebook;
  Last: Single;
begin
  Data.Amplitude := ReadBits(Reader, FAmplitudeBits);
  if (Data.Amplitude = 0) or Reader.EndOfPacket then
    Exit(False);
  BookNumber := ReadBits(Reader, VorbisIntegerLog(Length(FBooks)));
  if (BookNumber >= Length(FBooks)) or Reader.EndOfPacket then
    Exit(False);
  Book := Codebooks[FBooks[BookNumber]];
  Dimensions := Book.Dimensions;
  if (Book.LookupType = 0) or (Dimensions = 0) then
    Exit(False);
  if Length(Data.Coefficients) < FOrder + Dimensions then
    SetLength(Data.Coefficients, FOrder + Dimensions);
  Count := 0;
  Last := 0;
  while Count < FOrder do
  begin
    Entry := Book.DecodeEntry(Reader);
    if Entry < 0 then
      Exit(False);
    for Index := 0 to Dimensions - 1 do
      Data.Coefficients[Count + Index] := Book.Vectors[Entry * Dimensions + Index] + Last;
    Last := Data.Coefficients[Count + Dimensions - 1];
    Inc(Count, Dimensions);
  end;
  Result := True;
end;

function Bark(Frequency: Double): Double;
begin
  Result := 13.1 * ArcTan(0.00074 * Frequency) + 2.24 * ArcTan(0.0000000185 * Frequency * Frequency)
    + 0.0001 * Frequency;
end;

function TVorbisFloor0.MapFor(HalfSize: Integer): PInteger;
var
  Slot, Index, Value: Integer;
  Scale: Double;
begin
  for Slot := 0 to 1 do
    if FMapSizes[Slot] = HalfSize then
      Exit(@FMaps[Slot][0]);
  if FMapSizes[0] = 0 then
    Slot := 0
  else
    Slot := 1;
  FMapSizes[Slot] := HalfSize;
  SetLength(FMaps[Slot], HalfSize + 1);
  Scale := FBarkMapSize / Bark(0.5 * FRate);
  for Index := 0 to HalfSize - 1 do
  begin
    Value := Floor(Bark(FRate * Index / (2.0 * HalfSize)) * Scale);
    if Value > FBarkMapSize - 1 then
      Value := FBarkMapSize - 1;
    FMaps[Slot][Index] := Value;
  end;
  FMaps[Slot][HalfSize] := -1;
  Result := @FMaps[Slot][0];
end;

procedure TVorbisFloor0.Synthesize(const Data: TFloorChannelData; HalfSize: Integer; Curve: PSingle);
var
  Map: PInteger;
  Index, Term, Current: Integer;
  Omega, CosOmega, P, Q, LinearValue: Double;
begin
  Map := MapFor(HalfSize);
  Index := 0;
  while Index < HalfSize do
  begin
    Current := Map[Index];
    Omega := Pi * Current / FBarkMapSize;
    CosOmega := Cos(Omega);
    if Odd(FOrder) then
    begin
      P := 1 - CosOmega * CosOmega;
      for Term := 0 to (FOrder - 3) div 2 do
        P := P * 4 * Sqr(Cos(Data.Coefficients[2 * Term + 1]) - CosOmega);
      Q := 0.25;
      for Term := 0 to (FOrder - 1) div 2 do
        Q := Q * 4 * Sqr(Cos(Data.Coefficients[2 * Term]) - CosOmega);
    end
    else
    begin
      P := (1 - CosOmega) / 2;
      Q := (1 + CosOmega) / 2;
      for Term := 0 to FOrder div 2 - 1 do
      begin
        P := P * 4 * Sqr(Cos(Data.Coefficients[2 * Term + 1]) - CosOmega);
        Q := Q * 4 * Sqr(Cos(Data.Coefficients[2 * Term]) - CosOmega);
      end;
    end;
    if P + Q <= 0 then
      LinearValue := 0
    else
      LinearValue := Exp(0.11512925 * (Data.Amplitude * FAmplitudeOffset /
        (((1 shl FAmplitudeBits) - 1) * Sqrt(P + Q)) - FAmplitudeOffset));
    while (Index < HalfSize) and (Map[Index] = Current) do
    begin
      Curve[Index] := LinearValue;
      Inc(Index);
    end;
  end;
end;

{ TVorbisFloor1 }

procedure TVorbisFloor1.ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList);
var
  Partitions, MaximumClass, ClassIndex, Subclass, Partition, Dimension, RangeBits, Count, Other: Integer;

  procedure CheckBook(Book: Integer);
  begin
    if Book >= Length(Codebooks) then
      MediaFail('Vorbis floor 1 names a missing codebook');
  end;

begin
  Partitions := ReadBits(Reader, 5);
  SetLength(FPartitionClasses, Partitions);
  MaximumClass := -1;
  for Partition := 0 to Partitions - 1 do
  begin
    FPartitionClasses[Partition] := ReadBits(Reader, 4);
    MaximumClass := Max(MaximumClass, FPartitionClasses[Partition]);
  end;
  for ClassIndex := 0 to MaximumClass do
  begin
    FClassDimensions[ClassIndex] := ReadBits(Reader, 3) + 1;
    FClassSubclasses[ClassIndex] := ReadBits(Reader, 2);
    FClassMasterbooks[ClassIndex] := -1;
    if FClassSubclasses[ClassIndex] > 0 then
    begin
      FClassMasterbooks[ClassIndex] := ReadBits(Reader, 8);
      CheckBook(FClassMasterbooks[ClassIndex]);
    end;
    for Subclass := 0 to (1 shl FClassSubclasses[ClassIndex]) - 1 do
    begin
      FSubclassBooks[ClassIndex, Subclass] := LongInt(ReadBits(Reader, 8)) - 1;
      CheckBook(FSubclassBooks[ClassIndex, Subclass]);
    end;
  end;
  FMultiplier := ReadBits(Reader, 2) + 1;
  RangeBits := ReadBits(Reader, 4);
  Count := 2;
  for Partition := 0 to Partitions - 1 do
    Inc(Count, FClassDimensions[FPartitionClasses[Partition]]);
  if Count > 65 then
    MediaFail('Vorbis floor 1 has too many points');
  SetLength(FXList, Count);
  FXList[0] := 0;
  FXList[1] := 1 shl RangeBits;
  Count := 2;
  for Partition := 0 to Partitions - 1 do
    for Dimension := 0 to FClassDimensions[FPartitionClasses[Partition]] - 1 do
    begin
      FXList[Count] := ReadBits(Reader, RangeBits);
      Inc(Count);
    end;
  for Partition := 0 to Count - 1 do
    for Other := Partition + 1 to Count - 1 do
      if FXList[Partition] = FXList[Other] then
        MediaFail('Vorbis floor 1 repeats a point');
  PrepareNeighbours;
end;

procedure TVorbisFloor1.PrepareNeighbours;
var
  Count, Point, Other, Swap: Integer;
begin
  Count := Length(FXList);
  SetLength(FLowNeighbour, Count);
  SetLength(FHighNeighbour, Count);
  for Point := 2 to Count - 1 do
  begin
    FLowNeighbour[Point] := 0;
    FHighNeighbour[Point] := 1;
    for Other := 0 to Point - 1 do
    begin
      if (FXList[Other] < FXList[Point]) and (FXList[Other] > FXList[FLowNeighbour[Point]]) then
        FLowNeighbour[Point] := Other;
      if (FXList[Other] > FXList[Point]) and (FXList[Other] < FXList[FHighNeighbour[Point]]) then
        FHighNeighbour[Point] := Other;
    end;
  end;
  SetLength(FSortedOrder, Count);
  for Point := 0 to Count - 1 do
    FSortedOrder[Point] := Point;
  { Insertion sort by X: at most 65 points. }
  for Point := 1 to Count - 1 do
  begin
    Other := Point;
    while (Other > 0) and (FXList[FSortedOrder[Other - 1]] > FXList[FSortedOrder[Other]]) do
    begin
      Swap := FSortedOrder[Other];
      FSortedOrder[Other] := FSortedOrder[Other - 1];
      FSortedOrder[Other - 1] := Swap;
      Dec(Other);
    end;
  end;
end;

function TVorbisFloor1.Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
  var Data: TFloorChannelData): Boolean;
const
  Ranges: array[1..4] of Integer = (256, 128, 86, 64);
var
  RangeBitCount, Offset, Partition, ClassIndex, Dimensions, ClassBits, SubclassMask, ClassValue, Index, Book,
  Entry: Integer;
begin
  if not ReadBit(Reader) then
    Exit(False);
  if Length(Data.YValues) < Length(FXList) then
    SetLength(Data.YValues, Length(FXList));
  RangeBitCount := VorbisIntegerLog(Ranges[FMultiplier] - 1);
  Data.YValues[0] := ReadBits(Reader, RangeBitCount);
  Data.YValues[1] := ReadBits(Reader, RangeBitCount);
  Offset := 2;
  for Partition := 0 to High(FPartitionClasses) do
  begin
    ClassIndex := FPartitionClasses[Partition];
    Dimensions := FClassDimensions[ClassIndex];
    ClassBits := FClassSubclasses[ClassIndex];
    SubclassMask := (1 shl ClassBits) - 1;
    ClassValue := 0;
    if ClassBits > 0 then
    begin
      ClassValue := Codebooks[FClassMasterbooks[ClassIndex]].DecodeEntry(Reader);
      if ClassValue < 0 then
        Exit(False);
    end;
    for Index := 0 to Dimensions - 1 do
    begin
      Book := FSubclassBooks[ClassIndex, ClassValue and SubclassMask];
      ClassValue := ClassValue shr ClassBits;
      if Book >= 0 then
      begin
        Entry := Codebooks[Book].DecodeEntry(Reader);
        if Entry < 0 then
          Exit(False);
        Data.YValues[Offset + Index] := Entry;
      end
      else
        Data.YValues[Offset + Index] := 0;
    end;
    Inc(Offset, Dimensions);
  end;
  Result := not Reader.EndOfPacket;
end;

function RenderPoint(X0, Y0, X1, Y1, X: Integer): Integer; inline;
var
  DeltaY, AbsoluteDeltaX, AbsoluteDeltaY, Error, Offset: Integer;
begin
  DeltaY := Y1 - Y0;
  AbsoluteDeltaX := X1 - X0;
  AbsoluteDeltaY := Abs(DeltaY);
  Error := AbsoluteDeltaY * (X - X0);
  Offset := Error div AbsoluteDeltaX;
  if DeltaY < 0 then
    Result := Y0 - Offset
  else
    Result := Y0 + Offset;
end;

{ Draws the line from (X0, Y0) to (X1, Y1), X1 excluded and nothing at or
  past Limit, as inverse decibel values into Curve. }
procedure RenderLine(X0, Y0, X1, Y1, Limit: Integer; Curve: PSingle);
var
  DeltaY, AbsoluteDeltaX, AbsoluteDeltaY, Base, StepY, X, Y, Error, Last: Integer;
begin
  DeltaY := Y1 - Y0;
  AbsoluteDeltaX := X1 - X0;
  if AbsoluteDeltaX <= 0 then
    Exit;
  AbsoluteDeltaY := Abs(DeltaY);
  Base := DeltaY div AbsoluteDeltaX;
  if DeltaY < 0 then
    StepY := Base - 1
  else
    StepY := Base + 1;
  AbsoluteDeltaY := AbsoluteDeltaY - Abs(Base) * AbsoluteDeltaX;
  Y := Y0;
  Error := 0;
  Last := Min(X1, Limit);
  if X0 < Last then
    Curve[X0] := InverseDecibelTable[Y and 255];
  for X := X0 + 1 to Last - 1 do
  begin
    Inc(Error, AbsoluteDeltaY);
    if Error >= AbsoluteDeltaX then
    begin
      Dec(Error, AbsoluteDeltaX);
      Inc(Y, StepY);
    end
    else
      Inc(Y, Base);
    Curve[X] := InverseDecibelTable[Y and 255];
  end;
end;

procedure TVorbisFloor1.Synthesize(const Data: TFloorChannelData; HalfSize: Integer; Curve: PSingle);
const
  Ranges: array[1..4] of Integer = (256, 128, 86, 64);
var
  Range, Count, Point, Low, High, Predicted, Value, HighRoom, LowRoom, Room, Sorted, LowX, LowY, HighX,
  HighY: Integer;
  FinalY: array[0..64] of Integer;
  Step2: array[0..64] of Boolean;
begin
  Range := Ranges[FMultiplier];
  Count := Length(FXList);
  Step2[0] := True;
  Step2[1] := True;
  FinalY[0] := Data.YValues[0];
  FinalY[1] := Data.YValues[1];
  for Point := 2 to Count - 1 do
  begin
    Low := FLowNeighbour[Point];
    High := FHighNeighbour[Point];
    Predicted := RenderPoint(FXList[Low], FinalY[Low], FXList[High], FinalY[High], FXList[Point]);
    Value := Data.YValues[Point];
    HighRoom := Range - Predicted;
    LowRoom := Predicted;
    if HighRoom < LowRoom then
      Room := HighRoom * 2
    else
      Room := LowRoom * 2;
    if Value <> 0 then
    begin
      Step2[Low] := True;
      Step2[High] := True;
      Step2[Point] := True;
      if Value >= Room then
      begin
        if HighRoom > LowRoom then
          FinalY[Point] := Value - LowRoom + Predicted
        else
          FinalY[Point] := Predicted - Value + HighRoom - 1;
      end
      else if Odd(Value) then
        FinalY[Point] := Predicted - (Value + 1) div 2
      else
        FinalY[Point] := Predicted + Value div 2;
    end
    else
    begin
      Step2[Point] := False;
      FinalY[Point] := Predicted;
    end;
  end;
  LowX := 0;
  LowY := FinalY[FSortedOrder[0]] * FMultiplier;
  HighX := 0;
  HighY := LowY;
  for Sorted := 1 to Count - 1 do
  begin
    Point := FSortedOrder[Sorted];
    if Step2[Point] then
    begin
      HighY := FinalY[Point] * FMultiplier;
      HighX := FXList[Point];
      RenderLine(LowX, LowY, HighX, HighY, HalfSize, Curve);
      LowX := HighX;
      LowY := HighY;
    end;
  end;
  if HighX < HalfSize then
    RenderLine(HighX, HighY, HalfSize, HighY, HalfSize, Curve);
end;

procedure FillInverseDecibelTable;
var
  Index: Integer;
  StepLog: Double;
begin
  { The table's entries are 1.0649863e-07 * r^i, r^255 making the last
    1.0: the published values to within a unit in the last place. }
  StepLog := -Ln(1.0649863e-07) / 255;
  for Index := 0 to 255 do
    InverseDecibelTable[Index] := Exp((Index - 255) * StepLog);
end;

initialization
  FillInverseDecibelTable;
end.
