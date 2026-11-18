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
  libssh against known answers: the data types (RFC 4251's mpint
  examples), base64, name-list negotiation, and the vectors that
  make-vectors.py works out with Python and OpenSSL
  (SshTest.Vectors.inc): sealed and opened packets of both ciphers, the
  curve25519-sha256 exchange hash and derived keys, host key blobs and
  signatures, OpenSSH private key files, RSA signatures and
  authorized_keys lines.
}
unit SshTest.KnownAnswers;

{$mode objfpc}
{$H+}

interface

procedure TestWireEncoding;
procedure TestCipherVectors;
procedure TestKeyExchangeVectors;
procedure TestHostKeyVectors;
procedure TestPublicKeyVectors;

implementation

uses
  SysUtils,
  TestChecks,
  SshTest.Helpers,
  Ssh.Wire,
  Ssh.Base64,
  Ssh.Algorithms,
  Ssh.PacketCiphers,
  Ssh.ChaChaPolyCipher,
  Ssh.AesGcmCipher,
  Ssh.KeyExchange,
  Ssh.HostKeys,
  Ssh.KeyFiles,
  Ssh.PublicKeys;

{$i SshTest.Vectors.inc}

procedure TestWireEncoding;
var
  Reader: TSshReader;
  Decoded: string;
  Names: TStringArray;
  Raised: Boolean;
