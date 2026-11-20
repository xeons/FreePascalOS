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
  The numbers of QUIC version 1 (RFC 9000, RFC 9001, RFC 9002): the
  version, frame types, transport error codes, transport parameter
  identifiers, and the limits and defaults the library works with.
}
unit Quic.Constants;

{$mode objfpc}

interface

const
  QuicVersion1 = $00000001;

  { Packet number spaces, which are also the encryption levels without
    0-RTT. }
  SpaceInitial = 0;
  SpaceHandshake = 1;
  SpaceApplication = 2;
  SpaceCount = 3;

  { Frame types (RFC 9000 section 19). }
  FramePadding = $00;
  FramePing = $01;
  FrameAck = $02;
  FrameAckWithEcn = $03;
  FrameResetStream = $04;
  FrameStopSending = $05;
  FrameCrypto = $06;
  FrameNewToken = $07;
  { $08-$0F: STREAM with the OFF ($04), LEN ($02) and FIN ($01) bits. }
  FrameStream = $08;
  FrameStreamLast = $0F;
  FrameStreamOffsetBit = $04;
  FrameStreamLengthBit = $02;
  FrameStreamFinBit = $01;
  FrameMaxData = $10;
  FrameMaxStreamData = $11;
  FrameMaxStreamsBidirectional = $12;
  FrameMaxStreamsUnidirectional = $13;
  FrameDataBlocked = $14;
  FrameStreamDataBlocked = $15;
  FrameStreamsBlockedBidirectional = $16;
  FrameStreamsBlockedUnidirectional = $17;
  FrameNewConnectionId = $18;
  FrameRetireConnectionId = $19;
  FramePathChallenge = $1A;
  FramePathResponse = $1B;
  FrameConnectionCloseTransport = $1C;
  FrameConnectionCloseApplication = $1D;
  FrameHandshakeDone = $1E;

  { Transport error codes (RFC 9000 section 20.1). }
  TransportNoError = $00;
  TransportInternalError = $01;
  TransportConnectionRefused = $02;
  TransportFlowControlError = $03;
  TransportStreamLimitError = $04;
  TransportStreamStateError = $05;
  TransportFinalSizeError = $06;
  TransportFrameEncodingError = $07;
  TransportParameterError = $08;
  TransportConnectionIdLimitError = $09;
  TransportProtocolViolation = $0A;
  TransportInvalidToken = $0B;
  TransportApplicationError = $0C;
  TransportCryptoBufferExceeded = $0D;
  TransportKeyUpdateError = $0E;
  TransportAeadLimitReached = $0F;
  TransportNoViablePath = $10;
  { 0x0100-0x01FF: CRYPTO_ERROR, the TLS alert in the low byte. }
  TransportCryptoError = $0100;

  { Transport parameters (RFC 9000 section 18.2). }
  ParameterOriginalDestinationConnectionId = $00;
  ParameterMaxIdleTimeout = $01;
  ParameterStatelessResetToken = $02;
  ParameterMaxUdpPayloadSize = $03;
  ParameterInitialMaxData = $04;
  ParameterInitialMaxStreamDataBidiLocal = $05;
  ParameterInitialMaxStreamDataBidiRemote = $06;
  ParameterInitialMaxStreamDataUni = $07;
  ParameterInitialMaxStreamsBidi = $08;
  ParameterInitialMaxStreamsUni = $09;
  ParameterAckDelayExponent = $0A;
  ParameterMaxAckDelay = $0B;
  ParameterDisableActiveMigration = $0C;
  ParameterPreferredAddress = $0D;
  ParameterActiveConnectionIdLimit = $0E;
  ParameterInitialSourceConnectionId = $0F;
  ParameterRetrySourceConnectionId = $10;

  { Sizes. }
  MaximumConnectionIdLength = 20;
  StatelessResetTokenLength = 16;
  { Every datagram with an ack-eliciting Initial packet is at least
    this long, and every path must carry it (RFC 9000 section 14). }
  MinimumDatagramSize = 1200;
  { What a datagram may be at most here: 1500 bytes of Ethernet less the
    IPv6 and UDP headers. }
  MaximumDatagramSize = 1452;
  { The authentication tag of every AEAD QUIC uses. }
  PacketTagLength = 16;
  { The bytes of ciphertext header protection samples. }
  HeaderSampleLength = 16;
  { The smallest stateless reset that can be told from a packet (RFC
    9000 section 10.3). }
  MinimumStatelessResetLength = 21;

  { Defaults of the transport parameters (RFC 9000 section 18.2). }
  DefaultAckDelayExponent = 3;
  DefaultMaxAckDelayMilliseconds = 25;
  DefaultActiveConnectionIdLimit = 2;
  DefaultMaxUdpPayloadSize = 65527;

  { RFC 9002's constants. }
  PacketThreshold = 3;
  { kTimeThreshold = 9/8 of an RTT. }
  TimeThresholdNumerator = 9;
  TimeThresholdDenominator = 8;
  TimerGranularityMilliseconds = 1;
  InitialRttMilliseconds = 333;
  PersistentCongestionThreshold = 3;

  { Stream identifiers: the low two bits. }
  StreamInitiatedByServer = $01;
  StreamUnidirectional = $02;
  MaximumStreamCount = QWord(1) shl 60;

implementation

end.
