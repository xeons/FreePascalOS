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
  IPv6 on an interface, as the settings ask (NetworkService.Ipv6Settings)
  and as the kernel has it.

  The kernel does most of IPv6 itself: in its automatic mode an
  interface gets a link-local address, asks for routers and takes their
  prefixes (SLAAC), default route and DNS servers. So the service only
  picks the mode - auto: Ipv6ModeAutomatic; none: Ipv6ModeOff; static:
  Ipv6ModeLinkLocal with the address of the settings and, if one is
  given, a default route through the gateway - and undoes a static
  address and route when the settings change.

  ReadIpv6Facts gathers what the state files and the DNS servers need:
  the addresses (tentative ones left out), the gateway of the
  interface's IPv6 default route and the DNS servers the routers gave.
}
unit NetworkService.Ipv6Configuration;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  NetworkService.Ipv6Settings;

type
  TIpv6Facts = record
    { Ipv6Mode* (0 if the kernel did not say). }
    Mode: LongWord;
    { "fec0::5054:ff:fe12:3456/64", the link-local one included. }
    Addresses: TStringArray;
    { The IPv6 default route's gateway on this interface, or empty. }
    Gateway: string;
    { From the routers' advertisements (RDNSS). }
    DnsServers: array of TInternetAddress;
  end;

function ReadIpv6Facts(constref Description: TAbiNetworkInterface; constref Routes: TRouteList): TIpv6Facts;
{ Takes away what applying Applied added (a static address and route). }
procedure UndoIpv6Settings(const Name: string; constref Applied: TIpv6Settings);
{ Applies Desired; CurrentMode is the interface's mode now. False (and
  Failure set) if the kernel refused something. }
function ApplyIpv6Settings(const Name: string; CurrentMode, Metric: LongWord; constref Desired: TIpv6Settings;
  out Failure: string): Boolean;

implementation

uses
  Sys.AddressText,
  NetworkService.Log;

function ReadIpv6Facts(constref Description: TAbiNetworkInterface; constref Routes: TRouteList): TIpv6Facts;
var
  Index: LongWord;
  Position: Integer;
  Server: TInternetAddress;
begin
  Result := Default(TIpv6Facts);
  Result.Mode := Description.Ipv6Mode;
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if (Description.Addresses[Index].Family = AddressFamilyIPv6) and
       ((Description.Addresses[Index].Flags and InterfaceAddressFlagTentative) = 0) then
    begin
      SetLength(Result.Addresses, Length(Result.Addresses) + 1);
      Result.Addresses[High(Result.Addresses)] := InterfaceAddressToText(Description.Addresses[Index]);
    end;
    Inc(Index);
  end;
  for Position := 0 to High(Routes) do
    if (Routes[Position].Destination.Family = AddressFamilyIPv6) and
       (Routes[Position].Destination.PrefixLength = 0) and
       (string(PChar(@Routes[Position].InterfaceName[0])) = string(PChar(@Description.Name[0]))) then
    begin
      Result.Gateway := AddressToText(RouteGateway(Routes[Position]));
      Break;
    end;
  Index := 0;
  while (Index < Description.Ipv6DnsServerCount) and (Index < MaximumDnsServers) do
  begin
    Server := AnyIpv6Address;
    Move(Description.Ipv6DnsServers[Index][0], Server.Bytes[0], 16);
    SetLength(Result.DnsServers, Length(Result.DnsServers) + 1);
    Result.DnsServers[High(Result.DnsServers)] := Server;
    Inc(Index);
  end;
end;

function ModeName(Mode: LongWord): string;
begin
  case Mode of
    Ipv6ModeOff: Result := 'off';
    Ipv6ModeLinkLocal: Result := 'link-local only';
    Ipv6ModeAutomatic: Result := 'automatic';
  else
    Result := IntToStr(Mode);
  end;
end;

procedure UndoIpv6Settings(const Name: string; constref Applied: TIpv6Settings);
var
  Error: LongInt;
begin
  if Applied.Method <> Ipv6MethodStatic then
    Exit;
  if Applied.HasGateway then
  begin
    Error := RemoveRoute(AnyIpv6Address, 0, Applied.Gateway);
    if (Error <> ErrorNone) and (Error <> ErrorNotFound) then
      Say(Name + ': removing the IPv6 default route: ' + ErrorText(Error));
  end;
  if Applied.HasAddress then
  begin
    Error := RemoveInterfaceIpv6Address(PChar(Name), Applied.Address);
    if (Error <> ErrorNone) and (Error <> ErrorNotFound) then
      Say(Name + ': removing the IPv6 address: ' + ErrorText(Error))
    else
      Say(Name + ': IPv6 address ' + AddressToText(Applied.Address) + ' removed');
  end;
end;

function SetMode(const Name: string; CurrentMode, Mode: LongWord; out Failure: string): Boolean;
var
  Error: LongInt;
begin
  Failure := '';
  if CurrentMode = Mode then
    Exit(True);
  Error := SetInterfaceIpv6Mode(PChar(Name), Mode);
  Result := Error = ErrorNone;
  if Result then
    Say(Name + ': IPv6 ' + ModeName(Mode))
  else
  begin
    Failure := 'IPv6 ' + ModeName(Mode) + ': ' + ErrorText(Error);
    Say(Name + ': ' + Failure);
  end;
end;

function HasIpv6DefaultRoute(const Name: string; constref Gateway: TInternetAddress): Boolean;
var
  Routes: TRouteList;
  Position: Integer;
begin
  Result := False;
  if ListRoutes(Routes) <> ErrorNone then
    Exit;
  for Position := 0 to High(Routes) do
    if (Routes[Position].Destination.Family = AddressFamilyIPv6) and
       (Routes[Position].Destination.PrefixLength = 0) and
       AddressesAreEqual(RouteGateway(Routes[Position]), Gateway) and
       (string(PChar(@Routes[Position].InterfaceName[0])) = Name) then
      Exit(True);
end;

function ApplyStaticIpv6(const Name: string; CurrentMode, Metric: LongWord; constref Desired: TIpv6Settings;
  out Failure: string): Boolean;
var
  Error: LongInt;
  AddressText: string;
begin
  if not SetMode(Name, CurrentMode, Ipv6ModeLinkLocal, Failure) then
    Exit(False);
  AddressText := AddressToText(Desired.Address) + '/' + IntToStr(Desired.PrefixLength);
  Error := AddInterfaceIpv6Address(PChar(Name), Desired.Address, Desired.PrefixLength);
  if (Error <> ErrorNone) and (Error <> ErrorExists) then
  begin
    Failure := 'IPv6 address ' + AddressText + ': ' + ErrorText(Error);
    Say(Name + ': ' + Failure);
    Exit(False);
  end;
  Say(Name + ': IPv6 address ' + AddressText);
  Result := True;
  if not Desired.HasGateway or HasIpv6DefaultRoute(Name, Desired.Gateway) then
    Exit;
  Error := AddRoute(AnyIpv6Address, 0, Desired.Gateway, PChar(Name), Metric);
  if Error <> ErrorNone then
    Say(Name + ': IPv6 default route through ' + AddressToText(Desired.Gateway) + ': ' + ErrorText(Error))
  else
    Say(Name + ': IPv6 default route through ' + AddressToText(Desired.Gateway));
end;

function ApplyIpv6Settings(const Name: string; CurrentMode, Metric: LongWord; constref Desired: TIpv6Settings;
  out Failure: string): Boolean;
begin
  Failure := '';
  if Desired.Problem <> '' then
  begin
    Failure := Desired.Problem;
    Say(Name + ': ' + Failure + ': IPv6 not configured');
    Exit(False);
  end;
  case Desired.Method of
    Ipv6MethodStatic: Result := ApplyStaticIpv6(Name, CurrentMode, Metric, Desired, Failure);
    Ipv6MethodNone: Result := SetMode(Name, CurrentMode, Ipv6ModeOff, Failure);
  else
    Result := SetMode(Name, CurrentMode, Ipv6ModeAutomatic, Failure);
  end;
end;

end.
