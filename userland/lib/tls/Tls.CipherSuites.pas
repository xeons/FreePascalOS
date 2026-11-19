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
  The cipher suites this library speaks: an AEAD and a hash (the key
  schedule's in TLS 1.3, the PRF's in TLS 1.2).

    TLS 1.3 (RFC 8446 appendix B.4)
      TLS_AES_128_GCM_SHA256                          $1301
      TLS_AES_256_GCM_SHA384                          $1302
      TLS_CHACHA20_POLY1305_SHA256                    $1303
    TLS 1.2: ECDHE only, AEAD only (RFC 5289, RFC 7905)
      TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256         $C02B
      TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384         $C02C
      TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256           $C02F
      TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384           $C030
      TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256     $CCA8
      TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256   $CCA9

  No CBC, no RSA key exchange, no static (EC)DH. The default offer puts
  the AES suites first when the processor has AES instructions, and
  leaves them out otherwise (the table driven AES could leak the key
  through timing); ChaCha20-Poly1305 is always offered.
}
unit Tls.CipherSuites;

{$mode objfpc}
{$H+}

interface

uses
  Crypto.Digests;

const
  CipherSuiteAes128GcmSha256 = $1301;
  CipherSuiteAes256GcmSha384 = $1302;
  CipherSuiteChaCha20Poly1305Sha256 = $1303;
  CipherSuiteEcdheEcdsaAes128GcmSha256 = $C02B;
  CipherSuiteEcdheEcdsaAes256GcmSha384 = $C02C;
  CipherSuiteEcdheRsaAes128GcmSha256 = $C02F;
  CipherSuiteEcdheRsaAes256GcmSha384 = $C030;
  CipherSuiteEcdheRsaChaCha20Poly1305 = $CCA8;
  CipherSuiteEcdheEcdsaChaCha20Poly1305 = $CCA9;

  MaximumCipherSuites = 9;

