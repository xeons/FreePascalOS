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
  What the network service says about each interface, in
  /var/lib/network/NAME.state (written whole and renamed into place, so
  a reader sees the old file or the new one), in the settings files'
  format (Configuration.Documents):

    Method = "dhcp"                 as in the settings
    State = "configured"            down, no-link, configuring,
                                    configured, failed
    Address = "10.0.2.15/24"        or "" while it has none
    Gateway = "10.0.2.2"
    DnsServers = ["10.0.2.3"]
    Domain = "example.org"
    LeaseSeconds = 86400            DHCP: how long the lease lasts
    LeaseObtained = 1794268800      ...and when it began (Unix time)
    DhcpServer = "10.0.2.2"

  This unit only reads the text (ParseInterfaceState), so it is checked
  on the host too (tools/SettingsTest); Configuration.NetworkStatus
  reads the files and puts them beside what the kernel says.
}
unit Configuration.NetworkState;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.NetworkSettings;

const
  NetworkStateFolder = '/var/lib/network';
  NetworkStateSuffix = '.state';

type
  TInterfaceProgress = (ProgressUnknown, ProgressDown, ProgressNoLink, ProgressConfiguring, ProgressConfigured,
    ProgressFailed);

  TInterfaceState = record
    Name: string;
    { A state file was read. }
    Known: Boolean;
    Method: TNetworkMethod;
    Progress: TInterfaceProgress;
    { "10.0.2.15/24", or empty. }
    Address: string;
    Gateway: string;
    DnsServers: TStringArray;
    Domain: string;
    { Zero without a lease. }
    LeaseSeconds: Int64;
    LeaseObtained: Int64;
    DhcpServer: string;
    { Ipv6Method auto when the file does not say. }
    Ipv6Method: TIpv6Method;
    { "fec0::5054:ff:fe12:3456/64", the link-local one included. }
    Ipv6Addresses: TStringArray;
    { The IPv6 default route's gateway, or empty. }
    Ipv6Gateway: string;
    { What routers advertised (RDNSS). }
    Ipv6DnsServers: TStringArray;
  end;

{ Reads a state file's Text for interface Name; False (and Known False)
  if it is not one. }
function ParseInterfaceState(const Name, Text: string; out State: TInterfaceState): Boolean;
{ "configured", ... as the files write them ("" for unknown). }
function InterfaceProgressName(Progress: TInterfaceProgress): string;
function ParseInterfaceProgress(const Text: string): TInterfaceProgress;
{ /var/lib/network/eth0.state }
function InterfaceStatePath(const Name: string): string;
{ When the lease ends (Unix time), 0 without one. }
function LeaseExpires(const State: TInterfaceState): Int64;

implementation

uses
  Configuration.Values,
  Configuration.Documents;

const
  ProgressNames: array[TInterfaceProgress] of string = ('', 'down', 'no-link', 'configuring', 'configured', 'failed');

function InterfaceProgressName(Progress: TInterfaceProgress): string;
begin
  Result := ProgressNames[Progress];
end;

function ParseInterfaceProgress(const Text: string): TInterfaceProgress;
var
  Candidate: TInterfaceProgress;
begin
  for Candidate := Succ(ProgressUnknown) to High(TInterfaceProgress) do
    if LowerCase(Trim(Text)) = ProgressNames[Candidate] then
      Exit(Candidate);
  Result := ProgressUnknown;
end;

function InterfaceStatePath(const Name: string): string;
begin
  Result := NetworkStateFolder + '/' + Name + NetworkStateSuffix;
end;

function LeaseExpires(const State: TInterfaceState): Int64;
begin
  if (State.LeaseSeconds <= 0) or (State.LeaseObtained <= 0) then
    Result := 0
  else
    Result := State.LeaseObtained + State.LeaseSeconds;
end;

function DocumentString(Document: TSettingsDocument; const Key: string): string;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Result := '';
  if Document.GetValue('', Key, Value, Fixed) and SettingAsString(Value, Result) then
    Result := Trim(Result)
  else
    Result := '';
end;

function DocumentInteger(Document: TSettingsDocument; const Key: string): Int64;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  if not Document.GetValue('', Key, Value, Fixed) or not SettingAsInteger(Value, Result) then
    Result := 0;
end;

function DocumentList(Document: TSettingsDocument; const Key: string): TStringArray;
var
  Value: TSettingValue;
  Fixed: Boolean;
begin
  if not Document.GetValue('', Key, Value, Fixed) or not SettingAsList(Value, Result) then
    Result := nil;
end;

function ParseInterfaceState(const Name, Text: string; out State: TInterfaceState): Boolean;
var
  Document: TSettingsDocument;
begin
  State := Default(TInterfaceState);
  State.Name := Name;
  Document := TSettingsDocument.Create;
  try
    Document.Parse(Text);
    State.Progress := ParseInterfaceProgress(DocumentString(Document, 'State'));
    { A file without a state it knows is not taken. }
    if State.Progress = ProgressUnknown then
      Exit(False);
    if not ParseNetworkMethod(DocumentString(Document, 'Method'), State.Method) then
      State.Method := NetworkMethodNone;
    State.Address := DocumentString(Document, 'Address');
    State.Gateway := DocumentString(Document, 'Gateway');
    State.DnsServers := DocumentList(Document, 'DnsServers');
    State.Domain := DocumentString(Document, 'Domain');
    State.LeaseSeconds := DocumentInteger(Document, 'LeaseSeconds');
    State.LeaseObtained := DocumentInteger(Document, 'LeaseObtained');
    State.DhcpServer := DocumentString(Document, 'DhcpServer');
    if not ParseIpv6Method(DocumentString(Document, 'Ipv6Method'), State.Ipv6Method) then
      State.Ipv6Method := Ipv6MethodAuto;
    State.Ipv6Addresses := DocumentList(Document, 'Ipv6Addresses');
    State.Ipv6Gateway := DocumentString(Document, 'Ipv6Gateway');
    State.Ipv6DnsServers := DocumentList(Document, 'Ipv6DnsServers');
    State.Known := True;
    Result := True;
  finally
    Document.Free;
  end;
end;

end.
