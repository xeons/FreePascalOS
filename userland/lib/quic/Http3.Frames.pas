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
  HTTP/3 frames (RFC 9114 section 7): a type and a length as QUIC
  variable-length integers, then the payload. Writing the frames the
  client sends (DATA, HEADERS, SETTINGS, GOAWAY) and reading SETTINGS
  and GOAWAY payloads; a stream's frames are taken apart as they arrive
  by THttp3FrameParser (Http3.FrameParser).

  SETTINGS: each identifier at most once; the HTTP/2 settings 0x02 to
  0x05 are refused (section 7.2.4.1); unknown ones are passed over.
}
unit Http3.Frames;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  THttp3Settings = record
    QpackMaxTableCapacity: QWord;
    MaxFieldSectionSize: QWord;
    QpackBlockedStreams: QWord;
  end;

{ The bytes of a frame's header (type and length). }
function FrameHeader(FrameType, PayloadLength: QWord): TBytes;
{ A whole frame. }
function MakeFrame(FrameType: QWord; Payload: PByte; Length: PtrUInt): TBytes;
function EncodeSettings(constref Settings: THttp3Settings): TBytes;
{ A SETTINGS payload: False on a malformed or forbidden setting. }
function DecodeSettings(Payload: PByte; Length: PtrUInt; out Settings: THttp3Settings): Boolean;
function DecodeGoaway(Payload: PByte; Length: PtrUInt; out Identifier: QWord): Boolean;
{ Reserved types (0x1f * N + 0x21) are there to be ignored. }
function FrameTypeIsReserved(FrameType: QWord): Boolean;

implementation

uses
  Http3.Constants,
  Quic.Buffers,
  Quic.VariableIntegers;

function FrameHeader(FrameType, PayloadLength: QWord): TBytes;
var
  Buffer: array[0..15] of Byte;
  Count: Integer;
begin
  Result := nil;
  Count := EncodeVariableInteger(FrameType, @Buffer[0]);
  Count := Count + EncodeVariableInteger(PayloadLength, @Buffer[Count]);
  SetLength(Result, Count);
  Move(Buffer[0], Result[0], Count);
end;

function MakeFrame(FrameType: QWord; Payload: PByte; Length: PtrUInt): TBytes;
var
  Header: TBytes;
begin
  Header := FrameHeader(FrameType, Length);
  Result := nil;
  SetLength(Result, System.Length(Header) + Length);
  Move(Header[0], Result[0], System.Length(Header));
  if Length > 0 then
    Move(Payload^, Result[System.Length(Header)], Length);
end;

function EncodeSettings(constref Settings: THttp3Settings): TBytes;
var
  Buffer: array[0..63] of Byte;
  Writer: TQuicWriter;
begin
  Writer.Initialize(@Buffer[0], SizeOf(Buffer));
  Writer.WriteVariable(Http3SettingQpackMaxTableCapacity);
  Writer.WriteVariable(Settings.QpackMaxTableCapacity);
  Writer.WriteVariable(Http3SettingQpackBlockedStreams);
  Writer.WriteVariable(Settings.QpackBlockedStreams);
  if Settings.MaxFieldSectionSize > 0 then
  begin
    Writer.WriteVariable(Http3SettingMaxFieldSectionSize);
    Writer.WriteVariable(Settings.MaxFieldSectionSize);
  end;
  Result := MakeFrame(Http3FrameSettings, @Buffer[0], Writer.Length);
end;

function DecodeSettings(Payload: PByte; Length: PtrUInt; out Settings: THttp3Settings): Boolean;
var
  Reader: TQuicReader;
  Identifier, Value: QWord;
  Seen: array of QWord;
  Index: Integer;
begin
  Settings := Default(THttp3Settings);
  Seen := nil;
  Reader.Initialize(Payload, Length);
  while not Reader.AtEnd do
  begin
    if not Reader.ReadVariable(Identifier) or not Reader.ReadVariable(Value) then
      Exit(False);
    if (Identifier >= 2) and (Identifier <= 5) then
      Exit(False);
    for Index := 0 to High(Seen) do
      if Seen[Index] = Identifier then
        Exit(False);
    SetLength(Seen, System.Length(Seen) + 1);
    Seen[High(Seen)] := Identifier;
    case Identifier of
      Http3SettingQpackMaxTableCapacity: Settings.QpackMaxTableCapacity := Value;
      Http3SettingMaxFieldSectionSize: Settings.MaxFieldSectionSize := Value;
      Http3SettingQpackBlockedStreams: Settings.QpackBlockedStreams := Value;
    end;
  end;
  Result := True;
end;

function DecodeGoaway(Payload: PByte; Length: PtrUInt; out Identifier: QWord): Boolean;
begin
  Result := (Length > 0) and (DecodeVariableInteger(Payload, Length, Identifier) = Integer(Length));
end;

function FrameTypeIsReserved(FrameType: QWord): Boolean;
begin
  Result := (FrameType >= $21) and ((FrameType - $21) mod $1F = 0);
end;

end.
