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
  The client's side of a key exchange in one named group: a fresh key
  pair whose public half goes to the server (key_share in TLS 1.3,
  ClientKeyExchange in TLS 1.2), and the shared secret once the
  server's half is in.

    x25519           32-byte keys; the secret is X25519 (RFC 7748), an
                     all-zero result refused (RFC 8446 section 7.4.2)
    secp256r1/384r1  uncompressed points (65 or 97 bytes); the secret is
                     the x coordinate (RFC 8446 section 7.4.2)
    X25519MLKEM768   the client sends an ML-KEM-768 encapsulation key
                     and an X25519 key (1184 + 32 bytes), the server an
                     ML-KEM ciphertext and its X25519 key (1088 + 32);
                     the secret is the ML-KEM secret then the X25519
                     one (draft-ietf-tls-ecdhe-mlkem). TLS 1.3 only.

  The default groups, in order of preference: x25519, X25519MLKEM768,
  secp256r1, secp384r1, secp521r1 (TLS 1.2 servers with a P-521
  certificate want its curve listed). Private keys are wiped when the
  share is.
}
unit Tls.KeyShares;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.MlKem;

const
  MaximumGroups = 8;
  MaximumKeySharePublicLength = MlKem768EncapsulationKeyLength + 32;
  MaximumSharedSecretLength = MlKemSharedSecretLength + 32;

