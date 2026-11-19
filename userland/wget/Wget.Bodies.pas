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
  What arrives goes to a sink (Wget.Sinks): the output, nothing, or a
  decoder in front of the output. DrainBody reads a body that is not
  wanted (a redirection's, an error's) so the connection can be used
  again.
}
unit Wget.Bodies;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Wget.Connections,
  Wget.Headers,
  Wget.Progress,
  Wget.Sinks;

const
  { A larger unwanted body is not read: the connection is closed. }
  MaximumDrainedBody = 1024 * 1024;

type
  TBodyOutcome = (BodyComplete, BodyEndedEarly, BodyConnectionFailed, BodyMalformed, BodyWriteFailed,
    BodyDecodeFailed);

{ Received counts the body bytes as they came (before any decoding).
  WriteError is the system's error code when writing failed. }
function ReceiveBody(Connection: TConnection; constref Response: THttpResponseHead; Sink: TBodySink;
  var Progress: TProgress; out Received: Int64; out WriteError: LongInt): TBodyOutcome;
{ Reads and drops the body; True if the connection can carry another
  request afterwards (the body had a known end, not too far off, and
  arrived whole). }
function DrainBody(Connection: TConnection; constref Response: THttpResponseHead): Boolean;

implementation

uses
  Abi.SystemCalls,
  Wget.Chunks;

const
  ReadSize = 16 * 1024;

function WriteData(Sink: TBodySink; var Progress: TProgress; Data: PByte; Length: PtrUInt;
  var Received: Int64; out WriteError: LongInt): Boolean;
begin
  WriteError := ErrorNone;
  if Length = 0 then
    Exit(True);
  Received := Received + Int64(Length);
  AdvanceProgress(Progress, Length);
  WriteError := Sink.Write(Data, Length);
  Result := WriteError = ErrorNone;
end;

{ What a failed write means. }
function WriteFailure(WriteError: LongInt): TBodyOutcome;
begin
  if WriteError = SinkDamagedData then
    Result := BodyDecodeFailed
  else
    Result := BodyWriteFailed;
end;

{ A body that arrived whole: the sink is told it ended. }
function Completed(Sink: TBodySink; out WriteError: LongInt): TBodyOutcome;
begin
  WriteError := Sink.Finish;
  if WriteError = ErrorNone then
    Result := BodyComplete
  else
    Result := WriteFailure(WriteError);
end;

function ReceiveChunkedBody(Connection: TConnection; Sink: TBodySink; var Progress: TProgress;
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
    RawLength := Connection.Receive(@Raw[0], SizeOf(Raw));
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
      if not WriteData(Sink, Progress, @Decoded[0], DecodedLength, Received, WriteError) then
        Exit(WriteFailure(WriteError));
      Offset := Offset + Consumed;
    end;
  end;
  Result := Completed(Sink, WriteError);
end;

function ReceiveBody(Connection: TConnection; constref Response: THttpResponseHead; Sink: TBodySink;
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
    Exit(ReceiveChunkedBody(Connection, Sink, Progress, Received, WriteError));
  while (Response.ContentLength < 0) or (Received < Response.ContentLength) do
  begin
    Wanted := SizeOf(Buffer);
    if (Response.ContentLength >= 0) and (Response.ContentLength - Received < Wanted) then
      Wanted := Response.ContentLength - Received;
    Count := Connection.Receive(@Buffer[0], Wanted);
    if Count < 0 then
      Exit(BodyConnectionFailed);
    if Count = 0 then
    begin
      { Without a length the body ends with the connection. }
      if Response.ContentLength < 0 then
        Exit(Completed(Sink, WriteError));
      Exit(BodyEndedEarly);
    end;
    if not WriteData(Sink, Progress, @Buffer[0], Count, Received, WriteError) then
      Exit(WriteFailure(WriteError));
  end;
  Result := Completed(Sink, WriteError);
end;

function DrainBody(Connection: TConnection; constref Response: THttpResponseHead): Boolean;
var
  Sink: TDiscardSink;
  Progress: TProgress;
  Received: Int64;
  WriteError: LongInt;
begin
  if StatusHasNoBody(Response.StatusCode) then
    Exit(True);
  if not Response.Chunked and ((Response.ContentLength < 0) or (Response.ContentLength > MaximumDrainedBody)) then
    Exit(False);
  Sink := TDiscardSink.Create;
  try
    BeginProgress(Progress, '', -1, 0, True);
    Result := (ReceiveBody(Connection, Response, Sink, Progress, Received, WriteError) = BodyComplete) and
      (Received <= MaximumDrainedBody);
  finally
    Sink.Free;
  end;
end;

end.
