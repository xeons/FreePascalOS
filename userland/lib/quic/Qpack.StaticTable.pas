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
  Field lines and QPACK's static table (RFC 9204 appendix A): the 99
  field lines every encoder and decoder know by index, and the lookup
  an encoder makes (a whole field line, or only its name).

  A field line is libhttp's THttpHeaderField, so HTTP/3's heads go to
  and from libhttp's messages without a copy into another shape.
}
unit Qpack.StaticTable;

{$mode objfpc}
{$H+}

interface

uses
  Http.HeaderFields;

type
  TQpackField = THttpHeaderField;
  TQpackFieldList = THttpHeaderFieldArray;

const
  StaticTableSize = 99;

{ The static entry at Index (0 .. 98). }
function StaticEntry(Index: Integer; out Field: TQpackField): Boolean;
{ The index of Name with Value (Exact), or of Name alone; -1 if none. }
procedure FindStaticEntry(const Name, Value: string; out ExactIndex, NameIndex: Integer);
function MakeField(const Name, Value: string): TQpackField;
procedure AddField(var Fields: TQpackFieldList; const Name, Value: string);
{ The first value of a field named Name (lower case), or ''. }
function FieldValue(constref Fields: TQpackFieldList; const Name: string): string;

implementation

uses
  SysUtils;

type
  TStaticEntry = record
    Name: PChar;
    Value: PChar;
  end;

const
  Entries: array[0..StaticTableSize - 1] of TStaticEntry = (
    (Name: ':authority'; Value: ''),
    (Name: ':path'; Value: '/'),
    (Name: 'age'; Value: '0'),
    (Name: 'content-disposition'; Value: ''),
    (Name: 'content-length'; Value: '0'),
    (Name: 'cookie'; Value: ''),
    (Name: 'date'; Value: ''),
    (Name: 'etag'; Value: ''),
    (Name: 'if-modified-since'; Value: ''),
    (Name: 'if-none-match'; Value: ''),
    (Name: 'last-modified'; Value: ''),
    (Name: 'link'; Value: ''),
    (Name: 'location'; Value: ''),
    (Name: 'referer'; Value: ''),
    (Name: 'set-cookie'; Value: ''),
    (Name: ':method'; Value: 'CONNECT'),
    (Name: ':method'; Value: 'DELETE'),
    (Name: ':method'; Value: 'GET'),
    (Name: ':method'; Value: 'HEAD'),
    (Name: ':method'; Value: 'OPTIONS'),
    (Name: ':method'; Value: 'POST'),
    (Name: ':method'; Value: 'PUT'),
    (Name: ':scheme'; Value: 'http'),
    (Name: ':scheme'; Value: 'https'),
    (Name: ':status'; Value: '103'),
    (Name: ':status'; Value: '200'),
    (Name: ':status'; Value: '304'),
    (Name: ':status'; Value: '404'),
    (Name: ':status'; Value: '503'),
    (Name: 'accept'; Value: '*/*'),
    (Name: 'accept'; Value: 'application/dns-message'),
    (Name: 'accept-encoding'; Value: 'gzip, deflate, br'),
    (Name: 'accept-ranges'; Value: 'bytes'),
    (Name: 'access-control-allow-headers'; Value: 'cache-control'),
    (Name: 'access-control-allow-headers'; Value: 'content-type'),
    (Name: 'access-control-allow-origin'; Value: '*'),
    (Name: 'cache-control'; Value: 'max-age=0'),
    (Name: 'cache-control'; Value: 'max-age=2592000'),
    (Name: 'cache-control'; Value: 'max-age=604800'),
    (Name: 'cache-control'; Value: 'no-cache'),
    (Name: 'cache-control'; Value: 'no-store'),
    (Name: 'cache-control'; Value: 'public, max-age=31536000'),
    (Name: 'content-encoding'; Value: 'br'),
    (Name: 'content-encoding'; Value: 'gzip'),
    (Name: 'content-type'; Value: 'application/dns-message'),
    (Name: 'content-type'; Value: 'application/javascript'),
    (Name: 'content-type'; Value: 'application/json'),
    (Name: 'content-type'; Value: 'application/x-www-form-urlencoded'),
    (Name: 'content-type'; Value: 'image/gif'),
    (Name: 'content-type'; Value: 'image/jpeg'),
    (Name: 'content-type'; Value: 'image/png'),
    (Name: 'content-type'; Value: 'text/css'),
    (Name: 'content-type'; Value: 'text/html; charset=utf-8'),
    (Name: 'content-type'; Value: 'text/plain'),
    (Name: 'content-type'; Value: 'text/plain;charset=utf-8'),
    (Name: 'range'; Value: 'bytes=0-'),
    (Name: 'strict-transport-security'; Value: 'max-age=31536000'),
    (Name: 'strict-transport-security'; Value: 'max-age=31536000; includesubdomains'),
    (Name: 'strict-transport-security'; Value: 'max-age=31536000; includesubdomains; preload'),
    (Name: 'vary'; Value: 'accept-encoding'),
    (Name: 'vary'; Value: 'origin'),
    (Name: 'x-content-type-options'; Value: 'nosniff'),
    (Name: 'x-xss-protection'; Value: '1; mode=block'),
    (Name: ':status'; Value: '100'),
    (Name: ':status'; Value: '204'),
    (Name: ':status'; Value: '206'),
    (Name: ':status'; Value: '302'),
    (Name: ':status'; Value: '400'),
    (Name: ':status'; Value: '403'),
    (Name: ':status'; Value: '421'),
    (Name: ':status'; Value: '425'),
    (Name: ':status'; Value: '500'),
    (Name: 'accept-language'; Value: ''),
    (Name: 'access-control-allow-credentials'; Value: 'FALSE'),
    (Name: 'access-control-allow-credentials'; Value: 'TRUE'),
    (Name: 'access-control-allow-headers'; Value: '*'),
    (Name: 'access-control-allow-methods'; Value: 'get'),
    (Name: 'access-control-allow-methods'; Value: 'get, post, options'),
    (Name: 'access-control-allow-methods'; Value: 'options'),
    (Name: 'access-control-expose-headers'; Value: 'content-length'),
    (Name: 'access-control-request-headers'; Value: 'content-type'),
    (Name: 'access-control-request-method'; Value: 'get'),
    (Name: 'access-control-request-method'; Value: 'post'),
    (Name: 'alt-svc'; Value: 'clear'),
    (Name: 'authorization'; Value: ''),
    (Name: 'content-security-policy'; Value: 'script-src ''none''; object-src ''none''; base-uri ''none'''),
    (Name: 'early-data'; Value: '1'),
    (Name: 'expect-ct'; Value: ''),
    (Name: 'forwarded'; Value: ''),
    (Name: 'if-range'; Value: ''),
    (Name: 'origin'; Value: ''),
    (Name: 'purpose'; Value: 'prefetch'),
    (Name: 'server'; Value: ''),
    (Name: 'timing-allow-origin'; Value: '*'),
    (Name: 'upgrade-insecure-requests'; Value: '1'),
    (Name: 'user-agent'; Value: ''),
    (Name: 'x-forwarded-for'; Value: ''),
    (Name: 'x-frame-options'; Value: 'deny'),
    (Name: 'x-frame-options'; Value: 'sameorigin'));

