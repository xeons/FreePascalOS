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
  TCP buffers that grow with the connection, and the sizes sockets ask
  for (SocketOptionReceiveBuffer, SocketOptionSendBuffer).

  Receive buffer auto-tuning: the bytes the reader takes are counted
  over a round trip (the receiver's own measure from echoed timestamps,
  else the sender's smoothed round trip, at least 4 ms); when a round
  trip has passed, the buffer grows to four times that
  (Network.TcpWindows.TunedReceiveBuffer), up to 4 MiB - and the next
  acknowledgment advertises the larger window. Only with window scaling:
  without it no window can exceed 64 KiB.

  The send buffer grows when a writer finds it full and the connection
  could keep more in flight than half of it.

  A size set by its socket's option is kept: the buffer takes that size
  (never less than what it holds) and does not grow.
}
unit Network.TcpBuffers;

{$mode objfpc}

interface

uses
  Network.TcpTypes;

{ The reader took Count bytes from the receive buffer. }
procedure NoteBytesRead(Connection: PTcpConnection; Count: LongWord);
{ A writer found the send buffer full: True if it grew. }
function GrowSendBuffer(Connection: PTcpConnection): Boolean;
{ Applies the sizes the connection's socket asked for. }
procedure ApplyRequestedBuffers(Connection: PTcpConnection);

implementation

uses
  Network.Core,
  Network.ByteRings,
  Network.TcpWindows;

const
  MinimumTuningRoundTrip = 4 * NanosecondsPerMillisecond;
  UnmeasuredRoundTrip = 100 * NanosecondsPerMillisecond;

function TuningRoundTrip(Connection: PTcpConnection): QWord;
begin
  if Connection^.ReceiveRoundTrip <> 0 then
    Result := Connection^.ReceiveRoundTrip
  else if Connection^.HasRoundTripSample then
    Result := Connection^.SmoothedRoundTrip
  else
    Result := UnmeasuredRoundTrip;
  if Result < MinimumTuningRoundTrip then
    Result := MinimumTuningRoundTrip;
end;

procedure NoteBytesRead(Connection: PTcpConnection; Count: LongWord);
var
  Now: QWord;
  Capacity: LongWord;
begin
  if (Connection^.RequestedReceiveBuffer <> 0) or not Connection^.WindowScaling or
     (Connection^.ReceiveBuffer.Data = nil) then
    Exit;
  Now := NetworkNow;
  if Connection^.TuningStart = 0 then
    Connection^.TuningStart := Now;
  Connection^.TuningBytes := Connection^.TuningBytes + Count;
  if Now - Connection^.TuningStart < TuningRoundTrip(Connection) then
    Exit;
  Capacity := TunedReceiveBuffer(Connection^.ReceiveBuffer.Capacity, Connection^.TuningBytes,
    MaximumReceiveBufferBytes);
  if Capacity > Connection^.ReceiveBuffer.Capacity then
    ResizeByteRing(Connection^.ReceiveBuffer, Capacity);
  Connection^.TuningStart := Now;
  Connection^.TuningBytes := 0;
end;

function GrowSendBuffer(Connection: PTcpConnection): Boolean;
var
  Capacity: LongWord;
begin
  Result := False;
  if (Connection^.RequestedSendBuffer <> 0) or (Connection^.SendBuffer.Data = nil) then
    Exit;
  Capacity := TunedSendBuffer(Connection^.SendBuffer.Capacity, Connection^.CongestionWindow,
    Connection^.SendWindow, MaximumSendBufferBytes);
  if Capacity > Connection^.SendBuffer.Capacity then
    Result := ResizeByteRing(Connection^.SendBuffer, Capacity);
end;

procedure ResizeTo(var Ring: TByteRing; Requested: LongWord);
begin
  if (Requested = 0) or (Ring.Data = nil) then
    Exit;
  if Requested < Ring.Count then
    Requested := Ring.Count;
  ResizeByteRing(Ring, Requested);
end;

procedure ApplyRequestedBuffers(Connection: PTcpConnection);
begin
  ResizeTo(Connection^.ReceiveBuffer, Connection^.RequestedReceiveBuffer);
  ResizeTo(Connection^.SendBuffer, Connection^.RequestedSendBuffer);
end;

end.
