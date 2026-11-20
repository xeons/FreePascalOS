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
  What a QUIC connection runs over: two routines that move datagrams to
  and from its peer, so the protocol code does not care whether they go
  through the system's UDP sockets (Quic.UdpSockets) or a test's.

  Send sends one datagram (all of it) and returns QuicErrorNone or an
  error. Receive waits up to TimeoutMilliseconds (0: not at all) for a
  datagram from the peer and returns its length, 0 when none came in
  time, or an error.
}
unit Quic.DatagramTransports;

{$mode objfpc}

interface

type
  TQuicSendDatagram = function(Context: Pointer; Data: PByte; Length: PtrUInt): LongInt;
  TQuicReceiveDatagram = function(Context: Pointer; Buffer: PByte; Capacity: PtrUInt;
    TimeoutMilliseconds: Int64): Int64;

  TQuicDatagramTransport = record
    Context: Pointer;
    Send: TQuicSendDatagram;
    Receive: TQuicReceiveDatagram;
  end;

{ Milliseconds from some fixed point: the clock of timers and RTTs. }
function QuicMilliseconds: Int64;

implementation

uses
  SysUtils;

function QuicMilliseconds: Int64;
begin
  Result := Int64(GetTickCount64);
end;

end.
