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
  Temporary addresses (RFC 8981), on interfaces with
  Ipv6OptionTemporaryAddresses: beside the automatic (SLAAC) address of
  each prefix a router advertises, one with a random identifier that
  connections this machine starts leave from (source selection's rule
  7), so that what it does from one day to the next cannot be tied
  together by its address.

  A temporary address lives at most TEMP_VALID_LIFETIME (two days) and
  is preferred at most TEMP_PREFERRED_LIFETIME (one day) less a
  DESYNC_FACTOR drawn for it (up to 0.4 of that, so that hosts do not
  all change at once), and never longer than its prefix. REGEN_ADVANCE
  (five seconds) before it is deprecated its successor is made; the old
  one stays, deprecated, for the connections that use it until its
  valid lifetime ends. A router renewing the prefix renews the
  temporary addresses within those limits. A temporary address another
  host has is replaced by a new one, three times at most in a row
  (TEMP_IDGEN_RETRIES). Under the network lock.
}
unit Network.TemporaryAddresses;

{$mode objfpc}

interface

uses
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Interfaces;

const
  TemporaryValidSeconds = 2 * 24 * 60 * 60;
  TemporaryPreferredSeconds = 24 * 60 * 60;
  { 2 + TEMP_IDGEN_RETRIES * DupAddrDetectTransmits * RetransTimer. }
  RegenerateAdvanceSeconds = 5;
  TemporaryIdentifierRetries = 3;

{ The prefix's automatic address was made or renewed with these
  lifetime ends: its temporary addresses follow (one is made if none is
  current). }
procedure UpdateTemporaryAddresses(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  PrefixValidUntil, PrefixPreferredUntil, Now: QWord);
{ On the timer, for a temporary address: makes its successor when it is
  about to be deprecated. }
procedure RunTemporaryAddressTimer(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Now: QWord);
{ The temporary address of Prefix was another host's (and is gone): a
  new one is made. }
procedure ReplaceDuplicateTemporaryAddress(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  Now: QWord);
{ Makes temporary addresses for the automatic ones (the option was
  turned on). }
procedure StartTemporaryAddresses(NetworkInterface: PNetworkInterface; Now: QWord);

implementation

uses
  Abi.SystemCalls,
  Network.Core,
  Network.Ipv6AddressList,
  Network.Ipv6Identifiers,
  Network.RandomNumbers;

const
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;
  { MAX_DESYNC_FACTOR: 0.4 of TEMP_PREFERRED_LIFETIME. }
  MaximumDesyncSeconds = (TemporaryPreferredSeconds div 10) * 4;

function Earlier(First, Second: QWord): QWord;
begin
  if First < Second then
    Result := First
  else
    Result := Second;
end;

function IsEnabled(NetworkInterface: PNetworkInterface): Boolean;
begin
  Result := (NetworkInterface^.Ipv6.Options and Ipv6OptionTemporaryAddresses) <> 0;
end;

function IsTemporaryOf(Entry: PIpv6InterfaceAddress; constref Prefix: TIpv6Address): Boolean;
begin
  Result := (Entry^.State <> Ipv6AddressFree) and (Entry^.Origin = Ipv6OriginTemporary) and
    SameIpv6Prefix(Entry^.Address, Prefix, 64);
end;

{ Makes room by dropping the deprecated temporary address that ends
  first; False if there is none. }
function DropOldestDeprecatedTemporary(NetworkInterface: PNetworkInterface): Boolean;
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  Oldest: PIpv6InterfaceAddress;
begin
  Oldest := nil;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State = Ipv6AddressDeprecated) and (Entry^.Origin = Ipv6OriginTemporary) and
       ((Oldest = nil) or (Entry^.ValidUntil < Oldest^.ValidUntil)) then
      Oldest := Entry;
  end;
  if Oldest = nil then
    Exit(False);
  RemoveIpv6AddressEntry(NetworkInterface, Oldest, 'removed (temporary, to make room)');
  Result := True;
end;

procedure CreateTemporaryAddress(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  PrefixValidUntil, PrefixPreferredUntil, Now: QWord);
var
  Desync: QWord;
  ValidLimit: QWord;
  PreferredLimit: QWord;
  PreferredUntil: QWord;
  Address: TIpv6Address;
  Error: LongInt;
  Entry: PIpv6InterfaceAddress;
