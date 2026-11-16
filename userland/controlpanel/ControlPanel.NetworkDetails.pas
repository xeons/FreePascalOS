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
  The Network page's Status tab: how the interface chosen is doing now -
  its state, address, gateway, DNS servers and domain, the DHCP lease
  (when it was obtained and when it expires, from which server), the
  adapter and its Ethernet address and MTU, and the packets and bytes
  sent and received - a caption and a value on each row, in logical
  units. The page shows it again every second and whenever the network
  service says something changed.
}
unit ControlPanel.NetworkDetails;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Labels,
  Configuration.NetworkStatus;

type
  TNetworkDetailRow = (DetailState, DetailAddress, DetailGateway, DetailDnsServers, DetailDomain, DetailLeaseObtained,
    DetailLeaseExpires, DetailDhcpServer, DetailAdapter, DetailHardwareAddress, DetailSent, DetailReceived);

  TNetworkDetails = class
  private
    FValues: array[TNetworkDetailRow] of TLabel;
  public
    { Puts the captions and values on Parent, from Top down. }
    constructor Create(Parent: TControl; Left, Top, Width: LongInt);
    procedure ShowStatus(const Status: TInterfaceStatus);
    { No interface to show. }
    procedure ShowNothing;
  end;

implementation

uses
  SysUtils,
  Sys.LocalTime,
  Sys.InternetAddresses,
  Util.Sizes,
  Configuration.NetworkSettings,
  Configuration.NetworkState;

const
  RowSpacing = 16;
  RowHeight = 16;
  CaptionWidth = 120;
  Captions: array[TNetworkDetailRow] of string = ('State:', 'Address:', 'Gateway:', 'DNS servers:', 'Domain:',
    'Lease obtained:', 'Lease expires:', 'DHCP server:', 'Adapter:', 'Ethernet address:', 'Sent:', 'Received:');
  NoValue = '-';

constructor TNetworkDetails.Create(Parent: TControl; Left, Top, Width: LongInt);
var
  Row: TNetworkDetailRow;
  Caption: TLabel;
  RowTop: LongInt;
begin
  inherited Create;
  RowTop := Top;
  for Row := Low(TNetworkDetailRow) to High(TNetworkDetailRow) do
  begin
    Caption := TLabel.Create(Parent);
    Caption.ShowsMnemonic := False;
    Caption.Text := Captions[Row];
    Caption.SetBounds(Left, RowTop, CaptionWidth, RowHeight);
    FValues[Row] := TLabel.Create(Parent);
    FValues[Row].ShowsMnemonic := False;
    FValues[Row].SetBounds(Left + CaptionWidth, RowTop, Width - CaptionWidth, RowHeight);
    RowTop := RowTop + RowSpacing;
  end;
end;

function OrNoValue(const Text: string): string;
begin
  if Text = '' then
    Result := NoValue
  else
    Result := Text;
end;

function LocalTimeText(Time: Int64): string;
var
  Local: TLocalTime;
begin
  if Time <= 0 then
    Exit(NoValue);
  DecodeLocalTime(Time, Local);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [Local.DateTime.Year, Local.DateTime.Month, Local.DateTime.Day,
    Local.DateTime.Hour, Local.DateTime.Minute, Local.DateTime.Second]);
end;

function CountText(Packets, Bytes: QWord): string;
begin
  Result := Format('%u packets, %u bytes (%s)', [Packets, Bytes, FormatHumanSize(Bytes)]);
end;

function StateText(const Status: TInterfaceStatus): string;
var
  Condition: string;
begin
  Condition := NetworkConditionText(Status.Condition);
  Result := UpperCase(Copy(Condition, 1, 1)) + Copy(Condition, 2, Length(Condition));
  if Status.State.Known and (Status.State.Method = NetworkMethodDhcp) then
    Result := Result + ' (DHCP)'
  else if Status.State.Known and (Status.State.Method = NetworkMethodStatic) then
    Result := Result + ' (static address)';
end;

function AddressText(const Text: string): string;
var
  AddressValue: LongWord;
  PrefixLength: LongWord;
begin
  if not ParseInterfaceAddress(Text, AddressValue, PrefixLength) then
    Exit(OrNoValue(Text));
  Result := Text + ' (netmask ' + NetmaskToText(PrefixLength) + ')';
end;

procedure TNetworkDetails.ShowStatus(const Status: TInterfaceStatus);
var
  Gateway: string;
begin
  FValues[DetailState].Text := StateText(Status);
  FValues[DetailAddress].Text := AddressText(Status.Address);
  Gateway := Status.State.Gateway;
  FValues[DetailGateway].Text := OrNoValue(Gateway);
  FValues[DetailDnsServers].Text := OrNoValue(JoinServerList(Status.State.DnsServers));
  FValues[DetailDomain].Text := OrNoValue(Status.State.Domain);
  FValues[DetailLeaseObtained].Text := LocalTimeText(Status.State.LeaseObtained);
  FValues[DetailLeaseExpires].Text := LocalTimeText(LeaseExpires(Status.State));
  FValues[DetailDhcpServer].Text := OrNoValue(Status.State.DhcpServer);
  FValues[DetailAdapter].Text := OrNoValue(Status.Description);
  FValues[DetailHardwareAddress].Text := Format('%s, MTU %u', [OrNoValue(Status.HardwareAddress), Status.Mtu]);
  FValues[DetailSent].Text := CountText(Status.Counters.SentPackets, Status.Counters.SentBytes);
  FValues[DetailReceived].Text := CountText(Status.Counters.ReceivedPackets, Status.Counters.ReceivedBytes);
end;

procedure TNetworkDetails.ShowNothing;
var
  Row: TNetworkDetailRow;
begin
  for Row := Low(TNetworkDetailRow) to High(TNetworkDetailRow) do
    FValues[Row].Text := NoValue;
end;

end.