type
  TAeadKind = (AeadAes128Gcm, AeadAes256Gcm, AeadChaCha20Poly1305);
  { Which key signs a TLS 1.2 suite's key exchange; TLS 1.3 suites leave
    that to the signature algorithms. }
  TSuiteAuthentication = (AuthenticationAny, AuthenticationEcdsa, AuthenticationRsa);

  TCipherSuiteInfo = record
    Identifier: Word;
    Aead: TAeadKind;
    Hash: TDigestAlgorithm;
    KeyLength: Integer;
    { True for the TLS 1.2 suites. }
    IsTls12: Boolean;
    Authentication: TSuiteAuthentication;
    Name: PChar;
    { OpenSSL's name (the same as Name for TLS 1.3). }
    OpenSslName: PChar;
  end;

  TCipherSuiteList = record
    Count: Integer;
    Identifiers: array[0..MaximumCipherSuites - 1] of Word;
  end;

function FindCipherSuite(Identifier: Word; out Info: TCipherSuiteInfo): Boolean;
{ The suites offered when a program does not choose. }
procedure DefaultCipherSuites(out List: TCipherSuiteList);
{ "TLS_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256" or
  OpenSSL's "ECDHE-RSA-AES128-GCM-SHA256". 0 when unknown. }
function CipherSuiteByName(const Name: string): Word;
function CipherSuiteListContains(constref List: TCipherSuiteList; Identifier: Word): Boolean;
function CipherSuiteIsTls12(Identifier: Word): Boolean;

implementation

uses
  SysUtils,
  Crypto.Aes;

const
  Suites: array[0..8] of TCipherSuiteInfo = (
    (Identifier: CipherSuiteAes128GcmSha256; Aead: AeadAes128Gcm; Hash: DigestSha256; KeyLength: 16;
     IsTls12: False; Authentication: AuthenticationAny;
     Name: 'TLS_AES_128_GCM_SHA256'; OpenSslName: 'TLS_AES_128_GCM_SHA256'),
    (Identifier: CipherSuiteAes256GcmSha384; Aead: AeadAes256Gcm; Hash: DigestSha384; KeyLength: 32;
     IsTls12: False; Authentication: AuthenticationAny;
     Name: 'TLS_AES_256_GCM_SHA384'; OpenSslName: 'TLS_AES_256_GCM_SHA384'),
    (Identifier: CipherSuiteChaCha20Poly1305Sha256; Aead: AeadChaCha20Poly1305; Hash: DigestSha256; KeyLength: 32;
     IsTls12: False; Authentication: AuthenticationAny;
     Name: 'TLS_CHACHA20_POLY1305_SHA256'; OpenSslName: 'TLS_CHACHA20_POLY1305_SHA256'),
    (Identifier: CipherSuiteEcdheEcdsaAes128GcmSha256; Aead: AeadAes128Gcm; Hash: DigestSha256; KeyLength: 16;
     IsTls12: True; Authentication: AuthenticationEcdsa;
     Name: 'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256'; OpenSslName: 'ECDHE-ECDSA-AES128-GCM-SHA256'),
    (Identifier: CipherSuiteEcdheEcdsaAes256GcmSha384; Aead: AeadAes256Gcm; Hash: DigestSha384; KeyLength: 32;
     IsTls12: True; Authentication: AuthenticationEcdsa;
     Name: 'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384'; OpenSslName: 'ECDHE-ECDSA-AES256-GCM-SHA384'),
    (Identifier: CipherSuiteEcdheRsaAes128GcmSha256; Aead: AeadAes128Gcm; Hash: DigestSha256; KeyLength: 16;
     IsTls12: True; Authentication: AuthenticationRsa;
     Name: 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'; OpenSslName: 'ECDHE-RSA-AES128-GCM-SHA256'),
    (Identifier: CipherSuiteEcdheRsaAes256GcmSha384; Aead: AeadAes256Gcm; Hash: DigestSha384; KeyLength: 32;
     IsTls12: True; Authentication: AuthenticationRsa;
     Name: 'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'; OpenSslName: 'ECDHE-RSA-AES256-GCM-SHA384'),
    (Identifier: CipherSuiteEcdheRsaChaCha20Poly1305; Aead: AeadChaCha20Poly1305; Hash: DigestSha256; KeyLength: 32;
     IsTls12: True; Authentication: AuthenticationRsa;
     Name: 'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256'; OpenSslName: 'ECDHE-RSA-CHACHA20-POLY1305'),
    (Identifier: CipherSuiteEcdheEcdsaChaCha20Poly1305; Aead: AeadChaCha20Poly1305; Hash: DigestSha256;
     KeyLength: 32; IsTls12: True; Authentication: AuthenticationEcdsa;
     Name: 'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256'; OpenSslName: 'ECDHE-ECDSA-CHACHA20-POLY1305'));

function FindCipherSuite(Identifier: Word; out Info: TCipherSuiteInfo): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Suites) do
    if Suites[Index].Identifier = Identifier then
    begin
      Info := Suites[Index];
      Exit(True);
    end;
  FillChar(Info, SizeOf(Info), 0);
  Result := False;
end;

procedure AddSuite(var List: TCipherSuiteList; Identifier: Word);
begin
  List.Identifiers[List.Count] := Identifier;
  Inc(List.Count);
end;

procedure DefaultCipherSuites(out List: TCipherSuiteList);
begin
  FillChar(List, SizeOf(List), 0);
  if AesIsConstantTime then
  begin
    AddSuite(List, CipherSuiteAes128GcmSha256);
    AddSuite(List, CipherSuiteChaCha20Poly1305Sha256);
    AddSuite(List, CipherSuiteAes256GcmSha384);
    AddSuite(List, CipherSuiteEcdheEcdsaAes128GcmSha256);
    AddSuite(List, CipherSuiteEcdheRsaAes128GcmSha256);
    AddSuite(List, CipherSuiteEcdheEcdsaChaCha20Poly1305);
    AddSuite(List, CipherSuiteEcdheRsaChaCha20Poly1305);
    AddSuite(List, CipherSuiteEcdheEcdsaAes256GcmSha384);
    AddSuite(List, CipherSuiteEcdheRsaAes256GcmSha384);
  end
  else
  begin
    AddSuite(List, CipherSuiteChaCha20Poly1305Sha256);
    AddSuite(List, CipherSuiteEcdheEcdsaChaCha20Poly1305);
    AddSuite(List, CipherSuiteEcdheRsaChaCha20Poly1305);
  end;
end;

function CipherSuiteByName(const Name: string): Word;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Suites) do
    if SameText(Name, string(Suites[Index].Name)) or SameText(Name, string(Suites[Index].OpenSslName)) then
      Exit(Suites[Index].Identifier);
end;

function CipherSuiteListContains(constref List: TCipherSuiteList; Identifier: Word): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to List.Count - 1 do
    if List.Identifiers[Index] = Identifier then
      Exit(True);
  Result := False;
end;

function CipherSuiteIsTls12(Identifier: Word): Boolean;
var
  Info: TCipherSuiteInfo;
begin
  Result := FindCipherSuite(Identifier, Info) and Info.IsTls12;
end;

end.
