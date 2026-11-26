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
  The numeric operators of spec section 4.3 that the processor does not
  do exactly as the spec says by itself.

  Rounding to an integral value (ceil, floor, trunc, nearest) works on
  the bits, so that it is exact for every value and keeps the sign of
  zero; a NaN comes back quiet. min and max order -0 below +0 and give a
  NaN when either operand is one. The conversions to integers report a
  NaN or an out of range value instead of converting (the trapping
  ones) or saturate (the _sat ones). Integer to f32 conversions of 64-bit
  values round once, directly to single precision: through double they
  could round twice.

  Arithmetic itself (add, sub, mul, div, sqrt) is the processor's, in
  single precision for f32; with floating point exceptions masked it is
  IEEE 754, and its NaN results are what the spec allows.
}
unit Wasm.Numerics;

{$mode objfpc}
{$H+}
{$R-}
{$Q-}

interface

const
  F32SignBit = DWord($80000000);
  F32QuietBit = DWord($00400000);
  F64SignBit = QWord($8000000000000000);
  F64QuietBit = QWord($0008000000000000);

type
  { The outcome of a trapping conversion. }
  TConversionResult = (crExact, crNotANumber, crOverflow);

function F32IsNaN(Bits: DWord): Boolean; inline;
function F64IsNaN(Bits: QWord): Boolean; inline;
function F32Ceil(Bits: DWord): DWord;
function F32Floor(Bits: DWord): DWord;
function F32Trunc(Bits: DWord): DWord;
function F32Nearest(Bits: DWord): DWord;
function F64Ceil(Bits: QWord): QWord;
function F64Floor(Bits: QWord): QWord;
function F64Trunc(Bits: QWord): QWord;
function F64Nearest(Bits: QWord): QWord;
function F32Min(A, B: DWord): DWord;
function F32Max(A, B: DWord): DWord;
function F64Min(A, B: QWord): QWord;
function F64Max(A, B: QWord): QWord;

function TruncateToI32(Value: Double; out Output: Int32): TConversionResult;
function TruncateToU32(Value: Double; out Output: DWord): TConversionResult;
function TruncateToI64(Value: Double; out Output: Int64): TConversionResult;
function TruncateToU64(Value: Double; out Output: QWord): TConversionResult;
function SaturateToI32(Value: Double): Int32;
function SaturateToU32(Value: Double): DWord;
function SaturateToI64(Value: Double): Int64;
function SaturateToU64(Value: Double): QWord;

function I64ToF32(Value: Int64): Single;
function U64ToF32(Value: QWord): Single;
function U64ToF64(Value: QWord): Double;
function U32ToF32(Value: DWord): Single; inline;

function CountLeadingZeros32(Value: DWord): DWord; inline;
function CountTrailingZeros32(Value: DWord): DWord; inline;
function CountLeadingZeros64(Value: QWord): QWord; inline;
function CountTrailingZeros64(Value: QWord): QWord; inline;
function RotateLeft32(Value: DWord; Count: DWord): DWord; inline;
function RotateRight32(Value: DWord; Count: DWord): DWord; inline;
function RotateLeft64(Value: QWord; Count: QWord): QWord; inline;
function RotateRight64(Value: QWord; Count: QWord): QWord; inline;

implementation

function F32IsNaN(Bits: DWord): Boolean;
begin
  Result := (Bits and $7FFFFFFF) > $7F800000;
end;

function F64IsNaN(Bits: QWord): Boolean;
begin
  Result := (Bits and QWord($7FFFFFFFFFFFFFFF)) > QWord($7FF0000000000000);
end;

{ The exponent of a finite value (unbiased), or 255 / 2047 for an
  infinity or NaN. }

function F32Trunc(Bits: DWord): DWord;
var
  Exponent: Integer;
begin
  Exponent := Integer((Bits shr 23) and $FF);
  if Exponent = $FF then
  begin
    if F32IsNaN(Bits) then
      Exit(Bits or F32QuietBit);
    Exit(Bits);
  end;
  Dec(Exponent, 127);
  if Exponent < 0 then
    Exit(Bits and F32SignBit);
  if Exponent >= 23 then
    Exit(Bits);
  Result := Bits and not ((DWord(1) shl (23 - Exponent)) - 1);
end;

