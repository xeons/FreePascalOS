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
  Numbers an off-path attacker must not guess, derived from a secret
  key with SipHash (Network.SipHash), for the kernel's network stack
  (Network.UnpredictableNumbers holds the keys):

    * TCP initial sequence numbers (RFC 6528): a 4-microsecond clock
      plus a keyed hash of the connection's four endpoints, so that
      numbers of one connection say nothing about another's and
      successive incarnations of one connection still move forward;
    * TCP timestamp offsets (RFC 7323 7.1): a keyed hash of the
      endpoints added to every TSval of the connection;
    * dynamic ports (RFC 6056 algorithm 4, "double-hash"): an offset
      hashed from the endpoints plus a counter picked from a small
      table by a second hash, so that the ports used towards one peer
      say nothing about those used towards another;
    * IPv4 identifications (RFC 7739 5.3): the same double hash over
      source, destination and protocol.

  Pure: the host test builds it.
}
unit Network.KeyedNumbers;

{$mode objfpc}
{$pointermath on}
{$rangechecks off}
{$overflowchecks off}

interface

uses
  Network.SipHash;

const
  { Counters of the double hash (RFC 6056 suggests a few hundred). }
  PerturbationTableLength = 256;
  { RFC 6528: the clock advances every 4 microseconds. }
  SequenceClockNanoseconds = 4000;

type
  { An endpoint as the hashes see it: the port and the address's bytes
    (an IPv4 address in the first four, the rest zero). }
  TKeyedEndpoint = record
    IsIpv6: Boolean;
    Port: Word;
    Address: array[0..15] of Byte;
  end;

  TPerturbationTable = record
    Counters: array[0..PerturbationTableLength - 1] of LongWord;
  end;

function KeyedIpv4Endpoint(Address: LongWord; Port: Word): TKeyedEndpoint;
function KeyedIpv6Endpoint(constref Address: array of Byte; Port: Word): TKeyedEndpoint;
{ A keyed hash of two endpoints (family, ports and addresses). }
function HashEndpoints(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): QWord;
{ RFC 6528: ISN = M + F(local, remote, secret). }
function KeyedInitialSequence(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint;
  ClockNanoseconds: QWord): LongWord;
{ The offset every TSval of the connection carries. }
function KeyedTimestampOffset(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): LongWord;
{ The table counter (0 .. PerturbationTableLength - 1) the double hash
  uses for the endpoints. }
function PerturbationIndex(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): LongWord;
{ The counter at Index, which then moves on by Step (at least 1). }
function TakePerturbation(var Table: TPerturbationTable; Index, Step: LongWord): LongWord;
{ The Attempt-th candidate (from 0) of the range First..Last for an
  Offset and a counter value. }
function DynamicPortCandidate(Offset, Counter, Attempt: LongWord; First, Last: Word): Word;
{ RFC 7739 5.3: an identification from the hashes of source,
  destination and protocol and the counter taken for them. }
function KeyedIpv4Identification(constref OffsetKey: TSipHashKey; Source, Destination: LongWord;
  Protocol: Byte; Counter: LongWord): Word;
{ The counter index for an IPv4 identification. }
function Ipv4IdentificationIndex(constref IndexKey: TSipHashKey; Source, Destination: LongWord;
  Protocol: Byte): LongWord;

implementation

const
  { Family, two ports, two addresses of up to 16 bytes. }
  EndpointBytes = 2 + 2 + 2 + 16 + 16;

procedure WriteBigEndian32(Target: PByte; Value: LongWord);
begin
  Target[0] := Byte(Value shr 24);
  Target[1] := Byte(Value shr 16);
  Target[2] := Byte(Value shr 8);
  Target[3] := Byte(Value);
end;

procedure ClearAddress(var Endpoint: TKeyedEndpoint);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    Endpoint.Address[Index] := 0;
end;

function KeyedIpv4Endpoint(Address: LongWord; Port: Word): TKeyedEndpoint;
begin
  ClearAddress(Result);
  Result.IsIpv6 := False;
  Result.Port := Port;
  WriteBigEndian32(@Result.Address[0], Address);
end;

function KeyedIpv6Endpoint(constref Address: array of Byte; Port: Word): TKeyedEndpoint;
var
  Index: Integer;
begin
  ClearAddress(Result);
  Result.IsIpv6 := True;
  Result.Port := Port;
  for Index := 0 to 15 do
    if Index <= High(Address) then
      Result.Address[Index] := Address[Index];
end;

procedure WriteEndpoint(Target: PByte; constref Endpoint: TKeyedEndpoint);
var
  Index: Integer;
begin
  Target[0] := Byte(Endpoint.Port shr 8);
  Target[1] := Byte(Endpoint.Port);
  for Index := 0 to 15 do
    Target[2 + Index] := Endpoint.Address[Index];
end;

function HashEndpoints(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): QWord;
var
  Message: array[0..EndpointBytes - 1] of Byte;
begin
  Message[0] := 0;
  Message[1] := Ord(Local.IsIpv6);
  WriteEndpoint(@Message[2], Local);
  WriteEndpoint(@Message[2 + 18], Remote);
  Result := SipHash24(Key, @Message[0], 2 + 18 + 18);
end;

function KeyedInitialSequence(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint;
  ClockNanoseconds: QWord): LongWord;
begin
  Result := LongWord(ClockNanoseconds div SequenceClockNanoseconds) + LongWord(HashEndpoints(Key, Local, Remote));
end;

function KeyedTimestampOffset(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): LongWord;
begin
  Result := LongWord(HashEndpoints(Key, Local, Remote) shr 32);
end;

function PerturbationIndex(constref Key: TSipHashKey; constref Local, Remote: TKeyedEndpoint): LongWord;
begin
  Result := LongWord(HashEndpoints(Key, Local, Remote) mod PerturbationTableLength);
end;

function TakePerturbation(var Table: TPerturbationTable; Index, Step: LongWord): LongWord;
begin
  Index := Index mod PerturbationTableLength;
  if Step = 0 then
    Step := 1;
  Result := Table.Counters[Index];
  Table.Counters[Index] := Table.Counters[Index] + Step;
end;

function DynamicPortCandidate(Offset, Counter, Attempt: LongWord; First, Last: Word): Word;
var
  Count: QWord;
begin
  Count := QWord(Last) - First + 1;
  Result := Word(First + (QWord(LongWord(Offset + Counter + Attempt)) mod Count));
end;

function HashIpv4Triple(constref Key: TSipHashKey; Source, Destination: LongWord; Protocol: Byte): QWord;
var
  Message: array[0..8] of Byte;
begin
  WriteBigEndian32(@Message[0], Source);
  WriteBigEndian32(@Message[4], Destination);
  Message[8] := Protocol;
  Result := SipHash24(Key, @Message[0], 9);
end;

function KeyedIpv4Identification(constref OffsetKey: TSipHashKey; Source, Destination: LongWord;
  Protocol: Byte; Counter: LongWord): Word;
begin
  Result := Word(LongWord(HashIpv4Triple(OffsetKey, Source, Destination, Protocol)) + Counter);
end;

function Ipv4IdentificationIndex(constref IndexKey: TSipHashKey; Source, Destination: LongWord;
  Protocol: Byte): LongWord;
begin
  Result := LongWord(HashIpv4Triple(IndexKey, Source, Destination, Protocol) mod PerturbationTableLength);
end;

end.