begin
  CheckEqual(SshMpint(''), FromHex('00000000'), 'mpint 0');
  CheckEqual(SshMpint(FromHex('09a378f9b2e332a7')), FromHex('0000000809a378f9b2e332a7'), 'mpint 9a378f9b2e332a7');
  CheckEqual(SshMpint(FromHex('80')), FromHex('000000020080'), 'mpint 80 (a zero byte in front)');
  CheckEqual(SshMpint(FromHex('000000ff')), FromHex('0000000200ff'), 'mpint leading zeros dropped');
  CheckEqual(SshUInt64(QWord($0102030405060708)), FromHex('0102030405060708'), 'uint64');
  CheckEqual(SshNameList(['zlib', 'none']), FromHex('000000097a6c69622c6e6f6e65'), 'name-list');

  Reader.Start(FromHex('0000000809a378f9b2e332a7') + FromHex('01') + FromHex('00000003616263'));
  CheckEqual(Reader.ReadMpint, FromHex('09a378f9b2e332a7'), 'mpint read back');
  Check(Reader.ReadBoolean, 'boolean read');
  CheckEqual(Reader.ReadString, 'abc', 'string read');
  Check(Reader.AtEnd, 'reader at the end');
  Raised := False;
  try
    Reader.ReadUInt32;
  except
    on ESshProtocolError do
      Raised := True;
  end;
  Check(Raised, 'reading past the end raises');
  Reader.Start(FromHex('0000000180'));
  Raised := False;
  try
    Reader.ReadMpint;
  except
    on ESshProtocolError do
      Raised := True;
  end;
  Check(Raised, 'a negative mpint is refused');
  Reader.Start(FromHex('ffffffff00'));
  Raised := False;
  try
    Reader.ReadString;
  except
    on ESshProtocolError do
      Raised := True;
  end;
  Check(Raised, 'a string longer than the message is refused');

  Check(EncodeBase64('foobar') = 'Zm9vYmFy', 'base64 foobar');
  Check(EncodeBase64('fooba') = 'Zm9vYmE=', 'base64 fooba');
  Check(EncodeBase64('foob') = 'Zm9vYg==', 'base64 foob');
  Check(DecodeBase64('Zm9v' + #10 + 'YmE=', Decoded) and (Decoded = 'fooba'), 'base64 decoded across lines');
  Check(not DecodeBase64('Zm9v!', Decoded), 'base64 with a wrong character refused');

  Names := SplitNameList('curve25519-sha256,ext-info-c,kex-strict-c-v00@openssh.com');
  Check(Length(Names) = 3, 'name-list split');
  Check(FirstCommonName(Names, ['curve25519-sha256@libssh.org', 'curve25519-sha256']) = 'curve25519-sha256',
    'negotiation takes the client''s first choice the server has');
  Check(FirstCommonName(Names, ['diffie-hellman-group14-sha256']) = '', 'negotiation without anything in common');
end;

procedure TestCipherVectors;
var
  ChaCha: TSshChaChaPolyCipher;
  Sender, Receiver: TSshAesGcmCipher;
  Wire, Body: string;
  PacketLength: LongWord;
begin
  ChaCha := TSshChaChaPolyCipher.Create(FromHex(ChaChaKey));
  try
    Wire := ChaCha.Seal(ChaChaSequence, FromHex(ChaChaPacket));
    CheckEqual(Wire, FromHex(ChaChaWire), 'chacha20-poly1305@openssh.com: sealed packet');
    PacketLength := ChaCha.DecryptLength(ChaChaSequence, Copy(FromHex(ChaChaWire), 1, 4));
    Check(PacketLength = LongWord(Length(FromHex(ChaChaPacket)) - 4), 'chacha20-poly1305: length decrypted');
    Check(ChaCha.Open(ChaChaSequence, FromHex(ChaChaWire), PacketLength, Body), 'chacha20-poly1305: opened');
    CheckEqual(Body, Copy(FromHex(ChaChaPacket), 5, MaxInt), 'chacha20-poly1305: body');
    Check(not ChaCha.Open(ChaChaSequence + 1, FromHex(ChaChaWire), PacketLength, Body),
      'chacha20-poly1305: a wrong sequence number fails the tag');
  finally
    ChaCha.Free;
  end;

  Sender := TSshAesGcmCipher.Create(FromHex(GcmKey), FromHex(GcmInitialValue));
  Receiver := TSshAesGcmCipher.Create(FromHex(GcmKey), FromHex(GcmInitialValue));
  try
    CheckEqual(Sender.Seal(0, FromHex(GcmPacket1)), FromHex(GcmWire1), 'aes256-gcm: first packet');
    CheckEqual(Sender.Seal(1, FromHex(GcmPacket2)), FromHex(GcmWire2),
      'aes256-gcm: second packet (invocation counter advanced)');
    Check(Receiver.Open(0, FromHex(GcmWire1), Length(FromHex(GcmPacket1)) - 4, Body) and
      (Body = Copy(FromHex(GcmPacket1), 5, MaxInt)), 'aes256-gcm: first packet opened');
    Wire := FromHex(GcmWire2);
    Wire[3] := Chr(Ord(Wire[3]) xor 1);
    Check(not Receiver.Open(1, Wire, Length(FromHex(GcmPacket2)) - 4, Body),
      'aes256-gcm: a changed length (additional data) fails the tag');
    Check(Receiver.Open(1, FromHex(GcmWire2), Length(FromHex(GcmPacket2)) - 4, Body) and
      (Body = Copy(FromHex(GcmPacket2), 5, MaxInt)), 'aes256-gcm: second packet opened');
  finally
    Sender.Free;
    Receiver.Free;
  end;
end;

procedure TestKeyExchangeVectors;
var
  Ephemeral: TSshEphemeralKey;
  Shared, Hash: string;
begin
  Ephemeral.PrivateKey := FromHex(ServerPrivate);
  Ephemeral.PublicKey := FromHex(ServerPublic);
  Check(ComputeSharedSecret(Ephemeral, FromHex(ClientPublic), Shared), 'curve25519: shared secret made');
  CheckEqual(Shared, FromHex(SharedSecret), 'curve25519: shared secret');
  Check(not ComputeSharedSecret(Ephemeral, StringOfChar(#0, 32), Shared),
    'curve25519: a small order client key refused');
  Hash := ComputeExchangeHash(ClientVersion, ServerVersion, FromHex(ClientInit), FromHex(ServerInit),
    FromHex(Ed25519Blob), FromHex(ClientPublic), FromHex(ServerPublic), FromHex(SharedSecret));
  CheckEqual(Hash, FromHex(ExchangeHash), 'curve25519-sha256: exchange hash H');
  CheckEqual(DeriveKey(FromHex(SharedSecret), Hash, Hash, 'A', 64), FromHex(DerivedKeyA), 'key derivation A (64 bytes)');
  CheckEqual(DeriveKey(FromHex(SharedSecret), Hash, Hash, 'B', 12), Copy(FromHex(DerivedKeyB), 1, 12),
    'key derivation B (12 bytes)');
  CheckEqual(DeriveKey(FromHex(SharedSecret), Hash, Hash, 'C', 32), Copy(FromHex(DerivedKeyC), 1, 32),
    'key derivation C (32 bytes)');
  CheckEqual(DeriveKey(FromHex(SharedSecret), Hash, Hash, 'D', 64), FromHex(DerivedKeyD), 'key derivation D (64 bytes)');
end;

procedure TestHostKeyVectors;
var
  Ed25519Key: TSshEd25519HostKey;
  EcdsaKey: TSshEcdsaP256HostKey;
  Loaded: TSshHostKey;
  Key: TSshPublicKey;
  Generated: TSshHostKey;
  Text: string;
begin
  Ed25519Key := TSshEd25519HostKey.Create(FromHex(Ed25519Seed));
  try
    CheckEqual(Ed25519Key.PublicBlob, FromHex(Ed25519Blob), 'ssh-ed25519 host key blob');
    CheckEqual(Ed25519Key.Sign(FromHex(ExchangeHash)), FromHex(Ed25519SignatureOfHash),
      'ssh-ed25519 signature of H');
    Check(ParsePublicKeyBlob(Ed25519Key.PublicBlob, Key) and
      VerifySshSignature(Key, 'ssh-ed25519', FromHex(ExchangeHash), Ed25519Key.Sign(FromHex(ExchangeHash))),
      'ssh-ed25519 signature verified');
    Text := EncodePrivateKeyFile(Ed25519Key, 'test');
    Loaded := DecodePrivateKeyFile(Text);
    Check((Loaded <> nil) and (Loaded.PublicBlob = Ed25519Key.PublicBlob), 'ssh-ed25519 key file written and read');
    Loaded.Free;
  finally
    Ed25519Key.Free;
  end;

  EcdsaKey := TSshEcdsaP256HostKey.Create(FromHex(EcdsaPrivate));
  try
    CheckEqual(EcdsaKey.PublicBlob, FromHex(EcdsaBlob), 'ecdsa-sha2-nistp256 host key blob');
    CheckEqual(EcdsaKey.Sign(FromHex(SignedData)), FromHex(EcdsaSignature),
      'ecdsa-sha2-nistp256 signature (RFC 6979)');
    Check(ParsePublicKeyBlob(EcdsaKey.PublicBlob, Key) and
      VerifySshSignature(Key, 'ecdsa-sha2-nistp256', FromHex(SignedData), FromHex(EcdsaSignature)),
      'ecdsa-sha2-nistp256 signature verified');
    Check(not VerifySshSignature(Key, 'ecdsa-sha2-nistp256', 'other data', FromHex(EcdsaSignature)),
      'ecdsa-sha2-nistp256 signature of other data refused');
    Text := EncodePrivateKeyFile(EcdsaKey, 'test');
    Loaded := DecodePrivateKeyFile(Text);
    Check((Loaded <> nil) and (Loaded.PublicBlob = EcdsaKey.PublicBlob), 'ecdsa key file written and read');
    Loaded.Free;
  finally
    EcdsaKey.Free;
  end;

  Loaded := DecodePrivateKeyFile(FromHex(Ed25519KeyFile));
  Check((Loaded <> nil) and (Loaded.PublicBlob = FromHex(Ed25519Blob)), 'an OpenSSH ed25519 key file read');
  Loaded.Free;
  Loaded := DecodePrivateKeyFile(FromHex(EcdsaKeyFile));
  Check((Loaded <> nil) and (Loaded.PublicBlob = FromHex(EcdsaBlob)), 'an OpenSSH ecdsa key file read');
  Loaded.Free;
  Check(DecodePrivateKeyFile('not a key') = nil, 'not a key file: nothing read');

  Generated := TSshEd25519HostKey.Generate;
  Check(ParsePublicKeyBlob(Generated.PublicBlob, Key) and
    VerifySshSignature(Key, 'ssh-ed25519', 'x', Generated.Sign('x')), 'a generated ed25519 key signs');
  Generated.Free;
  Generated := TSshEcdsaP256HostKey.Generate;
  Check(ParsePublicKeyBlob(Generated.PublicBlob, Key) and
    VerifySshSignature(Key, 'ecdsa-sha2-nistp256', 'x', Generated.Sign('x')), 'a generated ecdsa key signs');
  Generated.Free;
end;

procedure TestPublicKeyVectors;
var
  Key: TSshPublicKey;
  Blob: string;
  HasOptions: Boolean;
  Changed: string;
begin
  Check(ParsePublicKeyBlob(FromHex(RsaBlob), Key) and (Key.Kind = PublicKeyKindRsa), 'ssh-rsa key read');
  Check(VerifySshSignature(Key, 'rsa-sha2-256', FromHex(SignedData), FromHex(RsaSignatureSha256)),
    'rsa-sha2-256 signature verified');
  Check(VerifySshSignature(Key, 'rsa-sha2-512', FromHex(SignedData), FromHex(RsaSignatureSha512)),
    'rsa-sha2-512 signature verified');
  Check(not VerifySshSignature(Key, 'rsa-sha2-512', FromHex(SignedData), FromHex(RsaSignatureSha256)),
    'an rsa-sha2-256 signature named rsa-sha2-512 refused');
  Check(not SignatureAlgorithmFits(Key, 'ssh-rsa'), 'SHA-1 ssh-rsa signatures not taken');
  Changed := FromHex(RsaSignatureSha256);
  Changed[Length(Changed)] := Chr(Ord(Changed[Length(Changed)]) xor 1);
  Check(not VerifySshSignature(Key, 'rsa-sha2-256', FromHex(SignedData), Changed), 'a changed RSA signature refused');

  Check(ParseAuthorizedKeyLine(AuthorizedLine, Blob, HasOptions) and not HasOptions, 'authorized_keys line read');
  CheckEqual(Blob, FromHex(AuthorizedBlob), 'authorized_keys line: the key');
  Check(ParseAuthorizedKeyLine(AuthorizedLineWithOptions, Blob, HasOptions) and HasOptions and
    (Blob = FromHex(AuthorizedBlob)), 'authorized_keys line with options: the key and its options seen');
  Check(not ParseAuthorizedKeyLine('# ssh-ed25519 AAAA', Blob, HasOptions), 'authorized_keys comment skipped');
  Check(not ParseAuthorizedKeyLine('', Blob, HasOptions), 'authorized_keys blank line skipped');
  Check(PublicKeyFingerprint(FromHex(AuthorizedBlob)) = AuthorizedFingerprint, 'SHA256 fingerprint');
  Check(PublicKeyLine(FromHex(AuthorizedBlob), 'user@laptop') = AuthorizedLine, 'OpenSSH public key line');
end;

end.