type
  TTlsGroupList = record
    Count: Integer;
    Groups: array[0..MaximumGroups - 1] of Word;
  end;

  TTlsKeyShare = record
    Group: Word;
    PublicKey: array[0..MaximumKeySharePublicLength - 1] of Byte;
    PublicLength: Integer;
    { x25519 / NIST curve private key, or the X25519 key of the hybrid. }
    PrivateKey: array[0..65] of Byte;
    PrivateLength: Integer;
    { The hybrid's ML-KEM decapsulation key. }
    DecapsulationKey: array[0..MlKem768DecapsulationKeyLength - 1] of Byte;
  end;

procedure DefaultGroups(out List: TTlsGroupList);
function GroupIsSupported(Group: Word): Boolean;
{ Whether TLS 1.2's ECDHE can use the group (not the hybrid). }
function GroupWorksWithTls12(Group: Word): Boolean;
function GroupListContains(constref List: TTlsGroupList; Group: Word): Boolean;
function GroupName(Group: Word): string;

{ A new key pair in Group; False for a group this library does not
  know. }
function MakeKeyShare(Group: Word; out Share: TTlsKeyShare): Boolean;
{ The shared secret from the server's share. TlsErrorNone, or
  TlsErrorIllegalParameter for a share that is malformed or gives a
  degenerate secret. }
function CompleteKeyShare(var Share: TTlsKeyShare; Peer: PByte; PeerLength: PtrUInt; Secret: PByte;
  out SecretLength: Integer): LongInt;
procedure WipeKeyShare(var Share: TTlsKeyShare);

implementation

uses
  Crypto.Bits,
  Crypto.Ecdh,
  Crypto.EllipticCurves,
  Crypto.KeyGeneration,
  Crypto.Random,
  Crypto.X25519,
  Tls.Constants,
  Tls.Errors;

procedure DefaultGroups(out List: TTlsGroupList);
begin
  FillChar(List, SizeOf(List), 0);
  List.Groups[0] := GroupX25519;
  List.Groups[1] := GroupX25519MlKem768;
  List.Groups[2] := GroupSecp256r1;
  List.Groups[3] := GroupSecp384r1;
  List.Groups[4] := GroupSecp521r1;
  List.Count := 5;
end;

function GroupIsSupported(Group: Word): Boolean;
begin
  Result := (Group = GroupX25519) or (Group = GroupX25519MlKem768) or (Group = GroupSecp256r1) or
    (Group = GroupSecp384r1) or (Group = GroupSecp521r1);
end;

function GroupWorksWithTls12(Group: Word): Boolean;
begin
  Result := GroupIsSupported(Group) and (Group <> GroupX25519MlKem768);
end;

function GroupListContains(constref List: TTlsGroupList; Group: Word): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to List.Count - 1 do
    if List.Groups[Index] = Group then
      Exit(True);
  Result := False;
end;

function GroupName(Group: Word): string;
begin
  case Group of
    GroupX25519: Result := 'x25519';
    GroupX25519MlKem768: Result := 'X25519MLKEM768';
    GroupSecp256r1: Result := 'secp256r1';
    GroupSecp384r1: Result := 'secp384r1';
    GroupSecp521r1: Result := 'secp521r1';
  else
    Result := 'unknown';
  end;
end;

function CurveOfGroup(Group: Word): TCurveName;
begin
  case Group of
    GroupSecp256r1: Result := CurveP256;
    GroupSecp384r1: Result := CurveP384;
  else
    Result := CurveP521;
  end;
end;

procedure MakeX25519(var Share: TTlsKeyShare; PublicKey: PByte);
begin
  RandomBytes(@Share.PrivateKey[0], 32);
  Share.PrivateLength := 32;
  X25519PublicKey(@Share.PrivateKey[0], PublicKey);
end;

function MakeKeyShare(Group: Word; out Share: TTlsKeyShare): Boolean;
var
  Seed: array[0..MlKemKeySeedLength - 1] of Byte;
  Curve: TCurveName;
begin
  FillChar(Share, SizeOf(Share), 0);
  Share.Group := Group;
  Result := True;
  case Group of
    GroupX25519:
      begin
        MakeX25519(Share, @Share.PublicKey[0]);
        Share.PublicLength := 32;
      end;
    GroupSecp256r1, GroupSecp384r1, GroupSecp521r1:
      begin
        Curve := CurveOfGroup(Group);
        GenerateEcdsaPrivateKey(Curve, @Share.PrivateKey[0]);
        Share.PrivateLength := EcdhSharedSecretLength(Curve);
        Result := EcdhPublicKey(Curve, @Share.PrivateKey[0], Share.PrivateLength, @Share.PublicKey[0]);
        Share.PublicLength := EcdhPublicKeyLength(Curve);
      end;
    GroupX25519MlKem768:
      begin
        RandomBytes(@Seed[0], SizeOf(Seed));
        MlKem768KeyPairFromSeed(@Seed[0], @Share.PublicKey[0], @Share.DecapsulationKey[0]);
        WipeMemory(@Seed[0], SizeOf(Seed));
        MakeX25519(Share, @Share.PublicKey[MlKem768EncapsulationKeyLength]);
        Share.PublicLength := MlKem768EncapsulationKeyLength + 32;
      end;
  else
    Result := False;
  end;
  if not Result then
    WipeKeyShare(Share);
end;

function AllZero(Bytes: PByte; Count: Integer): Boolean;
var
  Index: Integer;
  Accumulated: Byte;
begin
  Accumulated := 0;
  for Index := 0 to Count - 1 do
    Accumulated := Accumulated or Bytes[Index];
  Result := Accumulated = 0;
end;

function CompleteKeyShare(var Share: TTlsKeyShare; Peer: PByte; PeerLength: PtrUInt; Secret: PByte;
  out SecretLength: Integer): LongInt;
var
  Curve: TCurveName;
begin
  SecretLength := 0;
  Result := TlsErrorIllegalParameter;
  case Share.Group of
    GroupX25519:
      begin
        if PeerLength <> 32 then
          Exit;
        if not X25519SharedSecret(@Share.PrivateKey[0], Peer, Secret) or AllZero(Secret, 32) then
          Exit;
        SecretLength := 32;
      end;
    GroupSecp256r1, GroupSecp384r1, GroupSecp521r1:
      begin
        Curve := CurveOfGroup(Share.Group);
        if not EcdhSharedSecret(Curve, @Share.PrivateKey[0], Share.PrivateLength, Peer, PeerLength, Secret) then
          Exit;
        SecretLength := EcdhSharedSecretLength(Curve);
      end;
    GroupX25519MlKem768:
      begin
        if PeerLength <> MlKem768CiphertextLength + 32 then
          Exit;
        MlKem768Decapsulate(@Share.DecapsulationKey[0], Peer, Secret);
        if not X25519SharedSecret(@Share.PrivateKey[0], Peer + MlKem768CiphertextLength,
          Secret + MlKemSharedSecretLength) or AllZero(Secret + MlKemSharedSecretLength, 32) then
        begin
          WipeMemory(Secret, MaximumSharedSecretLength);
          Exit;
        end;
        SecretLength := MlKemSharedSecretLength + 32;
      end;
  else
    Exit(TlsErrorInternal);
  end;
  Result := TlsErrorNone;
end;

procedure WipeKeyShare(var Share: TTlsKeyShare);
begin
  WipeMemory(@Share, SizeOf(Share));
end;

end.
