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
  IndexedDB keys as the service sees them: byte strings whose byte
  order is the order of keys (Indexed Database API 3.0, 2.8 "compare
  two keys"). The platform script encodes them (81-indexeddb-keys.js):

    number  $10, then the double's 8 bytes big-endian, the sign bit
            flipped for a positive number, every bit for a negative
            one (-0 is written as 0)
    date    $20, then the time value the same way
    string  $30, then each UTF-16 code unit u as one byte u + 1 (u
            below $7F), two bytes $80 or (v shr 8), v and $FF with
            v = u - $7F (u below $407F), else three bytes
            $C0 or (u shr 10), (u shr 2) and $FF, (u and 3) shl 6;
            then a 0 byte
    binary  $40, then each byte b the same way as a code unit; a 0 byte
    array   $50, then the items' encodings, then a 0 byte

  No encoding is the beginning of another, so a key followed by another
  key (an index key and its record's primary key) still sorts by the
  first key, then the second, compared as bytes. That also makes every
  bound a "first entry at or above" search (PrefixSuccessor turns "above
  K" and "at or below K" into it).
}
unit Web.IndexedDb.Keys;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  KeyTagNumber = $10;
  KeyTagDate = $20;
  KeyTagString = $30;
  KeyTagBinary = $40;
  KeyTagArray = $50;

type
  { A key range (2.9); a missing bound is unbounded. }
  TIdbKeyRange = record
    HasLower, HasUpper: Boolean;
    LowerOpen, UpperOpen: Boolean;
    Lower, Upper: TBytes;
  end;

{ Negative, zero or positive as A sorts before, with or after B. }
function CompareKeyBytes(const A, B: TBytes): Integer;
{ Whether Key begins with Prefix. }
function KeyHasPrefix(const Key, Prefix: TBytes): Boolean;
{ The least byte string above every string beginning with Key; False
  when there is none (Key is all $FF bytes). }
function PrefixSuccessor(const Key: TBytes; out Successor: TBytes): Boolean;
{ The number of a number key; False for any other key. }
function KeyNumberValue(const Key: TBytes; out Value: Double): Boolean;
{ The key of a number (what the key generator makes). }
function NumberKey(Value: Double): TBytes;
function KeyInRange(constref Range: TIdbKeyRange; const Key: TBytes): Boolean;
function UnboundedRange: TIdbKeyRange;
function ConcatKeys(const First, Second: TBytes): TBytes;

implementation

function CompareKeyBytes(const A, B: TBytes): Integer;
var
  Shorter, Index: Integer;
begin
  Shorter := Length(A);
  if Length(B) < Shorter then
    Shorter := Length(B);
  for Index := 0 to Shorter - 1 do
    if A[Index] <> B[Index] then
      Exit(Integer(A[Index]) - Integer(B[Index]));
  Result := Length(A) - Length(B);
end;

function KeyHasPrefix(const Key, Prefix: TBytes): Boolean;
var
  Index: Integer;
begin
  if Length(Prefix) > Length(Key) then
    Exit(False);
  for Index := 0 to Length(Prefix) - 1 do
    if Key[Index] <> Prefix[Index] then
      Exit(False);
  Result := True;
end;

function PrefixSuccessor(const Key: TBytes; out Successor: TBytes): Boolean;
var
  Last: Integer;
begin
  Successor := nil;
  Last := Length(Key) - 1;
  while (Last >= 0) and (Key[Last] = $FF) do
    Dec(Last);
  if Last < 0 then
    Exit(False);
  Successor := Copy(Key, 0, Last + 1);
  Inc(Successor[Last]);
  Result := True;
end;

function KeyNumberValue(const Key: TBytes; out Value: Double): Boolean;
var
  Bits: QWord;
  Index: Integer;
begin
  Value := 0;
  if (Length(Key) <> 9) or (Key[0] <> KeyTagNumber) then
    Exit(False);
  Bits := 0;
  for Index := 1 to 8 do
    Bits := (Bits shl 8) or Key[Index];
  if (Bits and QWord($8000000000000000)) <> 0 then
    Bits := Bits xor QWord($8000000000000000)
  else
    Bits := not Bits;
  Move(Bits, Value, 8);
  Result := True;
end;

function NumberKey(Value: Double): TBytes;
var
  Bits: QWord;
  Index: Integer;
begin
  if Value = 0 then
    Value := 0;
  Move(Value, Bits, 8);
  if (Bits and QWord($8000000000000000)) <> 0 then
    Bits := not Bits
  else
    Bits := Bits xor QWord($8000000000000000);
  Result := nil;
  SetLength(Result, 9);
  Result[0] := KeyTagNumber;
  for Index := 8 downto 1 do
  begin
    Result[Index] := Bits and $FF;
    Bits := Bits shr 8;
  end;
end;

function KeyInRange(constref Range: TIdbKeyRange; const Key: TBytes): Boolean;
var
  Comparison: Integer;
begin
  if Range.HasLower then
  begin
    Comparison := CompareKeyBytes(Key, Range.Lower);
    if (Comparison < 0) or ((Comparison = 0) and Range.LowerOpen) then
      Exit(False);
  end;
  if Range.HasUpper then
  begin
    Comparison := CompareKeyBytes(Key, Range.Upper);
    if (Comparison > 0) or ((Comparison = 0) and Range.UpperOpen) then
      Exit(False);
  end;
  Result := True;
end;

function UnboundedRange: TIdbKeyRange;
begin
  Result := Default(TIdbKeyRange);
end;

function ConcatKeys(const First, Second: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(First) + Length(Second));
  if Length(First) > 0 then
    Move(First[0], Result[0], Length(First));
  if Length(Second) > 0 then
    Move(Second[0], Result[Length(First)], Length(Second));
end;

end.
