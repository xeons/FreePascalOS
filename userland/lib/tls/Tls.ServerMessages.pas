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
  Reading the handshake messages a TLS 1.3 server sends (RFC 8446
  section 4): ServerHello and HelloRetryRequest, EncryptedExtensions,
  CertificateRequest, Certificate, CertificateVerify, NewSessionTicket
  and KeyUpdate. A ServerHello may also choose TLS 1.2 (no
  supported_versions): its TLS 1.2 extensions are read here too, and
  the rest of TLS 1.2's messages in Tls.ServerMessages12. Each takes the message body (after the 4-byte header)
  and returns TlsErrorNone or the error to fail the handshake with.

  Every length is checked against what is left; extensions may appear
  once each, and only those the client offered (RFC 8446 section 4.2):
  anything else is refused.
}
unit Tls.ServerMessages;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.ByteBuffers;

const
  MaximumServerCertificates = 16;

type
  TServerHello = record
    { VersionTls13 or VersionTls12. }
    Version: Word;
    Random: PByte;
    IsRetryRequest: Boolean;
    SessionIdEcho: TTlsByteRange;
    CipherSuite: Word;
    HasKeyShare: Boolean;
    KeyShareGroup: Word;
    { Empty in a HelloRetryRequest. }
    KeyShare: TTlsByteRange;
    HasCookie: Boolean;
    Cookie: TTlsByteRange;
    { TLS 1.3: the server took the offered PSK (its index). }
    HasPreSharedKey: Boolean;
    SelectedIdentity: Word;
    { TLS 1.2's extensions. }
    HasExtendedMasterSecret: Boolean;
    HasRenegotiationInfo: Boolean;
    StatusRequestAcknowledged: Boolean;
    SelectedProtocol: TTlsByteRange;
  end;

  TServerCertificates = record
    Count: Integer;
    Entries: array of TTlsByteRange;
  end;

{ OfferedProtocol is the ALPN name offered (empty: none). }
function ParseServerHello(Body: PByte; Length: PtrUInt; const OfferedProtocol: string;
  out Hello: TServerHello): LongInt;
{ An ALPN extension's data from a server: exactly the one name offered. }
function ParseSelectedProtocol(var Data: TTlsReader; const Offered: string; out Selected: TTlsByteRange): LongInt;
{ CertificateStatus (RFC 6066 section 8): an OCSP response. }
function ParseCertificateStatusBody(var Reader: TTlsReader; out Response: TTlsByteRange): LongInt;
{ OfferedProtocol is the ALPN name the client offered (nil: none);
  SelectedProtocol is the server's choice (empty: none). }
function ParseEncryptedExtensions(Body: PByte; Length: PtrUInt; OfferedProtocol: PChar;
  out SelectedProtocol: TTlsByteRange): LongInt;
function ParseCertificateRequest(Body: PByte; Length: PtrUInt; out Context: TTlsByteRange): LongInt;
{ Staple is the OCSP response stapled to the server's certificate
  (status_request on the first entry), or empty. }
function ParseCertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates;
  out Staple: TTlsByteRange): LongInt;
function ParseCertificateVerify(Body: PByte; Length: PtrUInt; out Scheme: Word; out Signature: TTlsByteRange): LongInt;
function ParseNewSessionTicket(Body: PByte; Length: PtrUInt; out Lifetime, AgeAdd: LongWord;
  out Nonce, Ticket: TTlsByteRange): LongInt;
function ParseKeyUpdate(Body: PByte; Length: PtrUInt; out UpdateRequested: Boolean): LongInt;

implementation

uses
  Tls.Constants,
  Tls.Errors;

const
  MaximumExtensionsSeen = 32;

type
  TSeenExtensions = record
    Count: Integer;
    Types: array[0..MaximumExtensionsSeen - 1] of Word;
  end;

{ False for a second extension of the same type. }
function NoteExtension(var Seen: TSeenExtensions; ExtensionType: Word): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Seen.Count - 1 do
    if Seen.Types[Index] = ExtensionType then
      Exit(False);
  if Seen.Count >= MaximumExtensionsSeen then
    Exit(False);
  Seen.Types[Seen.Count] := ExtensionType;
  Inc(Seen.Count);
  Result := True;
end;

function ParseSelectedProtocol(var Data: TTlsReader; const Offered: string; out Selected: TTlsByteRange): LongInt;
var
  Names: TTlsReader;
  Name: TTlsByteRange;
begin
  Selected := ByteRange(nil, 0);
  if Offered = '' then
    Exit(TlsErrorUnsupportedExtension);
  { Exactly one name, which must be the one offered. }
  if not ReadVector(Data, 2, Names) or not ReaderAtEnd(Data) then
    Exit(TlsErrorMalformedMessage);
  if not ReadVectorBytes(Names, 1, Name) or (Name.Length = 0) or not ReaderAtEnd(Names) then
    Exit(TlsErrorMalformedMessage);
  if (Name.Length <> PtrUInt(System.Length(Offered))) or (CompareByte(Name.Data^, Offered[1], Name.Length) <> 0) then
    Exit(TlsErrorNoApplicationProtocol);
  Selected := Name;
  Result := TlsErrorNone;
end;

function ParseCertificateStatusBody(var Reader: TTlsReader; out Response: TTlsByteRange): LongInt;
var
  StatusType: Byte;
begin
  Response := ByteRange(nil, 0);
  if not ReadUInt8(Reader, StatusType) or (StatusType <> CertificateStatusOcsp) or
     not ReadVectorBytes(Reader, 3, Response) or (Response.Length = 0) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

function ParseTls13HelloExtensions(var Extensions: TTlsReader; var Hello: TServerHello): LongInt;
var
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Data: TTlsReader;
  Group: Word;
  SelectedVersion: Word;
begin
  Seen.Count := 0;
  while not ReaderAtEnd(Extensions) do
  begin
    if not ReadUInt16(Extensions, ExtensionType) or not ReadVector(Extensions, 2, Data) then
      Exit(TlsErrorMalformedMessage);
    if not NoteExtension(Seen, ExtensionType) then
      Exit(TlsErrorIllegalParameter);
    case ExtensionType of
      ExtensionSupportedVersions:
        if not ReadUInt16(Data, SelectedVersion) or not ReaderAtEnd(Data) then
          Exit(TlsErrorMalformedMessage);
      ExtensionKeyShare:
        begin
          if not ReadUInt16(Data, Group) then
            Exit(TlsErrorMalformedMessage);
          Hello.HasKeyShare := True;
          Hello.KeyShareGroup := Group;
          { A HelloRetryRequest names only the group. }
          if not Hello.IsRetryRequest then
          begin
            if not ReadVectorBytes(Data, 2, Hello.KeyShare) or (Hello.KeyShare.Length = 0) then
              Exit(TlsErrorMalformedMessage);
          end;
          if not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
        end;
      ExtensionCookie:
        begin
          if not Hello.IsRetryRequest then
            Exit(TlsErrorUnsupportedExtension);
          if not ReadVectorBytes(Data, 2, Hello.Cookie) or (Hello.Cookie.Length = 0) or not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          Hello.HasCookie := True;
        end;
      ExtensionPreSharedKey:
        begin
          if Hello.IsRetryRequest then
            Exit(TlsErrorUnsupportedExtension);
          if not ReadUInt16(Data, Hello.SelectedIdentity) or not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          Hello.HasPreSharedKey := True;
        end;
    else
      Exit(TlsErrorUnsupportedExtension);
    end;
  end;
  Result := TlsErrorNone;
end;

function ParseTls12HelloExtensions(var Extensions: TTlsReader; const OfferedProtocol: string;
  var Hello: TServerHello): LongInt;
var
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Data, Formats: TTlsReader;
  Format: Byte;
  Renegotiated: TTlsByteRange;
  Uncompressed: Boolean;
begin
  Seen.Count := 0;
  while not ReaderAtEnd(Extensions) do
  begin
    if not ReadUInt16(Extensions, ExtensionType) or not ReadVector(Extensions, 2, Data) then
      Exit(TlsErrorMalformedMessage);
    if not NoteExtension(Seen, ExtensionType) then
      Exit(TlsErrorIllegalParameter);
    case ExtensionType of
      ExtensionServerName, ExtensionExtendedMasterSecret, ExtensionStatusRequest:
        begin
          if not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          if ExtensionType = ExtensionExtendedMasterSecret then
            Hello.HasExtendedMasterSecret := True
          else if ExtensionType = ExtensionStatusRequest then
            Hello.StatusRequestAcknowledged := True;
        end;
      ExtensionRenegotiationInfo:
        begin
          { A first handshake: renegotiated_connection is empty. }
          if not ReadVectorBytes(Data, 1, Renegotiated) or not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          if Renegotiated.Length <> 0 then
            Exit(TlsErrorHandshakeFailure);
          Hello.HasRenegotiationInfo := True;
        end;
      ExtensionEcPointFormats:
        begin
          if not ReadVector(Data, 1, Formats) or not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          Uncompressed := False;
          while ReadUInt8(Formats, Format) do
            if Format = PointFormatUncompressed then
              Uncompressed := True;
          if not Uncompressed then
            Exit(TlsErrorIllegalParameter);
        end;
      ExtensionApplicationLayerProtocol:
        begin
          Result := ParseSelectedProtocol(Data, OfferedProtocol, Hello.SelectedProtocol);
          if Result <> TlsErrorNone then
            Exit;
        end;
    else
      { session_ticket, encrypt_then_mac and the rest were not offered. }
      Exit(TlsErrorUnsupportedExtension);
    end;
  end;
  Result := TlsErrorNone;
end;

{ supported_versions' value (TLS 1.3's mark): 0 when absent. }
function SelectedVersionOf(Extensions: TTlsReader; out Present: Boolean): Word;
var
  ExtensionType: Word;
  Data: TTlsReader;
begin
  Result := 0;
  Present := False;
  while ReadUInt16(Extensions, ExtensionType) and ReadVector(Extensions, 2, Data) do
    if ExtensionType = ExtensionSupportedVersions then
    begin
      Present := True;
      if not ReadUInt16(Data, Result) then
        Result := 0;
      Exit;
    end;
end;

function ParseServerHello(Body: PByte; Length: PtrUInt; const OfferedProtocol: string;
  out Hello: TServerHello): LongInt;
var
  Reader, Extensions: TTlsReader;
  LegacyVersion: Word;
  Compression: Byte;
  HasVersions: Boolean;
  SelectedVersion: Word;
begin
  FillChar(Hello, SizeOf(Hello), 0);
  InitializeReader(Reader, Body, Length);
  if not ReadUInt16(Reader, LegacyVersion) or not ReadBytes(Reader, 32, Hello.Random) or
     not ReadVectorBytes(Reader, 1, Hello.SessionIdEcho) or not ReadUInt16(Reader, Hello.CipherSuite) or
     not ReadUInt8(Reader, Compression) then
    Exit(TlsErrorMalformedMessage);
  Hello.IsRetryRequest := CompareByte(Hello.Random^, HelloRetryRequestRandom[0], 32) = 0;
  if ReaderAtEnd(Reader) then
    InitializeReader(Extensions, nil, 0)
  else if not ReadVector(Reader, 2, Extensions) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);

  SelectedVersion := SelectedVersionOf(Extensions, HasVersions);
  if not HasVersions then
  begin
    { TLS 1.2 or older. }
    if Hello.IsRetryRequest or (LegacyVersion <> VersionTls12) then
      Exit(TlsErrorProtocolVersion);
    if Compression <> 0 then
      Exit(TlsErrorIllegalParameter);
    Hello.Version := VersionTls12;
    Exit(ParseTls12HelloExtensions(Extensions, OfferedProtocol, Hello));
  end;
  if (SelectedVersion <> VersionTls13) or (LegacyVersion <> VersionTls12) or (Compression <> 0) then
    Exit(TlsErrorIllegalParameter);
  Hello.Version := VersionTls13;
  Result := ParseTls13HelloExtensions(Extensions, Hello);
  if Result <> TlsErrorNone then
    Exit;
  { (A HelloRetryRequest may ask only for a cookie.) }
  if not Hello.HasKeyShare and not Hello.IsRetryRequest then
    Exit(TlsErrorMissingExtension);
  Result := TlsErrorNone;
