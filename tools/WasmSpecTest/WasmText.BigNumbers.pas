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
  Unsigned integers of any size, just enough of them for rounding a
  float literal correctly: building one from digits, multiplying by a
  small number, shifting, comparing and subtracting. Limbs are 32 bits,
  least significant first, with no zero limbs at the top.
}
unit WasmText.BigNumbers;

{$mode objfpc}
{$H+}

interface

type
  TBigNumber = array of Cardinal;

function BigFromSmall(Value: Cardinal): TBigNumber;
procedure BigMultiplyAdd(var Number: TBigNumber; Factor, Addend: Cardinal);
function BigShiftLeft(const Number: TBigNumber; Bits: Integer): TBigNumber;
function BigCompare(const Left, Right: TBigNumber): Integer;
{ Left := Left - Right, with Left >= Right. }
procedure BigSubtract(var Left: TBigNumber; const Right: TBigNumber);
function BigBitLength(const Number: TBigNumber): Integer;
function BigIsZero(const Number: TBigNumber): Boolean;
function BigPowerOfTen(Exponent: Integer): TBigNumber;

implementation

procedure Normalize(var Number: TBigNumber);
var
  Size: Integer;
begin
  Size := Length(Number);
  while (Size > 0) and (Number[Size - 1] = 0) do
    Dec(Size);
  SetLength(Number, Size);
end;

function BigFromSmall(Value: Cardinal): TBigNumber;
begin
  Result := nil;
  if Value <> 0 then
  begin
    SetLength(Result, 1);
    Result[0] := Value;
  end;
end;

procedure BigMultiplyAdd(var Number: TBigNumber; Factor, Addend: Cardinal);
var
  Index: Integer;
  Carry, Product: QWord;
begin
  Carry := Addend;
  for Index := 0 to High(Number) do
  begin
    Product := QWord(Number[Index]) * Factor + Carry;
    Number[Index] := Cardinal(Product and $FFFFFFFF);
    Carry := Product shr 32;
  end;
  if Carry <> 0 then
  begin
    SetLength(Number, Length(Number) + 1);
    Number[High(Number)] := Cardinal(Carry);
  end;
end;

function BigShiftLeft(const Number: TBigNumber; Bits: Integer): TBigNumber;
var
  LimbShift, BitShift, Index: Integer;
  Value: QWord;
begin
  Result := nil;
  if Length(Number) = 0 then
    Exit;
  LimbShift := Bits div 32;
  BitShift := Bits mod 32;
  SetLength(Result, Length(Number) + LimbShift + 1);
  for Index := 0 to High(Result) do
    Result[Index] := 0;
  for Index := 0 to High(Number) do
  begin
    Value := QWord(Number[Index]) shl BitShift;
    Result[Index + LimbShift] := Result[Index + LimbShift] or Cardinal(Value and $FFFFFFFF);
    Result[Index + LimbShift + 1] := Cardinal(Value shr 32);
  end;
  Normalize(Result);
end;

function BigCompare(const Left, Right: TBigNumber): Integer;
var
  Index: Integer;
begin
  if Length(Left) <> Length(Right) then
  begin
    if Length(Left) < Length(Right) then
      Result := -1
    else
      Result := 1;
    Exit;
  end;
  for Index := High(Left) downto 0 do
    if Left[Index] <> Right[Index] then
    begin
      if Left[Index] < Right[Index] then
        Result := -1
      else
        Result := 1;
      Exit;
    end;
  Result := 0;
end;

procedure BigSubtract(var Left: TBigNumber; const Right: TBigNumber);
var
  Index: Integer;
  Borrow, Difference: Int64;
begin
  Borrow := 0;
  for Index := 0 to High(Left) do
  begin
    Difference := Int64(Left[Index]) - Borrow;
    if Index <= High(Right) then
      Difference := Difference - Int64(Right[Index]);
    if Difference < 0 then
    begin
      Difference := Difference + (Int64(1) shl 32);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Left[Index] := Cardinal(Difference);
  end;
  Normalize(Left);
end;

function BigBitLength(const Number: TBigNumber): Integer;
var
  Top: Cardinal;
begin
  if Length(Number) = 0 then
    Exit(0);
  Result := (Length(Number) - 1) * 32;
  Top := Number[High(Number)];
  while Top <> 0 do
  begin
    Inc(Result);
    Top := Top shr 1;
  end;
end;

function BigIsZero(const Number: TBigNumber): Boolean;
begin
  Result := Length(Number) = 0;
end;

function BigPowerOfTen(Exponent: Integer): TBigNumber;
var
  Index: Integer;
begin
  Result := BigFromSmall(1);
  for Index := 1 to Exponent div 9 do
    BigMultiplyAdd(Result, 1000000000, 0);
  for Index := 1 to Exponent mod 9 do
    BigMultiplyAdd(Result, 10, 0);
end;

end.
