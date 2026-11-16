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
  Receiving a response body into the output (RFC 9112 section 6.3): as
  many bytes as Content-Length says, the chunks of a chunked body, or
  everything until the server closes the connection. A body that ends
  early is reported (the transfer may be retried from where it broke).
}
unit Wget.Bodies;

{$mode objfpc}
{$pointermath on}

interface

uses
  Wget.Connections,
  Wget.Files,
  Wget.Headers,
  Wget.Progress;

type
  TBodyOutcome = (BodyComplete, BodyEndedEarly, BodyConnectionFailed, BodyMalformed, BodyWriteFailed);

{ Received counts the body bytes written. WriteError is the system's
  error code when writing failed. }
function ReceiveBody(var Connection: TConnection; constref Response: THttpResponseHead; var Target: TOutputTarget;
  var Progress: TProgress; out Received: Int64; out WriteError: LongInt): TBodyOutcome;

implementation

uses
  Abi.SystemCalls,
  Wget.Chunks;

const
  ReadSize = 16 * 1024;

function WriteData(var Target: TOutputTarget; var Progress: TProgress; Data: PByte; Length: PtrUInt;
  var Received: Int64; out WriteError: LongInt): Boolean;
begin
  WriteError := ErrorNone;
  if Length = 0 then
    Exit(True);
  WriteError := WriteOutput(Target, Data, Length);
  if WriteError <> ErrorNone then
    Exit(False);
  Received := Received + Int64(Length);
  AdvanceProgress(Progress, Length);
  Result := True;
end;

function ReceiveChunkedBody(var Connection: TConnection; var Target: TOutputTarget; var Progress: TProgress;
  var Received: Int64; out WriteError: LongInt): TBodyOutcome;
var
  Decoder: TChunkDecoder;
  Raw: array[0..ReadSize - 1] of Byte;
  Decoded: array[0..ReadSize - 1] of Byte;
  RawLength: Int64;
  Offset: PtrUInt;
  DecodedLength, Consumed: PtrUInt;
begin
  WriteError := ErrorNone;
  BeginChunkDecoder(Decoder);
  while not ChunkDecoderFinished(Decoder) do
  begin
    RawLength := ReceiveFromConnection(Connection, @Raw[0], SizeOf(Raw));
    if RawLength < 0 then
      Exit(BodyConnectionFailed);
    if RawLength = 0 then
      Exit(BodyEndedEarly);
    Offset := 0;
    while (Offset < PtrUInt(RawLength)) and not ChunkDecoderFinished(Decoder) do
    begin
      if not DecodeChunks(Decoder, @Raw[Offset], PtrUInt(RawLength) - Offset, @Decoded[0], DecodedLength,
        Consumed) then
        Exit(BodyMalformed);
      if not WriteData(Target, Progress, @Decoded[0], DecodedLength, Received, WriteError) then
        Exit(BodyWriteFailed);
      Offset := Offset + Consumed;
    end;
  end;
  Result := BodyComplete;
end;

function ReceiveBody(var Connection: TConnection; constref Response: THttpResponseHead; var Target: TOutputTarget;
  var Progress: TProgress; out Received: Int64; out WriteError: LongInt): TBodyOutcome;
var
  Buffer: array[0..ReadSize - 1] of Byte;
  Wanted: Int64;
  Count: Int64;
begin
  Received := 0;
  WriteError := ErrorNone;
  if StatusHasNoBody(Response.StatusCode) then
    Exit(BodyComplete);
  if Response.Chunked then
    Exit(ReceiveChunkedBody(Connection, Target, Progress, Received, WriteError));
  while (Response.ContentLength < 0) or (Received < Response.ContentLength) do
  begin
    Wanted := SizeOf(Buffer);
    if (Response.ContentLength >= 0) and (Response.ContentLength - Received < Wanted) then
      Wanted := Response.ContentLength - Received;
    Count := ReceiveFromConnection(Connection, @Buffer[0], Wanted);
    if Count < 0 then
      Exit(BodyConnectionFailed);
    if Count = 0 then
    begin
      { Without a length the body ends with the connection. }
      if Response.ContentLength < 0 then
        Exit(BodyComplete);
      Exit(BodyEndedEarly);
    end;
    if not WriteData(Target, Progress, @Buffer[0], Count, Received, WriteError) then
      Exit(BodyWriteFailed);
  end;
  Result := BodyComplete;
end;

end.
