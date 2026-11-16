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
  wget's connection to a server: the host looked up (Sys.HostNames,
  numeric addresses without DNS), a TCP connection made within the
  timeout, and for https a TLS session over it (libtls, Tls.Sessions).
  Reads go through a buffer, so the response head can be looked for and
  what follows it handed to the body.
}
unit Wget.Connections;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.InternetAddresses,
  Tls.CipherSuites,
  Tls.Sessions,
  Wget.Urls;

const
  ConnectionBufferSize = 16 * 1024;

type
  TConnectionSettings = record
    { 0: no limit. }
    TimeoutMilliseconds: Int64;
    VerifyCertificates: Boolean;
    { nil: the system's roots. }
    TrustFile: PChar;
    CipherSuites: TCipherSuiteList;
    Quiet: Boolean;
  end;

  TConnectionFailure = (FailureNone, FailureLookUp, FailureConnect, FailureTimeout, FailureTls,
    FailureCertificate, FailureTransfer);

  TConnection = record
    Socket: Int64;
    Session: PTlsSession;
    UsesTls: Boolean;
    TimeoutMilliseconds: Int64;
    Address: TInternetAddress;
    Buffer: array[0..ConnectionBufferSize - 1] of Byte;
    BufferStart, BufferEnd: PtrUInt;
    Failure: TConnectionFailure;
    { A system error code, or a TLS error code, of the failure. }
    ErrorCode: LongInt;
    ErrorText: array[0..511] of Char;
  end;

{ Looks the host up, connects and (https) runs the TLS handshake,
  telling the user what it does unless quiet. On failure Failure and
  ErrorText say why. }
function OpenConnection(var Connection: TConnection; constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
procedure CloseConnection(var Connection: TConnection);
function SendToConnection(var Connection: TConnection; Data: Pointer; Length: PtrUInt): Boolean;
{ Bytes read (from the buffer first), 0 at the end, -1 on failure. }
function ReceiveFromConnection(var Connection: TConnection; Buffer: Pointer; Length: PtrUInt): Int64;
{ Reads more into the buffer (moving what is there to the front); the
  same results. }
function FillConnectionBuffer(var Connection: TConnection): Int64;
procedure ConsumeConnectionBuffer(var Connection: TConnection; Count: PtrUInt);

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Format,
  Sys.HostNames,
  Sys.Sockets,
  Sys.Streams,
  Tls.Client,
  Tls.Errors;

procedure SetFailure(var Connection: TConnection; Failure: TConnectionFailure; Code: LongInt; Text: PChar);
var
  Index: Integer;
begin
  Connection.Failure := Failure;
  Connection.ErrorCode := Code;
  Index := 0;
  while (Text[Index] <> #0) and (Index < High(Connection.ErrorText)) do
  begin
    Connection.ErrorText[Index] := Text[Index];
    Inc(Index);
  end;
  Connection.ErrorText[Index] := #0;
end;

{ A non-blocking connect, waited for at most the timeout. }
function ConnectWithTimeout(var Connection: TConnection; constref Target: TAbiSocketAddress): LongInt;
var
  Waited: Int64;
  Pending: Int64;
  Timeout: Int64;
begin
  Result := ConnectSocket(Connection.Socket, Target);
  if Result = ErrorInProgress then
  begin
    Timeout := Connection.TimeoutMilliseconds;
    if Timeout <= 0 then
      Timeout := InfiniteWait;
    Waited := WaitForSocket(Connection.Socket, SocketWritable, Timeout);
    if Waited < 0 then
      Exit(ErrorCodeOf(Waited));
    Result := GetSocketOption(Connection.Socket, SocketOptionError, Pending);
    if Result = ErrorNone then
      Result := LongInt(Pending);
  end;
  if Result = ErrorNone then
    SetSocketOption(Connection.Socket, SocketOptionNonBlocking, 0);
end;

function OpenTls(var Connection: TConnection; constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
var
  Options: TTlsSessionOptions;
  Error: LongInt;
  Message: array[0..383] of Char;
  Ignored: LongInt;
begin
  InitializeTlsSessionOptions(Options);
  Options.ServerName := @Url.Host[0];
  Options.VerifyCertificates := Settings.VerifyCertificates;
  Options.TrustFile := Settings.TrustFile;
  Options.TimeoutMilliseconds := Settings.TimeoutMilliseconds;
  Options.ApplicationProtocol := 'http/1.1';
  Options.CipherSuites := Settings.CipherSuites;
  Error := OpenTlsSession(Connection.Socket, Options, Connection.Session);
  if Error <> TlsErrorNone then
  begin
    DescribeTlsSessionError(Connection.Session, Error, @Message[0], SizeOf(Message));
    if TlsErrorIsCertificateError(Error) then
      SetFailure(Connection, FailureCertificate, Error, @Message[0])
    else if Error = TlsErrorTimedOut then
      SetFailure(Connection, FailureTimeout, Error, @Message[0])
    else
      SetFailure(Connection, FailureTls, Error, @Message[0]);
    Exit(False);
  end;
  Ignored := TlsIgnoredCertificateError(Connection.Session^.Connection);
  if (Ignored <> TlsErrorNone) and not Settings.Quiet then
  begin
    DescribeTlsSessionError(Connection.Session, Ignored, @Message[0], SizeOf(Message));
    WriteFormatted(StandardError, 'WARNING: cannot verify %s''s certificate: %s.'#10,
      [ArgumentText(@Url.Host[0]), ArgumentText(@Message[0])]);
  end;
  Result := True;
end;

function OpenConnection(var Connection: TConnection; constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
var
  Error: LongInt;
  Target: TAbiSocketAddress;
  AddressText: array[0..SocketAddressTextCapacity - 1] of Char;
  Numeric: TInternetAddress;
begin
  FillChar(Connection, SizeOf(Connection), 0);
  Connection.Socket := -1;
  Connection.UsesTls := Url.Scheme = SchemeHttps;
  Connection.TimeoutMilliseconds := Settings.TimeoutMilliseconds;
  Result := False;

  if not ParseIpv4Address(@Url.Host[0], Numeric) and not Settings.Quiet then
    WriteFormatted(StandardError, 'Resolving %s... ', [ArgumentText(@Url.Host[0])]);
  Error := LookUpHost(@Url.Host[0], Connection.Address);
  if Error <> ErrorNone then
  begin
    if not ParseIpv4Address(@Url.Host[0], Numeric) and not Settings.Quiet then
      WriteFormatted(StandardError, 'failed: %s.'#10, [ArgumentText(ErrorMessage(Error))]);
    SetFailure(Connection, FailureLookUp, Error, 'unable to resolve host address');
    Exit;
  end;
  FormatInternetAddress(Connection.Address, @AddressText[0], SizeOf(AddressText));
  if not Settings.Quiet then
  begin
    if not ParseIpv4Address(@Url.Host[0], Numeric) then
      WriteFormatted(StandardError, '%s'#10, [ArgumentText(@AddressText[0])]);
    WriteFormatted(StandardError, 'Connecting to %s|%s|:%d... ', [ArgumentText(@Url.Host[0]),
      ArgumentText(@AddressText[0]), ArgumentNumber(Url.Port)]);
  end;

  Connection.Socket := CreateSocket(AddressFamilyIPv4, SocketKindStream or SocketKindNonBlocking, ProtocolDefault);
  if Connection.Socket < 0 then
  begin
    Error := ErrorCodeOf(Connection.Socket);
    if not Settings.Quiet then
      WriteFormatted(StandardError, 'failed: %s.'#10, [ArgumentText(ErrorMessage(Error))]);
    SetFailure(Connection, FailureConnect, Error, ErrorMessage(Error));
    Exit;
  end;
  Target := MakeSocketAddress(Connection.Address, Url.Port);
  Error := ConnectWithTimeout(Connection, Target);
  if Error <> ErrorNone then
  begin
    if not Settings.Quiet then
      WriteFormatted(StandardError, 'failed: %s.'#10, [ArgumentText(ErrorMessage(Error))]);
    if Error = ErrorTimedOut then
      SetFailure(Connection, FailureTimeout, Error, ErrorMessage(Error))
    else
      SetFailure(Connection, FailureConnect, Error, ErrorMessage(Error));
    CloseConnection(Connection);
    Exit;
  end;
  if not Settings.Quiet then
    WriteLine(StandardError, 'connected.');

  if Connection.UsesTls and not OpenTls(Connection, Url, Settings) then
  begin
    CloseConnection(Connection);
    Exit;
  end;
  Result := True;
end;

procedure CloseConnection(var Connection: TConnection);
begin
  if Connection.Session <> nil then
  begin
    CloseTlsSession(Connection.Session);
    FreeTlsSession(Connection.Session);
  end;
  if Connection.Socket >= 0 then
    CloseSocket(Connection.Socket);
  Connection.Socket := -1;
end;

function SendToConnection(var Connection: TConnection; Data: Pointer; Length: PtrUInt): Boolean;
var
  Error: LongInt;
begin
  if Connection.UsesTls then
  begin
    Result := WriteTlsSession(Connection.Session, Data, Length) = Int64(Length);
    if not Result then
      SetFailure(Connection, FailureTransfer, TlsErrorTransportFailed, 'the TLS connection failed');
    Exit;
  end;
  Error := SendAll(Connection.Socket, Data, Length);
  Result := Error = ErrorNone;
  if not Result then
    SetFailure(Connection, FailureTransfer, Error, ErrorMessage(Error));
end;

{ Straight from the socket or the TLS session. }
function ReceiveRaw(var Connection: TConnection; Buffer: Pointer; Length: PtrUInt): Int64;
var
  Waited: Int64;
  Message: array[0..383] of Char;
begin
  if Connection.UsesTls then
  begin
    Result := ReadTlsSession(Connection.Session, Buffer, Length);
    if Result < 0 then
    begin
      DescribeTlsSessionError(Connection.Session, LongInt(Result), @Message[0], SizeOf(Message));
      if Result = TlsErrorTimedOut then
        SetFailure(Connection, FailureTimeout, LongInt(Result), 'Read error (Connection timed out)')
      else
        SetFailure(Connection, FailureTransfer, LongInt(Result), @Message[0]);
      Result := -1;
    end;
    Exit;
  end;
  if Connection.TimeoutMilliseconds > 0 then
  begin
    Waited := WaitForSocket(Connection.Socket, SocketReadable, Connection.TimeoutMilliseconds);
    if Waited < 0 then
    begin
      if ErrorCodeOf(Waited) = ErrorTimedOut then
        SetFailure(Connection, FailureTimeout, ErrorTimedOut, 'Read error (Connection timed out)')
      else
        SetFailure(Connection, FailureTransfer, ErrorCodeOf(Waited), ErrorMessage(ErrorCodeOf(Waited)));
      Exit(-1);
    end;
  end;
  Result := ReceiveOnSocket(Connection.Socket, Buffer, Length, 0);
  if Result < 0 then
  begin
    SetFailure(Connection, FailureTransfer, ErrorCodeOf(Result), ErrorMessage(ErrorCodeOf(Result)));
    Result := -1;
  end;
end;

function FillConnectionBuffer(var Connection: TConnection): Int64;
begin
  if Connection.BufferStart > 0 then
  begin
    if Connection.BufferEnd > Connection.BufferStart then
      Move(Connection.Buffer[Connection.BufferStart], Connection.Buffer[0],
        Connection.BufferEnd - Connection.BufferStart);
    Connection.BufferEnd := Connection.BufferEnd - Connection.BufferStart;
    Connection.BufferStart := 0;
  end;
  if Connection.BufferEnd >= ConnectionBufferSize then
    Exit(0);
  Result := ReceiveRaw(Connection, @Connection.Buffer[Connection.BufferEnd], ConnectionBufferSize -
    Connection.BufferEnd);
  if Result > 0 then
    Connection.BufferEnd := Connection.BufferEnd + PtrUInt(Result);
end;

procedure ConsumeConnectionBuffer(var Connection: TConnection; Count: PtrUInt);
begin
  if Count > Connection.BufferEnd - Connection.BufferStart then
    Count := Connection.BufferEnd - Connection.BufferStart;
  Connection.BufferStart := Connection.BufferStart + Count;
end;

function ReceiveFromConnection(var Connection: TConnection; Buffer: Pointer; Length: PtrUInt): Int64;
var
  Available: PtrUInt;
begin
  Available := Connection.BufferEnd - Connection.BufferStart;
  if Available > 0 then
  begin
    if Available > Length then
      Available := Length;
    Move(Connection.Buffer[Connection.BufferStart], Buffer^, Available);
    Connection.BufferStart := Connection.BufferStart + Available;
    Exit(Available);
  end;
  Result := ReceiveRaw(Connection, Buffer, Length);
end;

end.
