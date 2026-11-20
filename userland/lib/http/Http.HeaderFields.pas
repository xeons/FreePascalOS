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
  A message's header (or trailer) fields (RFC 9110 section 5): an
  ordered list of name-value pairs; names compare without case and are
  kept in lower case (HTTP/2 and HTTP/3 send them so), values as given
  less the white space around them.

  Storage is compact: one array of pairs, and the names of the fields
  HPACK's static table knows (and a few more) are shared strings, so a
  response's common names cost no allocation. Combining (a comma
  separated list from every field of a name) is done when asked, never
  for Set-Cookie (RFC 9110 section 5.3).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.HeaderFields;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  THttpHeaderField = record
    Name: string;
    Value: string;
  end;

  THttpHeaderFieldArray = array of THttpHeaderField;

  THttpHeaders = class
  private
    FFields: THttpHeaderFieldArray;
    FCount: Integer;
    function GetField(Index: Integer): THttpHeaderField;
    function IndexOf(const LowerName: string; Start: Integer): Integer;
  public
    procedure Clear;
    procedure Assign(Source: THttpHeaders);
    procedure Add(const Name, Value: string);
    { Replaces every field of the name with one (adds it if missing). }
    procedure SetValue(const Name, Value: string);
    procedure Remove(const Name: string);
    function Has(const Name: string): Boolean;
    { The first field's value. }
    function Get(const Name: string; out Value: string): Boolean;
    { The first field's value, or ''. }
    function Value(const Name: string): string;
    function GetAll(const Name: string): TStringArray;
    { Every field of the name joined with ", " (RFC 9110 5.3). }
    function Combined(const Name: string): string;
    { A copy of the fields as an array. }
    function FieldArray: THttpHeaderFieldArray;
    property Count: Integer read FCount;
    property Fields[Index: Integer]: THttpHeaderField read GetField; default;
  end;

{ A field list has a field of the (lower case) name. }
function FieldsHave(constref Fields: THttpHeaderFieldArray; const Name: string): Boolean;
{ The first value of the (lower case) name, or ''. }
function FieldsValue(constref Fields: THttpHeaderFieldArray; const Name: string): string;

{ The name in lower case, as a shared string when it is a common one. }
function InternFieldName(const Name: string): string;
{ RFC 9110 5.6.2: one or more tchar. }
function IsFieldNameValid(const Name: string): Boolean;
{ No CR, LF or NUL (RFC 9110 5.5). }
function IsFieldValueValid(const Value: string): Boolean;
{ Spaces and tabs off both ends. }
function TrimFieldValue(const Value: string): string;

implementation

const
  CommonNames: array[0..76] of string = (
    ':authority', ':method', ':path', ':scheme', ':status', ':protocol',
    'accept', 'accept-charset', 'accept-encoding', 'accept-language', 'accept-ranges',
    'access-control-allow-credentials', 'access-control-allow-headers', 'access-control-allow-methods',
    'access-control-allow-origin', 'access-control-expose-headers', 'access-control-max-age', 'age', 'allow',
    'alt-svc', 'authorization', 'cache-control', 'connection', 'content-disposition', 'content-encoding',
    'content-language', 'content-length', 'content-location', 'content-range', 'content-security-policy',
    'content-type', 'cookie', 'date', 'etag', 'expect', 'expires', 'from', 'host', 'if-match',
    'if-modified-since', 'if-none-match', 'if-range', 'if-unmodified-since', 'keep-alive', 'last-modified',
    'link', 'location', 'max-forwards', 'origin', 'pragma', 'priority', 'proxy-authenticate',
    'proxy-authorization', 'range', 'referer', 'refresh', 'retry-after', 'server', 'set-cookie',
    'strict-transport-security', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'user-agent', 'vary', 'via',
    'www-authenticate', 'x-content-type-options', 'x-frame-options', 'x-xss-protection',
    'timing-allow-origin', 'referrer-policy', 'cross-origin-resource-policy', 'early-data', 'server-timing',
    'report-to');

  TokenCharacters = ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'..'9',
    'a'..'z', 'A'..'Z'];

function FieldsHave(constref Fields: THttpHeaderFieldArray; const Name: string): Boolean;
var
  Field: THttpHeaderField;
begin
  for Field in Fields do
    if Field.Name = Name then
      Exit(True);
  Result := False;
end;

function FieldsValue(constref Fields: THttpHeaderFieldArray; const Name: string): string;
var
  Field: THttpHeaderField;
begin
  for Field in Fields do
    if Field.Name = Name then
      Exit(Field.Value);
  Result := '';
end;

function InternFieldName(const Name: string): string;
var
  Lower: string;
  Index: Integer;
begin
  Lower := LowerCase(Name);
  for Index := 0 to High(CommonNames) do
    if CommonNames[Index] = Lower then
      Exit(CommonNames[Index]);
  Result := Lower;
end;

function IsFieldNameValid(const Name: string): Boolean;
var
  Character: Char;
begin
  if Name = '' then
    Exit(False);
  for Character in Name do
    if not (Character in TokenCharacters) then
      Exit(False);
  Result := True;
end;

function IsFieldValueValid(const Value: string): Boolean;
var
  Character: Char;
begin
  for Character in Value do
    if Character in [#0, #10, #13] then
      Exit(False);
  Result := True;
end;

function TrimFieldValue(const Value: string): string;
var
  First, Last: Integer;
begin
  First := 1;
  Last := Length(Value);
  while (First <= Last) and (Value[First] in [' ', #9]) do
    Inc(First);
  while (Last >= First) and (Value[Last] in [' ', #9]) do
    Dec(Last);
  Result := Copy(Value, First, Last - First + 1);
end;

function THttpHeaders.GetField(Index: Integer): THttpHeaderField;
begin
  Result := FFields[Index];
end;

function THttpHeaders.IndexOf(const LowerName: string; Start: Integer): Integer;
var
  Index: Integer;
begin
  for Index := Start to FCount - 1 do
    if FFields[Index].Name = LowerName then
      Exit(Index);
  Result := -1;
end;

procedure THttpHeaders.Clear;
var
  Index: Integer;
begin
  for Index := 0 to FCount - 1 do
    FFields[Index] := Default(THttpHeaderField);
  FCount := 0;
end;

procedure THttpHeaders.Assign(Source: THttpHeaders);
var
  Index: Integer;
begin
  Clear;
  for Index := 0 to Source.Count - 1 do
    Add(Source.FFields[Index].Name, Source.FFields[Index].Value);
end;

procedure THttpHeaders.Add(const Name, Value: string);
begin
  if FCount = Length(FFields) then
  begin
    if FCount < 8 then
      SetLength(FFields, 8)
    else
      SetLength(FFields, FCount * 2);
  end;
  FFields[FCount].Name := InternFieldName(Name);
  FFields[FCount].Value := TrimFieldValue(Value);
  Inc(FCount);
end;

procedure THttpHeaders.SetValue(const Name, Value: string);
var
  Lower: string;
  Index: Integer;
begin
  Lower := LowerCase(Name);
  Index := IndexOf(Lower, 0);
  if Index < 0 then
  begin
    Add(Name, Value);
    Exit;
  end;
  FFields[Index].Value := TrimFieldValue(Value);
  Index := IndexOf(Lower, Index + 1);
  while Index >= 0 do
  begin
    Delete(FFields, Index, 1);
    Dec(FCount);
    Index := IndexOf(Lower, Index);
  end;
end;

procedure THttpHeaders.Remove(const Name: string);
var
  Lower: string;
  Index: Integer;
begin
  Lower := LowerCase(Name);
  Index := IndexOf(Lower, 0);
  while Index >= 0 do
  begin
    Delete(FFields, Index, 1);
    Dec(FCount);
    Index := IndexOf(Lower, Index);
  end;
end;

function THttpHeaders.Has(const Name: string): Boolean;
begin
  Result := IndexOf(LowerCase(Name), 0) >= 0;
end;

function THttpHeaders.Get(const Name: string; out Value: string): Boolean;
var
  Index: Integer;
begin
  Index := IndexOf(LowerCase(Name), 0);
  Result := Index >= 0;
  if Result then
    Value := FFields[Index].Value
  else
    Value := '';
end;

function THttpHeaders.Value(const Name: string): string;
begin
  Get(Name, Result);
end;

function THttpHeaders.GetAll(const Name: string): TStringArray;
var
  Lower: string;
  Index: Integer;
begin
  Result := nil;
  Lower := LowerCase(Name);
  for Index := 0 to FCount - 1 do
    if FFields[Index].Name = Lower then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FFields[Index].Value;
    end;
end;

function THttpHeaders.FieldArray: THttpHeaderFieldArray;
begin
  Result := Copy(FFields, 0, FCount);
end;

function THttpHeaders.Combined(const Name: string): string;
var
  Lower: string;
  Index: Integer;
begin
  Result := '';
  Lower := LowerCase(Name);
  for Index := 0 to FCount - 1 do
    if FFields[Index].Name = Lower then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + FFields[Index].Value;
    end;
end;

end.
