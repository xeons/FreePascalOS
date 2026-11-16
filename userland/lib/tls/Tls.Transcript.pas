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
  The transcript hash (RFC 8446 section 4.4.1): the hash of every
  handshake message so far, headers included.

  The hash is the cipher suite's, which is known only once the server
  has answered, so the ClientHello is kept until StartTranscript names
  it. A HelloRetryRequest replaces the first ClientHello by a synthetic
  message_hash message holding its hash (ReplaceWithMessageHash).
  TranscriptHash gives the hash so far without ending the running one.
}
unit Tls.Transcript;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Digests,
  Tls.ByteBuffers;

type
  TTlsTranscript = record
    Started: Boolean;
    Hash: TDigestAlgorithm;
    Running: TDigestContext;
    { Messages before the hash is known. }
    Pending: TTlsBuilder;
  end;

procedure InitializeTranscript(out Transcript: TTlsTranscript);
procedure FreeTranscript(var Transcript: TTlsTranscript);
procedure AddToTranscript(var Transcript: TTlsTranscript; Data: PByte; Length: PtrUInt);
procedure StartTranscript(var Transcript: TTlsTranscript; Hash: TDigestAlgorithm);
procedure TranscriptHash(constref Transcript: TTlsTranscript; out Output: TDigestOutput);
{ After a HelloRetryRequest: the transcript so far (the first
  ClientHello) becomes message_hash(Hash(ClientHello1)). }
procedure ReplaceWithMessageHash(var Transcript: TTlsTranscript);

implementation

uses
  Crypto.Bits,
  Tls.Constants;

procedure InitializeTranscript(out Transcript: TTlsTranscript);
begin
  FillChar(Transcript, SizeOf(Transcript), 0);
  InitializeBuilder(Transcript.Pending);
end;

procedure FreeTranscript(var Transcript: TTlsTranscript);
begin
  FreeBuilder(Transcript.Pending);
  WipeMemory(@Transcript.Running, SizeOf(Transcript.Running));
  Transcript.Started := False;
end;

procedure AddToTranscript(var Transcript: TTlsTranscript; Data: PByte; Length: PtrUInt);
begin
  if Transcript.Started then
    UpdateDigest(Transcript.Running, Data, Length)
  else
    AppendBytes(Transcript.Pending, Data, Length);
end;

procedure StartTranscript(var Transcript: TTlsTranscript; Hash: TDigestAlgorithm);
begin
  if Transcript.Started then
    Exit;
  Transcript.Hash := Hash;
  BeginDigest(Transcript.Running, Hash);
  if Transcript.Pending.Length > 0 then
    UpdateDigest(Transcript.Running, Transcript.Pending.Data, Transcript.Pending.Length);
  FreeBuilder(Transcript.Pending);
  Transcript.Started := True;
end;

procedure TranscriptHash(constref Transcript: TTlsTranscript; out Output: TDigestOutput);
var
  Copy: TDigestContext;
begin
  Copy := Transcript.Running;
  FinishDigest(Copy, Output);
end;

procedure ReplaceWithMessageHash(var Transcript: TTlsTranscript);
var
  FirstHash: TDigestOutput;
  Header: array[0..3] of Byte;
  HashLength: Integer;
begin
  TranscriptHash(Transcript, FirstHash);
  HashLength := DigestSize(Transcript.Hash);
  BeginDigest(Transcript.Running, Transcript.Hash);
  Header[0] := HandshakeMessageHash;
  Header[1] := 0;
  Header[2] := 0;
  Header[3] := Byte(HashLength);
  UpdateDigest(Transcript.Running, @Header[0], 4);
  UpdateDigest(Transcript.Running, @FirstHash[0], HashLength);
end;

end.
