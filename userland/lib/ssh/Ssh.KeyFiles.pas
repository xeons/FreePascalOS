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
  Private key files in OpenSSH's format (PROTOCOL.key), unencrypted,
  so host keys can be read by ssh-keygen and others:

    -----BEGIN OPENSSH PRIVATE KEY-----
    base64 of:
      "openssh-key-v1" 0, string "none" (cipher), string "none" (kdf),
      string "" (kdf options), uint32 1 (keys), string public key blob,
      string private section:
        uint32 check, uint32 check (the same random number),
        string key type, the key's private fields, string comment,
        padding 1, 2, 3 ... to a multiple of 8
    -----END OPENSSH PRIVATE KEY-----

  Only text is made and read here; the caller writes the file (mode
  0600) and reads it.
}
unit Ssh.KeyFiles;

{$mode objfpc}{$H+}

interface

uses
  Ssh.HostKeys;

function EncodePrivateKeyFile(Key: TSshHostKey; const Comment: string): string;
{ A new host key from the file's text; nil when it is not an
  unencrypted OpenSSH private key of a kind handled here. }
function DecodePrivateKeyFile(const Text: string): TSshHostKey;

implementation

uses
  SysUtils,
  Crypto.Random,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.Base64;

const
  BeginLine = '-----BEGIN OPENSSH PRIVATE KEY-----';
  EndLine = '-----END OPENSSH PRIVATE KEY-----';
  Magic = 'openssh-key-v1'#0;
  LineWidth = 70;

function EncodePrivateKeyFile(Key: TSshHostKey; const Comment: string): string;
var
  Check: LongWord;
  Section, Binary, Encoded: string;
  Pad: Integer;
  Position: Integer;
begin
  RandomBytes(@Check, SizeOf(Check));
  Section := SshUInt32(Check) + SshUInt32(Check) + SshString(Key.Algorithm) + Key.PrivateFields +
    SshString(Comment);
  Pad := 1;
  while Length(Section) mod 8 <> 0 do
  begin
    Section := Section + Chr(Pad);
    Inc(Pad);
  end;
  Binary := Magic + SshString('none') + SshString('none') + SshString('') + SshUInt32(1) +
    SshString(Key.PublicBlob) + SshString(Section);
  Encoded := EncodeBase64(Binary);
  Result := BeginLine + #10;
  Position := 1;
  while Position <= Length(Encoded) do
  begin
    Result := Result + Copy(Encoded, Position, LineWidth) + #10;
    Inc(Position, LineWidth);
  end;
  Result := Result + EndLine + #10;
  WipeString(Section);
  WipeString(Binary);
  WipeString(Encoded);
end;

function DecodeSection(const Section: string): TSshHostKey;
var
  Reader: TSshReader;
  KeyType: string;
  PublicKey, PrivateKey, Curve, Point, Scalar: string;
begin
  Result := nil;
  Reader.Start(Section);
  if Reader.ReadUInt32 <> Reader.ReadUInt32 then
    Exit;
  KeyType := Reader.ReadString;
  if KeyType = HostKeyEd25519 then
  begin
    PublicKey := Reader.ReadString;
    PrivateKey := Reader.ReadString;
    if (Length(PublicKey) <> 32) or (Length(PrivateKey) <> 64) then
      Exit;
    Result := TSshEd25519HostKey.Create(Copy(PrivateKey, 1, 32));
    WipeString(PrivateKey);
    if TSshEd25519HostKey(Result).PublicKey <> PublicKey then
      FreeAndNil(Result);
  end
  else if KeyType = HostKeyEcdsaP256 then
  begin
    Curve := Reader.ReadString;
    Point := Reader.ReadString;
    Scalar := Reader.ReadMpint;
    if (Curve <> CurveNameP256) or (Length(Scalar) > 32) then
      Exit;
    Result := TSshEcdsaP256HostKey.Create(Scalar);
    WipeString(Scalar);
    if TSshEcdsaP256HostKey(Result).PublicPoint <> Point then
      FreeAndNil(Result);
  end;
end;

function DecodePrivateKeyFile(const Text: string): TSshHostKey;
var
  First, Last: Integer;
  Binary: string;
  Reader: TSshReader;
  Section: string;
begin
  Result := nil;
  First := Pos(BeginLine, Text);
  Last := Pos(EndLine, Text);
  if (First = 0) or (Last <= First) then
    Exit;
  First := First + Length(BeginLine);
  if not DecodeBase64(Copy(Text, First, Last - First), Binary) then
    Exit;
  try
    if Copy(Binary, 1, Length(Magic)) <> Magic then
      Exit;
    Reader.Start(Copy(Binary, Length(Magic) + 1, MaxInt));
    if (Reader.ReadString <> 'none') or (Reader.ReadString <> 'none') then
      Exit;
    Reader.ReadString;
    if Reader.ReadUInt32 <> 1 then
      Exit;
    Reader.ReadString;
    Section := Reader.ReadString;
    Result := DecodeSection(Section);
  except
    on Exception do
      FreeAndNil(Result);
  end;
  WipeString(Section);
  WipeString(Binary);
end;

end.
