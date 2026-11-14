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
  Message digests over whole messages: MD5, SHA-1, SHA-224, SHA-256,
  SHA-384, SHA-512 and BLAKE2b-512.

    BeginDigest(Context, DigestSha256);
    UpdateDigest(Context, Data, Count);   (any number of times)
    FinishDigest(Context, Output);        (DigestSize bytes)

  This unit buffers input into blocks and pads the last one; the
  compression functions are in Crypto.Md5, Crypto.Sha1, Crypto.Sha256,
  Crypto.Sha512 and Crypto.Blake2b.
}
unit Crypto.Digests;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Md5,
  Crypto.Sha1,
  Crypto.Sha256,
  Crypto.Sha512,
  Crypto.Blake2b;

const
  MaximumDigestSize = 64;
  MaximumDigestBlockSize = 128;

type
  TDigestAlgorithm = (DigestMd5, DigestSha1, DigestSha224, DigestSha256, DigestSha384,
    DigestSha512, DigestBlake2b);

  TDigestContext = record
    Algorithm: TDigestAlgorithm;
    Md5State: TMd5State;
    Sha1State: TSha1State;
    Sha256State: TSha256State;
    Sha512State: TSha512State;   { also BLAKE2b }
    Block: array[0..MaximumDigestBlockSize - 1] of Byte;
    BlockFill: LongWord;
    { Bytes in all blocks compressed so far. }
    CompressedBytes: QWord;
  end;

  TDigestOutput = array[0..MaximumDigestSize - 1] of Byte;

procedure BeginDigest(out Context: TDigestContext; Algorithm: TDigestAlgorithm);
procedure UpdateDigest(var Context: TDigestContext; Data: PByte; Count: QWord);
{ Writes DigestSize bytes to Output (the rest is zero) and wipes the
  context. }
procedure FinishDigest(var Context: TDigestContext; out Output: TDigestOutput);
{ All in one. }
procedure ComputeDigest(Algorithm: TDigestAlgorithm; Data: PByte; Count: QWord; out Output: TDigestOutput);

function DigestSize(Algorithm: TDigestAlgorithm): Integer;
function DigestBlockSize(Algorithm: TDigestAlgorithm): Integer;
{ "MD5", "SHA256", "BLAKE2b" (as in BSD style checksum lines). }
function DigestTagName(Algorithm: TDigestAlgorithm): PChar;

{ Lower case hexadecimal text of the first ByteCount bytes. Buffer needs
  2 * ByteCount + 1 characters. }
function FormatHexBytes(Bytes: PByte; ByteCount: Integer; Buffer: PChar): PChar;

implementation

uses
  Runtime.Memory,
  Crypto.Bits;

const
  HexDigits: array[0..15] of Char = '0123456789abcdef';

function DigestSize(Algorithm: TDigestAlgorithm): Integer;
begin
  case Algorithm of
    DigestMd5: Result := 16;
    DigestSha1: Result := 20;
    DigestSha224: Result := 28;
    DigestSha256: Result := 32;
    DigestSha384: Result := 48;
  else
    Result := 64;
  end;
end;

function DigestBlockSize(Algorithm: TDigestAlgorithm): Integer;
begin
  if Algorithm in [DigestSha384, DigestSha512, DigestBlake2b] then
    Result := 128
  else
    Result := 64;
end;

function DigestTagName(Algorithm: TDigestAlgorithm): PChar;
begin
  case Algorithm of
    DigestMd5: Result := 'MD5';
    DigestSha1: Result := 'SHA1';
    DigestSha224: Result := 'SHA224';
    DigestSha256: Result := 'SHA256';
    DigestSha384: Result := 'SHA384';
    DigestSha512: Result := 'SHA512';
  else
    Result := 'BLAKE2b';
  end;
end;

function FormatHexBytes(Bytes: PByte; ByteCount: Integer; Buffer: PChar): PChar;
var
  Index: Integer;
begin
  for Index := 0 to ByteCount - 1 do
  begin
    Buffer[2 * Index] := HexDigits[Bytes[Index] shr 4];
    Buffer[2 * Index + 1] := HexDigits[Bytes[Index] and 15];
  end;
  Buffer[2 * ByteCount] := #0;
  Result := Buffer;
end;

procedure BeginDigest(out Context: TDigestContext; Algorithm: TDigestAlgorithm);
begin
  ZeroMemory(@Context, SizeOf(Context));
  Context.Algorithm := Algorithm;
  case Algorithm of
    DigestMd5: Context.Md5State := Md5InitialState;
    DigestSha1: Context.Sha1State := Sha1InitialState;
    DigestSha224: Context.Sha256State := Sha224InitialState;
    DigestSha256: Context.Sha256State := Sha256InitialState;
    DigestSha384: Context.Sha512State := Sha384InitialState;
    DigestSha512: Context.Sha512State := Sha512InitialState;
    DigestBlake2b: Blake2bInitialize(Context.Sha512State, 64);
  end;
end;

