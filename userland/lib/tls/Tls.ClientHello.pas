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
  The ClientHello (RFC 8446 section 4.1.2) of a client that speaks TLS
  1.3 and TLS 1.2: legacy_version 1.2, a random, a 32-byte legacy
  session id (middlebox compatibility mode, appendix D.4), the cipher
  suites of the versions offered, no compression, and the extensions

    server_name                 the host, unless it is an IP address
    status_request              an OCSP response, please (RFC 6066)
    supported_groups            the groups offered, x25519 first
    ec_point_formats            uncompressed (TLS 1.2, RFC 8422)
    signature_algorithms        ECDSA P-256/P-384/P-521, Ed25519,
                                RSA-PSS, RSA PKCS#1
    application_layer_protocol  when the program names one
    extended_master_secret      (TLS 1.2, RFC 7627)
    supported_versions          TLS 1.3 and/or TLS 1.2
    cookie                      the server's, after a HelloRetryRequest
    psk_key_exchange_modes      psk_dhe_ke, when resuming is allowed
    key_share                   the shares the handshake made (TLS 1.3)
    renegotiation_info          empty: a first handshake (RFC 5746)
    quic_transport_parameters   in QUIC mode (Tls.Quic), which also
                                leaves the legacy session id empty
    pre_shared_key              a session ticket, last of all, its
                                binder left for the handshake to fill
}
unit Tls.ClientHello;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Tls.ByteBuffers,
  Tls.CipherSuites,
  Tls.KeyShares;

const
  MaximumOfferedKeyShares = 2;

