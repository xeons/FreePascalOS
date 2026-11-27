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
  The kernel's list of sockets as ss sees it: each socket's netid (tcp,
  udp, or raw for ICMP), its state in ss's terms (a UDP or ICMP socket
  with a peer is ESTAB, one without UNCONN), and whether the options
  and the filter pick it. TCP sockets neither bound nor connected are
  left out, as netstat leaves them out.
}
unit Ss.Sockets;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
  Sys.NetworkInterfaces,
  Ss.Filters,
  Ss.Options;

type
  TNetid = (NetidTcp, NetidUdp, NetidRaw);

function NetidOf(constref Entry: TAbiSocketInformation): TNetid;
function NetidName(Netid: TNetid): string;
function SocketStateOf(constref Entry: TAbiSocketInformation): TSocketState;
function FactsOf(constref Entry: TAbiSocketInformation): TSocketFacts;
{ A TCP socket made but neither bound nor connected. }
function IsUnplaced(constref Entry: TAbiSocketInformation): Boolean;
{ The states shown with these options (and the filter's). }
function ShownStates(constref Options: TSsOptions): TSocketStates;
function SocketIsShown(constref Entry: TAbiSocketInformation; constref Options: TSsOptions;
  States: TSocketStates): Boolean;
{ The sockets to show, in ss's order: TCP, UDP, raw; IPv4 before IPv6
  within each. }
function SelectSockets(const Entries: TSocketInformationList; constref Options: TSsOptions): TSocketInformationList;

implementation

uses
  Sys.InternetAddresses;

const
  FamiliesInOrder: array[0..1] of Word = (AddressFamilyIPv4, AddressFamilyIPv6);

function NetidOf(constref Entry: TAbiSocketInformation): TNetid;
begin
  case Entry.Protocol of
    ProtocolTcp: Result := NetidTcp;
    ProtocolUdp: Result := NetidUdp;
  else
    Result := NetidRaw;
  end;
end;

function NetidName(Netid: TNetid): string;
begin
  case Netid of
    NetidTcp: Result := 'tcp';
    NetidUdp: Result := 'udp';
  else
    Result := 'raw';
  end;
end;

function TcpSocketState(State: LongWord): TSocketState;
begin
  case State of
    TcpStateListen: Result := StateListen;
    TcpStateSynSent: Result := StateSynSent;
    TcpStateSynReceived: Result := StateSynReceived;
    TcpStateEstablished: Result := StateEstablished;
    TcpStateFinWait1: Result := StateFinWait1;
    TcpStateFinWait2: Result := StateFinWait2;
    TcpStateCloseWait: Result := StateCloseWait;
    TcpStateClosing: Result := StateClosing;
    TcpStateLastAck: Result := StateLastAck;
    TcpStateTimeWait: Result := StateTimeWait;
  else
    Result := StateClosed;
  end;
end;

function SocketStateOf(constref Entry: TAbiSocketInformation): TSocketState;
begin
  if Entry.Protocol = ProtocolTcp then
    Result := TcpSocketState(Entry.State)
  else if (Entry.PeerAddress.Port <> 0) or not AddressIsUnspecified(SocketAddressHost(Entry.PeerAddress)) then
    Result := StateEstablished
  else
    Result := StateClosed;
end;

function FactsOf(constref Entry: TAbiSocketInformation): TSocketFacts;
begin
  Result.State := SocketStateOf(Entry);
  Result.LocalAddress := SocketAddressHost(Entry.LocalAddress);
  Result.PeerAddress := SocketAddressHost(Entry.PeerAddress);
  Result.LocalPort := Entry.LocalAddress.Port;
  Result.PeerPort := Entry.PeerAddress.Port;
end;

function IsUnplaced(constref Entry: TAbiSocketInformation): Boolean;
begin
  Result := (Entry.Protocol = ProtocolTcp) and (Entry.State = TcpStateClosed) and (Entry.LocalAddress.Port = 0);
end;

function ShownStates(constref Options: TSsOptions): TSocketStates;
var
  Defaults: TSocketStates;
begin
  if Options.All then
    Defaults := AllSocketStates
  else if Options.ListeningOnly then
    Defaults := ListeningSocketStates
  else
    Defaults := DefaultSocketStates;
  Result := EffectiveStates(Options.Filter, Defaults);
end;

function NetidIsSelected(Netid: TNetid; constref Options: TSsOptions): Boolean;
begin
  case Netid of
    NetidTcp: Result := Options.ShowTcp;
    NetidUdp: Result := Options.ShowUdp;
  else
    Result := Options.ShowRaw;
  end;
end;

function SocketIsShown(constref Entry: TAbiSocketInformation; constref Options: TSsOptions;
  States: TSocketStates): Boolean;
begin
  Result := False;
  if (Entry.Family = AddressFamilyIPv4) and not Options.ShowIpv4 then
    Exit;
  if (Entry.Family = AddressFamilyIPv6) and not Options.ShowIpv6 then
    Exit;
  if not NetidIsSelected(NetidOf(Entry), Options) or IsUnplaced(Entry) then
    Exit;
  if not (SocketStateOf(Entry) in States) then
    Exit;
  Result := ExpressionMatches(Options.Filter.Expression, FactsOf(Entry));
end;

function SelectSockets(const Entries: TSocketInformationList; constref Options: TSsOptions): TSocketInformationList;
var
  States: TSocketStates;
  Netid: TNetid;
  Family: Word;
  Index: Integer;
begin
  Result := nil;
  States := ShownStates(Options);
  for Netid := Low(TNetid) to High(TNetid) do
    for Family in FamiliesInOrder do
      for Index := 0 to High(Entries) do
        if (NetidOf(Entries[Index]) = Netid) and (Entries[Index].Family = Family) and
           SocketIsShown(Entries[Index], Options, States) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Entries[Index];
        end;
end;

end.
