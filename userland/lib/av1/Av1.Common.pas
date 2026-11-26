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
  The mathematical functions of the AV1 specification (section 4.7):
  Clip3, Round2, Round2Signed, FloorLog2, CeilLog2, and the decoder's
  error (EAv1Error, raised for streams that break the format's rules or
  use what the decoder does not support).

  The specification's >> on negative numbers is an arithmetic shift;
  Free Pascal's shr is logical, so ShiftRight (SarLongint / SarInt64)
  is used wherever the value can be negative.
}
unit Av1.Common;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EAv1Error = class(Exception);

procedure RaiseAv1Error(const Detail: string);

function Clip3(Low, High, Value: Integer): Integer; inline;
function Round2(Value: Integer; Bits: Integer): Integer; inline;
function Round2Int64(Value: Int64; Bits: Integer): Int64; inline;
function Round2Signed(Value: Integer; Bits: Integer): Integer; inline;
function Round2SignedInt64(Value: Int64; Bits: Integer): Int64; inline;
function ShiftRight(Value: Integer; Bits: Integer): Integer; inline;
function ShiftRight64(Value: Int64; Bits: Integer): Int64; inline;
function FloorLog2(Value: LongWord): Integer;
function CeilLog2(Value: LongWord): Integer;
function Min(A, B: Integer): Integer; inline;
function Max(A, B: Integer): Integer; inline;

implementation

procedure RaiseAv1Error(const Detail: string);
begin
  raise EAv1Error.Create('AV1: ' + Detail);
end;

function Clip3(Low, High, Value: Integer): Integer;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function Round2(Value: Integer; Bits: Integer): Integer;
begin
  if Bits = 0 then
    Result := Value
  else
    Result := SarLongint(Value + (1 shl (Bits - 1)), Bits);
end;

function Round2Int64(Value: Int64; Bits: Integer): Int64;
begin
  if Bits = 0 then
    Result := Value
  else
    Result := SarInt64(Value + (Int64(1) shl (Bits - 1)), Bits);
end;

function Round2Signed(Value: Integer; Bits: Integer): Integer;
begin
  if Value >= 0 then
    Result := Round2(Value, Bits)
  else
    Result := -Round2(-Value, Bits);
end;

function Round2SignedInt64(Value: Int64; Bits: Integer): Int64;
begin
  if Value >= 0 then
    Result := Round2Int64(Value, Bits)
  else
    Result := -Round2Int64(-Value, Bits);
end;

function ShiftRight(Value: Integer; Bits: Integer): Integer;
begin
  Result := SarLongint(Value, Bits);
end;

function ShiftRight64(Value: Int64; Bits: Integer): Int64;
begin
  Result := SarInt64(Value, Bits);
end;

function FloorLog2(Value: LongWord): Integer;
begin
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

function CeilLog2(Value: LongWord): Integer;
var
  Power: QWord;
begin
  if Value < 2 then
    Exit(0);
  Result := 1;
  Power := 2;
  while Power < Value do
  begin
    Inc(Result);
    Power := Power shl 1;
  end;
end;

function Min(A, B: Integer): Integer;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

function Max(A, B: Integer): Integer;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

end.
