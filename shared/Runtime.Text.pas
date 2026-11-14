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
  Text helpers shared by the loader and the kernel.

  Strings are plain null-terminated character arrays (PChar). Number
  formatting writes into a caller supplied TNumberText buffer, so nothing
  here ever allocates memory.
}
unit Runtime.Text;

{$mode objfpc}
{$pointermath on}

interface

type
  { Large enough for a 64-bit value in binary plus the terminator. }
  TNumberText = array[0..65] of Char;

function TextLength(Text: PChar): PtrUInt;
function TextIsEqual(First: PChar; Second: PChar): Boolean;

{ Copies at most DestinationCapacity - 1 characters and always terminates. }
procedure CopyText(Destination: PChar; Source: PChar; DestinationCapacity: PtrUInt);

{ Formats Value in the given base (2..16), padding with leading zeros up to
  MinimumDigits. Returns a pointer into Buffer. }
function FormatUnsigned(Value: QWord; Base: LongWord; MinimumDigits: LongWord;
  var Buffer: TNumberText): PChar;

function FormatDecimal(Value: QWord; var Buffer: TNumberText): PChar;
function FormatSignedDecimal(Value: Int64; var Buffer: TNumberText): PChar;
function FormatHexadecimal(Value: QWord; MinimumDigits: LongWord; var Buffer: TNumberText): PChar;

implementation

const
  DigitCharacters: array[0..15] of Char = '0123456789ABCDEF';

function TextLength(Text: PChar): PtrUInt;
begin
  Result := 0;
  if Text = nil then
    Exit;
  while Text[Result] <> #0 do
    Inc(Result);
end;

function TextIsEqual(First: PChar; Second: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while (First[Index] <> #0) and (First[Index] = Second[Index]) do
    Inc(Index);
  Result := First[Index] = Second[Index];
end;

procedure CopyText(Destination: PChar; Source: PChar; DestinationCapacity: PtrUInt);
var
  Index: PtrUInt;
begin
  if DestinationCapacity = 0 then
    Exit;

  Index := 0;
  while (Index < DestinationCapacity - 1) and (Source[Index] <> #0) do
  begin
    Destination[Index] := Source[Index];
    Inc(Index);
  end;
  Destination[Index] := #0;
end;

function FormatUnsigned(Value: QWord; Base: LongWord; MinimumDigits: LongWord;
  var Buffer: TNumberText): PChar;
var
  Position: Integer;
  DigitCount: LongWord;
begin
  if (Base < 2) or (Base > 16) then
    Base := 10;

  Position := High(Buffer);
  Buffer[Position] := #0;
  DigitCount := 0;

  repeat
    Dec(Position);
    Buffer[Position] := DigitCharacters[Value mod Base];
    Value := Value div Base;
    Inc(DigitCount);
  until (Value = 0) and (DigitCount >= MinimumDigits);

  Result := @Buffer[Position];
end;

function FormatDecimal(Value: QWord; var Buffer: TNumberText): PChar;
begin
  Result := FormatUnsigned(Value, 10, 1, Buffer);
end;

function FormatSignedDecimal(Value: Int64; var Buffer: TNumberText): PChar;
var
  Magnitude: QWord;
begin
  if Value >= 0 then
    Exit(FormatUnsigned(QWord(Value), 10, 1, Buffer));

  { Negating in unsigned arithmetic also handles the most negative value. }
  Magnitude := QWord(0) - QWord(Value);
  Result := FormatUnsigned(Magnitude, 10, 1, Buffer);
  Dec(Result);
  Result^ := '-';
end;

function FormatHexadecimal(Value: QWord; MinimumDigits: LongWord; var Buffer: TNumberText): PChar;
begin
  Result := FormatUnsigned(Value, 16, MinimumDigits, Buffer);
end;

end.