function StaticEntry(Index: Integer; out Field: TQpackField): Boolean;
begin
  Field := Default(TQpackField);
  if (Index < 0) or (Index >= StaticTableSize) then
    Exit(False);
  Field.Name := string(Entries[Index].Name);
  Field.Value := string(Entries[Index].Value);
  Result := True;
end;

procedure FindStaticEntry(const Name, Value: string; out ExactIndex, NameIndex: Integer);
var
  Index: Integer;
begin
  ExactIndex := -1;
  NameIndex := -1;
  for Index := 0 to StaticTableSize - 1 do
    if StrComp(Entries[Index].Name, PChar(Name)) = 0 then
    begin
      if NameIndex < 0 then
        NameIndex := Index;
      if StrComp(Entries[Index].Value, PChar(Value)) = 0 then
      begin
        ExactIndex := Index;
        Exit;
      end;
    end;
end;

function MakeField(const Name, Value: string): TQpackField;
begin
  Result.Name := Name;
  Result.Value := Value;
end;

procedure AddField(var Fields: TQpackFieldList; const Name, Value: string);
var
  Count: Integer;
begin
  Count := Length(Fields);
  SetLength(Fields, Count + 1);
  Fields[Count].Name := Name;
  Fields[Count].Value := Value;
end;

function FieldValue(constref Fields: TQpackFieldList; const Name: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Fields) do
    if Fields[Index].Name = Name then
      Exit(Fields[Index].Value);
  Result := '';
end;

end.
