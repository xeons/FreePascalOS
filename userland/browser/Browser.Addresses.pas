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
  What the address bar's text means:

  - a URL with a scheme the browser knows (http, https, file, about,
    data) is taken as it is;
  - an absolute path is a local file (file://);
  - something that looks like a host (a dot or a colon and port, or
    localhost, no spaces), with a path or not, is https://text; a bare
    IP address or localhost is http://text (local test servers);
  - anything else is searched for with the search URL ("%s" replaced
    by the words, form-encoded) when one is set, and otherwise is not
    an address (the browser shows an error page saying so).

  Plain logic (the RTL only), checked on the host.
}
unit Browser.Addresses;

{$mode objfpc}
{$H+}

interface

type
  TAddressKind = (AddressUrl, AddressSearch, AddressInvalid);

{ The URL to go to for Text; AddressInvalid leaves Url empty. }
function InterpretAddress(const Text, SearchUrl: string; out Url: string): TAddressKind;
{ Text form-encoded (spaces as "+"). }
function FormEncodeWords(const Text: string): string;
{ Whether Text looks like a host name or address, with a port and a
  path or not. }
function LooksLikeHost(const Text: string): Boolean;

implementation

uses
  SysUtils;

const
  KnownSchemes: array[0..5] of string = ('http', 'https', 'file', 'about', 'data', 'view-source');

function FormEncodeWords(const Text: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
var
  Index: Integer;
  Character: Char;
begin
  Result := '';
  for Index := 1 to Length(Text) do
  begin
    Character := Text[Index];
    if Character in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '*'] then
      Result := Result + Character
    else if Character = ' ' then
      Result := Result + '+'
    else
      Result := Result + '%' + Hex[Ord(Character) shr 4] + Hex[Ord(Character) and 15];
  end;
end;

function SchemeOf(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = ':' then
    begin
      if Index > 1 then
        Result := LowerCase(Copy(Text, 1, Index - 1));
      Exit;
    end;
    if not (Text[Index] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']) then
      Exit;
  end;
end;

function IsKnownScheme(const Scheme: string): Boolean;
var
  Index: Integer;
begin
  for Index := Low(KnownSchemes) to High(KnownSchemes) do
    if KnownSchemes[Index] = Scheme then
      Exit(True);
  Result := False;
end;

{ The host part: up to the first "/", "?" or "#". }
function HostPart(const Text: string): string;
var
  Index: Integer;
begin
  Result := Text;
  for Index := 1 to Length(Text) do
    if Text[Index] in ['/', '?', '#'] then
      Exit(Copy(Text, 1, Index - 1));
end;

function IsIpv4Host(const Host: string): Boolean;
var
  Parts: TStringArray;
  Index, Value: Integer;
begin
  Parts := Host.Split(['.']);
  if Length(Parts) <> 4 then
    Exit(False);
  for Index := 0 to 3 do
    if not TryStrToInt(Parts[Index], Value) or (Value < 0) or (Value > 255) or (Parts[Index] = '') then
      Exit(False);
  Result := True;
end;

{ The host without a port ("example.com:8080" is "example.com"). }
function WithoutPort(const Host: string; out HasPort: Boolean): string;
var
  Colon, Port: Integer;
begin
  HasPort := False;
  Result := Host;
  if (Host <> '') and (Host[1] = '[') then
    Exit;
  Colon := LastDelimiter(':', Host);
  if (Colon > 0) and TryStrToInt(Copy(Host, Colon + 1, MaxInt), Port) and (Port > 0) and (Port < 65536) then
  begin
    HasPort := True;
    Result := Copy(Host, 1, Colon - 1);
  end;
end;

function LooksLikeHost(const Text: string): Boolean;
var
  Host, Name: string;
  HasPort: Boolean;
  Index: Integer;
begin
  Result := False;
  if (Text = '') or (Pos(' ', Text) > 0) then
    Exit;
  Host := HostPart(Text);
  if Host = '' then
    Exit;
  if (Host[1] = '[') and (Pos(']', Host) > 0) then
    Exit(True);
  Name := WithoutPort(Host, HasPort);
  if Name = '' then
    Exit;
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_']) and (Ord(Name[Index]) < $80) then
      Exit;
  if (Name[1] = '.') or (Name[Length(Name)] = '.') then
    Exit;
  Result := (Pos('.', Name) > 0) or HasPort or SameText(Name, 'localhost');
end;

function InterpretAddress(const Text, SearchUrl: string; out Url: string): TAddressKind;
var
  Trimmed, Scheme, Host: string;
  HasPort: Boolean;
begin
  Url := '';
  Trimmed := Trim(Text);
  if Trimmed = '' then
    Exit(AddressInvalid);
  Scheme := SchemeOf(Trimmed);
  if IsKnownScheme(Scheme) then
  begin
    Url := Trimmed;
    Exit(AddressUrl);
  end;
  if Trimmed[1] = '/' then
  begin
    Url := 'file://' + Trimmed;
    Exit(AddressUrl);
  end;
  if LooksLikeHost(Trimmed) then
  begin
    Host := WithoutPort(HostPart(Trimmed), HasPort);
    if IsIpv4Host(Host) or SameText(Host, 'localhost') or ((Host <> '') and (Host[1] = '[')) then
      Url := 'http://' + Trimmed
    else
      Url := 'https://' + Trimmed;
    Exit(AddressUrl);
  end;
  if SearchUrl <> '' then
  begin
    if Pos('%s', SearchUrl) > 0 then
      Url := StringReplace(SearchUrl, '%s', FormEncodeWords(Trimmed), [])
    else
      Url := SearchUrl + FormEncodeWords(Trimmed);
    Exit(AddressSearch);
  end;
  Result := AddressInvalid;
end;

end.