procedure CompressBlock(var Context: TDigestContext; Block: PByte);
begin
  case Context.Algorithm of
    DigestMd5: Md5Compress(Context.Md5State, Block);
    DigestSha1: Sha1Compress(Context.Sha1State, Block);
    DigestSha224, DigestSha256: Sha256Compress(Context.Sha256State, Block);
    DigestSha384, DigestSha512: Sha512Compress(Context.Sha512State, Block);
  end;
end;

procedure UpdateDigest(var Context: TDigestContext; Data: PByte; Count: QWord);
var
  BlockSize: LongWord;
  Take: QWord;
begin
  BlockSize := LongWord(DigestBlockSize(Context.Algorithm));
  while Count > 0 do
  begin
    { BLAKE2b compresses its last block differently, and only
      FinishDigest knows which block is last: a full block is kept until
      more data arrives. }
    if (Context.Algorithm = DigestBlake2b) and (Context.BlockFill = BlockSize) then
    begin
      Context.CompressedBytes := Context.CompressedBytes + BlockSize;
      Blake2bCompress(Context.Sha512State, @Context.Block[0], Context.CompressedBytes, False);
      Context.BlockFill := 0;
    end;
    Take := BlockSize - Context.BlockFill;
    if Take > Count then
      Take := Count;
    CopyMemory(@Context.Block[Context.BlockFill], Data, Take);
    Context.BlockFill := Context.BlockFill + LongWord(Take);
    Data := Data + Take;
    Count := Count - Take;
    if (Context.Algorithm <> DigestBlake2b) and (Context.BlockFill = BlockSize) then
    begin
      CompressBlock(Context, @Context.Block[0]);
      Context.CompressedBytes := Context.CompressedBytes + BlockSize;
      Context.BlockFill := 0;
    end;
  end;
end;

{ MD5 and SHA: append 0x80, zeros, and the message length in bits. }
procedure PadAndCompress(var Context: TDigestContext);
var
  BlockSize: LongWord;
  LengthBytes: LongWord;
  BitCount: QWord;
begin
  BlockSize := LongWord(DigestBlockSize(Context.Algorithm));
  if BlockSize = 128 then
    LengthBytes := 16
  else
    LengthBytes := 8;
  BitCount := (Context.CompressedBytes + Context.BlockFill) * 8;

  Context.Block[Context.BlockFill] := $80;
  Inc(Context.BlockFill);
  if Context.BlockFill > BlockSize - LengthBytes then
  begin
    FillMemory(@Context.Block[Context.BlockFill], BlockSize - Context.BlockFill, 0);
    CompressBlock(Context, @Context.Block[0]);
    Context.BlockFill := 0;
  end;
  FillMemory(@Context.Block[Context.BlockFill], BlockSize - Context.BlockFill, 0);
  if Context.Algorithm = DigestMd5 then
    StoreLittleEndian64(@Context.Block[BlockSize - 8], BitCount)
  else
    StoreBigEndian64(@Context.Block[BlockSize - 8], BitCount);
  CompressBlock(Context, @Context.Block[0]);
end;

procedure FinishDigest(var Context: TDigestContext; out Output: TDigestOutput);
var
  Index: Integer;
begin
  FillMemory(@Output, SizeOf(Output), 0);
  if Context.Algorithm = DigestBlake2b then
  begin
    Context.CompressedBytes := Context.CompressedBytes + Context.BlockFill;
    FillMemory(@Context.Block[Context.BlockFill], 128 - Context.BlockFill, 0);
    Blake2bCompress(Context.Sha512State, @Context.Block[0], Context.CompressedBytes, True);
    for Index := 0 to 7 do
      StoreLittleEndian64(@Output[Index * 8], Context.Sha512State[Index]);
  end
  else
  begin
    PadAndCompress(Context);
    case Context.Algorithm of
      DigestMd5:
        for Index := 0 to 3 do
          StoreLittleEndian32(@Output[Index * 4], Context.Md5State[Index]);
      DigestSha1:
        for Index := 0 to 4 do
          StoreBigEndian32(@Output[Index * 4], Context.Sha1State[Index]);
      DigestSha224, DigestSha256:
        for Index := 0 to 7 do
          StoreBigEndian32(@Output[Index * 4], Context.Sha256State[Index]);
    else
      for Index := 0 to 7 do
        StoreBigEndian64(@Output[Index * 8], Context.Sha512State[Index]);
    end;
    { SHA-224 and SHA-384 output only part of the state. }
    for Index := DigestSize(Context.Algorithm) to MaximumDigestSize - 1 do
      Output[Index] := 0;
  end;
  WipeMemory(@Context, SizeOf(Context));
end;

procedure ComputeDigest(Algorithm: TDigestAlgorithm; Data: PByte; Count: QWord; out Output: TDigestOutput);
var
  Context: TDigestContext;
begin
  BeginDigest(Context, Algorithm);
  UpdateDigest(Context, Data, Count);
  FinishDigest(Context, Output);
end;

end.
