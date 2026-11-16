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
  A TLS 1.3 client connection as an object, over any transport:

    Client := TTlsClientConnection.Create(Transport, Options);
    try
      if Client.Handshake <> TlsErrorNone then ... Client.DescribeError
      Client.WriteText(Request);
      Count := Client.Read(@Buffer, SizeOf(Buffer));   (0: closed)
      Client.Close;
    finally
      Client.Free;
    end;

  The same connection as Tls.Client's routines, which do the work; the
  object owns the connection and frees it. Creating one raises ETlsError
  for options it cannot use; reading and writing return TlsError codes
  as the routines do, since a program usually acts on which error it
  was (a certificate, a timeout).
}
unit Tls.ClientConnections;

{$mode objfpc}
{$H+}

interface

uses
  Tls.Connections,
  Tls.Transport;

type
  TTlsClientConnection = class
  private
    FConnection: PTlsConnection;
    function GetLastError: LongInt;
    function GetIgnoredCertificateError: LongInt;
    function GetCipherSuiteName: string;
    function GetSelectedProtocol: string;
    function GetClosedCleanly: Boolean;
  public
    constructor Create(constref Transport: TTlsTransport; constref Options: TTlsClientOptions);
    destructor Destroy; override;
    function Handshake: LongInt;
    { Bytes read, 0 at the end of the stream, or a TlsError code. }
    function Read(Buffer: Pointer; Length: PtrUInt): Int64;
    { Length, or a TlsError code. }
    function Write(Buffer: Pointer; Length: PtrUInt): Int64;
    function WriteText(const Text: string): Int64;
    { Sends close_notify (once). }
    function Close: LongInt;
    { "the certificate has expired (certificate: example.com)" }
    function DescribeError(Error: LongInt): string;
    property Connection: PTlsConnection read FConnection;
    property LastError: LongInt read GetLastError;
    { With VerifyCertificates off: what the check would have refused. }
    property IgnoredCertificateError: LongInt read GetIgnoredCertificateError;
    property CipherSuiteName: string read GetCipherSuiteName;
    { The ALPN protocol the server chose, or ''. }
    property SelectedProtocol: string read GetSelectedProtocol;
    { True when the stream ended with the server's close_notify. }
    property ClosedCleanly: Boolean read GetClosedCleanly;
  end;

implementation

uses
  Tls.Client,
  Tls.Errors;

constructor TTlsClientConnection.Create(constref Transport: TTlsTransport; constref Options: TTlsClientOptions);
var
  Error: LongInt;
begin
  inherited Create;
  Error := CreateTlsClient(Transport, Options, FConnection);
  if Error <> TlsErrorNone then
    raise ETlsError.CreateCode(Error);
end;

destructor TTlsClientConnection.Destroy;
begin
  FreeTlsClient(FConnection);
  inherited Destroy;
end;

function TTlsClientConnection.Handshake: LongInt;
begin
  Result := TlsHandshake(FConnection);
end;

function TTlsClientConnection.Read(Buffer: Pointer; Length: PtrUInt): Int64;
begin
  Result := TlsRead(FConnection, Buffer, Length);
end;

function TTlsClientConnection.Write(Buffer: Pointer; Length: PtrUInt): Int64;
begin
  Result := TlsWrite(FConnection, Buffer, Length);
end;

function TTlsClientConnection.WriteText(const Text: string): Int64;
begin
  Result := TlsWrite(FConnection, PChar(Text), System.Length(Text));
end;

function TTlsClientConnection.Close: LongInt;
begin
  Result := TlsClose(FConnection);
end;

function TTlsClientConnection.DescribeError(Error: LongInt): string;
begin
  Result := TlsErrorDescription(FConnection, Error);
end;

function TTlsClientConnection.GetLastError: LongInt;
begin
  Result := TlsLastError(FConnection);
end;

function TTlsClientConnection.GetIgnoredCertificateError: LongInt;
begin
  Result := TlsIgnoredCertificateError(FConnection);
end;

function TTlsClientConnection.GetCipherSuiteName: string;
begin
  Result := TlsCipherSuiteName(FConnection);
end;

function TTlsClientConnection.GetSelectedProtocol: string;
begin
  Result := TlsSelectedProtocol(FConnection);
end;

function TTlsClientConnection.GetClosedCleanly: Boolean;
begin
  Result := TlsClosedCleanly(FConnection);
end;

end.
