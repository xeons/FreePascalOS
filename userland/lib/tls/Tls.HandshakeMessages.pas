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
  Sending and expecting handshake messages, for both versions'
  handshakes: what is sent goes into the transcript as well; what is
  expected must be of the type (or one of the two types) the handshake
  is ready for.
}
unit Tls.HandshakeMessages;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.Connections;

function SendHandshakeMessage(Connection: PTlsConnection; Message: PByte; Length: PtrUInt): LongInt;
{ The next message, which must be of type Expected (or, when
  Alternative is not 0, of that type). }
function ExpectMessage(Connection: PTlsConnection; Expected, Alternative: Byte; out MessageType: Byte;
  out Message: PByte; out MessageLength: PtrUInt): LongInt;
{ A Certificate message with no certificates (the answer to a request):
  TLS 1.3's has a context, TLS 1.2's only the empty list. }
function SendEmptyCertificate(Connection: PTlsConnection; Context: PByte; ContextLength: PtrUInt;
  Tls13: Boolean): LongInt;

implementation

uses
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Errors,
  Tls.RecordLayer,
  Tls.Transcript;

function SendHandshakeMessage(Connection: PTlsConnection; Message: PByte; Length: PtrUInt): LongInt;
begin
  AddToTranscript(Connection^.Transcript, Message, Length);
  Result := SendRecords(Connection, ContentHandshake, Message, Length);
end;

function ExpectMessage(Connection: PTlsConnection; Expected, Alternative: Byte; out MessageType: Byte;
  out Message: PByte; out MessageLength: PtrUInt): LongInt;
begin
  Result := NextHandshakeMessage(Connection, MessageType, Message, MessageLength);
  if Result <> TlsErrorNone then
    Exit;
  if (MessageType <> Expected) and ((Alternative = 0) or (MessageType <> Alternative)) then
    Result := TlsErrorUnexpectedMessage;
end;

function SendEmptyCertificate(Connection: PTlsConnection; Context: PByte; ContextLength: PtrUInt;
  Tls13: Boolean): LongInt;
var
  Message: TTlsBuilder;
  Body, ContextVector, List: PtrUInt;
begin
  InitializeBuilder(Message);
  AppendByte(Message, HandshakeCertificate);
  Body := BeginVector(Message, 3);
  if Tls13 then
  begin
    ContextVector := BeginVector(Message, 1);
    AppendBytes(Message, Context, ContextLength);
    EndVector(Message, ContextVector, 1);
  end;
  List := BeginVector(Message, 3);
  EndVector(Message, List, 3);
  EndVector(Message, Body, 3);
  if Message.Failed then
    Result := TlsErrorOutOfMemory
  else
    Result := SendHandshakeMessage(Connection, Message.Data, Message.Length);
  FreeBuilder(Message);
end;

end.
