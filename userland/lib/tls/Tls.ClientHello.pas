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
  The ClientHello (RFC 8446 section 4.1.2) of a TLS 1.3 client:
  legacy_version 1.2, a random, a 32-byte legacy session id (middlebox
  compatibility mode, appendix D.4), the cipher suites, no compression,
  and the extensions

    server_name                 the host, unless it is an IP address
    supported_groups            x25519
    signature_algorithms        ECDSA P-256/P-384, RSA-PSS, RSA PKCS#1
                                (the last only for certificates)
    supported_versions          TLS 1.3 only
    key_share                   an X25519 public key
    application_layer_protocol  when the program names one
    cookie                      the server's, after a HelloRetryRequest
}
unit Tls.ClientHello;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.ByteBuffers,
  Tls.CipherSuites;

type
  TClientHelloParameters = record
    Random: array[0..31] of Byte;
    SessionId: array[0..31] of Byte;
    CipherSuites: TCipherSuiteList;
    { Empty: no server_name. }
    ServerName: string;
    KeyShare: array[0..31] of Byte;
    { Empty: no cookie. }
    Cookie: TTlsByteRange;
    { Empty: no ALPN. }
    ApplicationProtocol: string;
  end;

const
  OfferedSignatureSchemes: array[0..10] of Word = (
    $0403, $0503, $0804, $0805, $0806, $0809, $080A, $080B, $0401, $0501, $0601);

{ Appends the whole handshake message, header included. }
procedure BuildClientHello(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
function SignatureSchemeWasOffered(Scheme: Word): Boolean;

implementation

uses
  Tls.Constants;

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

procedure AddSupportedGroups(var Builder: TTlsBuilder);
var
  Extension, List: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionSupportedGroups);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  AppendUInt16(Builder, GroupX25519);
  EndVector(Builder, List, 2);
  EndVector(Builder, Extension, 2);
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

procedure AddSupportedVersions(var Builder: TTlsBuilder);
var
  Extension, List: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionSupportedVersions);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 1);
  AppendUInt16(Builder, VersionTls13);
  EndVector(Builder, List, 1);
  EndVector(Builder, Extension, 2);
end;

procedure AddKeyShare(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Extension, List, Key: PtrUInt;
begin
  AppendUInt16(Builder, ExtensionKeyShare);
  Extension := BeginVector(Builder, 2);
  List := BeginVector(Builder, 2);
  AppendUInt16(Builder, GroupX25519);
  Key := BeginVector(Builder, 2);
  AppendBytes(Builder, @Parameters.KeyShare[0], 32);
  EndVector(Builder, Key, 2);
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

procedure BuildClientHello(var Builder: TTlsBuilder; constref Parameters: TClientHelloParameters);
var
  Body, Suites, Compression, Extensions, SessionId: PtrUInt;
  Index: Integer;
begin
  AppendByte(Builder, HandshakeClientHello);
  Body := BeginVector(Builder, 3);
  AppendUInt16(Builder, VersionTls12);
  AppendBytes(Builder, @Parameters.Random[0], 32);
  SessionId := BeginVector(Builder, 1);
  AppendBytes(Builder, @Parameters.SessionId[0], 32);
  EndVector(Builder, SessionId, 1);
  Suites := BeginVector(Builder, 2);
  for Index := 0 to Parameters.CipherSuites.Count - 1 do
    AppendUInt16(Builder, Parameters.CipherSuites.Identifiers[Index]);
  EndVector(Builder, Suites, 2);
  Compression := BeginVector(Builder, 1);
  AppendByte(Builder, 0);
  EndVector(Builder, Compression, 1);

  Extensions := BeginVector(Builder, 2);
  if Parameters.ServerName <> '' then
    AddServerName(Builder, Parameters.ServerName);
  AddSupportedGroups(Builder);
  AddSignatureAlgorithms(Builder);
  AddSupportedVersions(Builder);
  AddKeyShare(Builder, Parameters);
  if Parameters.ApplicationProtocol <> '' then
    AddApplicationProtocol(Builder, Parameters.ApplicationProtocol);
  if Parameters.Cookie.Length > 0 then
    AddCookie(Builder, Parameters.Cookie);
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