begin
  Desync := NetworkRandomBelow(MaximumDesyncSeconds) * NanosecondsPerSecond;
  ValidLimit := Now + QWord(TemporaryValidSeconds) * NanosecondsPerSecond;
  PreferredLimit := Now + QWord(TemporaryPreferredSeconds) * NanosecondsPerSecond - Desync;
  PreferredUntil := Earlier(PrefixPreferredUntil, PreferredLimit);
  { Not worth making if it would be deprecated almost at once. }
  if PreferredUntil <= Now + QWord(RegenerateAdvanceSeconds) * NanosecondsPerSecond then
    Exit;
  Address := TemporaryAddressFor(Prefix);
  Error := AddIpv6Address(NetworkInterface, Address, 64, Ipv6OriginTemporary, Earlier(PrefixValidUntil, ValidLimit),
    PreferredUntil);
  if (Error = ErrorNoSpace) and DropOldestDeprecatedTemporary(NetworkInterface) then
    Error := AddIpv6Address(NetworkInterface, Address, 64, Ipv6OriginTemporary,
      Earlier(PrefixValidUntil, ValidLimit), PreferredUntil);
  if Error <> ErrorNone then
    Exit;
  Entry := FindIpv6Address(NetworkInterface, Address);
  if Entry = nil then
    Exit;
  Entry^.TemporaryValidLimit := ValidLimit;
  Entry^.TemporaryPreferredLimit := PreferredLimit;
  Entry^.HasSuccessor := False;
  RequestNetworkWakeAt(PreferredUntil - QWord(RegenerateAdvanceSeconds) * NanosecondsPerSecond);
end;

procedure UpdateTemporaryAddresses(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  PrefixValidUntil, PrefixPreferredUntil, Now: QWord);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  HasCurrent: Boolean;
begin
  if not IsEnabled(NetworkInterface) then
    Exit;
  HasCurrent := False;
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if not IsTemporaryOf(Entry, Prefix) then
      Continue;
    Entry^.ValidUntil := Earlier(PrefixValidUntil, Entry^.TemporaryValidLimit);
    Entry^.PreferredUntil := Earlier(PrefixPreferredUntil, Entry^.TemporaryPreferredLimit);
    if Entry^.ValidUntil <> Ipv6Forever then
      RequestNetworkWakeAt(Entry^.ValidUntil);
    if Entry^.HasSuccessor then
      Continue;
    if (Entry^.State = Ipv6AddressDeprecated) and (Entry^.PreferredUntil > Now) then
      Entry^.State := Ipv6AddressPreferred;
    if Entry^.State <> Ipv6AddressDeprecated then
      HasCurrent := True;
  end;
  if not HasCurrent and (PrefixValidUntil > Now) then
    CreateTemporaryAddress(NetworkInterface, Prefix, PrefixValidUntil, PrefixPreferredUntil, Now);
end;

{ The automatic address of the prefix (it gives the prefix's
  lifetimes); nil if there is none. }
function FindAutomaticAddressOf(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address): PIpv6InterfaceAddress;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Result := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Result^.State <> Ipv6AddressFree) and (Result^.Origin = Ipv6OriginAutomatic) and
       SameIpv6Prefix(Result^.Address, Prefix, 64) then
      Exit;
  end;
  Result := nil;
end;

procedure RunTemporaryAddressTimer(NetworkInterface: PNetworkInterface; Entry: PIpv6InterfaceAddress; Now: QWord);
var
  RegenerateAt: QWord;
  Automatic: PIpv6InterfaceAddress;
  Prefix: TIpv6Address;
begin
  if (Entry^.Origin <> Ipv6OriginTemporary) or (Entry^.State <> Ipv6AddressPreferred) or Entry^.HasSuccessor or
     (Entry^.PreferredUntil = Ipv6Forever) then
    Exit;
  RegenerateAt := Entry^.PreferredUntil - QWord(RegenerateAdvanceSeconds) * NanosecondsPerSecond;
  if RegenerateAt > Now then
  begin
    RequestNetworkWakeAt(RegenerateAt);
    Exit;
  end;
  Entry^.HasSuccessor := True;
  Prefix := Ipv6PrefixOf(Entry^.Address, 64);
  Automatic := FindAutomaticAddressOf(NetworkInterface, Prefix);
  if (Automatic = nil) or (Automatic^.State <> Ipv6AddressPreferred) or not IsEnabled(NetworkInterface) then
    Exit;
  CreateTemporaryAddress(NetworkInterface, Prefix, Automatic^.ValidUntil, Automatic^.PreferredUntil, Now);
end;

procedure ReplaceDuplicateTemporaryAddress(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  Now: QWord);
var
  Automatic: PIpv6InterfaceAddress;
begin
  Inc(NetworkInterface^.Ipv6.TemporaryRetries);
  if NetworkInterface^.Ipv6.TemporaryRetries > TemporaryIdentifierRetries then
    Exit;
  Automatic := FindAutomaticAddressOf(NetworkInterface, Prefix);
  if (Automatic = nil) or not IsEnabled(NetworkInterface) then
    Exit;
  CreateTemporaryAddress(NetworkInterface, Prefix, Automatic^.ValidUntil, Automatic^.PreferredUntil, Now);
end;

procedure StartTemporaryAddresses(NetworkInterface: PNetworkInterface; Now: QWord);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
begin
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State <> Ipv6AddressFree) and (Entry^.Origin = Ipv6OriginAutomatic) then
      UpdateTemporaryAddresses(NetworkInterface, Entry^.Address, Entry^.ValidUntil, Entry^.PreferredUntil, Now);
  end;
end;

end.
