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
  The numbers of HTTP/3 (RFC 9114): frame types, unidirectional stream
  types, settings and error codes; and the library's own HTTP-level
  error results (negative, beside libquic's QuicError* ones).
}
unit Http3.Constants;

{$mode objfpc}
{$H+}

interface

const
  { Frame types (section 7.2). }
  Http3FrameData = $00;
  Http3FrameHeaders = $01;
  Http3FrameCancelPush = $03;
  Http3FrameSettings = $04;
  Http3FramePushPromise = $05;
  Http3FrameGoaway = $07;
  Http3FrameMaxPushId = $0D;
  { RFC 9218 section 7.2: a request stream's new priority, on the
    control stream. }
  Http3FramePriorityUpdate = $F0700;

  { Unidirectional stream types (section 6.2; RFC 9204 section 4.2). }
  Http3StreamControl = $00;
  Http3StreamPush = $01;
  Http3StreamQpackEncoder = $02;
  Http3StreamQpackDecoder = $03;

  { Settings (section 7.2.4.1; RFC 9204 section 5). }
  Http3SettingQpackMaxTableCapacity = $01;
  Http3SettingMaxFieldSectionSize = $06;
  Http3SettingQpackBlockedStreams = $07;

  { Error codes (section 8.1). }
  Http3NoError = $0100;
  Http3GeneralProtocolError = $0101;
  Http3InternalError = $0102;
  Http3StreamCreationError = $0103;
  Http3ClosedCriticalStream = $0104;
  Http3FrameUnexpected = $0105;
  Http3FrameError = $0106;
  Http3ExcessiveLoad = $0107;
  Http3IdError = $0108;
  Http3SettingsError = $0109;
  Http3MissingSettings = $010A;
  Http3RequestRejected = $010B;
  Http3RequestCancelled = $010C;
  Http3RequestIncomplete = $010D;
  Http3MessageError = $010E;
  Http3ConnectError = $010F;
  Http3VersionFallback = $0110;

  { Results of the HTTP/3 calls besides QuicError*. }
  Http3ErrorNone = 0;
  { The response broke HTTP's rules (RFC 9114 section 4.1.2). }
  Http3ErrorMalformedResponse = -101;
  { The server reset the request stream (its code is kept). }
  Http3ErrorRequestReset = -102;
  { The connection broke an HTTP/3 rule and was closed. }
  Http3ErrorConnection = -103;
  { The server is going away (GOAWAY): no new requests. }
  Http3ErrorGoingAway = -104;
  { The response ended before its head or body was complete. }
  Http3ErrorIncomplete = -105;
  { The call is not possible in the request's state. }
  Http3ErrorInvalidState = -106;
  { The request was given up by its caller while it waited. }
  Http3ErrorCanceled = -107;

{ "H3_FRAME_UNEXPECTED", "QPACK_DECOMPRESSION_FAILED", ... }
function Http3ErrorName(Code: QWord): string;

implementation

uses
  SysUtils;

function Http3ErrorName(Code: QWord): string;
begin
  case Code of
    Http3NoError: Result := 'H3_NO_ERROR';
    Http3GeneralProtocolError: Result := 'H3_GENERAL_PROTOCOL_ERROR';
    Http3InternalError: Result := 'H3_INTERNAL_ERROR';
    Http3StreamCreationError: Result := 'H3_STREAM_CREATION_ERROR';
    Http3ClosedCriticalStream: Result := 'H3_CLOSED_CRITICAL_STREAM';
    Http3FrameUnexpected: Result := 'H3_FRAME_UNEXPECTED';
    Http3FrameError: Result := 'H3_FRAME_ERROR';
    Http3ExcessiveLoad: Result := 'H3_EXCESSIVE_LOAD';
    Http3IdError: Result := 'H3_ID_ERROR';
    Http3SettingsError: Result := 'H3_SETTINGS_ERROR';
    Http3MissingSettings: Result := 'H3_MISSING_SETTINGS';
    Http3RequestRejected: Result := 'H3_REQUEST_REJECTED';
    Http3RequestCancelled: Result := 'H3_REQUEST_CANCELLED';
    Http3RequestIncomplete: Result := 'H3_REQUEST_INCOMPLETE';
    Http3MessageError: Result := 'H3_MESSAGE_ERROR';
    Http3ConnectError: Result := 'H3_CONNECT_ERROR';
    Http3VersionFallback: Result := 'H3_VERSION_FALLBACK';
    $0200: Result := 'QPACK_DECOMPRESSION_FAILED';
    $0201: Result := 'QPACK_ENCODER_STREAM_ERROR';
    $0202: Result := 'QPACK_DECODER_STREAM_ERROR';
  else
    Result := '0x' + IntToHex(Code, 1);
  end;
end;

end.