{ Rounds the magnitude up (away from zero) to an integer. }
function F32RoundMagnitudeUp(Bits: DWord): DWord;
var
  Exponent: Integer;
  Mask: DWord;
begin
  Exponent := Integer((Bits shr 23) and $FF) - 127;
  if Bits and $7FFFFFFF = 0 then
    Exit(Bits);
  if Exponent < 0 then
    Exit((Bits and F32SignBit) or $3F800000);
  if Exponent >= 23 then
    Exit(Bits);
  Mask := (DWord(1) shl (23 - Exponent)) - 1;
  Result := (Bits + Mask) and not Mask;
end;

function F32Ceil(Bits: DWord): DWord;
begin
  if (Bits shr 23) and $FF = $FF then
    Exit(F32Trunc(Bits));
  if Bits and F32SignBit <> 0 then
    Result := F32Trunc(Bits)
  else
    Result := F32RoundMagnitudeUp(Bits);
end;

function F32Floor(Bits: DWord): DWord;
begin
  if (Bits shr 23) and $FF = $FF then
    Exit(F32Trunc(Bits));
  if Bits and F32SignBit <> 0 then
    Result := F32RoundMagnitudeUp(Bits)
  else
    Result := F32Trunc(Bits);
end;

function F32Nearest(Bits: DWord): DWord;
var
  Exponent: Integer;
  Mask, Half, Fraction, Integral: DWord;
begin
  Exponent := Integer((Bits shr 23) and $FF);
  if Exponent = $FF then
    Exit(F32Trunc(Bits));
  Dec(Exponent, 127);
  if Exponent >= 23 then
    Exit(Bits);
  if Exponent < -1 then
    Exit(Bits and F32SignBit);
  if Exponent = -1 then
  begin
    { 0.5 <= |x| < 1: a half rounds to the even zero. }
    if Bits and $7FFFFF = 0 then
      Exit(Bits and F32SignBit);
    Exit((Bits and F32SignBit) or $3F800000);
  end;
  Mask := (DWord(1) shl (23 - Exponent)) - 1;
  Half := DWord(1) shl (22 - Exponent);
  Fraction := Bits and Mask;
  Integral := Bits and not Mask;
  if (Fraction > Half) or ((Fraction = Half) and (Integral and (Mask + 1) <> 0)) then
    Integral := Integral + Mask + 1;
  Result := Integral;
end;

function F64Trunc(Bits: QWord): QWord;
var
  Exponent: Integer;
begin
  Exponent := Integer((Bits shr 52) and $7FF);
  if Exponent = $7FF then
  begin
    if F64IsNaN(Bits) then
      Exit(Bits or F64QuietBit);
    Exit(Bits);
  end;
  Dec(Exponent, 1023);
  if Exponent < 0 then
    Exit(Bits and F64SignBit);
  if Exponent >= 52 then
    Exit(Bits);
  Result := Bits and not ((QWord(1) shl (52 - Exponent)) - 1);
end;

function F64RoundMagnitudeUp(Bits: QWord): QWord;
var
  Exponent: Integer;
  Mask: QWord;
begin
  Exponent := Integer((Bits shr 52) and $7FF) - 1023;
  if Bits and QWord($7FFFFFFFFFFFFFFF) = 0 then
    Exit(Bits);
  if Exponent < 0 then
    Exit((Bits and F64SignBit) or QWord($3FF0000000000000));
  if Exponent >= 52 then
    Exit(Bits);
  Mask := (QWord(1) shl (52 - Exponent)) - 1;
  Result := (Bits + Mask) and not Mask;
end;

function F64Ceil(Bits: QWord): QWord;
begin
  if (Bits shr 52) and $7FF = $7FF then
    Exit(F64Trunc(Bits));
  if Bits and F64SignBit <> 0 then
    Result := F64Trunc(Bits)
  else
    Result := F64RoundMagnitudeUp(Bits);
end;

function F64Floor(Bits: QWord): QWord;
begin
  if (Bits shr 52) and $7FF = $7FF then
    Exit(F64Trunc(Bits));
  if Bits and F64SignBit <> 0 then
    Result := F64RoundMagnitudeUp(Bits)
  else
    Result := F64Trunc(Bits);
end;

function F64Nearest(Bits: QWord): QWord;
var
  Exponent: Integer;
  Mask, Half, Fraction, Integral: QWord;
