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
  The host parser (URL Standard section 3.5): "[...]" is an IPv6
  address; the host of a URL that is not special is opaque (refused if
  it has a forbidden host code point, else percent-encoded with the C0
  control set); a special URL's host is percent-decoded, put through
  domain to ASCII and, when it ends in a number, must be an IPv4
  address.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.Hosts;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records;

function ParseHost(const Input: string; IsOpaque: Boolean; out Host: TUrlHost): Boolean;
{ True for an IPv4 or IPv6 host. }
function HostIsIpAddress(constref Host: TUrlHost): Boolean;
function SameHost(constref First, Second: TUrlHost): Boolean;

implementation

uses
  SysUtils,
  Url.DomainNames,
  Url.IpAddresses,
  Url.PercentEncoding;

function ParseOpaqueHost(const Input: string; out Host: TUrlHost): Boolean;
var
  Character: Char;
begin
  Host := Default(TUrlHost);
  for Character in Input do
    if IsForbiddenHostCharacter(Character) then
      Exit(False);
  Host.Kind := UrlHostOpaque;
  Host.Name := PercentEncode(Input, EncodeC0Control);
  Result := True;
end;

function ParseHost(const Input: string; IsOpaque: Boolean; out Host: TUrlHost): Boolean;
var
  Ascii: string;
begin
  Host := Default(TUrlHost);
  if (Input <> '') and (Input[1] = '[') then
  begin
    if Input[Length(Input)] <> ']' then
      Exit(False);
    Host.Kind := UrlHostIpv6;
    Exit(ParseIpv6(Copy(Input, 2, Length(Input) - 2), Host.Ipv6));
  end;
  if IsOpaque then
    Exit(ParseOpaqueHost(Input, Host));
  if not DomainToAscii(PercentDecode(Input), Ascii) then
    Exit(False);
  if EndsInNumber(Ascii) then
  begin
    Host.Kind := UrlHostIpv4;
    Exit(ParseIpv4(Ascii, Host.Ipv4));
  end;
  Host.Kind := UrlHostDomain;
  Host.Name := Ascii;
  Result := True;
end;

function HostIsIpAddress(constref Host: TUrlHost): Boolean;
begin
  Result := Host.Kind in [UrlHostIpv4, UrlHostIpv6];
end;

function SameHost(constref First, Second: TUrlHost): Boolean;
begin
  Result := (First.Kind = Second.Kind) and (SerializeHost(First) = SerializeHost(Second));
end;

end.