end;

function ParseEncryptedExtensions(Body: PByte; Length: PtrUInt; OfferedProtocol: PChar;
  out SelectedProtocol: TTlsByteRange): LongInt;
var
  Reader, Extensions, Data: TTlsReader;
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Offered: string;
begin
  SelectedProtocol := ByteRange(nil, 0);
  Offered := string(OfferedProtocol);
  InitializeReader(Reader, Body, Length);
  if not ReadVector(Reader, 2, Extensions) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  Seen.Count := 0;
  while not ReaderAtEnd(Extensions) do
  begin
    if not ReadUInt16(Extensions, ExtensionType) or not ReadVector(Extensions, 2, Data) then
      Exit(TlsErrorMalformedMessage);
    if not NoteExtension(Seen, ExtensionType) then
      Exit(TlsErrorIllegalParameter);
    case ExtensionType of
      ExtensionServerName:
        { The server used the name: an empty extension. }
        if not ReaderAtEnd(Data) then
          Exit(TlsErrorMalformedMessage);
      ExtensionSupportedGroups:
        { The server's preferences, for later connections: ignored. }
        ;
      ExtensionApplicationLayerProtocol:
        begin
          Result := ParseSelectedProtocol(Data, Offered, SelectedProtocol);
          if Result <> TlsErrorNone then
            Exit;
        end;
    else
      Exit(TlsErrorUnsupportedExtension);
    end;
  end;
  Result := TlsErrorNone;
end;

function ParseCertificateRequest(Body: PByte; Length: PtrUInt; out Context: TTlsByteRange): LongInt;
var
  Reader, Extensions: TTlsReader;
begin
  InitializeReader(Reader, Body, Length);
  if not ReadVectorBytes(Reader, 1, Context) or not ReadVector(Reader, 2, Extensions) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  { The extensions (signature_algorithms at least) only matter to a
    client that has a certificate; this one answers with none. }
  if ReaderRemaining(Extensions) < 2 then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

{ The extensions of a CertificateEntry: status_request (read on the
  first entry, passed over on the others); signed_certificate_timestamp
  was not asked for. }
function ParseEntryExtensions(var Extensions: TTlsReader; IsFirst: Boolean; var Staple: TTlsByteRange): LongInt;
var
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Data: TTlsReader;
begin
  Seen.Count := 0;
  while not ReaderAtEnd(Extensions) do
  begin
    if not ReadUInt16(Extensions, ExtensionType) or not ReadVector(Extensions, 2, Data) then
      Exit(TlsErrorMalformedMessage);
    if not NoteExtension(Seen, ExtensionType) then
      Exit(TlsErrorIllegalParameter);
    if ExtensionType <> ExtensionStatusRequest then
      Exit(TlsErrorUnsupportedExtension);
    if IsFirst then
    begin
      Result := ParseCertificateStatusBody(Data, Staple);
      if Result <> TlsErrorNone then
        Exit;
    end;
  end;
  Result := TlsErrorNone;
end;

function ParseCertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates;
  out Staple: TTlsByteRange): LongInt;