begin
  Exponent := Integer((Bits shr 52) and $7FF);
  if Exponent = $7FF then
    Exit(F64Trunc(Bits));
  Dec(Exponent, 1023);
  if Exponent >= 52 then
    Exit(Bits);
  if Exponent < -1 then
    Exit(Bits and F64SignBit);
  if Exponent = -1 then
  begin
    if Bits and QWord($FFFFFFFFFFFFF) = 0 then
      Exit(Bits and F64SignBit);
    Exit((Bits and F64SignBit) or QWord($3FF0000000000000));
  end;
  Mask := (QWord(1) shl (52 - Exponent)) - 1;
  Half := QWord(1) shl (51 - Exponent);
  Fraction := Bits and Mask;
  Integral := Bits and not Mask;
  if (Fraction > Half) or ((Fraction = Half) and (Integral and (Mask + 1) <> 0)) then
    Integral := Integral + Mask + 1;
  Result := Integral;
end;

function F32Min(A, B: DWord): DWord;
begin
  if F32IsNaN(A) then
    Exit(A or F32QuietBit);
  if F32IsNaN(B) then
    Exit(B or F32QuietBit);
  if PSingle(@A)^ = PSingle(@B)^ then
    Exit(A or B);
  if PSingle(@A)^ < PSingle(@B)^ then
    Result := A
  else
    Result := B;
end;

function F32Max(A, B: DWord): DWord;
begin
  if F32IsNaN(A) then
    Exit(A or F32QuietBit);
  if F32IsNaN(B) then
    Exit(B or F32QuietBit);
  if PSingle(@A)^ = PSingle(@B)^ then
    Exit(A and B);
  if PSingle(@A)^ > PSingle(@B)^ then
    Result := A
  else
    Result := B;
end;

function F64Min(A, B: QWord): QWord;
begin
  if F64IsNaN(A) then
    Exit(A or F64QuietBit);
  if F64IsNaN(B) then
    Exit(B or F64QuietBit);
  if PDouble(@A)^ = PDouble(@B)^ then
    Exit(A or B);
  if PDouble(@A)^ < PDouble(@B)^ then
    Result := A
  else
    Result := B;
end;

function F64Max(A, B: QWord): QWord;
begin
  if F64IsNaN(A) then
    Exit(A or F64QuietBit);
  if F64IsNaN(B) then
    Exit(B or F64QuietBit);
  if PDouble(@A)^ = PDouble(@B)^ then
    Exit(A and B);
  if PDouble(@A)^ > PDouble(@B)^ then
    Result := A
  else
    Result := B;
end;

{ Typed, so that they stay doubles (an untyped constant may be a single). }
const
  TwoTo31: Double = 2147483648.0;
  BelowI32: Double = -2147483649.0;
  TwoTo32: Double = 4294967296.0;
  TwoTo63: Double = 9223372036854775808.0;
  TwoTo64: Double = 18446744073709551616.0;

function TruncateToI32(Value: Double; out Output: Int32): TConversionResult;
begin
  Output := 0;
  if Value <> Value then
    Exit(crNotANumber);
  if not ((Value > BelowI32) and (Value < TwoTo31)) then
    Exit(crOverflow);
  Output := Int32(Trunc(Value));
  Result := crExact;
end;

function TruncateToU32(Value: Double; out Output: DWord): TConversionResult;
begin
  Output := 0;
  if Value <> Value then
    Exit(crNotANumber);
  if not ((Value > -1.0) and (Value < TwoTo32)) then
    Exit(crOverflow);
  Output := DWord(Trunc(Value));
  Result := crExact;
end;

function TruncateToI64(Value: Double; out Output: Int64): TConversionResult;
begin
  Output := 0;
  if Value <> Value then
    Exit(crNotANumber);
  if not ((Value >= -TwoTo63) and (Value < TwoTo63)) then
    Exit(crOverflow);
  Output := Trunc(Value);
  Result := crExact;
end;

function TruncateToU64(Value: Double; out Output: QWord): TConversionResult;
begin
  Output := 0;
  if Value <> Value then
    Exit(crNotANumber);
  if not ((Value > -1.0) and (Value < TwoTo64)) then
    Exit(crOverflow);
  if Value >= TwoTo63 then
    Output := QWord(Trunc(Value - TwoTo63)) + QWord($8000000000000000)
  else
    Output := QWord(Trunc(Value));
  Result := crExact;