type
  TOfferedKeyShare = record
    Group: Word;
    Data: PByte;
    Length: PtrUInt;
  end;

  TClientHelloParameters = record
    Random: array[0..31] of Byte;
    SessionId: array[0..31] of Byte;
    CipherSuites: TCipherSuiteList;
    { Empty: no server_name. }
    ServerName: string;
    Groups: TTlsGroupList;
    KeyShares: array[0..MaximumOfferedKeyShares - 1] of TOfferedKeyShare;
    KeyShareCount: Integer;
    MinimumVersion, MaximumVersion: Word;
    { Empty: no cookie. }
    Cookie: TTlsByteRange;
    { Empty: no ALPN. }
    ApplicationProtocol: string;
    { psk_key_exchange_modes goes out (tickets may be issued). }
    AllowResumption: Boolean;
    { A ticket to resume with (empty: none), its obfuscated age and the
      length of its binder (the hash's). }
    PskIdentity: TBytes;
    ObfuscatedTicketAge: LongWord;
    BinderLength: Integer;
    { QUIC (Tls.Quic): an empty legacy session id and the
      quic_transport_parameters extension with these bytes. }
    Quic: Boolean;
    QuicTransportParameters: TBytes;
  end;

const
  OfferedSignatureSchemes: array[0..12] of Word = (
    $0403, $0503, $0603, $0807, $0804, $0805, $0806, $0809, $080A, $080B, $0401, $0501, $0601);

{ Appends the whole handshake message, header included. With a PSK,
  BindersOffset is where in the message the binders begin (the
  truncated ClientHello the binder covers ends there) and the binder
  is zeros; otherwise it is 0. }
procedure BuildClientHello(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters;
  out BindersOffset: PtrUInt);
function SignatureSchemeWasOffered(Scheme: Word): Boolean;
{ Whether a suite goes into a ClientHello offering these versions. }
function SuiteFitsVersions(Identifier: Word; MinimumVersion, MaximumVersion: Word): Boolean;

implementation

uses
  Tls.Constants,
  Tls.Quic;

function SuiteFitsVersions(Identifier: Word; MinimumVersion, MaximumVersion: Word): Boolean;
begin
  if CipherSuiteIsTls12(Identifier) then
    Result := MinimumVersion <= VersionTls12
  else
    Result := MaximumVersion >= VersionTls13;
end;

procedure AddServerName(var Builder: TTlsBuilder; const Name: string);
var
  Extension, List, HostName: PtrUInt;
  NameLength: PtrUInt;
begin
  NameLength := Length(Name);
  { Without a final dot (RFC 6066 section 3). }
  if (NameLength > 0) and (Name[NameLength] = '.') then
    Dec(NameLength);
  AppendUInt16(Builder, ExtensionServerName);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  AppendByte(Builder, 0);   { host_name }
  HostName := BeginVector(Builder, 2);
  AppendBytes(Builder, PChar(Name), NameLength);
  EndVector(Builder, HostName, 2);
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
end;

(* CertificateStatusRequest: ocsp, no responder ids, no extensions. *)
procedure AddStatusRequest(var Builder: TTlsBuilder);
begin
  AppendUInt16(Builder, ExtensionStatusRequest);
  AppendUInt16(Builder, 5);
  AppendByte(Builder, CertificateStatusOcsp);
  AppendUInt16(Builder, 0);
  AppendUInt16(Builder, 0);
end;

procedure AddSupportedGroups(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Extension, List: PtrUInt;
  Index: Integer;
  Group: Word;
begin
  AppendUInt16(Builder, ExtensionSupportedGroups);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  for Index := 0 to Parameters.Groups.Count - 1 do
  begin
    Group := Parameters.Groups.Groups[Index];
    { The hybrid needs TLS 1.3. }
    if (Parameters.MaximumVersion < VersionTls13) and not GroupWorksWithTls12(Group) then
      Continue;
    AppendUInt16(Builder, Group);
  end;
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
end;

procedure AddPointFormats(var Builder: TTlsBuilder);
begin
  AppendUInt16(Builder, ExtensionEcPointFormats);
  AppendUInt16(Builder, 2);
  AppendByte(Builder, 1);
  AppendByte(Builder, PointFormatUncompressed);
end;

procedure AddSignatureAlgorithms(var Builder: TTlsBuilder);
var
  Extension, List: PtrUInt;
  Index: Integer;
begin
  AppendUInt16(Builder, ExtensionSignatureAlgorithms);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  for Index := 0 to High(OfferedSignatureSchemes) do
    AppendUInt16(Builder, OfferedSignatureSchemes[Index]);
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
end;

procedure AddEmptyExtension(var Builder: TTlsBuilder; ExtensionType: Word);
begin
  AppendUInt16(Builder, ExtensionType);
  AppendUInt16(Builder, 0);
end;

procedure AddSupportedVersions(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Extension, List: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionSupportedVersions);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 1);
  if Parameters.MaximumVersion >= VersionTls13 then
    AppendUInt16(Builder, VersionTls13);
  if Parameters.MinimumVersion <= VersionTls12 then
    AppendUInt16(Builder, VersionTls12);
  EndVector(Builder, List, 1);
  EndVector(Builder, Extension, 2);
end;

procedure AddKeyShares(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Extension, List, Key: PtrUInt;
  Index: Integer;
begin
  AppendUInt16(Builder, ExtensionKeyShare);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  for Index := 0 to Parameters.KeyShareCount - 1 do
  begin
    AppendUInt16(Builder, Parameters.KeyShares[Index].Group);
    Key := BeginVector(Builder, 2);
    AppendBytes(Builder, Parameters.KeyShares[Index].Data, Parameters.KeyShares[Index].Length);
    EndVector(Builder, Key, 2);
  end;
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
end;

procedure AddApplicationProtocol(var Builder: TTlsBuilder; const Protocol: string);
var
  Extension, List, Name: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionApplicationLayerProtocol);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  Name := BeginVector(Builder, 1);
  AppendBytes(Builder, PChar(Protocol), Length(Protocol));
  EndVector(Builder, Name, 1);
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
end;

procedure AddCookie(var Builder: TTlsBuilder; constref Cookie: TTlsByteRange);
var
  Extension, Value: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionCookie);
  Extension := BeginVector(Builder, 2);
  Value := BeginVector(Builder, 2);
  AppendBytes(Builder, Cookie.Data, Cookie.Length);
  EndVector(Builder, Value, 2);
  EndVector(Builder, Extension, 2);
end;

procedure AddPskModes(var Builder: TTlsBuilder);
begin
  AppendUInt16(Builder, ExtensionPskKeyExchangeModes);
  AppendUInt16(Builder, 2);
  AppendByte(Builder, 1);
  AppendByte(Builder, PskModeDheKeyExchange);
end;

procedure AddQuicTransportParameters(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Extension: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionQuicTransportParameters);
  Extension := BeginVector(Builder, 2);
  if Length(Parameters.QuicTransportParameters) > 0 then
    AppendBytes(Builder, @Parameters.QuicTransportParameters[0], Length(Parameters.QuicTransportParameters));
  EndVector(Builder, Extension, 2);
end;

procedure AddRenegotiationInfo(var Builder: TTlsBuilder);
begin
  AppendUInt16(Builder, ExtensionRenegotiationInfo);
  AppendUInt16(Builder, 1);
  AppendByte(Builder, 0);
end;

(* OfferedPsks: one identity (ticket, obfuscated age) and its binder
   (zeros for now). Returns where the binders vector starts in the
   builder. *)
function AddPreSharedKey(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters): PtrUInt;
var
  Extension, Identities, Identity, Binders, Binder: PtrUInt;
  Index: Integer;
begin
  AppendUInt16(Builder, ExtensionPreSharedKey);
  Extension := BeginVector(Builder, 2);
  Identities := BeginVector(Builder, 2);
  Identity := BeginVector(Builder, 2);
  AppendBytes(Builder, @Parameters.PskIdentity[0], Length(Parameters.PskIdentity));
  EndVector(Builder, Identity, 2);
  AppendByte(Builder, Byte(Parameters.ObfuscatedTicketAge shr 24));
  AppendByte(Builder, Byte(Parameters.ObfuscatedTicketAge shr 16));
  AppendByte(Builder, Byte(Parameters.ObfuscatedTicketAge shr 8));
  AppendByte(Builder, Byte(Parameters.ObfuscatedTicketAge));
  EndVector(Builder, Identities, 2);
  Result := Builder.Length;
  Binders := BeginVector(Builder, 2);
  Binder := BeginVector(Builder, 1);
  for Index := 1 to Parameters.BinderLength do
    AppendByte(Builder, 0);
  EndVector(Builder, Binder, 1);
  EndVector(Builder, Binders, 2);
  EndVector(Builder, Extension, 2);
end;

procedure BuildClientHello(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters;
  out BindersOffset: PtrUInt);
var
  Start, Body, Suites, Compression, Extensions, SessionId: PtrUInt;
  Index: Integer;
  OffersTls12, OffersTls13: Boolean;
  Identifier: Word;
begin
  BindersOffset := 0;
  OffersTls12 := Parameters.MinimumVersion <= VersionTls12;
  OffersTls13 := Parameters.MaximumVersion >= VersionTls13;
  Start := Builder.Length;
  AppendByte(Builder, HandshakeClientHello);
  Body := BeginVector(Builder, 3);
  AppendUInt16(Builder, VersionTls12);
  AppendBytes(Builder, @Parameters.Random[0], 32);
  SessionId := BeginVector(Builder, 1);
  if not Parameters.Quic then
    AppendBytes(Builder, @Parameters.SessionId[0], 32);
  EndVector(Builder, SessionId, 1);
  Suites := BeginVector(Builder, 2);
  for Index := 0 to Parameters.CipherSuites.Count - 1 do
  begin
    Identifier := Parameters.CipherSuites.Identifiers[Index];
    if SuiteFitsVersions(Identifier, Parameters.MinimumVersion, Parameters.MaximumVersion) then
      AppendUInt16(Builder, Identifier);
  end;
  EndVector(Builder, Suites, 2);
  Compression := BeginVector(Builder, 1);
  AppendByte(Builder, 0);
  EndVector(Builder, Compression, 1);

  Extensions := BeginVector(Builder, 2);
  if Parameters.ServerName <> '' then
    AddServerName(Builder, Parameters.ServerName);
  AddStatusRequest(Builder);
  AddSupportedGroups(Builder, Parameters);
  if OffersTls12 then
    AddPointFormats(Builder);
  AddSignatureAlgorithms(Builder);
  if Parameters.ApplicationProtocol <> '' then
    AddApplicationProtocol(Builder, Parameters.ApplicationProtocol);
  if OffersTls12 then
    AddEmptyExtension(Builder, ExtensionExtendedMasterSecret);
  AddSupportedVersions(Builder, Parameters);
  if Parameters.Cookie.Length > 0 then
    AddCookie(Builder, Parameters.Cookie);
  if OffersTls13 then
  begin
    if Parameters.AllowResumption then
      AddPskModes(Builder);
    AddKeyShares(Builder, Parameters);
  end;
  if OffersTls12 then
    AddRenegotiationInfo(Builder);
  if Parameters.Quic then
    AddQuicTransportParameters(Builder, Parameters);
  if OffersTls13 and (Length(Parameters.PskIdentity) > 0) then
    BindersOffset := AddPreSharedKey(Builder, Parameters) - Start;
  EndVector(Builder, Extensions, 2);
  EndVector(Builder, Body, 3);
end;

function SignatureSchemeWasOffered(Scheme: Word): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(OfferedSignatureSchemes) do
    if OfferedSignatureSchemes[Index] = Scheme then
      Exit(True);
  Result := False;
end;

end.
