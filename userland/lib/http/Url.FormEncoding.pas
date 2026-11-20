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
  application/x-www-form-urlencoded (URL Standard section 5): a list
  of name-value pairs, "&" between them, "=" inside, "+" for a space,
  everything else in the form percent-encode set as %XX. Parsing skips
  empty pieces, takes a piece without "=" as a name with an empty
  value, turns "+" into a space and percent-decodes; the result is
  UTF-8 as the bytes were.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.FormEncoding;

{$mode objfpc}
{$H+}

interface

type
  TNameValuePair = record
    Name: string;
    Value: string;
  end;

  TNameValueList = array of TNameValuePair;

function ParseFormEncoded(const Input: string): TNameValueList;
function SerializeFormEncoded(constref List: TNameValueList): string;

implementation

uses
  SysUtils,
  Url.PercentEncoding;

function DecodePart(const Text: string): string;
begin
  Result := PercentDecode(StringReplace(Text, '+', ' ', [rfReplaceAll]));
end;

function ParseFormEncoded(const Input: string): TNameValueList;
var
  Piece: string;
  Equals, Count: Integer;
begin
  Result := nil;
  Count := 0;
  for Piece in Input.Split(['&']) do
  begin
    if Piece = '' then
      Continue;
    SetLength(Result, Count + 1);
    Equals := Pos('=', Piece);
    if Equals > 0 then
    begin
      Result[Count].Name := DecodePart(Copy(Piece, 1, Equals - 1));
      Result[Count].Value := DecodePart(Copy(Piece, Equals + 1, MaxInt));
    end
    else
    begin
      Result[Count].Name := DecodePart(Piece);
      Result[Count].Value := '';
    end;
    Inc(Count);
  end;
end;

function SerializeFormEncoded(constref List: TNameValueList): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(List) do
  begin
    if Index > 0 then
      Result := Result + '&';
    Result := Result + PercentEncode(List[Index].Name, EncodeForm, True) + '=' +
      PercentEncode(List[Index].Value, EncodeForm, True);
  end;
end;

end.