end;

function SaturateToI32(Value: Double): Int32;
begin
  if Value <> Value then
    Exit(0);
  if Value <= -TwoTo31 then
    Exit(Low(Int32));
  if Value >= TwoTo31 then
    Exit(High(Int32));
  Result := Int32(Trunc(Value));
end;

function SaturateToU32(Value: Double): DWord;
begin
  if (Value <> Value) or (Value <= 0.0) then
    Exit(0);
  if Value >= TwoTo32 then
    Exit(High(DWord));
  Result := DWord(Trunc(Value));
end;

function SaturateToI64(Value: Double): Int64;
begin
  if Value <> Value then
    Exit(0);
  if Value <= -TwoTo63 then
    Exit(Low(Int64));
  if Value >= TwoTo63 then
    Exit(High(Int64));
  Result := Trunc(Value);
end;

function SaturateToU64(Value: Double): QWord;
begin
  if (Value <> Value) or (Value <= 0.0) then
    Exit(0);
  if Value >= TwoTo64 then
    Exit(High(QWord));
  if Value >= TwoTo63 then
    Result := QWord(Trunc(Value - TwoTo63)) + QWord($8000000000000000)
  else
    Result := QWord(Trunc(Value));
end;

{ A magnitude of up to 64 bits as a double that rounds to the same single:
  bits below the 53 a double keeps are folded into a sticky bit, so the
  double is exact and the one rounding to single is correct. }
function MagnitudeToSingle(Magnitude: QWord): Single;
var
  Shift: Integer;
  Reduced: QWord;
  Value: Double;
begin
  if Magnitude < (QWord(1) shl 53) then
  begin
    Value := Int64(Magnitude);
    Exit(Value);
  end;
  Shift := 0;
  Reduced := Magnitude;
  while Reduced >= (QWord(1) shl 53) do
  begin
    Reduced := (Reduced shr 1) or (Reduced and 1);
    Inc(Shift);
  end;
  Value := Int64(Reduced);
  while Shift > 0 do
  begin
    Value := Value * 2.0;
    Dec(Shift);
  end;
  Result := Value;
end;

function I64ToF32(Value: Int64): Single;
begin
  if Value < 0 then
    Result := -MagnitudeToSingle(QWord(0) - QWord(Value))
  else
    Result := MagnitudeToSingle(QWord(Value));
end;

function U64ToF32(Value: QWord): Single;
begin
  Result := MagnitudeToSingle(Value);
end;

function U64ToF64(Value: QWord): Double;
begin
  if Value < QWord($8000000000000000) then
    Result := Int64(Value)
  else
  begin
    Result := Int64((Value shr 1) or (Value and 1));
    Result := Result * 2.0;
  end;
end;

function U32ToF32(Value: DWord): Single;
var
  Exact: Double;
begin
  Exact := Int64(Value);
  Result := Exact;
end;

function CountLeadingZeros32(Value: DWord): DWord;
begin
  if Value = 0 then
    Result := 32
  else
    Result := 31 - BsrDWord(Value);
end;

function CountTrailingZeros32(Value: DWord): DWord;
begin
  if Value = 0 then
    Result := 32
  else
    Result := BsfDWord(Value);
end;

function CountLeadingZeros64(Value: QWord): QWord;
begin
  if Value = 0 then
    Result := 64
  else
    Result := 63 - BsrQWord(Value);
end;

function CountTrailingZeros64(Value: QWord): QWord;
begin
  if Value = 0 then
    Result := 64
  else
    Result := BsfQWord(Value);
end;

function RotateLeft32(Value: DWord; Count: DWord): DWord;
begin
  Count := Count and 31;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shl Count) or (Value shr (32 - Count));
end;

function RotateRight32(Value: DWord; Count: DWord): DWord;
begin
  Count := Count and 31;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shr Count) or (Value shl (32 - Count));
end;

function RotateLeft64(Value: QWord; Count: QWord): QWord;
begin
  Count := Count and 63;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shl Count) or (Value shr (64 - Count));
end;

function RotateRight64(Value: QWord; Count: QWord): QWord;
begin
  Count := Count and 63;
  if Count = 0 then
    Result := Value
  else
    Result := (Value shr Count) or (Value shl (64 - Count));
end;

end.
