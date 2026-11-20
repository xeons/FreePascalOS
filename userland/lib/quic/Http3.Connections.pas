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
  The client's side of an HTTP/3 connection (RFC 9114) over an
  established QUIC connection: the control stream with this side's
  SETTINGS, the QPACK encoder and decoder streams, and the server's
  unidirectional streams as they open:

    control         SETTINGS first (else H3_MISSING_SETTINGS), then
                    GOAWAY (no new requests at or above its stream ID)
                    and CANCEL_PUSH; any other frame there is
                    H3_FRAME_UNEXPECTED, its end H3_CLOSED_CRITICAL_STREAM
    QPACK encoder   fed to the decoder (the dynamic table)
    QPACK decoder   read and passed over (this encoder never inserts)
    push            refused (no MAX_PUSH_ID was sent): H3_ID_ERROR
    other types     STOP_SENDING H3_STREAM_CREATION_ERROR

  The settings offered: a 4 KiB QPACK dynamic table, 16 blocked
  streams, field sections up to 64 KiB. Requests go on bidirectional
  streams (Http3.Requests); a connection error closes the QUIC
  connection with the HTTP/3 code.
}
unit Http3.Connections;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Http3.FrameParser,
  Http3.Frames,
  Qpack.Decoder,
  Quic.Connections;

const
  Http3TableCapacity = 4096;
  Http3BlockedStreams = 16;
  Http3MaximumFieldSectionSize = 65536;

