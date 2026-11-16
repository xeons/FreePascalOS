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
  wget's connection to a server: the host looked up (Sys.HostLookup:
  numeric addresses without DNS, IPv6 first when this machine can reach
  it), a TCP connection made within the timeout to each address in turn
  until one takes it, and for https a TLS session over it (libtls,
  TTlsSocketSession).
  Reads go through a buffer, so the response head can be looked for and
  what follows it handed to the body.
}
unit Wget.Connections;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls,
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
    { Without it the system's roots. }
    HasTrustFile: Boolean;
    TrustFile: string;
    CipherSuites: TCipherSuiteList;
    Quiet: Boolean;
  end;

  TConnectionFailure = (FailureNone, FailureLookUp, FailureConnect, FailureTimeout, FailureTls,
    FailureCertificate, FailureTransfer);

  TConnection = class
  private
    FSocket: Int64;
    FSession: TTlsSocketSession;
    FUsesTls: Boolean;
    FTimeoutMilliseconds: Int64;
    FBuffer: array[0..ConnectionBufferSize - 1] of Byte;
    FBufferStart, FBufferEnd: PtrUInt;
    FFailure: TConnectionFailure;
    FErrorCode: LongInt;
    FErrorText: string;
    procedure SetFailure(Failure: TConnectionFailure; Code: LongInt; const Text: string);
    function ConnectWithTimeout(constref Target: TAbiSocketAddress): LongInt;
    function OpenTls(constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
    function ResolveUrlHost(constref Url: TUrl; constref Settings: TConnectionSettings;
      out Addresses: TInternetAddressArray): Boolean;
    function ConnectToAddress(constref Url: TUrl; constref Address: TInternetAddress;
      constref Settings: TConnectionSettings): Boolean;
    function ReceiveRaw(Buffer: Pointer; Length: PtrUInt): Int64;
    function GetBufferedData: PChar;
    function GetBufferedCount: PtrUInt;
  public
    constructor Create;
    destructor Destroy; override;
    { Looks the host up, connects and (https) runs the TLS handshake,
      telling the user what it does unless quiet. On failure Failure and
      ErrorText say why. }
    function Open(constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
    procedure Close;
    function Send(const Data: string): Boolean;
    { Bytes read (from the buffer first), 0 at the end, -1 on failure. }
    function Receive(Buffer: Pointer; Length: PtrUInt): Int64;
    { Reads more into the buffer (moving what is there to the front); the
      same results. }
    function FillBuffer: Int64;
    procedure ConsumeBuffer(Count: PtrUInt);
    { What the buffer holds that was not consumed yet. }
    property BufferedData: PChar read GetBufferedData;
    property BufferedCount: PtrUInt read GetBufferedCount;
    property Failure: TConnectionFailure read FFailure;
    { A system error code, or a TLS error code, of the failure. }
    property ErrorCode: LongInt read FErrorCode;
    property ErrorText: string read FErrorText;
  end;

implementation

uses
  SysUtils,
  Sys.Errors,
  Sys.HostNames,
  Sys.HostLookup,
  Sys.AddressText,
  Sys.Sockets,
  Tls.Errors,
  Sys.Streams;

const
  TimeoutText = 'Read error (Connection timed out)';

{ The words for a system error code ("Connection refused"). }
function SystemErrorText(Code: LongInt): string;
begin
  Result := ErrorMessage(Code);
end;

constructor TConnection.Create;
begin
  inherited Create;
  FSocket := -1;
end;

destructor TConnection.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TConnection.SetFailure(Failure: TConnectionFailure; Code: LongInt; const Text: string);
begin
  FFailure := Failure;
  FErrorCode := Code;
  FErrorText := Text;
end;

{ A non-blocking connect, waited for at most the timeout. }
function TConnection.ConnectWithTimeout(constref Target: TAbiSocketAddress): LongInt;
var
  Waited: Int64;
  Pending: Int64;
  Timeout: Int64;
begin
  Result := ConnectSocket(FSocket, Target);
  if Result = ErrorInProgress then
  begin
    Timeout := FTimeoutMilliseconds;
    if Timeout <= 0 then
      Timeout := InfiniteWait;
    Waited := WaitForSocket(FSocket, SocketWritable, Timeout);
    if Waited < 0 then
      Exit(ErrorCodeOf(Waited));
    Result := GetSocketOption(FSocket, SocketOptionError, Pending);
    if Result = ErrorNone then
      Result := LongInt(Pending);
  end;
  if Result = ErrorNone then
    SetSocketOption(FSocket, SocketOptionNonBlocking, 0);
end;

function TConnection.OpenTls(constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
var
  Error: LongInt;
  Ignored: LongInt;
begin
  FSession := TTlsSocketSession.Create;
  FSession.ServerName := Url.Host;
  FSession.VerifyCertificates := Settings.VerifyCertificates;
  if Settings.HasTrustFile then
    FSession.TrustFile := Settings.TrustFile;
  FSession.TimeoutMilliseconds := Settings.TimeoutMilliseconds;
  FSession.ApplicationProtocol := 'http/1.1';
  FSession.CipherSuites := Settings.CipherSuites;
  Error := FSession.Open(FSocket);
  if Error <> TlsErrorNone then
  begin
    if TlsErrorIsCertificateError(Error) then
      SetFailure(FailureCertificate, Error, FSession.DescribeError(Error))
    else if Error = TlsErrorTimedOut then
      SetFailure(FailureTimeout, Error, FSession.DescribeError(Error))
    else
      SetFailure(FailureTls, Error, FSession.DescribeError(Error));
    Exit(False);
  end;
  Ignored := FSession.IgnoredCertificateError;
  if (Ignored <> TlsErrorNone) and not Settings.Quiet then
    PrintErrorString(Format('WARNING: cannot verify %s''s certificate: %s.'#10,
      [Url.Host, FSession.DescribeError(Ignored)]));
  Result := True;
end;

{ The addresses of the URL's host in the order to try them, saying so
  as wget does ("Resolving host... address, address"). }
function TConnection.ResolveUrlHost(constref Url: TUrl; constref Settings: TConnectionSettings;
  out Addresses: TInternetAddressArray): Boolean;
var
  Error: LongInt;
  Numeric: TInternetAddress;
  IsName: Boolean;
  Index: Integer;
  Line: string;
begin
  IsName := not TextToAddress(Url.Host, Numeric);
  if IsName and not Settings.Quiet then
    PrintErrorString(Format('Resolving %s... ', [Url.Host]));
  Error := ResolveHost(Url.Host, HostFamilyAny, Addresses);
  if (Error = ErrorNone) and (Length(Addresses) = 0) then
    Error := ErrorNotFound;
  Result := Error = ErrorNone;
  if not Result then
  begin
    if IsName and not Settings.Quiet then
      PrintErrorString(Format('failed: %s.'#10, [SystemErrorText(Error)]));
    SetFailure(FailureLookUp, Error, 'unable to resolve host address');
    Exit;
  end;
  if not IsName or Settings.Quiet then
    Exit;
  Line := '';
  for Index := 0 to High(Addresses) do
  begin
    if Index > 0 then
      Line := Line + ', ';
    Line := Line + AddressToText(Addresses[Index]);
  end;
  PrintErrorStringLine(Line);
end;

{ One attempt: a socket of the address's family connected within the
  timeout. False (the failure recorded) if it did not connect. }
function TConnection.ConnectToAddress(constref Url: TUrl; constref Address: TInternetAddress;
  constref Settings: TConnectionSettings): Boolean;
var
  Error: LongInt;
begin
  Result := False;
  if not Settings.Quiet then
    PrintErrorString(Format('Connecting to %s|%s|:%d... ', [Url.Host, AddressToText(Address), Url.Port]));
  FSocket := CreateSocket(Address.Family, SocketKindStream or SocketKindNonBlocking, ProtocolDefault);
  if FSocket < 0 then
  begin
    Error := ErrorCodeOf(FSocket);
    FSocket := -1;
    if not Settings.Quiet then
      PrintErrorString(Format('failed: %s.'#10, [SystemErrorText(Error)]));
    SetFailure(FailureConnect, Error, SystemErrorText(Error));
    Exit;
  end;
  Error := ConnectWithTimeout(MakeSocketAddress(Address, Url.Port));
  if Error <> ErrorNone then
  begin
    if not Settings.Quiet then
      PrintErrorString(Format('failed: %s.'#10, [SystemErrorText(Error)]));
    if Error = ErrorTimedOut then
      SetFailure(FailureTimeout, Error, SystemErrorText(Error))
    else
      SetFailure(FailureConnect, Error, SystemErrorText(Error));
    Close;
    Exit;
  end;
  if not Settings.Quiet then
    PrintErrorStringLine('connected.');
  Result := True;
end;

function TConnection.Open(constref Url: TUrl; constref Settings: TConnectionSettings): Boolean;
var
  Addresses: TInternetAddressArray;
  Address: TInternetAddress;
  Connected: Boolean;
begin
  FUsesTls := Url.Scheme = SchemeHttps;
  FTimeoutMilliseconds := Settings.TimeoutMilliseconds;
  Result := False;
  if not ResolveUrlHost(Url, Settings, Addresses) then
    Exit;
  Connected := False;
  for Address in Addresses do
  begin
    Connected := ConnectToAddress(Url, Address, Settings);
    if Connected then
      Break;
  end;
  if not Connected then
    Exit;

  if FUsesTls and not OpenTls(Url, Settings) then
  begin
    Close;
    Exit;
  end;
  Result := True;
end;

procedure TConnection.Close;
begin
  if FSession <> nil then
  begin
    FSession.Close;
    FreeAndNil(FSession);
  end;
  if FSocket >= 0 then
    CloseSocket(FSocket);
  FSocket := -1;
end;

function TConnection.Send(const Data: string): Boolean;
var
  Error: LongInt;
begin
  if FUsesTls then
  begin
    Result := FSession.Write(PChar(Data), Length(Data)) = Int64(Length(Data));
    if not Result then
      SetFailure(FailureTransfer, TlsErrorTransportFailed, 'the TLS connection failed');
    Exit;
  end;
  Error := SendAll(FSocket, PChar(Data), Length(Data));
  Result := Error = ErrorNone;
  if not Result then
    SetFailure(FailureTransfer, Error, SystemErrorText(Error));
end;

{ Straight from the socket or the TLS session. }
function TConnection.ReceiveRaw(Buffer: Pointer; Length: PtrUInt): Int64;
var
  Waited: Int64;
begin
  if FUsesTls then
  begin
    Result := FSession.Read(Buffer, Length);
    if Result < 0 then
    begin
      if Result = TlsErrorTimedOut then
        SetFailure(FailureTimeout, LongInt(Result), TimeoutText)
      else
        SetFailure(FailureTransfer, LongInt(Result), FSession.DescribeError(LongInt(Result)));
      Result := -1;
    end;
    Exit;
  end;
  if FTimeoutMilliseconds > 0 then
  begin
    Waited := WaitForSocket(FSocket, SocketReadable, FTimeoutMilliseconds);
    if Waited < 0 then
    begin
      if ErrorCodeOf(Waited) = ErrorTimedOut then
        SetFailure(FailureTimeout, ErrorTimedOut, TimeoutText)
      else
        SetFailure(FailureTransfer, ErrorCodeOf(Waited), SystemErrorText(ErrorCodeOf(Waited)));
      Exit(-1);
    end;
  end;
  Result := ReceiveOnSocket(FSocket, Buffer, Length, 0);
  if Result < 0 then
  begin
    SetFailure(FailureTransfer, ErrorCodeOf(Result), SystemErrorText(ErrorCodeOf(Result)));
    Result := -1;
  end;
end;

function TConnection.GetBufferedData: PChar;
begin
  Result := PChar(@FBuffer[FBufferStart]);
end;

function TConnection.GetBufferedCount: PtrUInt;
begin
  Result := FBufferEnd - FBufferStart;
end;

function TConnection.FillBuffer: Int64;
begin
  if FBufferStart > 0 then
  begin
    if FBufferEnd > FBufferStart then
      Move(FBuffer[FBufferStart], FBuffer[0], FBufferEnd - FBufferStart);
    FBufferEnd := FBufferEnd - FBufferStart;
    FBufferStart := 0;
  end;
  if FBufferEnd >= ConnectionBufferSize then
    Exit(0);
  Result := ReceiveRaw(@FBuffer[FBufferEnd], ConnectionBufferSize - FBufferEnd);
  if Result > 0 then
    FBufferEnd := FBufferEnd + PtrUInt(Result);
end;

procedure TConnection.ConsumeBuffer(Count: PtrUInt);
begin
  if Count > BufferedCount then
    Count := BufferedCount;
  FBufferStart := FBufferStart + Count;
end;

function TConnection.Receive(Buffer: Pointer; Length: PtrUInt): Int64;
var
  Available: PtrUInt;
begin
  Available := BufferedCount;
  if Available > 0 then
  begin
    if Available > Length then
      Available := Length;
    Move(FBuffer[FBufferStart], Buffer^, Available);
    FBufferStart := FBufferStart + Available;
    Exit(Available);
  end;
  Result := ReceiveRaw(Buffer, Length);
end;

end.
