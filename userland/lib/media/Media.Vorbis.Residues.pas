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
  Vorbis residues (specification section 8): the fine structure of the
  spectrum, multiplied by the floor.

  The coded range of each channel's vector is cut into partitions; a
  classification codebook gives the class of several partitions at once,
  and up to eight passes each add, for every partition whose class has a
  book in that pass, a vector-quantised refinement. Type 0 interleaves a
  codeword's values across the partition, type 1 lays them out in order,
  and type 2 decodes all the channels as one vector interleaved sample by
  sample (as type 1) and then splits it.

  An end of packet stops the decoding where it is: what was read so far
  stands (section 8.6.2).
}
unit Media.Vorbis.Residues;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Vorbis.BitReader,
  Media.Vorbis.Codebooks,
  Media.Vorbis.Floors;

type
  TResidueVectors = array of PSingle;
  TChannelFlags = array of Boolean;

  TVorbisResidue = class
  private
    FResidueType: Integer;
    FBegin, FEnd, FPartitionSize, FClassifications, FClassbook: Integer;
    FCascade: array of Integer;
    FBooks: array of array[0..7] of Integer;
    FClassNumbers: array of Integer;
    FInterleaved: array of Single;
    { Type 2's one vector and its flag. }
    FOneVector: TResidueVectors;
    FOneFlag: TChannelFlags;
    procedure DecodeVectors(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
      const Vectors: TResidueVectors; const DoNotDecode: TChannelFlags; ChannelCount, VectorSize: Integer;
      Interleaving: Boolean);
  public
    constructor Create(ResidueType: Integer);
    procedure ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList);
    { Decodes ChannelCount vectors of HalfSize values at Vectors (zeroed
      first); channels flagged in DoNotDecode are left zero. }
    procedure Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
      const Vectors: TResidueVectors; const DoNotDecode: TChannelFlags; ChannelCount, HalfSize: Integer);
  end;

implementation

uses
  Media.Errors;

constructor TVorbisResidue.Create(ResidueType: Integer);
begin
  inherited Create;
  FResidueType := ResidueType;
end;

procedure TVorbisResidue.ReadFrom(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList);
var
  Classification, Pass, HighBits, LowBits: Integer;
begin
  FBegin := ReadBits(Reader, 24);
  FEnd := ReadBits(Reader, 24);
  FPartitionSize := ReadBits(Reader, 24) + 1;
  FClassifications := ReadBits(Reader, 6) + 1;
  FClassbook := ReadBits(Reader, 8);
  if FClassbook >= Length(Codebooks) then
    MediaFail('Vorbis residue names a missing codebook');
  if Codebooks[FClassbook].Dimensions < 1 then
    MediaFail('Vorbis residue classbook without dimensions');
  SetLength(FCascade, FClassifications);
  SetLength(FBooks, FClassifications);
  for Classification := 0 to FClassifications - 1 do
  begin
    HighBits := 0;
    LowBits := ReadBits(Reader, 3);
    if ReadBit(Reader) then
      HighBits := ReadBits(Reader, 5);
    FCascade[Classification] := HighBits * 8 + LowBits;
  end;
  for Classification := 0 to FClassifications - 1 do
    for Pass := 0 to 7 do
      if (FCascade[Classification] and (1 shl Pass)) <> 0 then
      begin
        FBooks[Classification][Pass] := ReadBits(Reader, 8);
        if FBooks[Classification][Pass] >= Length(Codebooks) then
          MediaFail('Vorbis residue names a missing codebook');
        if Codebooks[FBooks[Classification][Pass]].LookupType = 0 then
          MediaFail('Vorbis residue book without vectors');
      end
      else
        FBooks[Classification][Pass] := -1;
end;

procedure TVorbisResidue.DecodeVectors(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
  const Vectors: TResidueVectors; const DoNotDecode: TChannelFlags; ChannelCount, VectorSize: Integer;
  Interleaving: Boolean);
var
  LimitBegin, LimitEnd, ClasswordsPerCodeword, PartitionsToRead, Pass, PartitionCount, Channel, Temp, Index,
  ClassNumber, BookNumber, Offset, Step, Dimensions, Entry, Position, Dimension, Stride: Integer;
  Classbook, Book: TVorbisCodebook;
  Target: PSingle;
  Values: PSingle;
