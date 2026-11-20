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
  The URL class's getters and setters (URL Standard section 6.1) on a
  URL record: href, origin, protocol, username, password, host,
  hostname, port, pathname, search and hash. A setter that the standard
  makes do nothing leaves the URL as it was; SetHref is the only one
  that can fail (the script binding throws a TypeError then).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Accessors;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

function GetHref(constref Url: TUrlRecord): string;
function SetHref(var Url: TUrlRecord; const Value: string): Boolean;
function GetOrigin(constref Url: TUrlRecord): string;
function GetProtocol(constref Url: TUrlRecord): string;
procedure SetProtocol(var Url: TUrlRecord; const Value: string);
function GetUsername(constref Url: TUrlRecord): string;
procedure SetUsername(var Url: TUrlRecord; const Value: string);
function GetPassword(constref Url: TUrlRecord): string;
procedure SetPassword(var Url: TUrlRecord; const Value: string);
function GetHost(constref Url: TUrlRecord): string;
procedure SetHost(var Url: TUrlRecord; const Value: string);
function GetHostname(constref Url: TUrlRecord): string;
procedure SetHostname(var Url: TUrlRecord; const Value: string);
function GetPort(constref Url: TUrlRecord): string;
procedure SetPort(var Url: TUrlRecord; const Value: string);
function GetPathname(constref Url: TUrlRecord): string;
procedure SetPathname(var Url: TUrlRecord; const Value: string);
function GetSearch(constref Url: TUrlRecord): string;
procedure SetSearch(var Url: TUrlRecord; const Value: string);
function GetHash(constref Url: TUrlRecord): string;
procedure SetHash(var Url: TUrlRecord; const Value: string);

{ A URL without a host, with the empty host, or of the file scheme. }
function CannotHaveCredentialsOrPort(constref Url: TUrlRecord): Boolean;

implementation

uses
  SysUtils,
  Url.Origins,
  Url.Parser,
  Url.PercentEncoding;

{ Runs the parser from a state on a copy; the copy is kept only when it
  worked. }
procedure ParseInto(var Url: TUrlRecord; const Input: string; State: TUrlParserState);
var
  Copy_: TUrlRecord;
begin
  Copy_ := Url;
  if ParseUrlWithOverride(Input, Copy_, State) then
    Url := Copy_;
end;

procedure StripTrailingSpacesFromOpaquePath(var Url: TUrlRecord);
begin
  if not Url.OpaquePath or Url.HasFragment or Url.HasQuery then
    Exit;
  while (Url.Path <> '') and (Url.Path[Length(Url.Path)] = ' ') do
    SetLength(Url.Path, Length(Url.Path) - 1);
end;

function CannotHaveCredentialsOrPort(constref Url: TUrlRecord): Boolean;
begin
  Result := (Url.Host.Kind in [UrlHostNull, UrlHostEmpty]) or (Url.Scheme = 'file');
end;

function GetHref(constref Url: TUrlRecord): string;
begin
  Result := SerializeUrl(Url);
end;

function SetHref(var Url: TUrlRecord; const Value: string): Boolean;
var
  Parsed: TUrlRecord;
begin
  Result := ParseUrl(Value, Parsed);
  if Result then
    Url := Parsed;
end;

function GetOrigin(constref Url: TUrlRecord): string;
begin
  Result := SerializeOrigin(OriginOfUrl(Url));
end;

function GetProtocol(constref Url: TUrlRecord): string;
begin
  Result := Url.Scheme + ':';
end;

procedure SetProtocol(var Url: TUrlRecord; const Value: string);
begin
  ParseInto(Url, Value + ':', StateSchemeStart);
end;

function GetUsername(constref Url: TUrlRecord): string;
begin
  Result := Url.Username;
end;

procedure SetUsername(var Url: TUrlRecord; const Value: string);
begin
  if CannotHaveCredentialsOrPort(Url) then
    Exit;
  Url.Username := PercentEncode(Value, EncodeUserinfo);
end;

function GetPassword(constref Url: TUrlRecord): string;
begin
  Result := Url.Password;
end;

procedure SetPassword(var Url: TUrlRecord; const Value: string);
begin
  if CannotHaveCredentialsOrPort(Url) then
    Exit;
  Url.Password := PercentEncode(Value, EncodeUserinfo);
end;

function GetHost(constref Url: TUrlRecord): string;
begin
  if Url.Host.Kind = UrlHostNull then
    Exit('');
  Result := SerializeHost(Url.Host);
  if Url.Port <> UrlPortNull then
    Result := Result + ':' + IntToStr(Url.Port);
end;

procedure SetHost(var Url: TUrlRecord; const Value: string);
begin
  if Url.OpaquePath then
    Exit;
  ParseInto(Url, Value, StateHost);
end;

function GetHostname(constref Url: TUrlRecord): string;
begin
  Result := SerializeHost(Url.Host);
end;

procedure SetHostname(var Url: TUrlRecord; const Value: string);
begin
  if Url.OpaquePath then
    Exit;
  ParseInto(Url, Value, StateHostname);
end;

function GetPort(constref Url: TUrlRecord): string;
begin
  if Url.Port = UrlPortNull then
    Result := ''
  else
    Result := IntToStr(Url.Port);
end;

procedure SetPort(var Url: TUrlRecord; const Value: string);
begin
  if CannotHaveCredentialsOrPort(Url) then
    Exit;
  if Value = '' then
    Url.Port := UrlPortNull
  else
    ParseInto(Url, Value, StatePort);
end;

function GetPathname(constref Url: TUrlRecord): string;
begin
  Result := SerializePath(Url);
end;

procedure SetPathname(var Url: TUrlRecord; const Value: string);
var
  Copy_: TUrlRecord;
begin
  if Url.OpaquePath then
    Exit;
  Copy_ := Url;
  Copy_.Path := '';
  if ParseUrlWithOverride(Value, Copy_, StatePathStart) then
    Url := Copy_;
end;

function GetSearch(constref Url: TUrlRecord): string;
begin
  if not Url.HasQuery or (Url.Query = '') then
    Result := ''
  else
    Result := '?' + Url.Query;
end;

procedure SetSearch(var Url: TUrlRecord; const Value: string);
var
  Input: string;
  Copy_: TUrlRecord;
begin
  if Value = '' then
  begin
    Url.HasQuery := False;
    Url.Query := '';
    StripTrailingSpacesFromOpaquePath(Url);
    Exit;
  end;
  Input := Value;
  if Input[1] = '?' then
    Delete(Input, 1, 1);
  Copy_ := Url;
  Copy_.HasQuery := True;
  Copy_.Query := '';
  if ParseUrlWithOverride(Input, Copy_, StateQuery) then
    Url := Copy_;
end;

function GetHash(constref Url: TUrlRecord): string;
begin
  if not Url.HasFragment or (Url.Fragment = '') then
    Result := ''
  else
    Result := '#' + Url.Fragment;
end;

procedure SetHash(var Url: TUrlRecord; const Value: string);
var
  Input: string;
  Copy_: TUrlRecord;
begin
  if Value = '' then
  begin
    Url.HasFragment := False;
    Url.Fragment := '';
    StripTrailingSpacesFromOpaquePath(Url);
    Exit;
  end;
  Input := Value;
  if Input[1] = '#' then
    Delete(Input, 1, 1);
  Copy_ := Url;
  Copy_.HasFragment := True;
  Copy_.Fragment := '';
  if ParseUrlWithOverride(Input, Copy_, StateFragment) then
    Url := Copy_;
end;

end.
