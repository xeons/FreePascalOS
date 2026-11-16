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
  and KeyUpdate. Each takes the message body (after the 4-byte header)
  and returns TlsErrorNone or the error to fail the handshake with.

  Every length is checked against what is left; extensions may appear
  once each, and only those the client offered (RFC 8446 section 4.2):
  anything else is refused.
}
unit Tls.ServerMessages;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.ByteBuffers;

const
  MaximumServerCertificates = 16;

type
  TServerHello = record
    IsRetryRequest: Boolean;
    SessionIdEcho: TTlsByteRange;
    CipherSuite: Word;
    HasKeyShare: Boolean;
    KeyShareGroup: Word;
    { Empty in a HelloRetryRequest. }
    KeyShare: TTlsByteRange;
    HasCookie: Boolean;
    Cookie: TTlsByteRange;
  end;

  TServerCertificates = record
    Count: Integer;
    Entries: array[0..MaximumServerCertificates - 1] of TTlsByteRange;
  end;

function ParseServerHello(Body: PByte; Length: PtrUInt; out Hello: TServerHello): LongInt;
{ OfferedProtocol is the ALPN name the client offered (nil: none);
  SelectedProtocol is the server's choice (empty: none). }
function ParseEncryptedExtensions(Body: PByte; Length: PtrUInt; OfferedProtocol: PChar;
  out SelectedProtocol: TTlsByteRange): LongInt;
function ParseCertificateRequest(Body: PByte; Length: PtrUInt; out Context: TTlsByteRange): LongInt;
function ParseCertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates): LongInt;
function ParseCertificateVerify(Body: PByte; Length: PtrUInt; out Scheme: Word; out Signature: TTlsByteRange): LongInt;
function ParseNewSessionTicket(Body: PByte; Length: PtrUInt): LongInt;
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

function TextLength(Text: PChar): PtrUInt;
begin
  Result := 0;
  if Text <> nil then
    while Text[Result] <> #0 do
      Inc(Result);
end;

function ParseServerHelloExtensions(var Extensions: TTlsReader; var Hello: TServerHello;
  out SelectedVersion: Word): LongInt;
var
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Data: TTlsReader;
  Group: Word;
begin
  Seen.Count := 0;
  SelectedVersion := 0;
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
    else
      { pre_shared_key and anything else were not offered. }
      Exit(TlsErrorUnsupportedExtension);
    end;
  end;
  Result := TlsErrorNone;
end;

function ParseServerHello(Body: PByte; Length: PtrUInt; out Hello: TServerHello): LongInt;
var
  Reader, Extensions: TTlsReader;
  LegacyVersion: Word;
  Random: PByte;
  Compression: Byte;
  SelectedVersion: Word;
begin
  FillChar(Hello, SizeOf(Hello), 0);
  InitializeReader(Reader, Body, Length);
  if not ReadUInt16(Reader, LegacyVersion) or not ReadBytes(Reader, 32, Random) or
     not ReadVectorBytes(Reader, 1, Hello.SessionIdEcho) or not ReadUInt16(Reader, Hello.CipherSuite) or
     not ReadUInt8(Reader, Compression) then
    Exit(TlsErrorMalformedMessage);
  Hello.IsRetryRequest := CompareByte(Random^, HelloRetryRequestRandom[0], 32) = 0;
  { A server that did not pick TLS 1.3 sends no extensions, or no
    supported_versions. }
  if ReaderAtEnd(Reader) then
    Exit(TlsErrorProtocolVersion);
  if not ReadVector(Reader, 2, Extensions) or not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
  Result := ParseServerHelloExtensions(Extensions, Hello, SelectedVersion);
  if Result <> TlsErrorNone then
    Exit;
  if SelectedVersion = 0 then
    Exit(TlsErrorProtocolVersion);
  if (SelectedVersion <> VersionTls13) or (LegacyVersion <> VersionTls12) then
    Exit(TlsErrorIllegalParameter);
  if Compression <> 0 then
    Exit(TlsErrorIllegalParameter);
  { (A HelloRetryRequest may ask only for a cookie.) }
  if not Hello.HasKeyShare and not Hello.IsRetryRequest then
    Exit(TlsErrorMissingExtension);
  Result := TlsErrorNone;
end;

function ParseEncryptedExtensions(Body: PByte; Length: PtrUInt; OfferedProtocol: PChar;
  out SelectedProtocol: TTlsByteRange): LongInt;
var
  Reader, Extensions, Data, Names: TTlsReader;
  Seen: TSeenExtensions;
  ExtensionType: Word;
  Name: TTlsByteRange;
begin
  SelectedProtocol := ByteRange(nil, 0);
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
          if TextLength(OfferedProtocol) = 0 then
            Exit(TlsErrorUnsupportedExtension);
          { Exactly one name, which must be the one offered. }
          if not ReadVector(Data, 2, Names) or not ReaderAtEnd(Data) then
            Exit(TlsErrorMalformedMessage);
          if not ReadVectorBytes(Names, 1, Name) or (Name.Length = 0) or not ReaderAtEnd(Names) then
            Exit(TlsErrorMalformedMessage);
          if (Name.Length <> TextLength(OfferedProtocol)) or
             (CompareByte(Name.Data^, OfferedProtocol^, Name.Length) <> 0) then
            Exit(TlsErrorNoApplicationProtocol);
          SelectedProtocol := Name;
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

function ParseCertificateMessage(Body: PByte; Length: PtrUInt; out Certificates: TServerCertificates): LongInt;
var
  Reader, List, Extensions: TTlsReader;
  Context: TTlsByteRange;
  Entry: TTlsByteRange;
begin
  FillChar(Certificates, SizeOf(Certificates), 0);
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
    { status_request and signed_certificate_timestamp were not asked
      for, so no entry may carry extensions. }
    if not ReaderAtEnd(Extensions) then
      Exit(TlsErrorUnsupportedExtension);
    if Certificates.Count >= MaximumServerCertificates then
      Exit(TlsErrorCertificateChainTooLong);
    Certificates.Entries[Certificates.Count] := Entry;
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

function ParseNewSessionTicket(Body: PByte; Length: PtrUInt): LongInt;
var
  Reader, Extensions: TTlsReader;
  Fixed: PByte;
  Nonce, Ticket: TTlsByteRange;
begin
  InitializeReader(Reader, Body, Length);
  { ticket_lifetime, ticket_age_add, ticket_nonce, ticket, extensions }
  if not ReadBytes(Reader, 8, Fixed) or not ReadVectorBytes(Reader, 1, Nonce) or
     not ReadVectorBytes(Reader, 2, Ticket) or (Ticket.Length = 0) or not ReadVector(Reader, 2, Extensions) or
     not ReaderAtEnd(Reader) then
    Exit(TlsErrorMalformedMessage);
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