begin
  LimitBegin := FBegin;
  if LimitBegin > VectorSize then
    LimitBegin := VectorSize;
  LimitEnd := FEnd;
  if LimitEnd > VectorSize then
    LimitEnd := VectorSize;
  if LimitEnd <= LimitBegin then
    Exit;
  Classbook := Codebooks[FClassbook];
  ClasswordsPerCodeword := Classbook.Dimensions;
  PartitionsToRead := (LimitEnd - LimitBegin) div FPartitionSize;
  if PartitionsToRead = 0 then
    Exit;
  Stride := PartitionsToRead + ClasswordsPerCodeword;
  if Length(FClassNumbers) < Stride * ChannelCount then
    SetLength(FClassNumbers, Stride * ChannelCount);
  for Pass := 0 to 7 do
  begin
    PartitionCount := 0;
    while PartitionCount < PartitionsToRead do
    begin
      if Pass = 0 then
        for Channel := 0 to ChannelCount - 1 do
          if not DoNotDecode[Channel] then
          begin
            Temp := Classbook.DecodeEntry(Reader);
            if Temp < 0 then
              Exit;
            for Index := ClasswordsPerCodeword - 1 downto 0 do
            begin
              FClassNumbers[Channel * Stride + PartitionCount + Index] := Temp mod FClassifications;
              Temp := Temp div FClassifications;
            end;
          end;
      Index := 0;
      while (Index < ClasswordsPerCodeword) and (PartitionCount < PartitionsToRead) do
      begin
        for Channel := 0 to ChannelCount - 1 do
          if not DoNotDecode[Channel] then
          begin
            ClassNumber := FClassNumbers[Channel * Stride + PartitionCount];
            BookNumber := FBooks[ClassNumber][Pass];
            if BookNumber < 0 then
              Continue;
            Book := Codebooks[BookNumber];
            Dimensions := Book.Dimensions;
            Offset := LimitBegin + PartitionCount * FPartitionSize;
            Target := Vectors[Channel] + Offset;
            if not Interleaving then
            begin
              { Type 1 (and type 2's single vector): values in order. }
              Position := 0;
              while Position < FPartitionSize do
              begin
                Entry := Book.DecodeEntry(Reader);
                if Entry < 0 then
                  Exit;
                Values := @Book.Vectors[Entry * Dimensions];
                for Dimension := 0 to Dimensions - 1 do
                begin
                  if Position >= FPartitionSize then
                    Break;
                  Target[Position] := Target[Position] + Values[Dimension];
                  Inc(Position);
                end;
              end;
            end
            else
            begin
              { Type 0: a codeword's values Step apart. }
              Step := FPartitionSize div Dimensions;
              for Position := 0 to Step - 1 do
              begin
                Entry := Book.DecodeEntry(Reader);
                if Entry < 0 then
                  Exit;
                Values := @Book.Vectors[Entry * Dimensions];
                for Dimension := 0 to Dimensions - 1 do
                  Target[Position + Dimension * Step] := Target[Position + Dimension * Step] + Values[Dimension];
              end;
            end;
          end;
        Inc(Index);
        Inc(PartitionCount);
      end;
    end;
  end;
end;

procedure TVorbisResidue.Decode(var Reader: TVorbisBitReader; const Codebooks: TVorbisCodebookList;
  const Vectors: TResidueVectors; const DoNotDecode: TChannelFlags; ChannelCount, HalfSize: Integer);
var
  Channel, Index: Integer;
  AnyToDecode: Boolean;
  Source: PSingle;
begin
  for Channel := 0 to ChannelCount - 1 do
    FillChar(Vectors[Channel]^, HalfSize * SizeOf(Single), 0);
  if FResidueType <> 2 then
  begin
    DecodeVectors(Reader, Codebooks, Vectors, DoNotDecode, ChannelCount, HalfSize, FResidueType = 0);
    Exit;
  end;
  AnyToDecode := False;
  for Channel := 0 to ChannelCount - 1 do
    if not DoNotDecode[Channel] then
      AnyToDecode := True;
  if not AnyToDecode then
    Exit;
  if Length(FInterleaved) < HalfSize * ChannelCount then
    SetLength(FInterleaved, HalfSize * ChannelCount);
  FillChar(FInterleaved[0], HalfSize * ChannelCount * SizeOf(Single), 0);
  SetLength(FOneVector, 1);
  FOneVector[0] := @FInterleaved[0];
  SetLength(FOneFlag, 1);
  FOneFlag[0] := False;
  DecodeVectors(Reader, Codebooks, FOneVector, FOneFlag, 1, HalfSize * ChannelCount, False);
  Source := @FInterleaved[0];
  for Index := 0 to HalfSize - 1 do
    for Channel := 0 to ChannelCount - 1 do
    begin
      Vectors[Channel][Index] := Source^;
      Inc(Source);
    end;
end;

end.
