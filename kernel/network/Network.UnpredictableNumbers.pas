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
  The network stack's secrets and the numbers made from them
  (Network.KeyedNumbers): TCP initial sequence numbers (RFC 6528), TCP
  timestamp offsets, dynamic port offsets (RFC 6056 algorithm 4) and
  IPv4 identifications (RFC 7739). Each use has its own SipHash key,
  taken from Kernel.Random the first time it is needed (the generator
  is seeded at boot, long before the first connection). Under the
  network lock.
}
unit Network.UnpredictableNumbers;

{$mode objfpc}

interface

uses
  Network.Addresses;

function InitialSequenceFor(constref Local, Remote: TNetworkEndpoint): LongWord;
function TimestampOffsetFor(constref Local, Remote: TNetworkEndpoint): LongWord;
{ Where the search for a dynamic port towards Remote starts, and the
  table counter it took (to be moved on with CountDynamicPortUse). }
procedure StartDynamicPortSearch(constref Local, Remote: TNetworkEndpoint; out Offset, Index, Counter: LongWord);
{ A search with no known peer: a random start (RFC 6056 algorithm 1). }
function RandomDynamicPortOffset: LongWord;
{ The search that started at Index took Attempts tries. }
procedure CountDynamicPortUse(Index, Attempts: LongWord);
function NextIpv4Identification(Source, Destination: TIpv4Address; Protocol: Byte): Word;

implementation

uses
  Abi.SystemCalls,
  Kernel.Random,
  Network.Core,
  Network.SipHash,
  Network.KeyedNumbers;

type
  TKeyUse = (KeySequence, KeyTimestamp, KeyPortOffset, KeyPortIndex, KeyIdentification,
    KeyIdentificationIndex);

var
  Keys: array[TKeyUse] of TSipHashKey;
  HaveKeys: Boolean;
  PortCounters: TPerturbationTable;
  IdentificationCounters: TPerturbationTable;

function Keyed(constref Endpoint: TNetworkEndpoint): TKeyedEndpoint;
begin
  if Endpoint.Family = AddressFamilyIPv6 then
    Result := KeyedIpv6Endpoint(Endpoint.Address6, Endpoint.Port)
  else
    Result := KeyedIpv4Endpoint(Endpoint.Address, Endpoint.Port);
end;

procedure EnsureKeys;
var
  Use: TKeyUse;
begin
  if HaveKeys then
    Exit;
  for Use := Low(TKeyUse) to High(TKeyUse) do
  begin
    Keys[Use].First := RandomQWord;
    Keys[Use].Second := RandomQWord;
  end;
  FillRandom(PByte(@PortCounters), SizeOf(PortCounters));
  FillRandom(PByte(@IdentificationCounters), SizeOf(IdentificationCounters));
  HaveKeys := True;
end;

function InitialSequenceFor(constref Local, Remote: TNetworkEndpoint): LongWord;
begin
  EnsureKeys;
  Result := KeyedInitialSequence(Keys[KeySequence], Keyed(Local), Keyed(Remote), NetworkNow);
end;

function TimestampOffsetFor(constref Local, Remote: TNetworkEndpoint): LongWord;
begin
  EnsureKeys;
  Result := KeyedTimestampOffset(Keys[KeyTimestamp], Keyed(Local), Keyed(Remote));
end;

procedure StartDynamicPortSearch(constref Local, Remote: TNetworkEndpoint; out Offset, Index, Counter: LongWord);
begin
  EnsureKeys;
  Offset := LongWord(HashEndpoints(Keys[KeyPortOffset], Keyed(Local), Keyed(Remote)));
  Index := PerturbationIndex(Keys[KeyPortIndex], Keyed(Local), Keyed(Remote));
  Counter := PortCounters.Counters[Index];
end;

function RandomDynamicPortOffset: LongWord;
begin
  Result := LongWord(RandomQWord);
end;

procedure CountDynamicPortUse(Index, Attempts: LongWord);
begin
  { As Linux does since 2022: a small random extra step, so that the
    counter does not tell how many ports were taken. }
  TakePerturbation(PortCounters, Index, Attempts + LongWord(RandomBelow(8)));
end;

function NextIpv4Identification(Source, Destination: TIpv4Address; Protocol: Byte): Word;
var
  Index: LongWord;
begin
  EnsureKeys;
  Index := Ipv4IdentificationIndex(Keys[KeyIdentificationIndex], Source, Destination, Protocol);
  Result := KeyedIpv4Identification(Keys[KeyIdentification], Source, Destination, Protocol,
    TakePerturbation(IdentificationCounters, Index, 1));
end;

end.
