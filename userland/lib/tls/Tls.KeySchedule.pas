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
  The TLS 1.3 key schedule (RFC 8446 section 7.1), without pre-shared
  keys:

                 0
                 |
       0 -> HKDF-Extract = Early Secret
                 |
           Derive-Secret(., "derived", "")
                 |
    (EC)DHE -> HKDF-Extract = Handshake Secret
                 +--> Derive-Secret(., "c hs traffic", CH..SH)
                 +--> Derive-Secret(., "s hs traffic", CH..SH)
           Derive-Secret(., "derived", "")
                 |
       0 -> HKDF-Extract = Master Secret
                 +--> Derive-Secret(., "c ap traffic", CH..server Finished)
                 +--> Derive-Secret(., "s ap traffic", CH..server Finished)

  plus the traffic keys and IVs of a secret (section 7.3), the Finished
  verify data (section 4.4.4) and the next secret of a KeyUpdate
  (section 7.2). Every secret is wiped when the schedule is.
}
unit Tls.KeySchedule;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Crypto.Digests;

type
  TTlsSecret = array[0..MaximumDigestSize - 1] of Byte;

  TTlsKeySchedule = record
    Hash: TDigestAlgorithm;
    HashLength: Integer;
    HandshakeSecret: TTlsSecret;
    MasterSecret: TTlsSecret;
    ClientHandshakeTraffic: TTlsSecret;
    ServerHandshakeTraffic: TTlsSecret;
    ClientApplicationTraffic: TTlsSecret;
    ServerApplicationTraffic: TTlsSecret;
  end;

{ HKDF-Expand-Label(Secret, Label, Context, Length) with "tls13 " put
  before Label. }
procedure ExpandLabel(Hash: TDigestAlgorithm; Secret: PByte; const Label_: string; Context: PByte; ContextLength: Integer;
  Output: PByte; OutputLength: Integer);
{ Derive-Secret with a transcript hash already computed. }
procedure DeriveSecret(Hash: TDigestAlgorithm; Secret: PByte; const Label_: string; TranscriptHash: PByte;
  out Output: TTlsSecret);

procedure BeginKeySchedule(out Schedule: TTlsKeySchedule; Hash: TDigestAlgorithm);
{ From the shared (EC)DHE secret and the hash of ClientHello..ServerHello. }
procedure DeriveHandshakeSecrets(var Schedule: TTlsKeySchedule; SharedSecret: PByte; SharedSecretLength: Integer;
  TranscriptHash: PByte);
{ From the hash of ClientHello..server Finished. }
procedure DeriveApplicationSecrets(var Schedule: TTlsKeySchedule; TranscriptHash: PByte);
procedure WipeKeySchedule(var Schedule: TTlsKeySchedule);

{ The write key and IV of a traffic secret. }
procedure DeriveTrafficKeys(Hash: TDigestAlgorithm; Secret: PByte; Key: PByte; KeyLength: Integer; Iv: PByte;
  IvLength: Integer);
{ HMAC(finished_key, transcript hash): HashLength bytes. }
procedure ComputeFinishedData(Hash: TDigestAlgorithm; BaseSecret: PByte; TranscriptHash: PByte;
  out VerifyData: TDigestOutput);
{ application_traffic_secret_N+1 from _N, in place. }
procedure NextTrafficSecret(Hash: TDigestAlgorithm; var Secret: TTlsSecret);

implementation

uses
  Crypto.Bits,
  Crypto.Hkdf,
  Crypto.Hmac;

const
  LabelPrefix = 'tls13 ';

procedure ExpandLabel(Hash: TDigestAlgorithm; Secret: PByte; const Label_: string; Context: PByte; ContextLength: Integer;
  Output: PByte; OutputLength: Integer);
var
  HkdfLabel: array[0..2 + 1 + 255 + 1 + 255 - 1] of Byte;
  Position: Integer;
  FullLabel: string;
  LabelLength: Integer;
begin
  FullLabel := LabelPrefix + Label_;
  LabelLength := Length(FullLabel);
  (* struct { uint16 length; opaque label<7..255>; opaque context<0..255>; } *)
  HkdfLabel[0] := Byte(OutputLength shr 8);
  HkdfLabel[1] := Byte(OutputLength);
  HkdfLabel[2] := Byte(LabelLength);
  Position := 3;
  Move(FullLabel[1], HkdfLabel[Position], LabelLength);
  Position := Position + LabelLength;
  HkdfLabel[Position] := Byte(ContextLength);
  Inc(Position);
  if ContextLength > 0 then
    Move(Context^, HkdfLabel[Position], ContextLength);
  Position := Position + ContextLength;
  HkdfExpand(Hash, Secret, QWord(DigestSize(Hash)), @HkdfLabel[0], QWord(Position), Output, QWord(OutputLength));
end;

procedure DeriveSecret(Hash: TDigestAlgorithm; Secret: PByte; const Label_: string; TranscriptHash: PByte;
  out Output: TTlsSecret);
begin
  FillChar(Output, SizeOf(Output), 0);
  ExpandLabel(Hash, Secret, Label_, TranscriptHash, DigestSize(Hash), @Output[0], DigestSize(Hash));
