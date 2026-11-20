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
  HTTP/2 frames: every frame the client builds read back field by field
  (RFC 9113 section 6's layouts written out in hexadecimal), header
  blocks split into HEADERS and CONTINUATION, padding, and the payload
  length rules; RFC 9218's Priority field and PRIORITY_UPDATE.
}
unit HttpTest.Http2Frames;

{$mode objfpc}
{$H+}

interface

procedure TestHttp2Frames;

implementation

uses
  SysUtils,
  TestChecks,
  Http.ByteBuffers,
  Http.Http2Frames,
  Http.Priorities;

function HexOf(constref Buffer: THttpByteBuffer): string;
begin
  if Buffer.Length = 0 then
    Exit('');
  Result := BytesToHex(@Buffer.Data[0], Buffer.Length);
end;

procedure TestBuilding;
var
  Buffer: THttpByteBuffer;
  Settings: array[0..1] of THttp2Setting;
  Opaque: array[0..7] of Byte;
  Index: Integer;
  Header: THttp2FrameHeader;
  Block: array[0..39] of Byte;
begin
  Buffer := Default(THttpByteBuffer);
  Settings[0].Identifier := SettingEnablePush;
  Settings[0].Value := 0;
  Settings[1].Identifier := SettingInitialWindowSize;
  Settings[1].Value := $100000;
  AppendSettingsFrame(Buffer, Settings);
  Check(HexOf(Buffer) = '00000c040000000000' + '000200000000' + '000400100000', 'SETTINGS built');
  ClearBuffer(Buffer);
  AppendSettingsAck(Buffer);
  Check(HexOf(Buffer) = '000000040100000000', 'SETTINGS acknowledgement built');
  ClearBuffer(Buffer);
  AppendWindowUpdate(Buffer, 3, $00ff0001);
  Check(HexOf(Buffer) = '000004080000000003' + '00ff0001', 'WINDOW_UPDATE built');
  ClearBuffer(Buffer);
  for Index := 0 to 7 do
    Opaque[Index] := Index + 1;
  AppendPing(Buffer, True, @Opaque[0]);
  Check(HexOf(Buffer) = '000008060100000000' + '0102030405060708', 'PING acknowledgement built');
  ClearBuffer(Buffer);
  AppendGoAway(Buffer, 7, ErrorProtocol, 'bye');
  Check(HexOf(Buffer) = '00000b070000000000' + '00000007' + '00000001' + '627965', 'GOAWAY built');
  ClearBuffer(Buffer);
  AppendResetStream(Buffer, 5, ErrorCancel);
  Check(HexOf(Buffer) = '000004030000000005' + '00000008', 'RST_STREAM built');
  ClearBuffer(Buffer);
  AppendDataFrame(Buffer, 1, PChar('hi'), 2, True);
  Check(HexOf(Buffer) = '000002000100000001' + '6869', 'DATA with END_STREAM built');
  ClearBuffer(Buffer);
  AppendPriorityUpdate(Buffer, 9, 'u=1, i');
  Check(HexOf(Buffer) = '00000a100000000000' + '00000009' + '753d312c2069', 'PRIORITY_UPDATE built');
  { A 40-byte block in frames of 16: HEADERS 16, CONTINUATION 16, 8. }
  for Index := 0 to 39 do
    Block[Index] := Index;
  ClearBuffer(Buffer);
  AppendHeaderBlock(Buffer, 3, @Block[0], 40, True, 16);
  Check(Buffer.Length = 3 * 9 + 40, 'header block split into three frames');
  Header := ReadFrameHeader(@Buffer.Data[0]);
  Check((Header.Length = 16) and (Header.FrameType = FrameHeaders) and (Header.Flags = FlagEndStream) and
    (Header.StreamId = 3), 'HEADERS: END_STREAM, no END_HEADERS');
  Header := ReadFrameHeader(@Buffer.Data[25]);
  Check((Header.Length = 16) and (Header.FrameType = FrameContinuation) and (Header.Flags = 0), 'CONTINUATION');
  Header := ReadFrameHeader(@Buffer.Data[50]);
  Check((Header.Length = 8) and (Header.FrameType = FrameContinuation) and (Header.Flags = FlagEndHeaders) and
    (Buffer.Data[59] = 32), 'the last CONTINUATION ends the headers');
end;

procedure TestReading;
var
  Bytes: TByteArray;
  Header: THttp2FrameHeader;
  Start, Count, LastStream, ErrorCode, Increment: LongWord;
  Settings: THttp2SettingArray;
  Debug: string;
begin
  Bytes := HexToBytes('00000c0109800000ff' + '03' + '80000001' + '10' + '616263' + '000000');
  Header := ReadFrameHeader(@Bytes[0]);
  Check((Header.Length = 12) and (Header.FrameType = FrameHeaders) and (Header.Flags = $09) and
    (Header.StreamId = $FF), 'frame header read (reserved bit dropped)');
  Header.Flags := FlagPadded or FlagPriority;
  Check(FramePayloadContent(Header, @Bytes[9], Start, Count) and (Start = 6) and (Count = 3),
    'padding and priority fields skipped');
  Header.Length := 3;
  Check(not FramePayloadContent(Header, @Bytes[9], Start, Count), 'padding longer than the frame refused');
  Bytes := HexToBytes('000300000064' + '0004ffffffff');
  Check(ParseSettings(@Bytes[0], 12, Settings) and (Length(Settings) = 2) and (Settings[0].Value = 100) and
    (Settings[1].Identifier = SettingInitialWindowSize), 'SETTINGS read');
  Check(not ParseSettings(@Bytes[0], 7, Settings), 'SETTINGS not a multiple of six refused');
  Bytes := HexToBytes('8000000500000002' + '6869');
  Check(ParseGoAway(@Bytes[0], 10, LastStream, ErrorCode, Debug) and (LastStream = 5) and
    (ErrorCode = ErrorInternal) and (Debug = 'hi'), 'GOAWAY read');
  Bytes := HexToBytes('80000010');
  Check(ParseWindowUpdate(@Bytes[0], 4, Increment) and (Increment = 16), 'WINDOW_UPDATE read');
  Check(not ParseWindowUpdate(@Bytes[0], 3, Increment), 'WINDOW_UPDATE of three bytes refused');
  Check(ParseResetStream(@Bytes[0], 4, ErrorCode) and not ParseResetStream(@Bytes[0], 5, ErrorCode),
    'RST_STREAM length');
  Check(Http2ErrorName(ErrorRefusedStream) = 'REFUSED_STREAM', 'error names');
end;

procedure TestPriorities;
var
  Priority: THttpPriority;
begin
  Check(FormatPriorityField(DefaultPriority) = '', 'priority: the default is not sent');
  Check(FormatPriorityField(MakePriority(0, True)) = 'u=0, i', 'priority: u=0, i');
  Check(FormatPriorityField(MakePriority(5, False)) = 'u=5', 'priority: u=5');
  Priority := ParsePriorityField('u=1, i');
  Check((Priority.Urgency = 1) and Priority.Incremental, 'priority: parsed');
  Priority := ParsePriorityField('i=?0, u=9, x=3');
  Check((Priority.Urgency = 3) and not Priority.Incremental, 'priority: bad values and unknown members ignored');
  Priority := ParsePriorityField('u=6;a=b, i;c');
  Check((Priority.Urgency = 6) and Priority.Incremental, 'priority: parameters ignored');
end;

procedure TestHttp2Frames;
begin
  TestBuilding;
  TestReading;
  TestPriorities;
end;

end.
