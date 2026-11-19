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
  The server's host keys: ssh-ed25519 (RFC 8709) and
  ecdsa-sha2-nistp256 (RFC 5656), each with its public key blob, its
  signatures in SSH form, and the private fields an OpenSSH private key
  file holds (Ssh.KeyFiles).

    ssh-ed25519           blob: string name, string key (32)
                          signature: string name, string R || S (64)
    ecdsa-sha2-nistp256   blob: string name, string "nistp256", string Q
                          signature: string name, string (mpint r, mpint s)
                          over SHA-256 of the data
}
unit Ssh.HostKeys;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSshHostKey = class
  public
    function Algorithm: string; virtual; abstract;
    function PublicBlob: string; virtual; abstract;
    { The signature of Data in SSH form (algorithm name and signature). }
    function Sign(const Data: string): string; virtual; abstract;
    { The key's fields after its type in an OpenSSH private key file. }
    function PrivateFields: string; virtual; abstract;
  end;

  TSshEd25519HostKey = class(TSshHostKey)
  private
    FSeed: string;
    FPublicKey: string;
  public
    constructor Create(const Seed: string);
    class function Generate: TSshEd25519HostKey;
    destructor Destroy; override;
    function Algorithm: string; override;
    function PublicBlob: string; override;
    function Sign(const Data: string): string; override;
    function PrivateFields: string; override;
    property PublicKey: string read FPublicKey;
  end;

  TSshEcdsaP256HostKey = class(TSshHostKey)
  private
    FPrivateKey: string;
    FPublicPoint: string;
  public
    { PrivateKey: d, big endian, 32 bytes (shorter ones are padded). }
    constructor Create(const PrivateKey: string);
    class function Generate: TSshEcdsaP256HostKey;
    destructor Destroy; override;
    function Algorithm: string; override;
    function PublicBlob: string; override;
    function Sign(const Data: string): string; override;
    function PrivateFields: string; override;
    property PublicPoint: string read FPublicPoint;
  end;

  { A host certificate (HostCertificate) with the key it certifies: the
    certificate's algorithm is offered and it goes as K_S; the key signs
    (its signature names the plain algorithm, as OpenSSH's do). Owns
    neither. }
  TSshCertifiedHostKey = class(TSshHostKey)
  private
    FKey: TSshHostKey;
    FCertificateType: string;
    FCertificateBlob: string;
  public
    constructor Create(Key: TSshHostKey; const CertificateType, CertificateBlob: string);
    function Algorithm: string; override;
    function PublicBlob: string; override;
    function Sign(const Data: string): string; override;
    function PrivateFields: string; override;
    property Key: TSshHostKey read FKey;
  end;

  THostKeyArray = array of TSshHostKey;

{ The algorithm names of Keys, in order. }
function HostKeyAlgorithms(const Keys: THostKeyArray): TStringArray;
{ The key for Algorithm; nil if there is none. }
function FindHostKey(const Keys: THostKeyArray; const Algorithm: string): TSshHostKey;

implementation

uses
  Crypto.Digests,
  Crypto.EllipticCurves,
  Crypto.Ecdsa,
  Crypto.Ed25519,
  Crypto.KeyGeneration,
  Ssh.Constants,
  Ssh.Wire;

const
  P256CoordinateSize = 32;
  P256PointSize = 1 + 2 * P256CoordinateSize;

constructor TSshEd25519HostKey.Create(const Seed: string);
begin
  inherited Create;
  if Length(Seed) <> Ed25519SeedSize then
    raise Exception.Create('an Ed25519 seed is 32 bytes');
  FSeed := Seed;
  UniqueString(FSeed);
  FPublicKey := '';
  SetLength(FPublicKey, Ed25519PublicKeySize);
  Ed25519PublicKey(@FSeed[1], @FPublicKey[1]);
end;

class function TSshEd25519HostKey.Generate: TSshEd25519HostKey;
var
  Seed: string;
begin
  Seed := '';
  SetLength(Seed, Ed25519SeedSize);
  GenerateEd25519Seed(@Seed[1]);
  Result := TSshEd25519HostKey.Create(Seed);
  WipeString(Seed);
end;

destructor TSshEd25519HostKey.Destroy;
begin
  WipeString(FSeed);
  inherited Destroy;
end;

function TSshEd25519HostKey.Algorithm: string;
begin
  Result := HostKeyEd25519;
end;

function TSshEd25519HostKey.PublicBlob: string;
begin
  Result := SshString(HostKeyEd25519) + SshString(FPublicKey);
end;

function TSshEd25519HostKey.Sign(const Data: string): string;
var
  Signature: string;
  DataPointer: PByte;
begin
  Signature := '';
  SetLength(Signature, Ed25519SignatureSize);
  DataPointer := nil;
  if Data <> '' then
    DataPointer := @Data[1];
  Ed25519Sign(@FSeed[1], DataPointer, Length(Data), @Signature[1]);
  Result := SshString(HostKeyEd25519) + SshString(Signature);
end;

function TSshEd25519HostKey.PrivateFields: string;
begin
  { The public key, then the "private key" of 64 bytes: the seed and the
    public key again. }
  Result := SshString(FPublicKey) + SshString(FSeed + FPublicKey);
end;

constructor TSshEcdsaP256HostKey.Create(const PrivateKey: string);
begin
  inherited Create;
  if Length(PrivateKey) > P256CoordinateSize then
    raise Exception.Create('an ECDSA P-256 private key is at most 32 bytes');
  FPrivateKey := StringOfChar(#0, P256CoordinateSize - Length(PrivateKey)) + PrivateKey;
  FPublicPoint := '';
  SetLength(FPublicPoint, P256PointSize);
  if not EcdsaPublicKey(CurveP256, @FPrivateKey[1], P256CoordinateSize, @FPublicPoint[1]) then
    raise Exception.Create('the ECDSA P-256 private key is out of range');
end;

class function TSshEcdsaP256HostKey.Generate: TSshEcdsaP256HostKey;
var
  PrivateKey: string;
begin
  PrivateKey := '';
  SetLength(PrivateKey, P256CoordinateSize);
  GenerateEcdsaPrivateKey(CurveP256, @PrivateKey[1]);
  Result := TSshEcdsaP256HostKey.Create(PrivateKey);
  WipeString(PrivateKey);
end;

destructor TSshEcdsaP256HostKey.Destroy;
begin
  WipeString(FPrivateKey);
  inherited Destroy;
end;

function TSshEcdsaP256HostKey.Algorithm: string;
begin
  Result := HostKeyEcdsaP256;
end;

function TSshEcdsaP256HostKey.PublicBlob: string;
begin
  Result := SshString(HostKeyEcdsaP256) + SshString(CurveNameP256) + SshString(FPublicPoint);
end;

function TSshEcdsaP256HostKey.Sign(const Data: string): string;
var
  Digest: TDigestOutput;
  R, S: string;
begin
  if Data = '' then
    ComputeDigest(DigestSha256, nil, 0, Digest)
  else
    ComputeDigest(DigestSha256, @Data[1], Length(Data), Digest);
  R := '';
  S := '';
  SetLength(R, P256CoordinateSize);
  SetLength(S, P256CoordinateSize);
  SignEcdsa(CurveP256, @FPrivateKey[1], P256CoordinateSize, DigestSha256, @Digest[0], DigestSize(DigestSha256),
    @R[1], @S[1]);
  Result := SshString(HostKeyEcdsaP256) + SshString(SshMpint(R) + SshMpint(S));
end;

function TSshEcdsaP256HostKey.PrivateFields: string;
begin
  Result := SshString(CurveNameP256) + SshString(FPublicPoint) + SshMpint(FPrivateKey);
end;

constructor TSshCertifiedHostKey.Create(Key: TSshHostKey; const CertificateType, CertificateBlob: string);
begin
  inherited Create;
  FKey := Key;
  FCertificateType := CertificateType;
  FCertificateBlob := CertificateBlob;
end;

function TSshCertifiedHostKey.Algorithm: string;
begin
  Result := FCertificateType;
end;

function TSshCertifiedHostKey.PublicBlob: string;
begin
  Result := FCertificateBlob;
end;

function TSshCertifiedHostKey.Sign(const Data: string): string;
begin
  Result := FKey.Sign(Data);
end;

function TSshCertifiedHostKey.PrivateFields: string;
begin
  Result := FKey.PrivateFields;
end;

function HostKeyAlgorithms(const Keys: THostKeyArray): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Keys));
  for Index := 0 to High(Keys) do
    Result[Index] := Keys[Index].Algorithm;
end;

function FindHostKey(const Keys: THostKeyArray; const Algorithm: string): TSshHostKey;
var
  Index: Integer;
begin
  for Index := 0 to High(Keys) do
    if Keys[Index].Algorithm = Algorithm then
      Exit(Keys[Index]);
  Result := nil;
end;

end.
