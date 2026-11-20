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
  The contents of libquic.so: QUIC version 1 (RFC 9000, 9001, 9002),
  QPACK (RFC 9204) and HTTP/3 (RFC 9114), client side. Compiling this
  unit compiles all of them.

  Everything but Quic.UdpSockets and Quic.Sessions is plain Pascal over
  a datagram transport and builds on the host too (make quic-test).
}
unit Quic.Contents;

{$mode objfpc}

interface

uses
  Quic.VariableIntegers,
  Quic.Buffers,
  Quic.Constants,
  Quic.Errors,
  Quic.ConnectionIds,
  Quic.RangeSets,
  Quic.TransportParameters,
  Quic.Frames,
  Quic.FrameWriter,
  Quic.PacketHeaders,
  Quic.PacketProtection,
  Quic.InitialSecrets,
  Quic.SendBuffers,
  Quic.ReceiveBuffers,
  Quic.Streams,
  Quic.Congestion,
  Quic.SentPackets,
  Quic.DatagramTransports,
  Quic.ConnectionState,
  Quic.StreamTable,
  Quic.LossRecovery,
  Quic.PacketSending,
  Quic.FrameHandling,
  Quic.PacketReceiving,
  Quic.ConnectionCore,
  Quic.ClientHandshake,
  Quic.Connections,
  Quic.UdpSockets,
  Quic.Sessions,
  Qpack.StaticTable,
  Qpack.Primitives,
  Qpack.DynamicTable,
  Qpack.Decoder,
  Qpack.Encoder,
  Http3.Constants,
  Http3.Frames,
  Http3.FrameParser,
  Http3.Connections,
  Http3.Requests;

implementation

end.