end;

procedure BeginKeySchedule(out Schedule: TTlsKeySchedule; Hash: TDigestAlgorithm);
begin
  FillChar(Schedule, SizeOf(Schedule), 0);
  Schedule.Hash := Hash;
  Schedule.HashLength := DigestSize(Hash);
end;

{ Derive-Secret(Secret, "derived", "") }
procedure DeriveSalt(var Schedule: TTlsKeySchedule; Secret: PByte; out Salt: TTlsSecret);
var
  EmptyHash: TDigestOutput;
begin
  ComputeDigest(Schedule.Hash, nil, 0, EmptyHash);
  DeriveSecret(Schedule.Hash, Secret, 'derived', @EmptyHash[0], Salt);
end;

procedure DeriveHandshakeSecrets(var Schedule: TTlsKeySchedule; SharedSecret: PByte; SharedSecretLength: Integer;
  TranscriptHash: PByte);
var
  Zeros: TTlsSecret;
  EarlySecret: TDigestOutput;
  Salt: TTlsSecret;
  Extracted: TDigestOutput;
begin
  FillChar(Zeros, SizeOf(Zeros), 0);
  { Without a PSK the early secret is HKDF-Extract(0, 0). }
  HkdfExtract(Schedule.Hash, @Zeros[0], QWord(Schedule.HashLength), @Zeros[0], QWord(Schedule.HashLength),
    EarlySecret);
  DeriveSalt(Schedule, @EarlySecret[0], Salt);
  HkdfExtract(Schedule.Hash, @Salt[0], QWord(Schedule.HashLength), SharedSecret, QWord(SharedSecretLength),
    Extracted);
  Move(Extracted[0], Schedule.HandshakeSecret[0], Schedule.HashLength);
  DeriveSecret(Schedule.Hash, @Schedule.HandshakeSecret[0], 'c hs traffic', TranscriptHash,
    Schedule.ClientHandshakeTraffic);
  DeriveSecret(Schedule.Hash, @Schedule.HandshakeSecret[0], 's hs traffic', TranscriptHash,
    Schedule.ServerHandshakeTraffic);
  WipeMemory(@EarlySecret[0], SizeOf(EarlySecret));
  WipeMemory(@Salt[0], SizeOf(Salt));
  WipeMemory(@Extracted[0], SizeOf(Extracted));
end;

procedure DeriveApplicationSecrets(var Schedule: TTlsKeySchedule; TranscriptHash: PByte);
var
  Zeros: TTlsSecret;
  Salt: TTlsSecret;
  Extracted: TDigestOutput;
begin
  FillChar(Zeros, SizeOf(Zeros), 0);
  DeriveSalt(Schedule, @Schedule.HandshakeSecret[0], Salt);
  HkdfExtract(Schedule.Hash, @Salt[0], QWord(Schedule.HashLength), @Zeros[0], QWord(Schedule.HashLength), Extracted);
  Move(Extracted[0], Schedule.MasterSecret[0], Schedule.HashLength);
  DeriveSecret(Schedule.Hash, @Schedule.MasterSecret[0], 'c ap traffic', TranscriptHash,
    Schedule.ClientApplicationTraffic);
  DeriveSecret(Schedule.Hash, @Schedule.MasterSecret[0], 's ap traffic', TranscriptHash,
    Schedule.ServerApplicationTraffic);
  WipeMemory(@Salt[0], SizeOf(Salt));
  WipeMemory(@Extracted[0], SizeOf(Extracted));
end;

procedure WipeKeySchedule(var Schedule: TTlsKeySchedule);
begin
  WipeMemory(@Schedule, SizeOf(Schedule));
end;

procedure DeriveTrafficKeys(Hash: TDigestAlgorithm; Secret: PByte; Key: PByte; KeyLength: Integer; Iv: PByte;
  IvLength: Integer);
begin
  ExpandLabel(Hash, Secret, 'key', nil, 0, Key, KeyLength);
  ExpandLabel(Hash, Secret, 'iv', nil, 0, Iv, IvLength);
end;

procedure ComputeFinishedData(Hash: TDigestAlgorithm; BaseSecret: PByte; TranscriptHash: PByte;
  out VerifyData: TDigestOutput);
var
  FinishedKey: TTlsSecret;
  HashLength: Integer;
begin
  HashLength := DigestSize(Hash);
  ExpandLabel(Hash, BaseSecret, 'finished', nil, 0, @FinishedKey[0], HashLength);
  ComputeHmac(Hash, @FinishedKey[0], QWord(HashLength), TranscriptHash, QWord(HashLength), VerifyData);
  WipeMemory(@FinishedKey[0], SizeOf(FinishedKey));
end;

procedure NextTrafficSecret(Hash: TDigestAlgorithm; var Secret: TTlsSecret);
var
  Next: TTlsSecret;
begin
  FillChar(Next, SizeOf(Next), 0);
  ExpandLabel(Hash, @Secret[0], 'traffic upd', nil, 0, @Next[0], DigestSize(Hash));
  Secret := Next;
  WipeMemory(@Next[0], SizeOf(Next));
end;

end.
