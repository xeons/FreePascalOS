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
  HTTP/2 frames (RFC 9113 section 4 and 6, and RFC 9218's
  PRIORITY_UPDATE): the 9-byte frame header (24-bit length, type,
  flags, 31-bit stream identifier), building each frame a client sends
  into a byte buffer (a header block split into HEADERS and
  CONTINUATION frames by the peer's maximum frame size), and reading
  the payloads it receives with their length rules (padding,
  SETTINGS in sixes, PING of eight bytes, WINDOW_UPDATE of four with an
  increment of 1 to 2^31-1).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Http2Frames;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Http.ByteBuffers;

const
  Http2Preface = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  FrameHeaderSize = 9;
  DefaultMaximumFrameSize = 16384;
  LargestMaximumFrameSize = 16777215;
  DefaultInitialWindowSize = 65535;
  LargestWindowSize = $7FFFFFFF;

  FrameData = $0;
  FrameHeaders = $1;
  FramePriority = $2;
  FrameResetStream = $3;
  FrameSettings = $4;
  FramePushPromise = $5;
  FramePing = $6;
  FrameGoAway = $7;
  FrameWindowUpdate = $8;
  FrameContinuation = $9;
  FrameAlternativeService = $A;
  FrameOrigin = $C;
  FramePriorityUpdate = $10;

  FlagEndStream = $1;
  FlagAck = $1;
  FlagEndHeaders = $4;
  FlagPadded = $8;
  FlagPriority = $20;

  ErrorNoError = $0;
  ErrorProtocol = $1;
  ErrorInternal = $2;
  ErrorFlowControl = $3;
  ErrorSettingsTimeout = $4;
  ErrorStreamClosed = $5;
  ErrorFrameSize = $6;
  ErrorRefusedStream = $7;
  ErrorCancel = $8;
  ErrorCompression = $9;
  ErrorConnect = $A;
  ErrorEnhanceYourCalm = $B;
  ErrorInadequateSecurity = $C;
  ErrorHttp11Required = $D;

  SettingHeaderTableSize = $1;
  SettingEnablePush = $2;
  SettingMaximumConcurrentStreams = $3;
  SettingInitialWindowSize = $4;
  SettingMaximumFrameSize = $5;
  SettingMaximumHeaderListSize = $6;
  SettingEnableConnectProtocol = $8;
  SettingNoRfc7540Priorities = $9;

type
  THttp2FrameHeader = record
    Length: LongWord;
    FrameType: Byte;
    Flags: Byte;
    StreamId: LongWord;
  end;

  THttp2Setting = record
    Identifier: Word;
    Value: LongWord;
  end;

  THttp2SettingArray = array of THttp2Setting;

function ReadFrameHeader(Data: PByte): THttp2FrameHeader;
procedure AppendFrameHeader(var Buffer: THttpByteBuffer; Length: LongWord; FrameType, Flags: Byte; StreamId: LongWord);

procedure AppendSettingsFrame(var Buffer: THttpByteBuffer; constref Settings: array of THttp2Setting);
procedure AppendSettingsAck(var Buffer: THttpByteBuffer);
procedure AppendWindowUpdate(var Buffer: THttpByteBuffer; StreamId, Increment: LongWord);
procedure AppendPing(var Buffer: THttpByteBuffer; Ack: Boolean; Opaque: PByte);
procedure AppendGoAway(var Buffer: THttpByteBuffer; LastStreamId, ErrorCode: LongWord; const Debug: string);
procedure AppendResetStream(var Buffer: THttpByteBuffer; StreamId, ErrorCode: LongWord);
procedure AppendDataFrame(var Buffer: THttpByteBuffer; StreamId: LongWord; Data: Pointer; Count: Integer;
  EndStream: Boolean);
{ A header block as HEADERS then CONTINUATION frames of at most
  MaximumFrameSize bytes each. }
procedure AppendHeaderBlock(var Buffer: THttpByteBuffer; StreamId: LongWord; Block: PByte; Count: Integer;
  EndStream: Boolean; MaximumFrameSize: LongWord);
procedure AppendPriorityUpdate(var Buffer: THttpByteBuffer; PrioritizedStreamId: LongWord; const FieldValue: string);

{ A DATA or HEADERS payload without its padding (and HEADERS' priority
  fields): where the content starts and how long it is. False for
  padding longer than the payload. }
function FramePayloadContent(constref Header: THttp2FrameHeader; Payload: PByte; out Start, Count: LongWord): Boolean;
function ParseSettings(Payload: PByte; Length: LongWord; out Settings: THttp2SettingArray): Boolean;
function ParseGoAway(Payload: PByte; Length: LongWord; out LastStreamId, ErrorCode: LongWord;
  out Debug: string): Boolean;
function ParseWindowUpdate(Payload: PByte; Length: LongWord; out Increment: LongWord): Boolean;
function ParseResetStream(Payload: PByte; Length: LongWord; out ErrorCode: LongWord): Boolean;

function Http2ErrorName(ErrorCode: LongWord): string;

implementation

uses
  SysUtils;

function ReadFrameHeader(Data: PByte): THttp2FrameHeader;
begin
  Result.Length := ReadUInt24(Data);
  Result.FrameType := Data[3];
  Result.Flags := Data[4];
  Result.StreamId := ReadUInt32(Data + 5) and $7FFFFFFF;
end;

procedure AppendFrameHeader(var Buffer: THttpByteBuffer; Length: LongWord; FrameType, Flags: Byte; StreamId: LongWord);
begin
  AppendUInt24(Buffer, Length);
  AppendByte(Buffer, FrameType);
  AppendByte(Buffer, Flags);
  AppendUInt32(Buffer, StreamId and $7FFFFFFF);
end;

procedure AppendSettingsFrame(var Buffer: THttpByteBuffer; constref Settings: array of THttp2Setting);
var
  Setting: THttp2Setting;
begin
  AppendFrameHeader(Buffer, Length(Settings) * 6, FrameSettings, 0, 0);
  for Setting in Settings do
  begin
    AppendUInt16(Buffer, Setting.Identifier);
    AppendUInt32(Buffer, Setting.Value);
  end;
end;

procedure AppendSettingsAck(var Buffer: THttpByteBuffer);
begin
  AppendFrameHeader(Buffer, 0, FrameSettings, FlagAck, 0);
end;

procedure AppendWindowUpdate(var Buffer: THttpByteBuffer; StreamId, Increment: LongWord);
begin
  AppendFrameHeader(Buffer, 4, FrameWindowUpdate, 0, StreamId);
  AppendUInt32(Buffer, Increment and $7FFFFFFF);
end;

procedure AppendPing(var Buffer: THttpByteBuffer; Ack: Boolean; Opaque: PByte);
begin
  if Ack then
    AppendFrameHeader(Buffer, 8, FramePing, FlagAck, 0)
  else
    AppendFrameHeader(Buffer, 8, FramePing, 0, 0);
  AppendBytes(Buffer, Opaque, 8);
end;

procedure AppendGoAway(var Buffer: THttpByteBuffer; LastStreamId, ErrorCode: LongWord; const Debug: string);
begin
  AppendFrameHeader(Buffer, 8 + Length(Debug), FrameGoAway, 0, 0);
  AppendUInt32(Buffer, LastStreamId and $7FFFFFFF);
  AppendUInt32(Buffer, ErrorCode);
  AppendText(Buffer, Debug);
end;

procedure AppendResetStream(var Buffer: THttpByteBuffer; StreamId, ErrorCode: LongWord);
begin
  AppendFrameHeader(Buffer, 4, FrameResetStream, 0, StreamId);
  AppendUInt32(Buffer, ErrorCode);
end;

procedure AppendDataFrame(var Buffer: THttpByteBuffer; StreamId: LongWord; Data: Pointer; Count: Integer;
  EndStream: Boolean);
var
  Flags: Byte;
begin
  Flags := 0;
  if EndStream then
    Flags := FlagEndStream;
  AppendFrameHeader(Buffer, Count, FrameData, Flags, StreamId);
  AppendBytes(Buffer, Data, Count);
end;

procedure AppendHeaderBlock(var Buffer: THttpByteBuffer; StreamId: LongWord; Block: PByte; Count: Integer;
  EndStream: Boolean; MaximumFrameSize: LongWord);
var
  Offset, Piece: Integer;
  Flags, FrameType: Byte;
begin
  Offset := 0;
  FrameType := FrameHeaders;
  repeat
    Piece := Count - Offset;
    if Piece > Integer(MaximumFrameSize) then
      Piece := MaximumFrameSize;
    Flags := 0;
    if (FrameType = FrameHeaders) and EndStream then
      Flags := Flags or FlagEndStream;
    if Offset + Piece = Count then
      Flags := Flags or FlagEndHeaders;
    AppendFrameHeader(Buffer, Piece, FrameType, Flags, StreamId);
    AppendBytes(Buffer, Block + Offset, Piece);
    Inc(Offset, Piece);
    FrameType := FrameContinuation;
  until Offset >= Count;
end;

procedure AppendPriorityUpdate(var Buffer: THttpByteBuffer; PrioritizedStreamId: LongWord; const FieldValue: string);
begin
  AppendFrameHeader(Buffer, 4 + Length(FieldValue), FramePriorityUpdate, 0, 0);
  AppendUInt32(Buffer, PrioritizedStreamId and $7FFFFFFF);
  AppendText(Buffer, FieldValue);
end;

function FramePayloadContent(constref Header: THttp2FrameHeader; Payload: PByte; out Start, Count: LongWord): Boolean;
var
  Padding: LongWord;
begin
  Start := 0;
  Count := Header.Length;
  Padding := 0;
  if (Header.Flags and FlagPadded) <> 0 then
  begin
    if Header.Length < 1 then
      Exit(False);
    Padding := Payload[0];
    Start := 1;
  end;
  if (Header.FrameType = FrameHeaders) and ((Header.Flags and FlagPriority) <> 0) then
    Inc(Start, 5);
  if Start + Padding > Header.Length then
    Exit(False);
  Count := Header.Length - Start - Padding;
  Result := True;
end;

function ParseSettings(Payload: PByte; Length: LongWord; out Settings: THttp2SettingArray): Boolean;
var
  Index: Integer;
begin
  Settings := nil;
  if Length mod 6 <> 0 then
    Exit(False);
  SetLength(Settings, Length div 6);
  for Index := 0 to High(Settings) do
  begin
    Settings[Index].Identifier := ReadUInt16(Payload + Index * 6);
    Settings[Index].Value := ReadUInt32(Payload + Index * 6 + 2);
  end;
  Result := True;
end;

function ParseGoAway(Payload: PByte; Length: LongWord; out LastStreamId, ErrorCode: LongWord;
  out Debug: string): Boolean;
begin
  LastStreamId := 0;
  ErrorCode := 0;
  Debug := '';
  if Length < 8 then
    Exit(False);
  LastStreamId := ReadUInt32(Payload) and $7FFFFFFF;
  ErrorCode := ReadUInt32(Payload + 4);
  SetString(Debug, PChar(Payload + 8), Length - 8);
  Result := True;
end;

function ParseWindowUpdate(Payload: PByte; Length: LongWord; out Increment: LongWord): Boolean;
begin
  Increment := 0;
  if Length <> 4 then
    Exit(False);
  Increment := ReadUInt32(Payload) and $7FFFFFFF;
  Result := True;
end;

function ParseResetStream(Payload: PByte; Length: LongWord; out ErrorCode: LongWord): Boolean;
begin
  ErrorCode := 0;
  if Length <> 4 then
    Exit(False);
  ErrorCode := ReadUInt32(Payload);
  Result := True;
end;

function Http2ErrorName(ErrorCode: LongWord): string;
begin
  case ErrorCode of
    ErrorNoError: Result := 'NO_ERROR';
    ErrorProtocol: Result := 'PROTOCOL_ERROR';
    ErrorInternal: Result := 'INTERNAL_ERROR';
    ErrorFlowControl: Result := 'FLOW_CONTROL_ERROR';
    ErrorSettingsTimeout: Result := 'SETTINGS_TIMEOUT';
    ErrorStreamClosed: Result := 'STREAM_CLOSED';
    ErrorFrameSize: Result := 'FRAME_SIZE_ERROR';
    ErrorRefusedStream: Result := 'REFUSED_STREAM';
    ErrorCancel: Result := 'CANCEL';
    ErrorCompression: Result := 'COMPRESSION_ERROR';
    ErrorConnect: Result := 'CONNECT_ERROR';
    ErrorEnhanceYourCalm: Result := 'ENHANCE_YOUR_CALM';
    ErrorInadequateSecurity: Result := 'INADEQUATE_SECURITY';
    ErrorHttp11Required: Result := 'HTTP_1_1_REQUIRED';
  else
    Result := 'error 0x' + IntToHex(ErrorCode, 1);
  end;
end;

end.
