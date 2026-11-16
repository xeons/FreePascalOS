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
  Copying the standard input to a connected socket and the socket to
  the standard output, both at once: one thread waits on the two
  handles together (CallWaitForHandles takes a socket, a pipe, a
  terminal or a file alike; a file is always ready) and moves whatever
  is ready. The input comes first when both are, so a file is sent
  whole before the peer's end is acted on.

  It ends when the peer ends its stream (TCP), when the connection
  fails, when nothing moved for -w seconds, or -q seconds after the end
  of the input. At the end of the input -N shuts the socket's sending
  side, so the peer sees the end too; otherwise the socket stays open
  for what the peer still sends.
}
unit Netcat.Relay;

{$mode objfpc}

interface

var
  { The standard input reached its end (or -d): later connections (-k)
    do not read it again. }
  InputIsFinished: Boolean = False;

{ Copies until the connection is done; False if it ended in an error
  (reported). }
function RelayConnection(Socket: Int64): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Kernel,
  Sys.Objects,
  Sys.Sockets,
  Sys.Time,
  Util.Messages,
  Netcat.Settings;

const
  TransferBytes = 16384;

type
  TRelayOutcome = (RelayGoesOn, RelayFinished, RelayFailed);

  TRelayState = record
    Socket: Int64;
    LastActivity: QWord;
    InputEndedAt: QWord;
  end;

var
  Buffer: array[0..TransferBytes - 1] of Byte;

function WriteAllToOutput(Data: PByte; Count: QWord): Boolean;
var
  Done: QWord;
  Written: Int64;
begin
  Done := 0;
  while Done < Count do
  begin
    Written := KernelWrite(StandardOutputHandle, Data + Done, Count - Done);
    if Written <= 0 then
      Exit(False);
    Done := Done + QWord(Written);
  end;
  Result := True;
end;

{ UDP: one datagram per piece of at most MaximumDatagramBytes. }
function SendToPeer(Socket: Int64; Data: PByte; Count: QWord): LongInt;
var
  Done: QWord;
  Piece: QWord;
  Sent: Int64;
begin
  if not Settings.Datagrams then
    Exit(SendAll(Socket, Data, Count));
  Done := 0;
  while Done < Count do
  begin
    Piece := Count - Done;
    if Piece > MaximumDatagramBytes then
      Piece := MaximumDatagramBytes;
    Sent := SendOnSocket(Socket, Data + Done, Piece, 0);
    if Sent < 0 then
      Exit(ErrorCodeOf(Sent));
    Done := Done + Piece;
  end;
  Result := ErrorNone;
end;

procedure FinishInput(var State: TRelayState);
begin
  InputIsFinished := True;
  State.InputEndedAt := UptimeMilliseconds;
  if Settings.ShutdownAtEndOfInput and not Settings.Datagrams then
    ShutdownSocket(State.Socket, SocketShutdownSend);
end;

function MoveInput(var State: TRelayState): TRelayOutcome;
var
  Count: Int64;
  Error: LongInt;
begin
  Count := KernelRead(StandardInputHandle, @Buffer[0], TransferBytes);
  if Count <= 0 then
  begin
    FinishInput(State);
    if Settings.QuitAfterInputMilliseconds = 0 then
      Exit(RelayFinished);
    Exit(RelayGoesOn);
  end;
  State.LastActivity := UptimeMilliseconds;
  Error := SendToPeer(State.Socket, @Buffer[0], QWord(Count));
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'write failed', []);
    Exit(RelayFailed);
  end;
  Result := RelayGoesOn;
end;

function MoveOutput(var State: TRelayState): TRelayOutcome;
var
  Count: Int64;
begin
  Count := ReceiveOnSocket(State.Socket, @Buffer[0], TransferBytes, 0);
  if Count < 0 then
  begin
    ReportError(ErrorCodeOf(Count), 'read failed', []);
    Exit(RelayFailed);
  end;
  { The end of a stream; for UDP an empty datagram, which is nothing to
    write. }
  if (Count = 0) and not Settings.Datagrams then
    Exit(RelayFinished);
  State.LastActivity := UptimeMilliseconds;
  if not WriteAllToOutput(@Buffer[0], QWord(Count)) then
    Exit(RelayFinished);
  Result := RelayGoesOn;
end;

function Earlier(First, Second: Int64): Int64;
begin
  if (First = NoTimeLimit) or ((Second <> NoTimeLimit) and (Second < First)) then
    Result := Second
  else
    Result := First;
end;

{ Milliseconds the next wait may last: until the connection has been
  idle for -w, or -q after the end of the input; InfiniteWait if
  neither applies. }
function WaitLimit(constref State: TRelayState): Int64;
var
  Now: QWord;
  Limit: Int64;
  Deadline: QWord;
begin
  Now := UptimeMilliseconds;
  Limit := NoTimeLimit;
  if Settings.TimeoutMilliseconds <> NoTimeLimit then
  begin
    Deadline := State.LastActivity + QWord(Settings.TimeoutMilliseconds);
    if Deadline > Now then
      Limit := Earlier(Limit, Int64(Deadline - Now))
    else
      Limit := 0;
  end;
  if InputIsFinished and (Settings.QuitAfterInputMilliseconds <> NoTimeLimit) then
  begin
    Deadline := State.InputEndedAt + QWord(Settings.QuitAfterInputMilliseconds);
    if Deadline > Now then
      Limit := Earlier(Limit, Int64(Deadline - Now))
    else
      Limit := 0;
  end;
  if Limit = NoTimeLimit then
    Result := InfiniteWait
  else
    Result := Limit;
end;

{ Waits for the input and the socket; the input is left out once it
  ended, or if it cannot be waited on (it is then taken as ended). }
function WaitForEither(var State: TRelayState): TRelayOutcome;
const
  InputPosition = 0;
  SocketPosition = 1;
var
  Ready: Int64;
begin
  if InputIsFinished then
  begin
    Ready := WaitForHandles([State.Socket], WaitLimit(State));
    { Numbered as in the wait for both. }
    if Ready = 0 then
      Ready := SocketPosition;
  end
  else
    Ready := WaitForHandles([StandardInputHandle, State.Socket], WaitLimit(State));
  if Ready = -ErrorTimedOut then
    Exit(RelayFinished);
  if (Ready = -ErrorBadHandle) or (Ready = -ErrorUnsupported) then
  begin
    FinishInput(State);
    Exit(RelayGoesOn);
  end;
  if Ready < 0 then
  begin
    ReportError(ErrorCodeOf(Ready), 'cannot wait for the connection', []);
    Exit(RelayFailed);
  end;
  if Ready = InputPosition then
    Result := MoveInput(State)
  else
    Result := MoveOutput(State);
end;

function RelayConnection(Socket: Int64): Boolean;
var
  State: TRelayState;
  Outcome: TRelayOutcome;
begin
  State.Socket := Socket;
  State.LastActivity := UptimeMilliseconds;
  State.InputEndedAt := State.LastActivity;
  if Settings.IgnoreInput then
    InputIsFinished := True;
  repeat
    Outcome := WaitForEither(State);
  until Outcome <> RelayGoesOn;
  Result := Outcome = RelayFinished;
end;

end.
