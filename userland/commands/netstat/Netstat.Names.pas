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
  How netstat and ss name hosts and ports: every address and port they
  show goes through here, so names come in one place.

  A host's name comes from /etc/hosts, else from a reverse (PTR) lookup
  through the system's DNS servers with a short timeout (one second, one
  try). Answers are kept for the rest of the run, and once a server
  fails to answer no more are asked, so a list of many sockets does not
  wait for each. The wildcard address (0.0.0.0, ::) stays a number.

  A port's name comes from /etc/ports (Netstat.Services) for the
  socket's protocol ("tcp" or "udp"), read once.
}
unit Netstat.Names;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.InternetAddresses;

const
  ReverseLookupTimeoutMilliseconds = 1000;

{ Address and port as netstat shows them ("10.0.2.15:22", "0.0.0.0:*");
  port 0 is "*". Without Numeric the host and the port are named when
  they have names. Protocol (ProtocolTcp, ProtocolUdp...) picks the
  list a port's name comes from. }
function EndpointText(constref Address: TAbiSocketAddress; Protocol: Word; Numeric: Boolean): string;
{ The host's name, or its address as a number (always with Numeric). }
function HostText(constref Address: TInternetAddress; Numeric: Boolean): string;
{ The port's service name for Protocol, or its number; 0 is "*". }
function PortText(Port: Word; Protocol: Word; Numeric: Boolean): string;
{ The port a service name has ("ssh": 22) for Protocol. }
function LookUpServicePort(const Name: string; Protocol: Word; out Port: Word): Boolean;
{ "tcp" or "udp", the protocol's name in the ports list ('' for others). }
function ServiceProtocolName(Protocol: Word): string;

implementation

uses
  Classes,
  SysUtils,
  Sys.DnsMessages,
  Sys.DnsNames,
  Sys.DnsQueries,
  Sys.HostsFile,
  Netstat.Services;

type
  TKnownName = record
    Address: TInternetAddress;
    Name: string;
  end;

var
  ServicesLoaded: Boolean = False;
  Services: TServiceTable;
  KnownNames: array of TKnownName;
  DnsGaveUp: Boolean = False;

procedure LoadServices;
var
  Lines: TStringList;
begin
  if ServicesLoaded then
    Exit;
  ServicesLoaded := True;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(PortsFilePath);
      Services := ParseServices(Lines.Text);
    except
      on EStreamError do
        Services := nil;
    end;
  finally
    Lines.Free;
  end;
end;

function ServiceProtocolName(Protocol: Word): string;
begin
  case Protocol of
    ProtocolTcp: Result := 'tcp';
    ProtocolUdp: Result := 'udp';
  else
    Result := '';
  end;
end;

function WithoutFinalDot(const Name: string): string;
begin
  if (Length(Name) > 1) and (Name[Length(Name)] = '.') then
    Result := Copy(Name, 1, Length(Name) - 1)
  else
    Result := Name;
end;

{ The PTR record's name in the answer to Question, or ''. }
function PointerFromAnswer(constref Message: TDnsMessage; const Question: string): string;
var
  Index: Integer;
begin
  Result := '';
  if Message.ResponseCode <> DnsResponseNoError then
    Exit;
  for Index := 0 to Message.RecordCount - 1 do
    if (Message.Records[Index].Section = DnsSectionAnswer) and
       (Message.Records[Index].RecordType = DnsTypePtr) then
      Exit(WithoutFinalDot(Message.Records[Index].Target));
end;

{ The name DNS gives Address, '' if none (or no server answers in time). }
function AskDns(constref Address: TInternetAddress): string;
var
  Question: string;
  Options: TDnsQueryOptions;
  Message: TDnsMessage;
  Details: TDnsQueryDetails;
  Error: LongInt;
begin
  Result := '';
  if DnsGaveUp or not ReverseLookupName(Address, Question) then
    Exit;
  SystemDnsQueryOptions(Options);
  if Length(Options.Servers) = 0 then
  begin
    DnsGaveUp := True;
    Exit;
  end;
  Options.TimeoutMilliseconds := ReverseLookupTimeoutMilliseconds;
  Options.Attempts := 1;
  Error := QueryDns(Question, DnsTypePtr, Options, Message, Details);
  if Error <> ErrorNone then
  begin
    { Nobody answered: the rest would wait as long. }
    DnsGaveUp := True;
    Exit;
  end;
  Result := PointerFromAnswer(Message, Question);
end;

function FindKnownName(constref Address: TInternetAddress; out Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(KnownNames) do
    if AddressesAreEqual(KnownNames[Index].Address, Address) then
    begin
      Name := KnownNames[Index].Name;
      Exit(True);
    end;
  Name := '';
  Result := False;
end;

procedure RememberName(constref Address: TInternetAddress; const Name: string);
begin
  SetLength(KnownNames, Length(KnownNames) + 1);
  KnownNames[High(KnownNames)].Address := Address;
  KnownNames[High(KnownNames)].Name := Name;
end;

function HostText(constref Address: TInternetAddress; Numeric: Boolean): string;
var
  Name: string;
begin
  Result := AddressToText(Address);
  if Numeric or AddressIsUnspecified(Address) then
    Exit;
  if not FindKnownName(Address, Name) then
  begin
    if not LookUpHostsFileAddress(Address, Name) then
      Name := AskDns(Address);
    RememberName(Address, Name);
  end;
  if Name <> '' then
    Result := Name;
end;

function PortText(Port: Word; Protocol: Word; Numeric: Boolean): string;
var
  Name: string;
begin
  if Port = 0 then
    Exit('*');
  Result := IntToStr(Port);
  if Numeric or (ServiceProtocolName(Protocol) = '') then
    Exit;
  LoadServices;
  Name := ServiceNameOf(Services, Port, ServiceProtocolName(Protocol));
  if Name <> '' then
    Result := Name;
end;

function LookUpServicePort(const Name: string; Protocol: Word; out Port: Word): Boolean;
begin
  LoadServices;
  Result := ServicePortOf(Services, Name, ServiceProtocolName(Protocol), Port);
end;

function EndpointText(constref Address: TAbiSocketAddress; Protocol: Word; Numeric: Boolean): string;
begin
  Result := HostText(SocketAddressHost(Address), Numeric) + ':' + PortText(Address.Port, Protocol, Numeric);
end;

end.
