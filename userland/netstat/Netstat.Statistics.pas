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
  netstat -s: the protocols' counters (CallGetNetworkStatistics) in the
  words net-tools uses, a group per protocol: Ip, Icmp (with the
  messages of each type that were seen), Tcp and Udp. -t or -u keeps
  to TCP or UDP.
}
unit Netstat.Statistics;

{$mode objfpc}

interface

uses
  Netstat.Selection;

{ Selection.ShowTcp and ShowUdp both set (no -t or -u): every group. }
procedure ShowProtocolStatistics(constref Selection: TNetstatSelection);

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Format,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Util.Messages;

procedure WriteCounter(Value: QWord; Text: PChar);
begin
  WriteFormatted(StandardOutput, '    %u %s'#10, [ArgumentUnsigned(Value), ArgumentText(Text)]);
end;

procedure ShowIp(constref Ip: TAbiIpStatistics);
begin
  WriteLine(StandardOutput, 'Ip:');
  { 2: not a router (RFC 1213's ipForwarding). }
  WriteLine(StandardOutput, '    Forwarding: 2');
  WriteCounter(Ip.Received, 'total packets received');
  WriteCounter(Ip.HeaderErrors, 'with invalid headers');
  WriteCounter(Ip.AddressErrors, 'with invalid addresses');
  WriteCounter(Ip.Forwarded, 'forwarded');
  WriteCounter(Ip.UnknownProtocols, 'with unknown protocol');
  WriteCounter(Ip.Delivered, 'incoming packets delivered');
  WriteCounter(Ip.SendRequests, 'requests sent out');
  WriteCounter(Ip.SendDiscards, 'outgoing packets dropped');
  WriteCounter(Ip.NoRoutes, 'dropped because of missing route');
  WriteCounter(Ip.ReassemblyFragments, 'reassemblies required');
  WriteCounter(Ip.Reassembled, 'packets reassembled ok');
  WriteCounter(Ip.ReassemblyFailures, 'packet reassemblies failed');
end;

{ net-tools' name for each ICMP type; nil for those it has none for. }
function IcmpTypeName(IcmpType: Integer): PChar;
begin
  case IcmpType of
    0: Result := 'echo replies';
    3: Result := 'destination unreachable';
    4: Result := 'source quenches';
    5: Result := 'redirects';
    8: Result := 'echo requests';
    11: Result := 'timeout in transit';
    12: Result := 'wrong parameters';
    13: Result := 'timestamp requests';
    14: Result := 'timestamp replies';
    15: Result := 'information requests';
    16: Result := 'information replies';
    17: Result := 'address mask request';
    18: Result := 'address mask replies';
  else
    Result := nil;
  end;
end;

{ The types that were seen, one line each. }
procedure WriteIcmpHistogram(Title: PChar; const Counts: array of QWord);
var
  IcmpType: Integer;
  Name: PChar;
  Written: Boolean;
begin
  Written := False;
  for IcmpType := 0 to High(Counts) do
  begin
    if Counts[IcmpType] = 0 then
      Continue;
    if not Written then
      WriteFormatted(StandardOutput, '    %s'#10, [ArgumentText(Title)]);
    Written := True;
    Name := IcmpTypeName(IcmpType);
    if Name <> nil then
      WriteFormatted(StandardOutput, '        %s: %u'#10, [ArgumentText(Name), ArgumentUnsigned(Counts[IcmpType])])
    else
      WriteFormatted(StandardOutput, '        type %d: %u'#10, [ArgumentNumber(IcmpType),
        ArgumentUnsigned(Counts[IcmpType])]);
  end;
end;

procedure ShowIcmp(constref Icmp: TAbiIcmpStatistics);
begin
  WriteLine(StandardOutput, 'Icmp:');
  WriteCounter(Icmp.Received, 'ICMP messages received');
  WriteCounter(Icmp.ReceiveErrors, 'input ICMP message failed');
  WriteIcmpHistogram('ICMP input histogram:', Icmp.ReceivedByType);
  WriteCounter(Icmp.Sent, 'ICMP messages sent');
  WriteCounter(Icmp.SendErrors, 'ICMP messages failed');
  WriteIcmpHistogram('ICMP output histogram:', Icmp.SentByType);
end;

procedure ShowTcp(constref Tcp: TAbiTcpStatistics);
begin
  WriteLine(StandardOutput, 'Tcp:');
  WriteCounter(Tcp.ActiveOpens, 'active connection openings');
  WriteCounter(Tcp.PassiveOpens, 'passive connection openings');
  WriteCounter(Tcp.FailedAttempts, 'failed connection attempts');
  WriteCounter(Tcp.EstablishedResets, 'connection resets received');
  WriteCounter(Tcp.CurrentlyEstablished, 'connections established');
  WriteCounter(Tcp.SegmentsReceived, 'segments received');
  WriteCounter(Tcp.SegmentsSent, 'segments sent out');
  WriteCounter(Tcp.SegmentsRetransmitted, 'segments retransmitted');
  WriteCounter(Tcp.ReceiveErrors, 'bad segments received');
  WriteCounter(Tcp.ResetsSent, 'resets sent');
end;

procedure ShowUdp(constref Udp: TAbiUdpStatistics);
begin
  WriteLine(StandardOutput, 'Udp:');
  WriteCounter(Udp.Received, 'packets received');
  WriteCounter(Udp.NoPorts, 'packets to unknown port received');
  WriteCounter(Udp.ReceiveErrors, 'packet receive errors');
  WriteCounter(Udp.Sent, 'packets sent');
  WriteCounter(Udp.ReceiveQueueErrors, 'receive buffer errors');
end;

procedure ShowProtocolStatistics(constref Selection: TNetstatSelection);
var
  Statistics: TAbiNetworkStatistics;
  Error: LongInt;
  Everything: Boolean;
begin
  Error := GetNetworkStatistics(Statistics);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the network statistics', []);
  Everything := Selection.ShowTcp and Selection.ShowUdp;
  if Everything then
  begin
    ShowIp(Statistics.Ip);
    ShowIcmp(Statistics.Icmp);
  end;
  if Selection.ShowTcp then
    ShowTcp(Statistics.Tcp);
  if Selection.ShowUdp then
    ShowUdp(Statistics.Udp);
end;

end.
