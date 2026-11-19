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

    ok <cipher suite> <bytes read> <closed cleanly: yes/no> <version>
       <group> <OCSP status: none/good/unknown> <resumed: yes/no>
    error <code> <message>

  With TInteropSettings.Connections 2 it connects twice, the second
  time with the ticket of the first (a line for each).
}
unit TlsTest.Interop;

{$mode objfpc}
{$H+}

interface

type
  TInteropSettings = record
    Port: Word;
    ServerName: string;
    TrustFile: string;
    CipherName: string;
    VerifyCertificates: Boolean;
    { 0: the default. }
    MaximumVersion: Word;
    { Comma-separated group names (x25519, secp256r1, secp384r1,
      X25519MLKEM768), or '' for the default. }
    Groups: string;
    { 1, or 2 to resume the first session in the second. }
    Connections: Integer;
  end;

{ Returns the exit code: 0 when every connection worked. }
function RunInteropClient(constref Settings: TInteropSettings): Integer;

implementation

uses
  Sockets,
  BaseUnix,
  SysUtils,
  DateUtils,
  Tls.CipherSuites,
  Tls.Client,
  Tls.Connections,
  Tls.Constants,
  Tls.Errors,
  Tls.KeyShares,
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

function GroupByName(const Name: string): Word;
begin
  if Name = 'x25519' then
    Result := GroupX25519
  else if Name = 'secp256r1' then
    Result := GroupSecp256r1
  else if Name = 'secp384r1' then
    Result := GroupSecp384r1
  else if Name = 'secp521r1' then
    Result := GroupSecp521r1
  else if Name = 'X25519MLKEM768' then
    Result := GroupX25519MlKem768
  else
    Result := 0;
end;

procedure ParseGroups(const Text: string; var List: TTlsGroupList);
var
  Names: TStringArray;
  Index: Integer;
begin
  List := Default(TTlsGroupList);
  if Text = '' then
    Exit;
  Names := Text.Split([',']);
  for Index := 0 to High(Names) do
    if List.Count < MaximumGroups then
    begin
      List.Groups[List.Count] := GroupByName(Names[Index]);
      Inc(List.Count);
    end;
end;

function StatusText(Connection: PTlsConnection): string;
begin
  case TlsCertificateStatus(Connection) of
    StatusGood: Result := 'good';
    StatusUnknown: Result := 'unknown';
  else
    Result := 'none';
  end;
end;

function YesNo(Value: Boolean): string;
begin
  if Value then
    Result := 'yes'
  else
    Result := 'no';
end;

{ One connection, a request and the answer read to the end. }
function ConnectOnce(constref Settings: TInteropSettings; Store: PTlsTrustStore): Integer;
var
  Socket: THostSocket;
  Address: TInetSockAddr;
  Transport: TTlsTransport;
  Options: TTlsClientOptions;
  Connection: PTlsConnection;
  Request: string;
  Error: LongInt;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Total: Int64;
begin
  Result := 1;
  Socket.Handle := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(Settings.Port);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if fpConnect(Socket.Handle, @Address, SizeOf(Address)) <> 0 then
  begin
    WriteLn('error connect cannot connect to port ', Settings.Port);
    CloseSocket(Socket.Handle);
    Exit;
  end;
  Transport.Context := @Socket;
  Transport.Send := @SendOnHostSocket;
  Transport.Receive := @ReceiveOnHostSocket;

  Options := Default(TTlsClientOptions);
  Options.ServerName := Settings.ServerName;
  Options.TrustStore := Store;
  Options.VerifyCertificates := Settings.VerifyCertificates;
  Options.VerificationTime := DateTimeToUnix(Now, False);
  Options.ApplicationProtocol := 'http/1.1';
  Options.MaximumVersion := Settings.MaximumVersion;
  ParseGroups(Settings.Groups, Options.Groups);
  if Settings.Connections > 1 then
    Options.SessionCacheKey := Settings.ServerName + ':' + IntToStr(Settings.Port);
  if Settings.CipherName <> '' then
  begin
    Options.CipherSuites.Count := 1;
    Options.CipherSuites.Identifiers[0] := CipherSuiteByName(Settings.CipherName);
  end;

  Error := CreateTlsClient(Transport, Options, Connection);
  if Error = TlsErrorNone then
    Error := TlsHandshake(Connection);
  if Error <> TlsErrorNone then
  begin
    WriteLn('error ', Error, ' ', TlsErrorDescription(Connection, Error));
    FreeTlsClient(Connection);
    CloseSocket(Socket.Handle);
    Exit;
  end;

  Request := 'GET / HTTP/1.0'#13#10'Host: ' + Settings.ServerName + #13#10#13#10;
  Count := TlsWrite(Connection, @Request[1], Length(Request));
  Total := 0;
  if Count >= 0 then
    repeat
      Count := TlsRead(Connection, @Buffer[0], SizeOf(Buffer));
      if Count > 0 then
        Total := Total + Count;
    until Count <= 0;
  if Count < 0 then
    WriteLn('error ', Count, ' ', TlsErrorDescription(Connection, Count))
  else
  begin
    WriteLn('ok ', TlsCipherSuiteName(Connection), ' ', Total, ' ', YesNo(TlsClosedCleanly(Connection)), ' ',
      TlsProtocolVersionName(Connection), ' ', TlsKeyExchangeGroupName(Connection), ' ', StatusText(Connection), ' ',
      YesNo(TlsSessionResumed(Connection)));
    if TlsIgnoredCertificateError(Connection) <> TlsErrorNone then
      WriteLn('ignored ', TlsErrorMessage(TlsIgnoredCertificateError(Connection)));
    Result := 0;
  end;
  TlsClose(Connection);
  FreeTlsClient(Connection);
  CloseSocket(Socket.Handle);
end;

function RunInteropClient(constref Settings: TInteropSettings): Integer;
var
  Store: PTlsTrustStore;
  Text: string;
  Round: Integer;
begin
  Result := 0;
  Store := CreateTrustStore;
  Text := ReadFileText(Settings.TrustFile);
  if Text <> '' then
    AddPemCertificates(Store, PChar(Text), Length(Text));
  for Round := 1 to Settings.Connections do
    if ConnectOnce(Settings, Store) <> 0 then
    begin
      Result := 1;
      Break;
    end;
  FreeTrustStore(Store);
end;

end.
end.
