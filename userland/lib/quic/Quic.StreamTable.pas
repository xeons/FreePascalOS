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
  A connection's streams and their flow control (RFC 9000 sections 2.1,
  4 and 19.11):

  - opening: this side's streams within the peer's MAX_STREAMS (else
    STREAMS_BLOCKED goes out and the caller waits); the peer's open
    when a frame first names them, every lower-numbered one of the kind
    with them, within the limit this side gave (else
    STREAM_LIMIT_ERROR);
  - limits: each stream sends within the peer's MAX_STREAM_DATA and the
    connection within its MAX_DATA; what the peer sends must stay within
    what this side gave (FLOW_CONTROL_ERROR), and as the application
    reads, the limits move on by the window (MAX_STREAM_DATA, MAX_DATA)
    once half of it is used;
  - forgetting streams that are done, which gives the peer room for a
    new one of the kind (MAX_STREAMS).
}
unit Quic.StreamTable;

{$mode objfpc}
{$H+}

interface

uses
  Quic.ConnectionState,
  Quic.Streams;

function FindStream(State: PQuicConnectionState; Id: QWord): PQuicStream;
{ Whether this side opens streams with this identifier. }
function StreamIsLocal(State: PQuicConnectionState; Id: QWord): Boolean;
{ A new stream of this side: QuicErrorNone, or QuicErrorStreamLimit. }
function OpenLocalStream(State: PQuicConnectionState; Bidirectional: Boolean; out Stream: PQuicStream): LongInt;
{ The stream a frame from the peer is about, opening peer streams as
  needed. nil with Code 0: a stream already forgotten (the frame is
  dropped); nil with a transport error code: the frame breaks the rules
  (a stream not open yet, or beyond the limit). }
function StreamForFrame(State: PQuicConnectionState; Id: QWord; out Code: QWord): PQuicStream;
{ The peer's data reached Highest on the stream: the connection's count
  goes up; False when that is beyond the connection limit. }
function NoteStreamDataReceived(State: PQuicConnectionState; Stream: PQuicStream; Highest: QWord): Boolean;
{ The application read Count bytes: limits move on when due. }
procedure NoteStreamDataRead(State: PQuicConnectionState; Stream: PQuicStream; Count: QWord);
{ The peer's limits from its transport parameters, for the streams
  open now and to come. }
