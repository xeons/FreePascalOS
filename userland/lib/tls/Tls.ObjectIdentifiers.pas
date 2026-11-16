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
  The object identifiers certificates use, as the contents bytes of
  their DER encoding (what Asn1ObjectIdentifierIs compares).
}
unit Tls.ObjectIdentifiers;

{$mode objfpc}

interface

const
  { PKCS #1 (RFC 8017): 1.2.840.113549.1.1.n }
  OidRsaEncryption: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $01);
  OidSha1WithRsa: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $05);
  OidMgf1: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $08);
  OidRsaPss: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $0A);
  OidSha256WithRsa: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $0B);
  OidSha384WithRsa: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $0C);
  OidSha512WithRsa: array[0..8] of Byte = ($2A, $86, $48, $86, $F7, $0D, $01, $01, $0D);

  { Elliptic curves (RFC 5480, RFC 5758). }
  OidEcPublicKey: array[0..6] of Byte = ($2A, $86, $48, $CE, $3D, $02, $01);
  OidCurveP256: array[0..7] of Byte = ($2A, $86, $48, $CE, $3D, $03, $01, $07);
  OidCurveP384: array[0..4] of Byte = ($2B, $81, $04, $00, $22);
  OidEcdsaWithSha256: array[0..7] of Byte = ($2A, $86, $48, $CE, $3D, $04, $03, $02);
  OidEcdsaWithSha384: array[0..7] of Byte = ($2A, $86, $48, $CE, $3D, $04, $03, $03);
  OidEcdsaWithSha512: array[0..7] of Byte = ($2A, $86, $48, $CE, $3D, $04, $03, $04);
  { Ed25519 (RFC 8410), recognized only to name it in errors. }
  OidEd25519: array[0..2] of Byte = ($2B, $65, $70);

  { Digests (RFC 5754, NIST). }
  OidSha1: array[0..4] of Byte = ($2B, $0E, $03, $02, $1A);
  OidSha256: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $01);
  OidSha384: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $02);
  OidSha512: array[0..8] of Byte = ($60, $86, $48, $01, $65, $03, $04, $02, $03);

  { Name attributes. }
  OidCommonName: array[0..2] of Byte = ($55, $04, $03);

  { Certificate extensions (RFC 5280): 2.5.29.n }
  OidSubjectKeyIdentifier: array[0..2] of Byte = ($55, $1D, $0E);
  OidKeyUsage: array[0..2] of Byte = ($55, $1D, $0F);
  OidSubjectAlternativeName: array[0..2] of Byte = ($55, $1D, $11);
  OidBasicConstraints: array[0..2] of Byte = ($55, $1D, $13);
  OidNameConstraints: array[0..2] of Byte = ($55, $1D, $1E);
  OidCertificatePolicies: array[0..2] of Byte = ($55, $1D, $20);
  OidAuthorityKeyIdentifier: array[0..2] of Byte = ($55, $1D, $23);
  OidExtendedKeyUsage: array[0..2] of Byte = ($55, $1D, $25);
  OidAnyExtendedKeyUsage: array[0..3] of Byte = ($55, $1D, $25, $00);
  { id-kp-serverAuth: 1.3.6.1.5.5.7.3.1 }
  OidServerAuthentication: array[0..7] of Byte = ($2B, $06, $01, $05, $05, $07, $03, $01);

implementation

end.
