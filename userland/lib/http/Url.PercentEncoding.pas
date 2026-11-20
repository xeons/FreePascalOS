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
  Percent-encoding (URL Standard section 1.3): the encode sets, each
  the one before it plus some characters,

    C0 control      C0 controls and everything above U+007E
    fragment        + space " < > `
    query           C0 control + space " # < >
    special-query   query + '
    path            query + ? ^ ` and the curly brackets
    userinfo        path + / : ; = @ [ \ ] ^ |
    component       userinfo + $ % & + ,
    form            component + ! ' ( ) ~  (application/x-www-form-urlencoded)

  Text is UTF-8, so every byte of a non-ASCII character is above 0x7E
  and is encoded by every set: encoding byte by byte is the same as
  UTF-8 percent-encoding by code point.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.PercentEncoding;

{$mode objfpc}
{$H+}

interface

type
  TPercentEncodeSet = (EncodeC0Control, EncodeFragment, EncodeQuery, EncodeSpecialQuery, EncodePath,
    EncodeUserinfo, EncodeComponent, EncodeForm);

function InEncodeSet(Value: Byte; EncodeSet: TPercentEncodeSet): Boolean;
{ Text with the bytes of the set as %XX (upper case hexadecimal).
  SpaceAsPlus: a space becomes "+" (form encoding). }
function PercentEncode(const Text: string; EncodeSet: TPercentEncodeSet; SpaceAsPlus: Boolean = False): string;
{ %XX sequences decoded; a "%" not followed by two hexadecimal digits
  stays as it is. }
function PercentDecode(const Text: string): string;
function HexDigitValue(Character: Char): Integer;

implementation

const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';

function InEncodeSet(Value: Byte; EncodeSet: TPercentEncodeSet): Boolean;
var
  Character: Char;
begin
  if (Value < $20) or (Value > $7E) then
    Exit(True);
  Character := Chr(Value);
  case EncodeSet of
    EncodeC0Control:
      Result := False;
    EncodeFragment:
      Result := Character in [' ', '"', '<', '>', '`'];
    EncodeQuery:
      Result := Character in [' ', '"', '#', '<', '>'];
    EncodeSpecialQuery:
      Result := Character in [' ', '"', '#', '<', '>', ''''];
    EncodePath:
      Result := Character in [' ', '"', '#', '<', '>', '?', '^', '`', '{', '}'];
    EncodeUserinfo:
      Result := Character in [' ', '"', '#', '<', '>', '?', '^', '`', '{', '}', '/', ':', ';', '=', '@', '[',
        '\', ']', '|'];
    EncodeComponent:
      Result := Character in [' ', '"', '#', '<', '>', '?', '^', '`', '{', '}', '/', ':', ';', '=', '@', '[',
        '\', ']', '|', '$', '%', '&', '+', ','];
    EncodeForm:
      Result := Character in [' ', '"', '#', '<', '>', '?', '^', '`', '{', '}', '/', ':', ';', '=', '@', '[',
        '\', ']', '|', '$', '%', '&', '+', ',', '!', '''', '(', ')', '~'];
  else
    Result := True;
  end;
end;

function PercentEncode(const Text: string; EncodeSet: TPercentEncodeSet; SpaceAsPlus: Boolean): string;
var
  Index, Output: Integer;
  Value: Byte;
begin
  Result := '';
  SetLength(Result, Length(Text) * 3);
  Output := 0;
  for Index := 1 to Length(Text) do
  begin
    Value := Ord(Text[Index]);
    if SpaceAsPlus and (Value = Ord(' ')) then
    begin
      Inc(Output);
      Result[Output] := '+';
    end
    else if InEncodeSet(Value, EncodeSet) then
    begin
      Result[Output + 1] := '%';
      Result[Output + 2] := HexDigits[Value shr 4];
      Result[Output + 3] := HexDigits[Value and 15];
      Inc(Output, 3);
    end
    else
    begin
      Inc(Output);
      Result[Output] := Chr(Value);
    end;
  end;
  SetLength(Result, Output);
end;

function HexDigitValue(Character: Char): Integer;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function PercentDecode(const Text: string): string;
var
  Index, Output: Integer;
begin
  Result := '';
  SetLength(Result, Length(Text));
  Output := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Inc(Output);
    if (Text[Index] = '%') and (Index + 2 <= Length(Text)) and (HexDigitValue(Text[Index + 1]) >= 0) and
       (HexDigitValue(Text[Index + 2]) >= 0) then
    begin
      Result[Output] := Chr(HexDigitValue(Text[Index + 1]) * 16 + HexDigitValue(Text[Index + 2]));
      Inc(Index, 3);
    end
    else
    begin
      Result[Output] := Text[Index];
      Inc(Index);
    end;
  end;
  SetLength(Result, Output);
end;

end.
