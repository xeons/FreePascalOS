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
  What every network card driver shares, between it and the network
  adapters (Io.NetworkAdapters): registering the adapter and announcing
  it, following its link (announcing each change, and the link coming
  back after suspend to RAM, and telling the network layer), and its
  statistics.

  Each driver embeds a TNetworkCard in its own record and fills in the
  link state it reads from its hardware; this unit decides whether that
  is a change. The lines it writes, which the tests look for:

    [net] eth1: Intel 82574L, address 52:54:00:12:34:56, link down, interrupts by MSI
    [net] eth1 (Intel 82574L): link up, 1000 Mbit/s full duplex
    [net] eth1 (Intel 82574L): link up after waking
}
unit Drivers.NetworkCards;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Io.NetworkAdapters;

type
  TNetworkCardStatistics = record
    FramesReceived: QWord;
    BytesReceived: QWord;
    FramesTransmitted: QWord;
    BytesTransmitted: QWord;
    { Frames the card received damaged (bad check sequence, alignment,
      length) or that the driver had to drop as malformed. }
    ReceiveErrors: QWord;
    { Frames the card had no room for. }
    ReceiveMissed: QWord;
    TransmitErrors: QWord;
    Collisions: QWord;
    LinkChanges: QWord;
  end;

  TNetworkLinkState = record
    IsUp: Boolean;
    { 0 if the card does not say. }
    SpeedMegabits: LongWord;
    FullDuplex: Boolean;
  end;

  PNetworkCard = ^TNetworkCard;
  TNetworkCard = record
    Adapter: PNetworkAdapter;
    Statistics: TNetworkCardStatistics;
    Link: TNetworkLinkState;
    { "MSI", "line", "polled": how the card raises its interrupts. }
    InterruptDescription: PChar;
    { Set on waking from suspend to RAM: the next time the link is seen
      up, that is announced. }
    AnnounceLinkAfterWaking: Boolean;
    LinkLock: TSpinLock;
  end;

{ Registers the card's adapter with the network layer and announces it
  with the link as Card^.Link holds it now. False if the adapter could
  not be registered. Passive level, while the system starts. }
function AddNetworkCard(Card: PNetworkCard; const Routines: TNetworkDriverRoutines; Context: Pointer;
  const Address: TEthernetAddress; Description: PChar): Boolean;

{ The driver read its link: if it changed, it is announced and the
  network layer told. Dispatch level or below. }
procedure UpdateNetworkCardLink(Card: PNetworkCard; const Link: TNetworkLinkState);

{ The driver set its card up again after suspend to RAM: the link coming
  up is announced (the tests wait for it). }
procedure NetworkCardWoke(Card: PNetworkCard);

{ Writes every card: its link and statistics (the kernel debug shell's
  netcards). }
procedure WriteNetworkCardSummary;

{ Neither all zeros, all ones, nor a group (multicast) address. }
function EthernetAddressIsUsable(const Address: TEthernetAddress): Boolean;

procedure DebugWriteEthernetAddress(const Address: TEthernetAddress);

implementation

uses
  Kernel.PriorityLevel,
  Debug.Output;

const
  MaximumCards = 16;

var
  Cards: array[0..MaximumCards - 1] of PNetworkCard;
  CardCount: Integer;

function EthernetAddressIsUsable(const Address: TEthernetAddress): Boolean;
var
  Index: Integer;
  AllZero: Boolean;
  AllOnes: Boolean;
begin
  AllZero := True;
  AllOnes := True;
  for Index := 0 to EthernetAddressLength - 1 do
  begin
    if Address[Index] <> 0 then
      AllZero := False;
    if Address[Index] <> $FF then
      AllOnes := False;
  end;
  Result := not AllZero and not AllOnes and ((Address[0] and 1) = 0);
end;

procedure DebugWriteEthernetAddress(const Address: TEthernetAddress);
var
  Index: Integer;
begin
  for Index := 0 to EthernetAddressLength - 1 do
  begin
    if Index > 0 then
      DebugWrite(':');
    DebugWriteHex(Address[Index], 2);
  end;
end;

procedure WriteCardName(Card: PNetworkCard);
begin
  DebugWrite(@Card^.Adapter^.Name[0]);
  DebugWrite(' (');
  DebugWrite(@Card^.Adapter^.Description[0]);
  DebugWrite(')');
end;