type
  THttp3PeerStream = record
    Id: QWord;
    { -1 until its type has arrived. }
    StreamType: Int64;
    TypeBytes: array[0..7] of Byte;
    TypeLength: Integer;
    Parser: THttp3FrameParser;
    Ignored: Boolean;
  end;

  THttp3ClientConnection = class
  private
    FQuic: TQuicConnection;
    FOwnsQuic: Boolean;
    FDecoder: TQpackDecoder;
    FControlStream: QWord;
    FEncoderStream: QWord;
    FDecoderStream: QWord;
    FStarted: Boolean;
    FPeerStreams: array of THttp3PeerStream;
    FPeerControlSeen: Boolean;
    FPeerEncoderSeen: Boolean;
    FPeerDecoderSeen: Boolean;
    FSettingsReceived: Boolean;
    FPeerSettings: THttp3Settings;
    FGoawayReceived: Boolean;
    FGoawayId: QWord;
    FError: LongInt;
    FErrorCode: QWord;
    FErrorText: string;
    procedure AcceptPeerStreams;
    procedure ReadPeerStream(Index: Integer);
    procedure HandleControlFrame(FrameType: QWord; Payload: PByte; Length: PtrUInt);
    function TakeStreamType(Index: Integer; var Data: PByte; var Count: PtrUInt): Boolean;
    procedure DispatchPeerData(Index: Integer; Data: PByte; Count: PtrUInt);
  public
    { Quic must be connected (Connect done) with ALPN "h3". }
    constructor Create(Quic: TQuicConnection; OwnsQuic: Boolean);
    destructor Destroy; override;
    { Opens this side's control and QPACK streams. }
    function Start: LongInt;
    { Handles what the server sent on its own streams and sends the
      decoder stream's acknowledgments. }
    function Service: LongInt;
    { Runs the connection once (at most until Deadline, a
      QuicMilliseconds time) and services the streams. }
    function WaitForProgress(Deadline: Int64): LongInt;
    { Ends the connection for breaking HTTP/3 (Code: H3_*). }
    procedure Fail(Code: QWord; const Reason: string);
    { H3_NO_ERROR, and the QUIC connection closes. }
    procedure Close;
    function ErrorDescription(Error: LongInt): string;
    { QuicErrorNone while usable. }
    function LastError: LongInt;
    property Quic: TQuicConnection read FQuic;
    property Decoder: TQpackDecoder read FDecoder;
    property SettingsReceived: Boolean read FSettingsReceived;
    property PeerSettings: THttp3Settings read FPeerSettings;
    property GoawayReceived: Boolean read FGoawayReceived;
    property GoawayId: QWord read FGoawayId;
  end;

implementation

uses
  Http3.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.Streams,
  Quic.VariableIntegers;

constructor THttp3ClientConnection.Create(Quic: TQuicConnection; OwnsQuic: Boolean);
begin
  inherited Create;
  FQuic := Quic;
  FOwnsQuic := OwnsQuic;
  FDecoder := TQpackDecoder.Create(Http3TableCapacity, Http3BlockedStreams);
  FDecoder.MaximumSectionSize := Http3MaximumFieldSectionSize;
end;

destructor THttp3ClientConnection.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FPeerStreams) do
    FPeerStreams[Index].Parser.Free;
  FDecoder.Free;
  if FOwnsQuic then
    FQuic.Free;
  inherited Destroy;
end;

function THttp3ClientConnection.LastError: LongInt;
begin
  if FError <> 0 then
    Exit(FError);
  Result := FQuic.LastError;
end;

function WriteStreamType(Quic: TQuicConnection; StreamType: Byte; out StreamId: QWord): LongInt;
var
  Written: Int64;
begin
  Result := Quic.OpenStream(False, StreamId);
  if Result <> QuicErrorNone then
    Exit;
  Written := Quic.Write(StreamId, @StreamType, 1);
  if Written < 0 then
    Exit(LongInt(Written));
  Result := QuicErrorNone;
end;

function THttp3ClientConnection.Start: LongInt;
var
  Settings: THttp3Settings;
  Frame: TBytes;
  Written: Int64;
begin
  if FStarted then
    Exit(QuicErrorNone);
  FStarted := True;
  Result := WriteStreamType(FQuic, Http3StreamControl, FControlStream);
  if Result <> QuicErrorNone then
    Exit;
  Settings.QpackMaxTableCapacity := Http3TableCapacity;
  Settings.QpackBlockedStreams := Http3BlockedStreams;
  Settings.MaxFieldSectionSize := Http3MaximumFieldSectionSize;
  Frame := EncodeSettings(Settings);
  Written := FQuic.Write(FControlStream, @Frame[0], Length(Frame));
  if Written < 0 then
    Exit(LongInt(Written));
  Result := WriteStreamType(FQuic, Http3StreamQpackEncoder, FEncoderStream);
  if Result <> QuicErrorNone then
    Exit;
  Result := WriteStreamType(FQuic, Http3StreamQpackDecoder, FDecoderStream);
end;

procedure THttp3ClientConnection.Fail(Code: QWord; const Reason: string);
begin
  if FError <> 0 then
    Exit;
  FError := Http3ErrorConnection;
  FErrorCode := Code;
  FErrorText := Reason;
  FQuic.Close(Code, Reason);
end;

procedure THttp3ClientConnection.Close;
begin
  if FQuic.LastError = QuicErrorNone then
    FQuic.Close(Http3NoError, '');
end;

procedure THttp3ClientConnection.AcceptPeerStreams;
var
  StreamId: QWord;
  Index: Integer;
begin
  while FQuic.AcceptStream(StreamId, 0) = QuicErrorNone do
  begin
    if StreamIsBidirectional(StreamId) then
    begin
      { Servers open no bidirectional streams in HTTP/3. }
      Fail(Http3StreamCreationError, 'the server opened a bidirectional stream');
      Exit;
    end;
    Index := Length(FPeerStreams);
    SetLength(FPeerStreams, Index + 1);
    FPeerStreams[Index] := Default(THttp3PeerStream);
    FPeerStreams[Index].Id := StreamId;
    FPeerStreams[Index].StreamType := -1;
  end;
end;

{ The stream type at the front of a unidirectional stream; False until
  it is all there. }
function THttp3ClientConnection.TakeStreamType(Index: Integer; var Data: PByte; var Count: PtrUInt): Boolean;
var
  Stream: ^THttp3PeerStream;
  Value: QWord;
begin
  Stream := @FPeerStreams[Index];
  while (Count > 0) and (Stream^.StreamType < 0) do
  begin
    Stream^.TypeBytes[Stream^.TypeLength] := Data^;
    Inc(Stream^.TypeLength);
    Inc(Data);
    Dec(Count);
    if Stream^.TypeLength = EncodedLengthOf(Stream^.TypeBytes[0]) then
    begin
      DecodeVariableInteger(@Stream^.TypeBytes[0], Stream^.TypeLength, Value);
      Stream^.StreamType := Int64(Value and $7FFFFFFFFFFFFFFF);
      case Stream^.StreamType of
        Http3StreamControl:
          begin
            if FPeerControlSeen then
            begin
              Fail(Http3StreamCreationError, 'a second control stream');
              Exit(False);
            end;
            FPeerControlSeen := True;
            Stream^.Parser := THttp3FrameParser.Create(65536);
          end;
        Http3StreamQpackEncoder, Http3StreamQpackDecoder:
          begin
            if ((Stream^.StreamType = Http3StreamQpackEncoder) and FPeerEncoderSeen) or
               ((Stream^.StreamType = Http3StreamQpackDecoder) and FPeerDecoderSeen) then
            begin
              Fail(Http3StreamCreationError, 'a second QPACK stream');
              Exit(False);
            end;
            if Stream^.StreamType = Http3StreamQpackEncoder then
              FPeerEncoderSeen := True
            else
              FPeerDecoderSeen := True;
          end;
        Http3StreamPush:
          begin
            Fail(Http3IdError, 'a push stream without MAX_PUSH_ID');
            Exit(False);
          end;
      else
        begin
          Stream^.Ignored := True;
          FQuic.StopSending(Stream^.Id, Http3StreamCreationError);
        end;
      end;
    end;
  end;
  Result := Stream^.StreamType >= 0;
end;

procedure THttp3ClientConnection.HandleControlFrame(FrameType: QWord; Payload: PByte; Length: PtrUInt);
var
  Identifier: QWord;
begin
  if not FSettingsReceived then
  begin
    if FrameType <> Http3FrameSettings then
    begin
      Fail(Http3MissingSettings, 'the control stream does not start with SETTINGS');
      Exit;
    end;
    if not DecodeSettings(Payload, Length, FPeerSettings) then
    begin
      Fail(Http3SettingsError, 'bad SETTINGS');
      Exit;
    end;
    FSettingsReceived := True;
    Exit;
  end;
  case FrameType of
    Http3FrameGoaway:
      begin
        if not DecodeGoaway(Payload, Length, Identifier) or not StreamIsBidirectional(Identifier) or
           StreamIsServerInitiated(Identifier) or (FGoawayReceived and (Identifier > FGoawayId)) then
        begin
          Fail(Http3IdError, 'a bad GOAWAY');
          Exit;
        end;
        FGoawayReceived := True;
        FGoawayId := Identifier;
      end;
    Http3FrameCancelPush:
      ;
  else
    Fail(Http3FrameUnexpected, 'a frame not allowed on the control stream');
  end;
end;

procedure THttp3ClientConnection.DispatchPeerData(Index: Integer; Data: PByte; Count: PtrUInt);
var
  FrameType: QWord;
  Payload: PByte;
  PayloadLength: PtrUInt;
  Outcome: THttp3ParseResult;
begin
  case FPeerStreams[Index].StreamType of
    Http3StreamControl:
      begin
        FPeerStreams[Index].Parser.Append(Data, Count);
        while FError = 0 do
        begin
          Outcome := FPeerStreams[Index].Parser.Next(FrameType, Payload, PayloadLength);
          case Outcome of
            ParseNeedMore:
              Break;
            ParseData:
              begin
                Fail(Http3FrameUnexpected, 'DATA on the control stream');
                Break;
              end;
            ParseFrameTooLarge:
              begin
                Fail(Http3ExcessiveLoad, 'a control frame too large');
                Break;
              end;
            ParseFrame:
              HandleControlFrame(FrameType, Payload, PayloadLength);
          end;
        end;
      end;
    Http3StreamQpackEncoder:
      if FDecoder.ProcessEncoderStream(Data, Count) <> 0 then
        Fail(QpackEncoderStreamError, 'a bad QPACK encoder stream');
  end;
end;

procedure THttp3ClientConnection.ReadPeerStream(Index: Integer);
var
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Data: PByte;
  Remaining: PtrUInt;
begin
  while FError = 0 do
  begin
    if FPeerStreams[Index].Ignored then
      Exit;
    Count := FQuic.ReadWithin(FPeerStreams[Index].Id, @Buffer[0], SizeOf(Buffer), 0);
    if Count = QuicErrorTimedOut then
      Exit;
    if (Count = 0) or (Count = QuicErrorStreamReset) or (Count = QuicErrorInvalidStream) then
    begin
      if (FPeerStreams[Index].StreamType >= Http3StreamControl) and
         (FPeerStreams[Index].StreamType <= Http3StreamQpackDecoder) and
         (FPeerStreams[Index].StreamType <> Http3StreamPush) then
        Fail(Http3ClosedCriticalStream, 'the server closed a critical stream');
      FPeerStreams[Index].Ignored := True;
      Exit;
    end;
    if Count < 0 then
      Exit;
    Data := @Buffer[0];
    Remaining := Count;
    if not TakeStreamType(Index, Data, Remaining) then
      Continue;
    if Remaining > 0 then
      DispatchPeerData(Index, Data, Remaining);
  end;
end;

function THttp3ClientConnection.Service: LongInt;
var
  Index: Integer;
  Acknowledgments: TBytes;
begin
  if FError = 0 then
    AcceptPeerStreams;
  Index := 0;
  while (FError = 0) and (Index < Length(FPeerStreams)) do
  begin
    ReadPeerStream(Index);
    Inc(Index);
  end;
  if (FError = 0) and FStarted then
  begin
    Acknowledgments := FDecoder.TakeDecoderStreamBytes;
    if Length(Acknowledgments) > 0 then
      FQuic.Write(FDecoderStream, @Acknowledgments[0], Length(Acknowledgments));
  end;
  Result := LastError;
end;

function THttp3ClientConnection.WaitForProgress(Deadline: Int64): LongInt;
begin
  Result := LastError;
  if Result <> 0 then
    Exit;
  if QuicMilliseconds >= Deadline then
    Exit(QuicErrorTimedOut);
  FQuic.Pump(Deadline - QuicMilliseconds);
  Result := Service;
end;

function THttp3ClientConnection.ErrorDescription(Error: LongInt): string;
begin
  case Error of
    Http3ErrorConnection:
      Result := 'HTTP/3 connection error ' + Http3ErrorName(FErrorCode) + ': ' + FErrorText;
    Http3ErrorMalformedResponse:
      Result := 'the server sent a malformed response';
    Http3ErrorRequestReset:
      Result := 'the server reset the request';
    Http3ErrorGoingAway:
      Result := 'the server is going away (GOAWAY)';
    Http3ErrorIncomplete:
      Result := 'the response ended early';
    Http3ErrorInvalidState:
      Result := 'not possible now';
    QuicErrorClosedByPeer:
      begin
        Result := FQuic.ErrorDescription(Error);
        if FQuic.State^.PeerCloseIsApplication then
          Result := Result + ' [' + Http3ErrorName(FQuic.State^.PeerCloseCode) + ']';
      end;
  else
    Result := FQuic.ErrorDescription(Error);
  end;
end;

end.
