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
  The TLS 1.3 cipher suites this library speaks (RFC 8446 appendix
  B.4): an AEAD and the hash of the key schedule.

    TLS_AES_128_GCM_SHA256         $1301
    TLS_AES_256_GCM_SHA384         $1302
    TLS_CHACHA20_POLY1305_SHA256   $1303

  The default offer puts the AES suites first when the processor has
  AES instructions, and leaves them out otherwise (the table driven AES
  could leak the key through timing); ChaCha20-Poly1305 is always
  offered.
}
unit Tls.CipherSuites;

{$mode objfpc}

interface

uses
  Crypto.Digests;

const
  CipherSuiteAes128GcmSha256 = $1301;
  CipherSuiteAes256GcmSha384 = $1302;
  CipherSuiteChaCha20Poly1305Sha256 = $1303;

  MaximumCipherSuites = 3;

type
  TAeadKind = (AeadAes128Gcm, AeadAes256Gcm, AeadChaCha20Poly1305);

  TCipherSuiteInfo = record
    Identifier: Word;
    Aead: TAeadKind;
    Hash: TDigestAlgorithm;
    KeyLength: Integer;
    Name: PChar;
  end;

  TCipherSuiteList = record
    Count: Integer;
    Identifiers: array[0..MaximumCipherSuites - 1] of Word;
  end;

function FindCipherSuite(Identifier: Word; out Info: TCipherSuiteInfo): Boolean;
{ The suites offered when a program does not choose. }
procedure DefaultCipherSuites(out List: TCipherSuiteList);
{ "TLS_AES_128_GCM_SHA256" etc.; also the OpenSSL style names
  ("TLS_AES_128_GCM_SHA256" is the same in both). 0 when unknown. }
function CipherSuiteByName(Name: PChar): Word;
function CipherSuiteListContains(constref List: TCipherSuiteList; Identifier: Word): Boolean;

implementation

uses
  Crypto.Aes;

const
  Suites: array[0..2] of TCipherSuiteInfo = (
    (Identifier: CipherSuiteAes128GcmSha256; Aead: AeadAes128Gcm; Hash: DigestSha256; KeyLength: 16;
     Name: 'TLS_AES_128_GCM_SHA256'),
    (Identifier: CipherSuiteAes256GcmSha384; Aead: AeadAes256Gcm; Hash: DigestSha384; KeyLength: 32;
     Name: 'TLS_AES_256_GCM_SHA384'),
    (Identifier: CipherSuiteChaCha20Poly1305Sha256; Aead: AeadChaCha20Poly1305; Hash: DigestSha256; KeyLength: 32;
     Name: 'TLS_CHACHA20_POLY1305_SHA256'));

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

procedure DefaultCipherSuites(out List: TCipherSuiteList);
begin
  FillChar(List, SizeOf(List), 0);
  if AesIsConstantTime then
  begin
    List.Identifiers[0] := CipherSuiteAes128GcmSha256;
    List.Identifiers[1] := CipherSuiteChaCha20Poly1305Sha256;
    List.Identifiers[2] := CipherSuiteAes256GcmSha384;
    List.Count := 3;
  end
  else
  begin
    List.Identifiers[0] := CipherSuiteChaCha20Poly1305Sha256;
    List.Count := 1;
  end;
end;

function NamesEqual(First, Second: PChar): Boolean;
var
  Index: Integer;
  Left, Right: Char;
begin
  Index := 0;
  repeat
    Left := UpCase(First[Index]);
    Right := UpCase(Second[Index]);
    if Left <> Right then
      Exit(False);
    Inc(Index);
  until Left = #0;
  Result := True;
end;

function CipherSuiteByName(Name: PChar): Word;
var
  Index: Integer;
begin
  Result := 0;
  if Name = nil then
    Exit;
  for Index := 0 to High(Suites) do
    if NamesEqual(Name, Suites[Index].Name) then
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

end.
