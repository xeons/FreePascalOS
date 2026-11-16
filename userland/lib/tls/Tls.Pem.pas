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
  PEM (RFC 7468): finding the "-----BEGIN CERTIFICATE-----" blocks of a
  text, such as a CA bundle, and decoding their base64 into DER. Text
  outside the blocks (comments, names) is skipped.
}
unit Tls.Pem;

{$mode objfpc}
{$pointermath on}

interface

type
  TPemScanner = record
    Position: PChar;
    Limit: PChar;
  end;

procedure BeginPemScan(out Scanner: TPemScanner; Text: PChar; Length: PtrUInt);
{ The next certificate block, decoded into a new buffer (free it with
  FreeMem); False when there are no more. A block that does not decode
  is skipped. }
function NextPemCertificate(var Scanner: TPemScanner; out Der: PByte; out DerLength: PtrUInt): Boolean;
{ Base64 (whitespace ignored, '=' padding) into Output, which needs
  3/4 of Length bytes; False for anything else. }
function DecodeBase64(Text: PChar; Length: PtrUInt; Output: PByte; out OutputLength: PtrUInt): Boolean;

implementation

const
  BeginMarker: PChar = '-----BEGIN CERTIFICATE-----';
  EndMarker: PChar = '-----END CERTIFICATE-----';

procedure BeginPemScan(out Scanner: TPemScanner; Text: PChar; Length: PtrUInt);
begin
  Scanner.Position := Text;
  Scanner.Limit := Text + Length;
end;

function MarkerLength(Marker: PChar): PtrUInt;
begin
  Result := 0;
  while Marker[Result] <> #0 do
    Inc(Result);
end;

{ Where Marker next appears in [From, Limit), or nil. }
function FindMarker(From, Limit: PChar; Marker: PChar): PChar;
var
  Count: PtrUInt;
begin
  Count := MarkerLength(Marker);
  while PtrUInt(Limit - From) >= Count do
  begin
    if CompareByte(From^, Marker^, Count) = 0 then
      Exit(From);
    Inc(From);
  end;
  Result := nil;
end;

function Base64Value(Character: Char): Integer;
begin
  case Character of
    'A'..'Z': Result := Ord(Character) - Ord('A');
    'a'..'z': Result := Ord(Character) - Ord('a') + 26;
    '0'..'9': Result := Ord(Character) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function DecodeBase64(Text: PChar; Length: PtrUInt; Output: PByte; out OutputLength: PtrUInt): Boolean;
var
  Index: PtrUInt;
  Accumulator: LongWord;
  Bits: Integer;
  Value: Integer;
  Padding: Integer;
begin
  OutputLength := 0;
  Accumulator := 0;
  Bits := 0;
  Padding := 0;
  Index := 0;
  while Index < Length do
  begin
    if Text[Index] in [' ', #9, #10, #13] then
    begin
      Inc(Index);
      Continue;
    end;
    if Text[Index] = '=' then
    begin
      Inc(Padding);
      Inc(Index);
      Continue;
    end;
    { Nothing but padding after padding. }
    if Padding > 0 then
      Exit(False);
    Value := Base64Value(Text[Index]);
    if Value < 0 then
      Exit(False);
    Accumulator := (Accumulator shl 6) or LongWord(Value);
    Bits := Bits + 6;
    if Bits >= 8 then
    begin
      Bits := Bits - 8;
      Output[OutputLength] := Byte(Accumulator shr Bits);
      Inc(OutputLength);
    end;
    Inc(Index);
  end;
  { Leftover bits must be the zeros of a final partial group. }
  Result := (Padding <= 2) and (Bits < 6) and ((Accumulator and ((1 shl Bits) - 1)) = 0);
end;

function NextPemCertificate(var Scanner: TPemScanner; out Der: PByte; out DerLength: PtrUInt): Boolean;
var
  BlockStart, BlockEnd: PChar;
  BodyLength: PtrUInt;
begin
  Der := nil;
  DerLength := 0;
  while True do
  begin
    BlockStart := FindMarker(Scanner.Position, Scanner.Limit, BeginMarker);
    if BlockStart = nil then
    begin
      Scanner.Position := Scanner.Limit;
      Exit(False);
    end;
    BlockStart := BlockStart + MarkerLength(BeginMarker);
    BlockEnd := FindMarker(BlockStart, Scanner.Limit, EndMarker);
    if BlockEnd = nil then
    begin
      Scanner.Position := Scanner.Limit;
      Exit(False);
    end;
    Scanner.Position := BlockEnd + MarkerLength(EndMarker);
    BodyLength := PtrUInt(BlockEnd - BlockStart);
    Der := GetMem(BodyLength * 3 div 4 + 3);
    if DecodeBase64(BlockStart, BodyLength, Der, DerLength) and (DerLength > 0) then
      Exit(True);
    FreeMem(Der);
    Der := nil;
    DerLength := 0;
  end;
end;

end.
