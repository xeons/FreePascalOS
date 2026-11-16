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
{$H+}

interface

uses
  SysUtils;

type
  TPemScanner = record
    Text: string;
    { Where the search for the next block starts (1-based). }
    Position: Integer;
  end;

procedure BeginPemScan(out Scanner: TPemScanner; const Text: string);
procedure BeginPemScan(out Scanner: TPemScanner; Text: PChar; Length: PtrUInt);
{ The next certificate block, decoded; False when there are no more. A
  block that does not decode is skipped. }
function NextPemCertificate(var Scanner: TPemScanner; out Der: TBytes): Boolean;
{ The same into a new buffer (free it with FreeMem). }
function NextPemCertificate(var Scanner: TPemScanner; out Der: PByte; out DerLength: PtrUInt): Boolean;
{ Base64 (whitespace ignored, '=' padding); False for anything else. }
function DecodeBase64(const Text: string; out Data: TBytes): Boolean;
{ The same into Output, which needs 3/4 of Length bytes. }
function DecodeBase64(Text: PChar; Length: PtrUInt; Output: PByte; out OutputLength: PtrUInt): Boolean;

implementation

uses
  StrUtils;

const
  BeginMarker = '-----BEGIN CERTIFICATE-----';
  EndMarker = '-----END CERTIFICATE-----';

procedure BeginPemScan(out Scanner: TPemScanner; const Text: string);
begin
  Scanner.Text := Text;
  Scanner.Position := 1;
end;

procedure BeginPemScan(out Scanner: TPemScanner; Text: PChar; Length: PtrUInt);
var
  Contents: string;
begin
  SetString(Contents, Text, Length);
  BeginPemScan(Scanner, Contents);
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

function DecodeBase64(const Text: string; out Data: TBytes): Boolean;
var
  Index: Integer;
  OutputLength: Integer;
  Accumulator: LongWord;
  Bits: Integer;
  Value: Integer;
  Padding: Integer;
begin
  Data := nil;
  SetLength(Data, Length(Text) * 3 div 4 + 3);
  OutputLength := 0;
  Accumulator := 0;
  Bits := 0;
  Padding := 0;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] in [' ', #9, #10, #13] then
      Continue;
    if Text[Index] = '=' then
    begin
      Inc(Padding);
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
      Data[OutputLength] := Byte(Accumulator shr Bits);
      Inc(OutputLength);
    end;
  end;
  SetLength(Data, OutputLength);
  { Leftover bits must be the zeros of a final partial group. }
  Result := (Padding <= 2) and (Bits < 6) and ((Accumulator and ((1 shl Bits) - 1)) = 0);
end;

function DecodeBase64(Text: PChar; Length: PtrUInt; Output: PByte; out OutputLength: PtrUInt): Boolean;
var
  Encoded: string;
  Data: TBytes;
begin
  SetString(Encoded, Text, Length);
  Result := DecodeBase64(Encoded, Data);
  OutputLength := System.Length(Data);
  if OutputLength > 0 then
    Move(Data[0], Output^, OutputLength);
end;

function NextPemCertificate(var Scanner: TPemScanner; out Der: TBytes): Boolean;
var
  BlockStart, BlockEnd: Integer;
begin
  Der := nil;
  while True do
  begin
    BlockStart := PosEx(BeginMarker, Scanner.Text, Scanner.Position);
    if BlockStart = 0 then
    begin
      Scanner.Position := Length(Scanner.Text) + 1;
      Exit(False);
    end;
    BlockStart := BlockStart + Length(BeginMarker);
    BlockEnd := PosEx(EndMarker, Scanner.Text, BlockStart);
    if BlockEnd = 0 then
    begin
      Scanner.Position := Length(Scanner.Text) + 1;
      Exit(False);
    end;
    Scanner.Position := BlockEnd + Length(EndMarker);
    if DecodeBase64(Copy(Scanner.Text, BlockStart, BlockEnd - BlockStart), Der) and (Length(Der) > 0) then
      Exit(True);
    Der := nil;
  end;
end;

function NextPemCertificate(var Scanner: TPemScanner; out Der: PByte; out DerLength: PtrUInt): Boolean;
var
  Data: TBytes;
begin
  Der := nil;
  DerLength := 0;
  Result := NextPemCertificate(Scanner, Data);
  if not Result then
    Exit;
  DerLength := Length(Data);
  Der := GetMem(DerLength);
  Move(Data[0], Der^, DerLength);
end;

end.