procedure WriteLink(const Link: TNetworkLinkState);
begin
  if not Link.IsUp then
  begin
    DebugWrite('link down');
    Exit;
  end;
  DebugWrite('link up');
  if Link.SpeedMegabits <> 0 then
  begin
    DebugWrite(', ');
    DebugWriteDecimal(Link.SpeedMegabits);
    if Link.FullDuplex then
      DebugWrite(' Mbit/s full duplex')
    else
      DebugWrite(' Mbit/s half duplex');
  end;
end;

function AddNetworkCard(Card: PNetworkCard; const Routines: TNetworkDriverRoutines; Context: Pointer;
  const Address: TEthernetAddress; Description: PChar): Boolean;
begin
  Result := False;
  InitializeSpinLock(Card^.LinkLock);
  Card^.Adapter := RegisterNetworkAdapter(Routines, Context, Address, Description);
  if Card^.Adapter = nil then
    Exit;
  if CardCount < MaximumCards then
  begin
    Cards[CardCount] := Card;
    Inc(CardCount);
  end;
  DebugBeginMessage;
  DebugWriteTag('net');
  DebugWrite(@Card^.Adapter^.Name[0]);
  DebugWrite(': ');
  DebugWrite(Description);
  DebugWrite(', address ');
  DebugWriteEthernetAddress(Address);
  DebugWrite(', ');
  WriteLink(Card^.Link);
  DebugWrite(', interrupts by ');
  DebugWriteLine(Card^.InterruptDescription);
  DebugEndMessage;
  Result := True;
end;

procedure UpdateNetworkCardLink(Card: PNetworkCard; const Link: TNetworkLinkState);
var
  PreviousLevel: TPriorityLevel;
  Changed: Boolean;
  AnnounceWaking: Boolean;
begin
  if Card^.Adapter = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(Card^.LinkLock);
  Changed := (Link.IsUp <> Card^.Link.IsUp) or
    (Link.IsUp and ((Link.SpeedMegabits <> Card^.Link.SpeedMegabits) or (Link.FullDuplex <> Card^.Link.FullDuplex)));
  AnnounceWaking := Link.IsUp and Card^.AnnounceLinkAfterWaking;
  if AnnounceWaking then
    Card^.AnnounceLinkAfterWaking := False;
  Card^.Link := Link;
  if Changed then
    Inc(Card^.Statistics.LinkChanges);
  ReleaseSpinLock(Card^.LinkLock, PreviousLevel);

  if Changed then
  begin
    DebugBeginMessage;
    DebugWriteTag('net');
    WriteCardName(Card);
    DebugWrite(': ');
    WriteLink(Link);
    DebugWriteLine('');
    DebugEndMessage;
  end;
  if AnnounceWaking then
  begin
    DebugBeginMessage;
    DebugWriteTag('net');
    WriteCardName(Card);
    DebugWriteLine(': link up after waking');
    DebugEndMessage;
  end;
  if Changed then
    NetworkLinkChanged(Card^.Adapter);
end;

procedure NetworkCardWoke(Card: PNetworkCard);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Card^.LinkLock);
  Card^.AnnounceLinkAfterWaking := True;
  ReleaseSpinLock(Card^.LinkLock, PreviousLevel);
end;

procedure WriteNetworkCardSummary;
var
  Index: Integer;
  Card: PNetworkCard;
begin
  DebugBeginMessage;
  if CardCount = 0 then
  begin
    DebugWriteTag('net');
    DebugWriteLine('no network cards');
  end;
  for Index := 0 to CardCount - 1 do
  begin
    Card := Cards[Index];
    DebugWriteTag('net');
    WriteCardName(Card);
    DebugWrite(': ');
    WriteLink(Card^.Link);
    DebugWriteLine('');
    with Card^.Statistics do
    begin
      DebugWriteTag('net');
      DebugWrite('  received ');
      DebugWriteDecimal(FramesReceived);
      DebugWrite(' frames (');
      DebugWriteDecimal(BytesReceived);
      DebugWrite(' bytes), ');
      DebugWriteDecimal(ReceiveErrors);
      DebugWrite(' damaged, ');
      DebugWriteDecimal(ReceiveMissed);
      DebugWriteLine(' missed');
      DebugWriteTag('net');
      DebugWrite('  sent ');
      DebugWriteDecimal(FramesTransmitted);
      DebugWrite(' frames (');
      DebugWriteDecimal(BytesTransmitted);
      DebugWrite(' bytes), ');
      DebugWriteDecimal(TransmitErrors);
      DebugWrite(' failed, ');
      DebugWriteDecimal(Collisions);
      DebugWrite(' collisions; ');
      DebugWriteDecimal(LinkChanges);
      DebugWriteLine(' link changes');
    end;
  end;
  DebugEndMessage;
end;

end.
