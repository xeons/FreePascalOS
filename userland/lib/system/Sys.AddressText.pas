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
  Internet addresses as strings, for programs that work with string
  rather than character buffers: an address and back, an address with
  its prefix, a socket address ("10.0.2.15:80", "[fec0::2]:80"), an
  IPv6 address with its zone ("fe80::2%eth0"), and a host and port
  given together ("example.org:80", "[::1]:8080").
}
unit Sys.AddressText;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.InternetAddresses;

function AddressToText(constref Address: TInternetAddress): string;
{ "10.0.2.15/24", "fec0::5054:ff:fe12:3456/64". }
function InterfaceAddressToText(constref Address: TAbiInterfaceAddress): string;
{ "10.0.2.15:80", "[fec0::2]:80". }
function SocketAddressToText(constref Address: TAbiSocketAddress): string;
{ The address alone of a socket address, with the zone of a link-local
  IPv6 address ("fe80::2%eth0"). }
function SocketHostToText(constref Address: TAbiSocketAddress): string;

{ An IPv4 or IPv6 address, nothing else. }
function TextToAddress(const Text: string; out Address: TInternetAddress): Boolean;
{ "A.B.C.D/N" or "IPv6/N"; without "/N" HasPrefix is False and the
  prefix the whole address. }
function TextToAddressWithPrefix(const Text: string; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
{ An address with an optional zone: "fe80::2%eth0" or "fe80::2%2" (an
  interface name or index). ScopeId is the interface's index, 0 without
  a zone. False for an unknown interface. }
function TextToScopedAddress(const Text: string; out Address: TInternetAddress; out ScopeId: LongWord): Boolean;

{ Splits "host:port", "[ipv6]:port", "[ipv6]", "host" and a bare IPv6
  address (two colons or more: no port) into the host (brackets taken
  off) and the port text (empty if there is none). False for an opening
  bracket that is never closed, or anything after it but ":port". }
function SplitHostAndPort(const Text: string; out Host, Port: string): Boolean;

implementation

uses
  SysUtils,
  Sys.NetworkInterfaces;

function AddressToText(constref Address: TInternetAddress): string;
var
  Buffer: array[0..InternetAddressTextCapacity - 1] of Char;
begin
  Result := StrPas(FormatInternetAddress(Address, @Buffer[0], SizeOf(Buffer)));
end;

function InterfaceAddressToText(constref Address: TAbiInterfaceAddress): string;
begin
  Result := AddressToText(InterfaceAddressHost(Address)) + '/' + IntToStr(Address.PrefixLength);
end;

function SocketAddressToText(constref Address: TAbiSocketAddress): string;
begin
  if Address.Family = AddressFamilyIPv6 then
    Result := '[' + SocketHostToText(Address) + ']:' + IntToStr(Address.Port)
  else
    Result := SocketHostToText(Address) + ':' + IntToStr(Address.Port);
end;

{ The name of the interface with Index, or the index as a number. }
function InterfaceNameOfIndex(Index: LongWord): string;
var
  Interfaces: TNetworkInterfaceList;
  Position: Integer;
begin
  Result := IntToStr(Index);
  if ListNetworkInterfaces(Interfaces) <> ErrorNone then
    Exit;
  for Position := 0 to High(Interfaces) do
    if Interfaces[Position].Index = Index then
      Exit(StrPas(PChar(@Interfaces[Position].Name[0])));
end;

function SocketHostToText(constref Address: TAbiSocketAddress): string;
var
  Host: TInternetAddress;
begin
  Host := SocketAddressHost(Address);
  Result := AddressToText(Host);
  if (Address.Family = AddressFamilyIPv6) and (Address.ScopeId <> 0) and AddressIsLinkLocal(Host) then
    Result := Result + '%' + InterfaceNameOfIndex(Address.ScopeId);
end;

function TextToAddress(const Text: string; out Address: TInternetAddress): Boolean;
begin
  Result := ParseInternetAddress(PChar(Text), Address);
end;

function TextToAddressWithPrefix(const Text: string; out Address: TInternetAddress; out PrefixLength: LongWord;
  out HasPrefix: Boolean): Boolean;
begin
  Result := ParseAddressWithPrefix(PChar(Text), Address, PrefixLength, HasPrefix);
end;

{ The index of the interface named Name (or written as a number). }
function InterfaceIndexOfName(const Name: string; out Index: LongWord): Boolean;
var
  Description: TAbiNetworkInterface;
  Number: LongInt;
begin
  Index := 0;
  if TryStrToInt(Name, Number) and (Number > 0) then
  begin
    Index := LongWord(Number);
    Exit(True);
  end;
  Result := FindNetworkInterface(PChar(Name), Description);
  if Result then
    Index := Description.Index;
end;

function TextToScopedAddress(const Text: string; out Address: TInternetAddress; out ScopeId: LongWord): Boolean;
var
  Separator: Integer;
begin
  ScopeId := 0;
  Separator := Pos('%', Text);
  if Separator = 0 then
    Exit(TextToAddress(Text, Address));
  Result := TextToAddress(Copy(Text, 1, Separator - 1), Address) and (Address.Family = AddressFamilyIPv6) and
    InterfaceIndexOfName(Copy(Text, Separator + 1, Length(Text) - Separator), ScopeId);
end;

function CountCharacter(const Text: string; Character: Char): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Length(Text) do
    if Text[Index] = Character then
      Inc(Result);
end;

function SplitHostAndPort(const Text: string; out Host, Port: string): Boolean;
var
  Closing: Integer;
  Separator: Integer;
begin
  Host := Text;
  Port := '';
  if (Text <> '') and (Text[1] = '[') then
  begin
    Closing := Pos(']', Text);
    if Closing = 0 then
      Exit(False);
    Host := Copy(Text, 2, Closing - 2);
    if Closing = Length(Text) then
      Exit(True);
    if Text[Closing + 1] <> ':' then
      Exit(False);
    Port := Copy(Text, Closing + 2, Length(Text) - Closing - 1);
    Exit(True);
  end;
  { A bare IPv6 address has no port. }
  if CountCharacter(Text, ':') <> 1 then
    Exit(True);
  Separator := Pos(':', Text);
  Host := Copy(Text, 1, Separator - 1);
  Port := Copy(Text, Separator + 1, Length(Text) - Separator);
  Result := True;
end;

end.
