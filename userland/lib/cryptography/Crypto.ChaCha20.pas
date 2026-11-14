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
  The ChaCha20 stream cipher (RFC 8439): a 256-bit key and a 96-bit
  nonce produce a stream of bytes that is XORed with the data, so the
  same call encrypts and decrypts. A key and nonce pair must never be
  used for two different messages.
}
unit Crypto.ChaCha20;

{$mode objfpc}
{$pointermath on}

interface

const
  ChaCha20KeySize = 32;
  ChaCha20NonceSize = 12;
  ChaCha20BlockSize = 64;

type
  TChaCha20Context = record
    State: array[0..15] of LongWord;
    KeyStream: array[0..ChaCha20BlockSize - 1] of Byte;
    { Bytes of KeyStream already used. }
    KeyStreamUsed: Integer;
  end;

procedure BeginChaCha20(out Context: TChaCha20Context; Key: PByte; Nonce: PByte; InitialCounter: LongWord);
{ XORs Count bytes of key stream into Source, writing to Destination
  (which may be Source). }
procedure ApplyChaCha20(var Context: TChaCha20Context; Source, Destination: PByte; Count: QWord);
procedure EndChaCha20(var Context: TChaCha20Context);

{ The raw block function: 64 bytes of key stream for State. }
procedure ChaCha20Block(const State: array of LongWord; Output: PByte);

implementation

uses
  Crypto.Bits;

procedure QuarterRound(var Working: array of LongWord; A, B, C, D: Integer);
begin
  Working[A] := Working[A] + Working[B];
  Working[D] := RotateLeft32(Working[D] xor Working[A], 16);
  Working[C] := Working[C] + Working[D];
  Working[B] := RotateLeft32(Working[B] xor Working[C], 12);
  Working[A] := Working[A] + Working[B];
  Working[D] := RotateLeft32(Working[D] xor Working[A], 8);
  Working[C] := Working[C] + Working[D];
  Working[B] := RotateLeft32(Working[B] xor Working[C], 7);
end;

procedure ChaCha20Block(const State: array of LongWord; Output: PByte);
var
  Working: array[0..15] of LongWord;
  Round: Integer;
  Index: Integer;
begin
  for Index := 0 to 15 do
    Working[Index] := State[Index];
  for Round := 1 to 10 do
  begin
    QuarterRound(Working, 0, 4, 8, 12);
    QuarterRound(Working, 1, 5, 9, 13);
    QuarterRound(Working, 2, 6, 10, 14);
    QuarterRound(Working, 3, 7, 11, 15);
    QuarterRound(Working, 0, 5, 10, 15);
    QuarterRound(Working, 1, 6, 11, 12);
    QuarterRound(Working, 2, 7, 8, 13);
    QuarterRound(Working, 3, 4, 9, 14);
  end;
  for Index := 0 to 15 do
    StoreLittleEndian32(Output + Index * 4, Working[Index] + State[Index]);
  WipeMemory(@Working[0], SizeOf(Working));
end;

procedure BeginChaCha20(out Context: TChaCha20Context; Key: PByte; Nonce: PByte; InitialCounter: LongWord);
var
  Index: Integer;
begin
  { "expand 32-byte k" }
  Context.State[0] := $61707865;
  Context.State[1] := $3320646e;
  Context.State[2] := $79622d32;
  Context.State[3] := $6b206574;
  for Index := 0 to 7 do
    Context.State[4 + Index] := LoadLittleEndian32(Key + Index * 4);
  Context.State[12] := InitialCounter;
  for Index := 0 to 2 do
    Context.State[13 + Index] := LoadLittleEndian32(Nonce + Index * 4);
  Context.KeyStreamUsed := ChaCha20BlockSize;
end;

procedure ApplyChaCha20(var Context: TChaCha20Context; Source, Destination: PByte; Count: QWord);
var
  Index: QWord;
begin
  Index := 0;
  while Index < Count do
  begin
    if Context.KeyStreamUsed = ChaCha20BlockSize then
    begin
      ChaCha20Block(Context.State, @Context.KeyStream[0]);
      Context.State[12] := Context.State[12] + 1;
      Context.KeyStreamUsed := 0;
    end;
    Destination[Index] := Source[Index] xor Context.KeyStream[Context.KeyStreamUsed];
    Inc(Context.KeyStreamUsed);
    Inc(Index);
  end;
end;

procedure EndChaCha20(var Context: TChaCha20Context);
begin
  WipeMemory(@Context, SizeOf(Context));
end;

end.
