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
  The keys of Initial packets (RFC 9001 section 5.2): both directions'
  secrets come from the Destination Connection ID of the client's first
  Initial packet (or the one a Retry gave), through HKDF-Extract with
  version 1's salt and HKDF-Expand-Label "client in" / "server in".
  Anyone can compute them: they protect against nothing but off-path
  injection and ossification.

  The Retry integrity tag (section 5.8) is AES-128-GCM with a fixed key
  and nonce over the Retry packet, with the client's original
  Destination Connection ID in front.
}
unit Quic.InitialSecrets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Quic.ConnectionIds,
  Quic.PacketProtection;

const
  InitialSalt: array[0..19] of Byte = (
    $38, $76, $2c, $f7, $f5, $59, $34, $b3, $4d, $17, $9a, $e6, $a4, $c8, $0c, $ad, $cc, $bb, $7f, $0a);
  RetryIntegrityKey: array[0..15] of Byte = (
    $be, $0c, $69, $0b, $9f, $66, $57, $5a, $1d, $76, $6b, $54, $e3, $68, $c8, $4e);
  RetryIntegrityNonce: array[0..11] of Byte = (
    $46, $15, $99, $d3, $5d, $63, $2b, $f2, $23, $98, $25, $bb);

type
  TQuicInitialSecret = array[0..31] of Byte;

procedure DeriveInitialSecrets(constref DestinationId: TQuicConnectionId; out ClientSecret,
  ServerSecret: TQuicInitialSecret);
{ The Initial packet keys of both directions for this Destination
  Connection ID. }
procedure DeriveInitialKeys(constref DestinationId: TQuicConnectionId; out ClientKeys, ServerKeys: TQuicPacketKeys);
{ The tag of a Retry packet of Length bytes (without its tag). }
procedure ComputeRetryIntegrityTag(constref OriginalDestinationId: TQuicConnectionId; Packet: PByte; Length: PtrUInt;
  Tag: PByte);
{ True when the last 16 bytes of the Retry packet are its tag. }
function RetryIntegrityTagIsValid(constref OriginalDestinationId: TQuicConnectionId; Packet: PByte;
  Length: PtrUInt): Boolean;

implementation

uses
  Crypto.AesGcm,
  Crypto.Bits,
  Crypto.Digests,
  Crypto.Hkdf,
  Tls.CipherSuites,
  Tls.KeySchedule;

procedure DeriveInitialSecrets(constref DestinationId: TQuicConnectionId; out ClientSecret,
  ServerSecret: TQuicInitialSecret);
var
  InitialSecret: TDigestOutput;
begin
  HkdfExtract(DigestSha256, @InitialSalt[0], SizeOf(InitialSalt), @DestinationId.Bytes[0], DestinationId.Length,
    InitialSecret);
  ExpandLabel(DigestSha256, @InitialSecret[0], 'client in', nil, 0, @ClientSecret[0], 32);
  ExpandLabel(DigestSha256, @InitialSecret[0], 'server in', nil, 0, @ServerSecret[0], 32);
  WipeMemory(@InitialSecret[0], SizeOf(InitialSecret));
end;

procedure DeriveInitialKeys(constref DestinationId: TQuicConnectionId; out ClientKeys, ServerKeys: TQuicPacketKeys);
var
  ClientSecret, ServerSecret: TQuicInitialSecret;
begin
  DeriveInitialSecrets(DestinationId, ClientSecret, ServerSecret);
  DerivePacketKeys(ClientKeys, AeadAes128Gcm, DigestSha256, @ClientSecret[0], 32);
  DerivePacketKeys(ServerKeys, AeadAes128Gcm, DigestSha256, @ServerSecret[0], 32);
  WipeMemory(@ClientSecret[0], 32);
  WipeMemory(@ServerSecret[0], 32);
end;

procedure ComputeRetryIntegrityTag(constref OriginalDestinationId: TQuicConnectionId; Packet: PByte; Length: PtrUInt;
  Tag: PByte);
var
  Key: TAesGcmKey;
  Pseudo: array of Byte;
begin
  Pseudo := nil;
  SetLength(Pseudo, 1 + OriginalDestinationId.Length + Length);
  Pseudo[0] := OriginalDestinationId.Length;
  if OriginalDestinationId.Length > 0 then
    Move(OriginalDestinationId.Bytes[0], Pseudo[1], OriginalDestinationId.Length);
  Move(Packet^, Pseudo[1 + OriginalDestinationId.Length], Length);
  PrepareAesGcmKey(Key, @RetryIntegrityKey[0], 16);
  SealAesGcm(Key, @RetryIntegrityNonce[0], @Pseudo[0], System.Length(Pseudo), nil, 0, nil, Tag);
end;

function RetryIntegrityTagIsValid(constref OriginalDestinationId: TQuicConnectionId; Packet: PByte;
  Length: PtrUInt): Boolean;
var
  Expected: array[0..15] of Byte;
begin
  if Length < 16 then
    Exit(False);
  ComputeRetryIntegrityTag(OriginalDestinationId, Packet, Length - 16, @Expected[0]);
  Result := ConstantTimeEqual(@Expected[0], Packet + Length - 16, 16);
end;

end.