var
  Reader, List, Extensions: TTlsReader;
  Context: TTlsByteRange;
  Entry: TTlsByteRange;
begin
  Certificates := Default(TServerCertificates);
  Staple := ByteRange(nil, 0);
  InitializeReader(Reader, Body, Length);
  if not ReadVectorBytes(Reader, 1, Context) or not ReadVector(Reader, 3, List) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  { The server's certificate is not in answer to a request: no context. }
  if Context.Length <> 0 then
    Exit(TlsErrorIllegalParameter);
  while not ReaderAtEnd(List) do
  begin
    if not ReadVectorBytes(List, 3, Entry) or (Entry.Length = 0) or not ReadVector(List, 2, Extensions) then
      Exit(TlsErrorMalformedMessage);
    Result := ParseEntryExtensions(Extensions, Certificates.Count = 0, Staple);
    if Result <> TlsErrorNone then
      Exit;
    if Certificates.Count >= MaximumServerCertificates then
      Exit(TlsErrorCertificateChainTooLong);
    Insert(Entry, Certificates.Entries, Certificates.Count);
    Inc(Certificates.Count);
  end;
  if Certificates.Count = 0 then
    Exit(TlsErrorCertificateMissing);
  Result := TlsErrorNone;
end;

function ParseCertificateVerify(Body: PByte; Length: PtrUInt; out Scheme: Word; out Signature: TTlsByteRange): LongInt;
var
  Reader: TTlsReader;
begin
  Signature := ByteRange(nil, 0);
  InitializeReader(Reader, Body, Length);
  if not ReadUInt16(Reader, Scheme) or not ReadVectorBytes(Reader, 2, Signature) or not ReaderAtEnd(Reader) or
     (Signature.Length = 0) then
    Exit(TlsErrorMalformedMessage);
  Result := TlsErrorNone;
end;

function ParseNewSessionTicket(Body: PByte; Length: PtrUInt; out Lifetime, AgeAdd: LongWord;
  out Nonce, Ticket: TTlsByteRange): LongInt;
var
  Reader, Extensions: TTlsReader;
  HighPart, LowPart: Word;
begin
  Lifetime := 0;
  AgeAdd := 0;
  Nonce := ByteRange(nil, 0);
  Ticket := ByteRange(nil, 0);
  InitializeReader(Reader, Body, Length);
  { ticket_lifetime, ticket_age_add, ticket_nonce, ticket, extensions
    (early_data and others: nothing to act on without early data). }
  if not ReadUInt16(Reader, HighPart) or not ReadUInt16(Reader, LowPart) then
    Exit(TlsErrorMalformedMessage);
  Lifetime := (LongWord(HighPart) shl 16) or LowPart;
  if not ReadUInt16(Reader, HighPart) or not ReadUInt16(Reader, LowPart) then
    Exit(TlsErrorMalformedMessage);
  AgeAdd := (LongWord(HighPart) shl 16) or LowPart;
  if not ReadVectorBytes(Reader, 1, Nonce) or not ReadVectorBytes(Reader, 2, Ticket) or (Ticket.Length = 0) or
     not ReadVector(Reader, 2, Extensions) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  { More than seven days is not allowed (RFC 8446 section 4.6.1). }
  if Lifetime > 7 * 24 * 60 * 60 then
    Exit(TlsErrorIllegalParameter);
  Result := TlsErrorNone;
end;

function ParseKeyUpdate(Body: PByte; Length: PtrUInt; out UpdateRequested: Boolean): LongInt;
begin
  UpdateRequested := False;
  if Length <> 1 then
    Exit(TlsErrorMalformedMessage);
  if Body[0] > 1 then
    Exit(TlsErrorIllegalParameter);
  UpdateRequested := Body[0] = 1;
  Result := TlsErrorNone;
end;

end.
