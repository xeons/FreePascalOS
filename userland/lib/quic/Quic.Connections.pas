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
  A QUIC connection the way programs use it:

    Connection := TQuicConnection.Create(Transport, Options);
    try
      if Connection.Connect <> QuicErrorNone then
        ... Connection.ErrorDescription ...
      Connection.OpenStream(True, Stream);
      Connection.Write(Stream, @Request[1], Length(Request), True);
      Count := Connection.Read(Stream, @Buffer, SizeOf(Buffer));  (0: end)
      Connection.Close(0, '');
    finally
      Connection.Free;
    end;

  Calls that wait (Connect, OpenStream when the peer allows no more
  streams, Write when the stream's buffer is full, Read, AcceptStream)
  run the connection meanwhile and give up after Timeout milliseconds
  (QuicErrorTimedOut); Pump runs it once for a caller that serves
  several streams. Stream identifiers are QUIC's: 0, 4, 8 ... for the
  client's bidirectional streams, 2, 6 ... for its unidirectional ones,
  3, 7 ... for the server's unidirectional ones.

  Quic.UdpSockets puts this over a UDP socket to a host and port.
}
unit Quic.Connections;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Quic.ConnectionState,
  Quic.DatagramTransports,
  Quic.TransportParameters;

type
  TQuicConnection = class
  private
    FState: PQuicConnectionState;
    FTimeout: Int64;
    FCipherSuiteName: string;
    FApplicationProtocol: string;
    FTlsDescription: string;
    function GetLastError: LongInt;
    function GetEstablished: Boolean;
    function GetStatistics: TQuicStatistics;
    function GetNewToken: TBytes;
    function GetPeerParameters: TQuicTransportParameters;
    function GetSmoothedRtt: Int64;
    function GetCongestionWindow: Int64;
    function GetDatagramSize: Integer;
    function WaitUntil(Deadline: Int64): LongInt;
  public
    { The transport's context must stay valid while the connection
      lives. }
    constructor Create(constref Transport: TQuicDatagramTransport; constref Options: TQuicConnectionOptions);
    { Takes over a connection made by other means (the test's server):
      its state is freed with the object. }
    constructor CreateFromState(State: PQuicConnectionState);
    destructor Destroy; override;
    { The handshake: QuicErrorNone once 1-RTT keys are there. }
    function Connect: LongInt;
    { A new stream of this side; waits up to Timeout for the peer to
      allow one. }
    function OpenStream(Bidirectional: Boolean; out StreamId: QWord): LongInt;
    { The next stream the peer opened that was not accepted yet;
      waits up to TimeoutMilliseconds (0: just looks). }
    function AcceptStream(out StreamId: QWord; TimeoutMilliseconds: Int64): LongInt;
    { Queues all Length bytes (waiting for room), with a FIN after them
      when Finish is set: Length, or an error. }
    function Write(StreamId: QWord; Buffer: Pointer; Length: PtrUInt; Finish: Boolean = False): Int64;
    { At most Length bytes, waiting up to Timeout for some: the count,
      0 at the end of the stream, QuicErrorStreamReset ... }
    function Read(StreamId: QWord; Buffer: Pointer; Length: PtrUInt): Int64;
    { The same without waiting longer than TimeoutMilliseconds (0: not
      at all): QuicErrorTimedOut when nothing came. }
    function ReadWithin(StreamId: QWord; Buffer: Pointer; Length: PtrUInt; TimeoutMilliseconds: Int64): Int64;
    { A FIN after what was written. }
    function FinishStream(StreamId: QWord): LongInt;
    { Abandons sending (RESET_STREAM) or receiving (STOP_SENDING). }
    function ResetStream(StreamId: QWord; ErrorCode: QWord): LongInt;
    function StopSending(StreamId: QWord; ErrorCode: QWord): LongInt;
    { Bytes ready to read now, and whether the end (or a reset) is next. }
    function StreamReadable(StreamId: QWord): Boolean;
    { Waits until every byte written to the stream was acknowledged. }
    function FlushStream(StreamId: QWord): LongInt;
    { Runs the connection once: sends, waits up to TimeoutMilliseconds
      for something to arrive or a timer, handles it. }
    function Pump(TimeoutMilliseconds: Int64): LongInt;
    { CONNECTION_CLOSE with an application error code (0: none). }
    procedure Close(ErrorCode: QWord; const Reason: string);
    { Moves to new 1-RTT keys (RFC 9001 section 6). }
    procedure RequestKeyUpdate;
    function ErrorDescription(Error: LongInt): string;
    property State: PQuicConnectionState read FState;
    property LastError: LongInt read GetLastError;
    property Established: Boolean read GetEstablished;
    { For every wait (milliseconds); 30 s unless set. }
    property Timeout: Int64 read FTimeout write FTimeout;
    property CipherSuiteName: string read FCipherSuiteName;
    property ApplicationProtocol: string read FApplicationProtocol;
    property Statistics: TQuicStatistics read GetStatistics;
    { The server's newest NEW_TOKEN, for the next connection's Options.Token. }
    property NewToken: TBytes read GetNewToken;
    property PeerParameters: TQuicTransportParameters read GetPeerParameters;
    property SmoothedRtt: Int64 read GetSmoothedRtt;
    property CongestionWindow: Int64 read GetCongestionWindow;
    property DatagramSize: Integer read GetDatagramSize;
  end;

implementation

uses
  Quic.ClientHandshake,
  Quic.ConnectionCore,
  Quic.Constants,
  Quic.Errors,
  Quic.Streams,
  Quic.StreamTable;

constructor TQuicConnection.Create(constref Transport: TQuicDatagramTransport;
  constref Options: TQuicConnectionOptions);
begin
  inherited Create;
  if (Transport.Send = nil) or (Transport.Receive = nil) then
    raise EQuicError.CreateCode(QuicErrorInvalidArgument, 'a QUIC connection needs a transport');
  FState := CreateConnectionState(RoleClient, Options, Transport);
  FTimeout := 30000;
end;

constructor TQuicConnection.CreateFromState(State: PQuicConnectionState);
begin
  inherited Create;
  FState := State;
  FTimeout := 30000;
end;

destructor TQuicConnection.Destroy;
begin
  if (FState <> nil) and ConnectionIsOpen(FState) and FState^.HandshakeComplete then
  begin
    CloseByApplication(FState, 0, '');
    FlushConnection(FState);
  end;
  FreeConnectionState(FState);
  inherited Destroy;
end;

function TQuicConnection.GetLastError: LongInt;
begin
  Result := ConnectionError(FState);
end;

function TQuicConnection.GetEstablished: Boolean;
begin
  Result := (FState^.Phase = PhaseEstablished);
end;

function TQuicConnection.GetStatistics: TQuicStatistics;
begin
  Result := FState^.Statistics;
end;

function TQuicConnection.GetNewToken: TBytes;
begin
  Result := Copy(FState^.ReceivedToken);
end;

function TQuicConnection.GetPeerParameters: TQuicTransportParameters;
begin
  Result := FState^.PeerParameters;
end;

function TQuicConnection.GetSmoothedRtt: Int64;
begin
  Result := FState^.Rtt.SmoothedRtt;
end;

function TQuicConnection.GetCongestionWindow: Int64;
begin
  Result := FState^.Congestion.CongestionWindow;
end;

function TQuicConnection.GetDatagramSize: Integer;
begin
  Result := FState^.MaximumDatagramSize;
end;

function TQuicConnection.WaitUntil(Deadline: Int64): LongInt;
begin
  if QuicMilliseconds >= Deadline then
    Exit(QuicErrorTimedOut);
  Result := PumpConnection(FState, Deadline);
end;

function TQuicConnection.Connect: LongInt;
var
  Outcome: TQuicHandshakeResult;
begin
  if FState^.HandshakeComplete or (FState^.Phase <> PhaseHandshaking) or (FState^.Statistics.PacketsSent > 0) then
    Exit(QuicErrorInvalidArgument);
  RunClientHandshake(FState, Outcome);
  FCipherSuiteName := Outcome.CipherSuiteName;
  FApplicationProtocol := Outcome.ApplicationProtocol;
  FTlsDescription := Outcome.TlsDescription;
  Result := Outcome.Error;
end;

function TQuicConnection.OpenStream(Bidirectional: Boolean; out StreamId: QWord): LongInt;
var
  Stream: PQuicStream;
  Deadline: Int64;
begin
  StreamId := 0;
  Deadline := QuicMilliseconds + FTimeout;
  while True do
  begin
    Result := ConnectionError(FState);
    if Result <> QuicErrorNone then
      Exit;
    if not FState^.HandshakeComplete then
      Exit(QuicErrorInvalidArgument);
    Result := OpenLocalStream(FState, Bidirectional, Stream);
    if Result = QuicErrorNone then
    begin
      StreamId := Stream^.Id;
      Exit;
    end;
    Result := WaitUntil(Deadline);
    if Result = QuicErrorTimedOut then
      Exit(QuicErrorStreamLimit);
  end;
end;

function TQuicConnection.AcceptStream(out StreamId: QWord; TimeoutMilliseconds: Int64): LongInt;
var
  Index: Integer;
  Deadline: Int64;
begin
  StreamId := 0;
  Deadline := QuicMilliseconds + TimeoutMilliseconds;
  while True do
  begin
    for Index := 0 to FState^.StreamCount - 1 do
      if not FState^.Streams[Index]^.Accepted then
      begin
        FState^.Streams[Index]^.Accepted := True;
        StreamId := FState^.Streams[Index]^.Id;
        Exit(QuicErrorNone);
      end;
    Result := ConnectionError(FState);
    if Result <> QuicErrorNone then
      Exit;
    if TimeoutMilliseconds <= 0 then
      Exit(QuicErrorTimedOut);
    Result := WaitUntil(Deadline);
    if Result <> QuicErrorNone then
      Exit;
  end;
end;

function TQuicConnection.Write(StreamId: QWord; Buffer: Pointer; Length: PtrUInt; Finish: Boolean): Int64;
var
  Stream: PQuicStream;
  Done, Taken: PtrUInt;
  Deadline: Int64;
  Error: LongInt;
begin
  Done := 0;
  Deadline := QuicMilliseconds + FTimeout;
  while True do
  begin
    Error := ConnectionError(FState);
    if Error <> QuicErrorNone then
      Exit(Error);
    Stream := FindStream(FState, StreamId);
    if (Stream = nil) or not Stream^.CanSend or Stream^.Send.FinQueued then
      Exit(QuicErrorInvalidStream);
    if Stream^.StopSendingReceived then
      Exit(QuicErrorStreamStopped);
    if Stream^.ResetRequested then
      Exit(QuicErrorInvalidStream);
    if Done < Length then
    begin
      Taken := Stream^.Send.Append(PByte(Buffer) + Done, Length - Done);
      Done := Done + Taken;
    end;
    if Done = Length then
    begin
      if Finish then
        Stream^.Send.QueueFin;
      FlushConnection(FState);
      Exit(Int64(Length));
    end;
    { The buffer is full: send, and wait for acknowledgements. }
    Error := WaitUntil(Deadline);
    if Error <> QuicErrorNone then
      Exit(Error);
  end;
end;

function TQuicConnection.ReadWithin(StreamId: QWord; Buffer: Pointer; Length: PtrUInt;
  TimeoutMilliseconds: Int64): Int64;
var
  Stream: PQuicStream;
  Count: PtrUInt;
  Deadline: Int64;
  Error: LongInt;
begin
  Deadline := QuicMilliseconds + TimeoutMilliseconds;
  while True do
  begin
    Stream := FindStream(FState, StreamId);
    if (Stream = nil) or not Stream^.CanReceive then
      Exit(QuicErrorInvalidStream);
    if Stream^.PeerReset then
    begin
      Stream^.EndSeen := True;
      Exit(QuicErrorStreamReset);
    end;
    if Stream^.Receive.Available > 0 then
    begin
      Count := Stream^.Receive.Read(Buffer, Length);
      NoteStreamDataRead(FState, Stream, Count);
      if Stream^.MaxStreamDataPending or FState^.MaxDataPending then
        FlushConnection(FState);
      Exit(Count);
    end;
    if Stream^.Receive.Finished then
    begin
      Stream^.EndSeen := True;
      Exit(0);
    end;
    Error := ConnectionError(FState);
    if Error <> QuicErrorNone then
      Exit(Error);
    if TimeoutMilliseconds <= 0 then
      Exit(QuicErrorTimedOut);
    Error := WaitUntil(Deadline);
    if Error <> QuicErrorNone then
      Exit(Error);
  end;
end;

function TQuicConnection.Read(StreamId: QWord; Buffer: Pointer; Length: PtrUInt): Int64;
begin
  Result := ReadWithin(StreamId, Buffer, Length, FTimeout);
end;

function TQuicConnection.FinishStream(StreamId: QWord): LongInt;
var
  Stream: PQuicStream;
begin
  Stream := FindStream(FState, StreamId);
  if (Stream = nil) or not Stream^.CanSend then
    Exit(QuicErrorInvalidStream);
  Stream^.Send.QueueFin;
  FlushConnection(FState);
  Result := ConnectionError(FState);
end;

function TQuicConnection.ResetStream(StreamId: QWord; ErrorCode: QWord): LongInt;
var
  Stream: PQuicStream;
begin
  Stream := FindStream(FState, StreamId);
  if (Stream = nil) or not Stream^.CanSend then
    Exit(QuicErrorInvalidStream);
  if not Stream^.ResetRequested and not Stream^.Send.AllAcknowledged then
  begin
    Stream^.ResetRequested := True;
    Stream^.ResetCode := ErrorCode;
    Stream^.ResetPending := True;
    Stream^.Send.Lost.Clear;
  end;
  FlushConnection(FState);
  Result := ConnectionError(FState);
end;

function TQuicConnection.StopSending(StreamId: QWord; ErrorCode: QWord): LongInt;
var
  Stream: PQuicStream;
begin
  Stream := FindStream(FState, StreamId);
  if (Stream = nil) or not Stream^.CanReceive then
    Exit(QuicErrorInvalidStream);
  if not Stream^.StopSendingRequested and not Stream^.Receive.Finished and not Stream^.PeerReset then
  begin
    Stream^.StopSendingRequested := True;
    Stream^.StopSendingCode := ErrorCode;
    Stream^.StopSendingPending := True;
  end;
  FlushConnection(FState);
  Result := ConnectionError(FState);
end;

function TQuicConnection.StreamReadable(StreamId: QWord): Boolean;
var
  Stream: PQuicStream;
begin
  Stream := FindStream(FState, StreamId);
  if (Stream = nil) or not Stream^.CanReceive then
    Exit(False);
  Result := (Stream^.Receive.Available > 0) or Stream^.Receive.Finished or Stream^.PeerReset;
end;

function TQuicConnection.FlushStream(StreamId: QWord): LongInt;
var
  Stream: PQuicStream;
  Deadline: Int64;
begin
  Deadline := QuicMilliseconds + FTimeout;
  while True do
  begin
    Stream := FindStream(FState, StreamId);
    if (Stream = nil) or Stream^.Send.Idle then
      Exit(QuicErrorNone);
    Result := WaitUntil(Deadline);
    if Result <> QuicErrorNone then
      Exit;
  end;
end;

function TQuicConnection.Pump(TimeoutMilliseconds: Int64): LongInt;
begin
  Result := PumpConnection(FState, QuicMilliseconds + TimeoutMilliseconds);
end;

procedure TQuicConnection.Close(ErrorCode: QWord; const Reason: string);
begin
  CloseByApplication(FState, ErrorCode, Reason);
  FlushConnection(FState);
end;

procedure TQuicConnection.RequestKeyUpdate;
begin
  FState^.KeyUpdateRequested := True;
end;

function TQuicConnection.ErrorDescription(Error: LongInt): string;
begin
  Result := QuicErrorMessage(Error);
  case Error of
    QuicErrorHandshakeFailed:
      if FTlsDescription <> '' then
        Result := Result + ': ' + FTlsDescription;
    QuicErrorClosedByPeer:
      begin
        if FState^.PeerCloseIsApplication then
          Result := Result + ' (application error 0x' + IntToHex(FState^.PeerCloseCode, 1)
        else
          Result := Result + ' (' + TransportErrorName(FState^.PeerCloseCode);
        if FState^.PeerCloseReason <> '' then
          Result := Result + ': ' + FState^.PeerCloseReason;
        Result := Result + ')';
      end;
    QuicErrorProtocolViolation:
      Result := Result + ' (' + TransportErrorName(FState^.CloseCode) + ': ' + FState^.CloseReason + ')';
    QuicErrorVersionNegotiation, QuicErrorIdleTimeout, QuicErrorTransportFailed:
      if FState^.ErrorDetail <> '' then
        Result := Result + ' (' + FState^.ErrorDetail + ')';
  end;
end;

end.
