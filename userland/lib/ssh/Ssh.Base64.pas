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
  Base64 (RFC 4648 section 4), as public keys (authorized_keys, .pub
  files) and OpenSSH private key files carry their bytes.
}
unit Ssh.Base64;

{$mode objfpc}{$H+}

interface

function EncodeBase64(const Data: string): string;
{ Skips white space; False for any other character that is not part of
  the alphabet, or for a length that cannot be. }
function DecodeBase64(const Text: string; out Data: string): Boolean;

implementation

const
  Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function EncodeBase64(const Data: string): string;
var
  Index: Integer;
  Group: LongWord;
  Remaining: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(Data) do
  begin
    Remaining := Length(Data) - Index + 1;
    Group := LongWord(Ord(Data[Index])) shl 16;
    if Remaining > 1 then
      Group := Group or (LongWord(Ord(Data[Index + 1])) shl 8);
    if Remaining > 2 then
      Group := Group or LongWord(Ord(Data[Index + 2]));
    Result := Result + Alphabet[((Group shr 18) and 63) + 1] + Alphabet[((Group shr 12) and 63) + 1];
    if Remaining > 1 then
      Result := Result + Alphabet[((Group shr 6) and 63) + 1]
    else
      Result := Result + '=';
    if Remaining > 2 then
      Result := Result + Alphabet[(Group and 63) + 1]
    else
      Result := Result + '=';
    Inc(Index, 3);
  end;
end;

function SymbolValue(Character: Char): Integer;
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

function DecodeBase64(const Text: string; out Data: string): Boolean;
var
  Index: Integer;
  Value: Integer;
  Accumulator: LongWord;
  Bits: Integer;
  Padding: Integer;
  Symbols: Integer;
begin
  Data := '';
  Result := False;
  Accumulator := 0;
  Bits := 0;
  Padding := 0;
  Symbols := 0;
  for Index := 1 to Length(Text) do
  begin
    case Text[Index] of
      ' ', #9, #10, #13:
        Continue;
      '=':
        begin
          Inc(Padding);
          Continue;
        end;
    end;
    { Nothing but padding may follow padding. }
    if Padding > 0 then
      Exit;
    Value := SymbolValue(Text[Index]);
    if Value < 0 then
      Exit;
    Inc(Symbols);
    Accumulator := ((Accumulator shl 6) or LongWord(Value)) and $FFFFFF;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Data := Data + Chr((Accumulator shr Bits) and $FF);
    end;
  end;
  if (Symbols mod 4 = 1) or (Padding > 2) then
    Exit;
  Result := True;
end;

end.
