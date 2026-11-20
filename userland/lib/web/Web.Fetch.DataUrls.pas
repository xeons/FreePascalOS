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
  data: URLs (Fetch Standard section 4.2.1, "data: URL processor"): the
  MIME type before the comma (text/plain;charset=US-ASCII when it is
  missing or bad, "text/plain" put before a type that starts with ";"),
  the body percent-decoded and, with ";base64", decoded by the
  Infra Standard's forgiving-base64 (ASCII whitespace dropped, "="
  padding optional, any other character a failure).
}
unit Web.Fetch.DataUrls;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Web.Fetch.MimeTypes;

type
  TDataUrlResult = record
    Valid: Boolean;
    MimeType: TMimeType;
    Body: string;
  end;

function ProcessDataUrl(constref Url: TUrlRecord): TDataUrlResult;
{ Infra's forgiving-base64 decode; False on failure. }
function ForgivingBase64Decode(const Input: string; out Output: string): Boolean;

implementation

uses
  Url.PercentEncoding;

function IsAsciiWhitespace(Character: Char): Boolean; inline;
begin
  Result := Character in [#9, #10, #12, #13, ' '];
end;

function TrimAsciiWhitespace(const Text: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Text);
  while (First <= Last) and IsAsciiWhitespace(Text[First]) do
    Inc(First);
  while (Last >= First) and IsAsciiWhitespace(Text[Last]) do
    Dec(Last);
  Result := Copy(Text, First, Last - First + 1);
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

function ForgivingBase64Decode(const Input: string; out Output: string): Boolean;
var
  Data: string;
  Index, Count, Value, Sextet, Bits, Written: Integer;
begin
  Output := '';
  Data := '';
  SetLength(Data, Length(Input));
  Count := 0;
  for Index := 1 to Length(Input) do
    if not IsAsciiWhitespace(Input[Index]) then
    begin
      Inc(Count);
      Data[Count] := Input[Index];
    end;
  SetLength(Data, Count);
  if Count mod 4 = 0 then
  begin
    if (Count >= 1) and (Data[Count] = '=') then
    begin
      Dec(Count);
      if (Count >= 1) and (Data[Count] = '=') then
        Dec(Count);
    end;
    SetLength(Data, Count);
  end;
  if Count mod 4 = 1 then
    Exit(False);
  SetLength(Output, (Count * 3) div 4);
  Written := 0;
  Value := 0;
  Bits := 0;
  for Index := 1 to Count do
  begin
    Sextet := Base64Value(Data[Index]);
    if Sextet < 0 then
    begin
      Output := '';
      Exit(False);
    end;
    Value := ((Value shl 6) or Sextet) and $FFFFFF;
    Inc(Bits, 6);
    if Bits >= 8 then
    begin
      Dec(Bits, 8);
      Inc(Written);
      Output[Written] := Chr((Value shr Bits) and $FF);
    end;
  end;
  SetLength(Output, Written);
  Result := True;
end;

function EndsWithBase64(const MimeText: string; out Stripped: string): Boolean;
var
  Position: Integer;
begin
  Stripped := MimeText;
  Position := Length(MimeText);
  while (Position >= 1) and (MimeText[Position] = ' ') do
    Dec(Position);
  if (Position < 6) or (LowerCase(Copy(MimeText, Position - 5, 6)) <> 'base64') then
    Exit(False);
  Dec(Position, 6);
  while (Position >= 1) and (MimeText[Position] = ' ') do
    Dec(Position);
  if (Position < 1) or (MimeText[Position] <> ';') then
    Exit(False);
  Stripped := Copy(MimeText, 1, Position - 1);
  Result := True;
end;

function ProcessDataUrl(constref Url: TUrlRecord): TDataUrlResult;
var
  Input, MimeText, Stripped, Body, Decoded: string;
  Comma: Integer;
begin
  Result := Default(TDataUrlResult);
  if Url.Scheme <> 'data' then
    Exit;
  Input := SerializeUrl(Url, True);
  Delete(Input, 1, Length('data:'));
  Comma := Pos(',', Input);
  if Comma = 0 then
    Exit;
  MimeText := TrimAsciiWhitespace(Copy(Input, 1, Comma - 1));
  Body := PercentDecode(Copy(Input, Comma + 1, MaxInt));
  if EndsWithBase64(MimeText, Stripped) then
  begin
    MimeText := Stripped;
    if not ForgivingBase64Decode(Body, Decoded) then
      Exit;
    Body := Decoded;
  end;
  if (MimeText <> '') and (MimeText[1] = ';') then
    MimeText := 'text/plain' + MimeText;
  Result.MimeType := ParseMimeType(MimeText);
  if not Result.MimeType.Valid then
    Result.MimeType := ParseMimeType('text/plain;charset=US-ASCII');
  Result.Body := Body;
  Result.Valid := True;
end;

end.
