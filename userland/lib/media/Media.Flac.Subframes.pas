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
  FLAC subframes (RFC 9639 section 9.2): one channel of a frame.

  A subframe is constant (one value), verbatim (raw samples), fixed
  prediction (orders 0 to 4, set polynomials) or linear prediction
  (orders 1 to 32, quantised coefficients and a shift), the predictors'
  residual Rice coded in 2^order partitions, each with its own parameter
  or an escape to raw bits. Wasted bits (low bits zero in every sample)
  are taken off before coding and put back after.

  Samples are 64-bit, so 32-bit audio and its 33-bit side channel need no
  special path; predictions sum in 64 bits.
}
unit Media.Flac.Subframes;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Flac.BitReader;

type
  TFlacSamples = array of Int64;

{ Decodes one subframe of BlockSize samples, BitsPerSample wide, into
  Samples (which has room); False if it is malformed. }
function DecodeFlacSubframe(var Reader: TFlacBitReader; BlockSize, BitsPerSample: Integer;
  Samples: PInt64): Boolean;

implementation

function DecodeResidual(var Reader: TFlacBitReader; BlockSize, Order: Integer; Residual: PInt64): Boolean;
var
  Method, PartitionOrder, Partitions, Partition, ParameterBits, Escape: Integer;
  Parameter, Count, Index, Written, RawBits: Integer;
begin
  Result := False;
  Method := ReadBits(Reader, 2);
  if Method > 1 then
    Exit;
  if Method = 0 then
  begin
    ParameterBits := 4;
    Escape := 15;
  end
  else
  begin
    ParameterBits := 5;
    Escape := 31;
  end;
  PartitionOrder := ReadBits(Reader, 4);
  Partitions := 1 shl PartitionOrder;
  if (BlockSize and (Partitions - 1)) <> 0 then
    Exit;
  if (BlockSize shr PartitionOrder) < Order then
    Exit;
  Written := 0;
  for Partition := 0 to Partitions - 1 do
  begin
    Count := BlockSize shr PartitionOrder;
    if Partition = 0 then
      Dec(Count, Order);
    Parameter := ReadBits(Reader, ParameterBits);
    if Parameter = Escape then
    begin
      RawBits := ReadBits(Reader, 5);
      if RawBits = 0 then
        for Index := 0 to Count - 1 do
          Residual[Written + Index] := 0
      else
        for Index := 0 to Count - 1 do
          Residual[Written + Index] := ReadSignedBits(Reader, RawBits);
    end
    else
      for Index := 0 to Count - 1 do
        Residual[Written + Index] := ReadRice(Reader, Parameter);
    Inc(Written, Count);
    if Reader.Overrun then
      Exit;
  end;
  Result := True;
end;

procedure RestoreFixed(Samples: PInt64; BlockSize, Order: Integer);
var
  Index: Integer;
begin
  case Order of
    1:
      for Index := 1 to BlockSize - 1 do
        Samples[Index] := Samples[Index] + Samples[Index - 1];
    2:
      for Index := 2 to BlockSize - 1 do
        Samples[Index] := Samples[Index] + 2 * Samples[Index - 1] - Samples[Index - 2];
    3:
      for Index := 3 to BlockSize - 1 do
        Samples[Index] := Samples[Index] + 3 * Samples[Index - 1] - 3 * Samples[Index - 2] + Samples[Index - 3];
    4:
      for Index := 4 to BlockSize - 1 do
        Samples[Index] := Samples[Index] + 4 * Samples[Index - 1] - 6 * Samples[Index - 2] +
          4 * Samples[Index - 3] - Samples[Index - 4];
  end;
end;

procedure RestoreLinear(Samples: PInt64; BlockSize, Order, Shift: Integer; const Coefficients: array of Int64);
var
  Index, Tap: Integer;
  Sum: Int64;
  History: PInt64;
begin
  for Index := Order to BlockSize - 1 do
  begin
    Sum := 0;
    History := @Samples[Index - 1];
    for Tap := 0 to Order - 1 do
    begin
      Sum := Sum + Coefficients[Tap] * History^;
      Dec(History);
    end;
    Samples[Index] := Samples[Index] + SarInt64(Sum, Shift);
  end;
end;

function DecodeFlacSubframe(var Reader: TFlacBitReader; BlockSize, BitsPerSample: Integer;
  Samples: PInt64): Boolean;
var
  Kind, Wasted, Order, Index, Precision, Shift: Integer;
  Value: Int64;
  Coefficients: array[0..31] of Int64;
begin
  Result := False;
  if ReadBits(Reader, 1) <> 0 then
    Exit;
  Kind := ReadBits(Reader, 6);
  Wasted := 0;
  if ReadBits(Reader, 1) <> 0 then
  begin
    Wasted := ReadUnary(Reader) + 1;
    if Wasted >= BitsPerSample then
      Exit;
    Dec(BitsPerSample, Wasted);
  end;
  case Kind of
    0:
      begin
        Value := ReadSignedBits(Reader, BitsPerSample);
        for Index := 0 to BlockSize - 1 do
          Samples[Index] := Value;
      end;
    1:
      for Index := 0 to BlockSize - 1 do
        Samples[Index] := ReadSignedBits(Reader, BitsPerSample);
    8..12:
      begin
        Order := Kind - 8;
        if Order > BlockSize then
          Exit;
        for Index := 0 to Order - 1 do
          Samples[Index] := ReadSignedBits(Reader, BitsPerSample);
        if not DecodeResidual(Reader, BlockSize, Order, @Samples[Order]) then
          Exit;
        RestoreFixed(Samples, BlockSize, Order);
      end;
    32..63:
      begin
        Order := Kind - 31;
        if Order > BlockSize then
          Exit;
        for Index := 0 to Order - 1 do
          Samples[Index] := ReadSignedBits(Reader, BitsPerSample);
        Precision := ReadBits(Reader, 4);
        if Precision = 15 then
          Exit;
        Inc(Precision);
        Shift := ReadSignedBits(Reader, 5);
        if Shift < 0 then
          Exit;
        for Index := 0 to Order - 1 do
          Coefficients[Index] := ReadSignedBits(Reader, Precision);
        if not DecodeResidual(Reader, BlockSize, Order, @Samples[Order]) then
          Exit;
        RestoreLinear(Samples, BlockSize, Order, Shift, Slice(Coefficients, Order));
      end;
  else
    Exit;
  end;
  if Reader.Overrun then
    Exit;
  if Wasted > 0 then
    for Index := 0 to BlockSize - 1 do
      Samples[Index] := Samples[Index] shl Wasted;
  Result := True;
end;

end.
