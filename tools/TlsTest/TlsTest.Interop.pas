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
  The whole client (Tls.Client) against a real TLS server on the host:
  a TCP connection to 127.0.0.1, the handshake, an HTTP request and the
  answer read to the end. run-interop.sh starts OpenSSL's s_server with
  the test certificates and checks what this prints:

    ok <cipher suite> <bytes read> <closed cleanly: yes/no>
    error <code> <message>
}
unit TlsTest.Interop;

{$mode objfpc}
{$H+}

interface

{ Returns the exit code: 0 when the connection worked. }
function RunInteropClient(Port: Word; const ServerName, TrustFile, CipherName: string;
  VerifyCertificates: Boolean): Integer;

implementation

uses
  Sockets,
  BaseUnix,
  SysUtils,
  DateUtils,
  Tls.CipherSuites,
  Tls.Client,
  Tls.Connections,
  Tls.Errors,
  Tls.Transport,
  Tls.TrustStore;

type
  THostSocket = record
    Handle: LongInt;
  end;
  PHostSocket = ^THostSocket;

function SendOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Done: PtrUInt;
  Sent: ssize_t;
begin
  Done := 0;
  while Done < Length do
  begin
    Sent := fpSend(PHostSocket(Context)^.Handle, Buffer + Done, Length - Done, 0);
    if Sent <= 0 then
      Exit(TlsErrorTransportFailed);
    Done := Done + PtrUInt(Sent);
  end;
  Result := Length;
end;

function ReceiveOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Received: ssize_t;
begin
  Received := fpRecv(PHostSocket(Context)^.Handle, Buffer, Length, 0);
  if Received < 0 then
    Exit(TlsErrorTransportFailed);
  Result := Received;
end;

function ReadFileText(const Path: string): string;
var
  Source: File of Byte;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  Assign(Source, Path);
  Reset(Source);
  SetLength(Result, FileSize(Source));
  if Length(Result) > 0 then
    BlockRead(Source, Result[1], Length(Result));
  Close(Source);
end;

function RunInteropClient(Port: Word; const ServerName, TrustFile, CipherName: string;
  VerifyCertificates: Boolean): Integer;
var
  Socket: THostSocket;
  Address: TInetSockAddr;
  Transport: TTlsTransport;
  Options: TTlsClientOptions;
  Connection: PTlsConnection;
  Store: PTlsTrustStore;
  Text, Request: string;
  Error: LongInt;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Total: Int64;
  Clean: string;
begin
  Result := 1;
  Store := CreateTrustStore;
  Text := ReadFileText(TrustFile);
  if Text <> '' then
    AddPemCertificates(Store, PChar(Text), Length(Text));

  Socket.Handle := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(Port);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if fpConnect(Socket.Handle, @Address, SizeOf(Address)) <> 0 then
  begin
    WriteLn('error connect cannot connect to port ', Port);
    FreeTrustStore(Store);
    Exit;
  end;
  Transport.Context := @Socket;
  Transport.Send := @SendOnHostSocket;
  Transport.Receive := @ReceiveOnHostSocket;

  FillChar(Options, SizeOf(Options), 0);
  Options.ServerName := PChar(ServerName);
  Options.TrustStore := Store;
  Options.VerifyCertificates := VerifyCertificates;
  Options.VerificationTime := DateTimeToUnix(Now, False);
  Options.ApplicationProtocol := 'http/1.1';
  if CipherName <> '' then
  begin
    Options.CipherSuites.Count := 1;
    Options.CipherSuites.Identifiers[0] := CipherSuiteByName(CipherName);
  end;

  Error := CreateTlsClient(Transport, Options, Connection);
  if Error = TlsErrorNone then
    Error := TlsHandshake(Connection);
  if Error <> TlsErrorNone then
  begin
    WriteLn('error ', Error, ' ', TlsErrorDescription(Connection, Error));
    FreeTlsClient(Connection);
    CloseSocket(Socket.Handle);
    FreeTrustStore(Store);
    Exit;
  end;

  Request := 'GET / HTTP/1.0'#13#10'Host: ' + ServerName + #13#10#13#10;
  Count := TlsWrite(Connection, @Request[1], Length(Request));
  Total := 0;
  if Count >= 0 then
    repeat
      Count := TlsRead(Connection, @Buffer[0], SizeOf(Buffer));
      if Count > 0 then
        Total := Total + Count;
    until Count <= 0;
  if Count < 0 then
  begin
    WriteLn('error ', Count, ' ', TlsErrorDescription(Connection, Count));
  end
  else
  begin
    if TlsClosedCleanly(Connection) then
      Clean := 'yes'
    else
      Clean := 'no';
    WriteLn('ok ', TlsCipherSuiteName(Connection), ' ', Total, ' ', Clean);
    if TlsIgnoredCertificateError(Connection) <> TlsErrorNone then
      WriteLn('ignored ', TlsErrorMessage(TlsIgnoredCertificateError(Connection)));
    Result := 0;
  end;
  TlsClose(Connection);
  FreeTlsClient(Connection);
  CloseSocket(Socket.Handle);
  FreeTrustStore(Store);
end;

end.
