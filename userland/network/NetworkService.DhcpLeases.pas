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
  A DHCP lease: the address a server lent, what came with it, and when
  it is to be renewed (T1), rebound (T2) and when it runs out.

  Times are kept on the uptime clock (milliseconds), which never jumps
  when the wall clock is set; the wall clock time it was obtained at is
  kept for the state file. Without T1 and T2 from the server they are
  half and seven eighths of the lease (RFC 2131 4.4.5); a lease of
  InfiniteLease never ends.
}
unit NetworkService.DhcpLeases;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.InternetAddresses,
  NetworkService.DhcpMessages;

const
  NoDeadline = High(QWord);
  { A prefix for a server that gives no subnet mask: the address's class
    (RFC 2131 says the client may guess). }
  ClassAPrefix = 8;
  ClassBPrefix = 16;
  ClassCPrefix = 24;

type
  TDhcpLease = record
    Address: TInternetAddress;
    PrefixLength: LongWord;
    HasGateway: Boolean;
    Gateway: TInternetAddress;
    DnsServers: array of TInternetAddress;
    DomainName: string;
    Server: TInternetAddress;
    LeaseSeconds: LongWord;
    RenewalSeconds: LongWord;
    RebindingSeconds: LongWord;
    { Uptime milliseconds, and the wall clock (Unix time), when the
      server acknowledged it. }
    ObtainedAt: QWord;
    ObtainedWallClock: Int64;
  end;

function LeaseFromReply(constref Reply: TDhcpReply; ObtainedAt: QWord; ObtainedWallClock: Int64): TDhcpLease;
{ Uptime milliseconds of T1, T2 and the end (NoDeadline: never). }
function RenewalTime(constref Lease: TDhcpLease): QWord;
function RebindingTime(constref Lease: TDhcpLease): QWord;
function ExpiryTime(constref Lease: TDhcpLease): QWord;
{ "10.0.2.15/24". }
function LeaseAddressText(constref Lease: TDhcpLease): string;
function AddressText(constref Address: TInternetAddress): string;
{ The same address, gateway, DNS servers and domain (a renewal that
  changes nothing that is applied). }
function SameLeaseConfiguration(constref First, Second: TDhcpLease): Boolean;

implementation

const
  MillisecondsPerSecond = 1000;

function AddressText(constref Address: TInternetAddress): string;
var
  Text: array[0..InternetAddressTextCapacity - 1] of Char;
begin
  FormatInternetAddress(Address, @Text[0], SizeOf(Text));
  Result := string(PChar(@Text[0]));
end;

function ClassPrefix(constref Address: TInternetAddress): LongWord;
begin
  if Address.Bytes[0] < 128 then
    Result := ClassAPrefix
  else if Address.Bytes[0] < 192 then
    Result := ClassBPrefix
  else
    Result := ClassCPrefix;
end;

function LeaseFromReply(constref Reply: TDhcpReply; ObtainedAt: QWord; ObtainedWallClock: Int64): TDhcpLease;
var
  Index: Integer;
begin
  Result.Address := Reply.YourAddress;
  if Reply.HasSubnetMask then
    Result.PrefixLength := Reply.PrefixLength
  else
    Result.PrefixLength := ClassPrefix(Reply.YourAddress);
  Result.HasGateway := Reply.RouterCount > 0;
  if Result.HasGateway then
    Result.Gateway := Reply.Routers[0]
  else
    Result.Gateway := AnyIpv4Address;
  SetLength(Result.DnsServers, Reply.DnsServerCount);
  for Index := 0 to Reply.DnsServerCount - 1 do
    Result.DnsServers[Index] := Reply.DnsServers[Index];
  Result.DomainName := Reply.DomainName;
  Result.Server := Reply.ServerIdentifier;
  if Reply.HasLeaseTime then
    Result.LeaseSeconds := Reply.LeaseSeconds
  else
    Result.LeaseSeconds := InfiniteLease;
  if Reply.HasRenewalTime and (Reply.RenewalSeconds < Result.LeaseSeconds) then
    Result.RenewalSeconds := Reply.RenewalSeconds
  else
    Result.RenewalSeconds := Result.LeaseSeconds div 2;
  if Reply.HasRebindingTime and (Reply.RebindingSeconds < Result.LeaseSeconds) and
     (Reply.RebindingSeconds >= Result.RenewalSeconds) then
    Result.RebindingSeconds := Reply.RebindingSeconds
  else
    Result.RebindingSeconds := LongWord(QWord(Result.LeaseSeconds) * 7 div 8);
  Result.ObtainedAt := ObtainedAt;
  Result.ObtainedWallClock := ObtainedWallClock;
end;

function TimeAfter(constref Lease: TDhcpLease; Seconds: LongWord): QWord;
begin
  if Lease.LeaseSeconds = InfiniteLease then
    Exit(NoDeadline);
  Result := Lease.ObtainedAt + QWord(Seconds) * MillisecondsPerSecond;
end;

function RenewalTime(constref Lease: TDhcpLease): QWord;
begin
  Result := TimeAfter(Lease, Lease.RenewalSeconds);
end;

function RebindingTime(constref Lease: TDhcpLease): QWord;
begin
  Result := TimeAfter(Lease, Lease.RebindingSeconds);
end;

function ExpiryTime(constref Lease: TDhcpLease): QWord;
begin
  Result := TimeAfter(Lease, Lease.LeaseSeconds);
end;

function LeaseAddressText(constref Lease: TDhcpLease): string;
begin
  Result := AddressText(Lease.Address) + '/' + IntToStr(Lease.PrefixLength);
end;

function SameLeaseConfiguration(constref First, Second: TDhcpLease): Boolean;
var
  Index: Integer;
begin
  Result := AddressesAreEqual(First.Address, Second.Address) and (First.PrefixLength = Second.PrefixLength) and
    (First.HasGateway = Second.HasGateway) and AddressesAreEqual(First.Gateway, Second.Gateway) and
    (First.DomainName = Second.DomainName) and (Length(First.DnsServers) = Length(Second.DnsServers));
  if not Result then
    Exit;
  for Index := 0 to High(First.DnsServers) do
    if not AddressesAreEqual(First.DnsServers[Index], Second.DnsServers[Index]) then
      Exit(False);
end;

end.
