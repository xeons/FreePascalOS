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
  SipHash-2-4 (Aumasson and Bernstein, 2012): a keyed hash of a short
  message into 64 bits, fast and, for a secret key, unpredictable. The
  network stack derives from it what an attacker must not guess (RFC
  6528's initial sequence numbers, RFC 6056's port offsets, IPv4
  identifications, TCP timestamp offsets); the key comes from
  Kernel.Random. Pure: the host test checks it against the reference
  vectors.
}
unit Network.SipHash;

{$mode objfpc}
{$pointermath on}
{$rangechecks off}
{$overflowchecks off}

interface

type
  TSipHashKey = record
    First: QWord;
    Second: QWord;
  end;

{ The hash of Length bytes at Message under Key. }
function SipHash24(constref Key: TSipHashKey; Message: PByte; Length: LongWord): QWord;
{ A key from its 16 bytes as the reference reads them (little-endian). }
function SipHashKeyFromBytes(Bytes: PByte): TSipHashKey;

implementation

function RotateLeft(Value: QWord; Count: Integer): QWord; inline;
begin
  Result := (Value shl Count) or (Value shr (64 - Count));
end;

function ReadLittleEndian64(Source: PByte): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 7 downto 0 do
    Result := (Result shl 8) or Source[Index];
end;

type
  TSipState = record
    V0, V1, V2, V3: QWord;
  end;

procedure SipRound(var State: TSipState);
begin
  State.V0 := State.V0 + State.V1;
  State.V1 := RotateLeft(State.V1, 13);
  State.V1 := State.V1 xor State.V0;
  State.V0 := RotateLeft(State.V0, 32);
  State.V2 := State.V2 + State.V3;
  State.V3 := RotateLeft(State.V3, 16);
  State.V3 := State.V3 xor State.V2;
  State.V0 := State.V0 + State.V3;
  State.V3 := RotateLeft(State.V3, 21);
  State.V3 := State.V3 xor State.V0;
  State.V2 := State.V2 + State.V1;
  State.V1 := RotateLeft(State.V1, 17);
  State.V1 := State.V1 xor State.V2;
  State.V2 := RotateLeft(State.V2, 32);
end;

procedure Compress(var State: TSipState; Word64: QWord);
begin
  State.V3 := State.V3 xor Word64;
  SipRound(State);
  SipRound(State);
  State.V0 := State.V0 xor Word64;
end;

function SipHash24(constref Key: TSipHashKey; Message: PByte; Length: LongWord): QWord;
var
  State: TSipState;
  Position: LongWord;
  Last: QWord;
  Index: LongWord;
begin
  State.V0 := Key.First xor QWord($736F6D6570736575);
  State.V1 := Key.Second xor QWord($646F72616E646F6D);
  State.V2 := Key.First xor QWord($6C7967656E657261);
  State.V3 := Key.Second xor QWord($7465646279746573);
  Position := 0;
  while Position + 8 <= Length do
  begin
    Compress(State, ReadLittleEndian64(Message + Position));
    Position := Position + 8;
  end;
  { The last block: what is left, and the length in its top byte. }
  Last := QWord(Length and $FF) shl 56;
  Index := 0;
  while Position + Index < Length do
  begin
    Last := Last or (QWord(Message[Position + Index]) shl (8 * Index));
    Inc(Index);
  end;
  Compress(State, Last);
  State.V2 := State.V2 xor $FF;
  SipRound(State);
  SipRound(State);
  SipRound(State);
  SipRound(State);
  Result := State.V0 xor State.V1 xor State.V2 xor State.V3;
end;

function SipHashKeyFromBytes(Bytes: PByte): TSipHashKey;
begin
  Result.First := ReadLittleEndian64(Bytes);
  Result.Second := ReadLittleEndian64(Bytes + 8);
end;

end.