procedure ApplyPeerStreamLimits(State: PQuicConnectionState);
{ Forgets the streams that are done. }
procedure RemoveFinishedStreams(State: PQuicConnectionState);
{ The connection's room for new stream bytes. }
function ConnectionSendCredit(State: PQuicConnectionState): QWord;

implementation

uses
  Quic.Constants,
  Quic.Errors;

function FindStream(State: PQuicConnectionState; Id: QWord): PQuicStream;
var
  Index: Integer;
begin
  for Index := 0 to State^.StreamCount - 1 do
    if State^.Streams[Index]^.Id = Id then
      Exit(State^.Streams[Index]);
  Result := nil;
end;

function StreamIsLocal(State: PQuicConnectionState; Id: QWord): Boolean;
begin
  Result := StreamIsServerInitiated(Id) = (State^.Role = RoleServer);
end;

{ The peer's initial limit for a stream, from its transport parameters. }
function PeerInitialStreamLimit(State: PQuicConnectionState; Id: QWord): QWord;
begin
  if not State^.PeerParametersKnown then
    Exit(0);
  if not StreamIsBidirectional(Id) then
    Result := State^.PeerParameters.InitialMaxStreamDataUni
  else if StreamIsLocal(State, Id) then
    { The peer's limit for streams this side opens. }
    Result := State^.PeerParameters.InitialMaxStreamDataBidiRemote
  else
    Result := State^.PeerParameters.InitialMaxStreamDataBidiLocal;
end;

function AddStream(State: PQuicConnectionState; Id: QWord): PQuicStream;
var
  Stream: PQuicStream;
begin
  New(Stream);
  Stream^ := Default(TQuicStream);
  Stream^.Id := Id;
  Stream^.LocallyInitiated := StreamIsLocal(State, Id);
  Stream^.CanSend := StreamIsBidirectional(Id) or Stream^.LocallyInitiated;
  Stream^.CanReceive := StreamIsBidirectional(Id) or not Stream^.LocallyInitiated;
  Stream^.Accepted := Stream^.LocallyInitiated;
  Stream^.Send.Initialize(State^.Options.StreamSendBuffer);
  Stream^.SendLimit := PeerInitialStreamLimit(State, Id);
  Stream^.ReceiveWindow := State^.Options.StreamWindow;
  Stream^.ReceiveLimit := Stream^.ReceiveWindow;
  Stream^.Receive.Initialize(Stream^.ReceiveWindow);
  if State^.StreamCount >= Length(State^.Streams) then
    SetLength(State^.Streams, State^.StreamCount * 2 + 8);
  State^.Streams[State^.StreamCount] := Stream;
  Inc(State^.StreamCount);
  Result := Stream;
end;

function OpenLocalStream(State: PQuicConnectionState; Bidirectional: Boolean; out Stream: PQuicStream): LongInt;
var
  Id: QWord;
begin
  Stream := nil;
  if Bidirectional then
  begin
    if State^.LocalBidirectionalOpened >= State^.PeerMaxStreamsBidirectional then
    begin
      State^.StreamsBlockedBidirectionalPending := True;
      Exit(QuicErrorStreamLimit);
    end;
    Id := State^.LocalBidirectionalOpened * 4;
    Inc(State^.LocalBidirectionalOpened);
  end
  else
  begin
    if State^.LocalUnidirectionalOpened >= State^.PeerMaxStreamsUnidirectional then
    begin
      State^.StreamsBlockedUnidirectionalPending := True;
      Exit(QuicErrorStreamLimit);
    end;
    Id := State^.LocalUnidirectionalOpened * 4 + StreamUnidirectional;
    Inc(State^.LocalUnidirectionalOpened);
  end;
  if State^.Role = RoleServer then
    Id := Id or StreamInitiatedByServer;
  Stream := AddStream(State, Id);
  Result := QuicErrorNone;
end;

function StreamForFrame(State: PQuicConnectionState; Id: QWord; out Code: QWord): PQuicStream;
var
  Index, Limit: QWord;
  Opened: PQWord;
  Base: QWord;
begin
  Code := 0;
  Result := FindStream(State, Id);
  if Result <> nil then
    Exit;
  Index := Id shr 2;
  if StreamIsLocal(State, Id) then
  begin
    { A stream of this side that was never opened, or one forgotten. }
    if StreamIsBidirectional(Id) then
      Limit := State^.LocalBidirectionalOpened
    else
      Limit := State^.LocalUnidirectionalOpened;
    if Index >= Limit then
      Code := TransportStreamStateError;
    Exit(nil);
  end;
  if StreamIsBidirectional(Id) then
  begin
    Opened := @State^.PeerBidirectionalOpened;
    Limit := State^.LocalMaxStreamsBidirectional;
  end
  else
  begin
    Opened := @State^.PeerUnidirectionalOpened;
    Limit := State^.LocalMaxStreamsUnidirectional;
  end;
  if Index < Opened^ then
    { Opened before and forgotten since. }
    Exit(nil);
  if Index >= Limit then
  begin
    Code := TransportStreamLimitError;
    Exit(nil);
  end;
  { Every stream of the kind below it opens with it. }
  Base := Id and 3;
  while Opened^ <= Index do
  begin
    Result := AddStream(State, Opened^ * 4 + Base);
    Inc(Opened^);
  end;
end;

function NoteStreamDataReceived(State: PQuicConnectionState; Stream: PQuicStream; Highest: QWord): Boolean;
begin
  if Highest > Stream^.Receive.HighestOffset then
    State^.DataReceived := State^.DataReceived + (Highest - Stream^.Receive.HighestOffset);
  Result := State^.DataReceived <= State^.LocalMaxData;
end;

procedure NoteStreamDataRead(State: PQuicConnectionState; Stream: PQuicStream; Count: QWord);
begin
  State^.DataConsumed := State^.DataConsumed + Count;
  { Half the window used: give the peer a new limit. }
  if not Stream^.Receive.FinalSizeKnown and
     (Stream^.Receive.ReadOffset + Stream^.ReceiveWindow div 2 >= Stream^.ReceiveLimit) then
  begin
    Stream^.ReceiveLimit := Stream^.Receive.ReadOffset + Stream^.ReceiveWindow;
    Stream^.MaxStreamDataPending := True;
  end;
  if State^.DataConsumed + State^.Options.ConnectionWindow div 2 >= State^.LocalMaxData then
  begin
    State^.LocalMaxData := State^.DataConsumed + State^.Options.ConnectionWindow;
    State^.MaxDataPending := True;
  end;
end;

procedure ApplyPeerStreamLimits(State: PQuicConnectionState);
var
  Index: Integer;
  Limit: QWord;
begin
  { MAX_DATA or MAX_STREAMS may have come first. }
  if State^.PeerParameters.InitialMaxData > State^.PeerMaxData then
    State^.PeerMaxData := State^.PeerParameters.InitialMaxData;
  if State^.PeerParameters.InitialMaxStreamsBidi > State^.PeerMaxStreamsBidirectional then
    State^.PeerMaxStreamsBidirectional := State^.PeerParameters.InitialMaxStreamsBidi;
  if State^.PeerParameters.InitialMaxStreamsUni > State^.PeerMaxStreamsUnidirectional then
    State^.PeerMaxStreamsUnidirectional := State^.PeerParameters.InitialMaxStreamsUni;
  for Index := 0 to State^.StreamCount - 1 do
  begin
    Limit := PeerInitialStreamLimit(State, State^.Streams[Index]^.Id);
    if Limit > State^.Streams[Index]^.SendLimit then
      State^.Streams[Index]^.SendLimit := Limit;
  end;
end;

procedure RemoveFinishedStreams(State: PQuicConnectionState);
var
  Index, Kept: Integer;
  Stream: PQuicStream;
begin
  Kept := 0;
  for Index := 0 to State^.StreamCount - 1 do
  begin
    Stream := State^.Streams[Index];
    if StreamSendDone(Stream) and StreamReceiveDone(Stream) and not Stream^.ResetPending and
       not Stream^.MaxStreamDataPending then
    begin
      if not Stream^.LocallyInitiated then
      begin
        { Room for another stream of the kind. }
        if StreamIsBidirectional(Stream^.Id) then
        begin
          Inc(State^.LocalMaxStreamsBidirectional);
          State^.MaxStreamsBidirectionalPending := True;
        end
        else
        begin
          Inc(State^.LocalMaxStreamsUnidirectional);
          State^.MaxStreamsUnidirectionalPending := True;
        end;
      end;
      Stream^.Send.Release;
      Stream^.Receive.Release;
      Dispose(Stream);
      Continue;
    end;
    State^.Streams[Kept] := Stream;
    Inc(Kept);
  end;
  State^.StreamCount := Kept;
  if State^.NextStreamToSend >= Kept then
    State^.NextStreamToSend := 0;
end;

function ConnectionSendCredit(State: PQuicConnectionState): QWord;
begin
  if State^.DataSent >= State^.PeerMaxData then
    Exit(0);
  Result := State^.PeerMaxData - State^.DataSent;
end;

end.
