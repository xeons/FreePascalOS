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
  LZ77 for the VP8L encoder: the pixels as literals and backward
  references (copy Length pixels from Distance back), found greedily
  through hash chains on pairs of pixels. A distance that is a near
  2-D neighbour (up to 7 lines up, 8 pixels left or 7 right) gets its
  short plane code, others the distance plus 120, as VP8L counts them.
}
unit Image.WebP.BackwardReferences;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

const
  MaximumCopyLength = 4096;

type
  TPixelToken = record
    { 0 for a literal. }
    Length: LongInt;
    { The literal's colour, or the distance code (plane code) of a
      copy. }
    Value: LongWord;
  end;
  TPixelTokens = array of TPixelToken;

{ The tokens of Width x Height pixels; Count is how many there are. }
function FindBackwardReferences(Pixels: PLongWord; Width, Height: LongInt; out Count: LongInt): TPixelTokens;

{ The VP8L prefix code of a length or distance code Value (1 or more):
  its symbol and extra bits. }
procedure PrefixEncode(Value: LongInt; out Symbol, ExtraBits, ExtraValue: LongInt);

implementation

const
  HashBits = 16;
  MinimumMatch = 3;
  MaximumTries = 32;
  MaximumDistance = 1 shl 18;
  PlaneCodes = 120;

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

procedure PrefixEncode(Value: LongInt; out Symbol, ExtraBits, ExtraValue: LongInt);
var
  Remainder: LongInt;
  HighestBit: LongInt;
  SecondBit: LongInt;
begin
  Remainder := Value - 1;
  if Remainder < 4 then
  begin
    Symbol := Remainder;
    ExtraBits := 0;
    ExtraValue := 0;
    Exit;
  end;
  HighestBit := 0;
  while (Remainder shr (HighestBit + 1)) <> 0 do
    Inc(HighestBit);
  SecondBit := (Remainder shr (HighestBit - 1)) and 1;
  ExtraBits := HighestBit - 1;
  ExtraValue := Remainder and ((1 shl ExtraBits) - 1);
  Symbol := 2 * HighestBit + SecondBit;
end;

function PairHash(First, Second: LongWord): LongInt; inline;
var
  Mixed: QWord;
begin
  Mixed := ((QWord(First) * QWord($1E35A7BD)) xor (QWord(Second) * QWord($7A8C1F13))) and $FFFFFFFF;
  Result := LongInt(Mixed shr (32 - HashBits));
end;

function FindBackwardReferences(Pixels: PLongWord; Width, Height: LongInt; out Count: LongInt): TPixelTokens;
var
  Total: PtrInt;
  Heads: array of LongInt;
  Chain: array of LongInt;
  PlaneDistances: array[1..PlaneCodes] of LongInt;
  Position: PtrInt;
  Candidate: LongInt;
  Tries: LongInt;
  BestLength: LongInt;
  BestDistance: LongInt;
  MatchLength: LongInt;
  Limit: LongInt;
  Index: LongInt;
  Code: LongInt;

  procedure Insert(At: PtrInt);
  var
    Hash: LongInt;
  begin
    if At + 1 >= Total then
      Exit;
    Hash := PairHash(Pixels[At], Pixels[At + 1]);
    Chain[At] := Heads[Hash];
    Heads[Hash] := At;
  end;

  procedure AddToken(TokenLength: LongInt; Value: LongWord);
  begin
    if Count >= Length(Result) then
      SetLength(Result, 2 * Length(Result) + 1024);
    Result[Count].Length := TokenLength;
    Result[Count].Value := Value;
    Inc(Count);
  end;

  function DistanceCode(Distance: LongInt): LongInt;
  var
    PlaneCode: LongInt;
  begin
    for PlaneCode := 1 to PlaneCodes do
      if PlaneDistances[PlaneCode] = Distance then
        Exit(PlaneCode);
    Result := Distance + PlaneCodes;
  end;

begin
  Result := nil;
  Count := 0;
  Total := PtrInt(Width) * Height;
  Heads := nil;
  Chain := nil;
  SetLength(Heads, 1 shl HashBits);
  for Index := 0 to High(Heads) do
    Heads[Index] := -1;
  SetLength(Chain, Total);
  for Index := 1 to PlaneCodes do
  begin
    Code := CodeToPlane[Index - 1];
    PlaneDistances[Index] := (Code shr 4) * Width + 8 - (Code and $F);
  end;
  Position := 0;
  while Position < Total do
  begin
    BestLength := 0;
    BestDistance := 0;
    if Position + 1 < Total then
    begin
      Limit := MaximumCopyLength;
      if Total - Position < Limit then
        Limit := Total - Position;
      Candidate := Heads[PairHash(Pixels[Position], Pixels[Position + 1])];
      Tries := 0;
      while (Candidate >= 0) and (Tries < MaximumTries) and (Position - Candidate <= MaximumDistance) do
      begin
        MatchLength := 0;
        while (MatchLength < Limit) and (Pixels[Candidate + MatchLength] = Pixels[Position + MatchLength]) do
          Inc(MatchLength);
        if MatchLength > BestLength then
        begin
          BestLength := MatchLength;
          BestDistance := Position - Candidate;
          if MatchLength = Limit then
            Break;
        end;
        Candidate := Chain[Candidate];
        Inc(Tries);
      end;
    end;
    if BestLength >= MinimumMatch then
    begin
      AddToken(BestLength, DistanceCode(BestDistance));
      for Index := 0 to BestLength - 1 do
        Insert(Position + Index);
      Inc(Position, BestLength);
    end
    else
    begin
      AddToken(0, Pixels[Position]);
      Insert(Position);
      Inc(Position);
    end;
  end;
end;

end.
