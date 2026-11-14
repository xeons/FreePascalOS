{
  HMAC (RFC 2104): a message authentication code from any digest of
  Crypto.Digests, e.g. HMAC-SHA256.
}
unit Crypto.Hmac;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Digests;

type
  THmacContext = record
    Inner: TDigestContext;
    { The key XOR the outer pad, kept for the final step. }
    OuterKeyBlock: array[0..MaximumDigestBlockSize - 1] of Byte;
  end;

procedure BeginHmac(out Context: THmacContext; Algorithm: TDigestAlgorithm; Key: PByte; KeyLength: QWord);
procedure UpdateHmac(var Context: THmacContext; Data: PByte; Count: QWord);
procedure FinishHmac(var Context: THmacContext; out Output: TDigestOutput);
procedure ComputeHmac(Algorithm: TDigestAlgorithm; Key: PByte; KeyLength: QWord; Data: PByte;
  Count: QWord; out Output: TDigestOutput);

implementation

uses
  Runtime.Memory,
  Crypto.Bits;

const
  InnerPad = $36;
  OuterPad = $5C;

procedure BeginHmac(out Context: THmacContext; Algorithm: TDigestAlgorithm; Key: PByte; KeyLength: QWord);
var
  KeyBlock: array[0..MaximumDigestBlockSize - 1] of Byte;
  InnerKeyBlock: array[0..MaximumDigestBlockSize - 1] of Byte;
  HashedKey: TDigestOutput;
  BlockSize: Integer;
  Index: Integer;
begin
  BlockSize := DigestBlockSize(Algorithm);
  ZeroMemory(@KeyBlock[0], SizeOf(KeyBlock));
  { Keys longer than a block are hashed first. }
  if KeyLength > QWord(BlockSize) then
  begin
    ComputeDigest(Algorithm, Key, KeyLength, HashedKey);
    CopyMemory(@KeyBlock[0], @HashedKey[0], DigestSize(Algorithm));
    WipeMemory(@HashedKey[0], SizeOf(HashedKey));
  end
  else if KeyLength > 0 then
    CopyMemory(@KeyBlock[0], Key, KeyLength);

  for Index := 0 to BlockSize - 1 do
  begin
    InnerKeyBlock[Index] := KeyBlock[Index] xor InnerPad;
    Context.OuterKeyBlock[Index] := KeyBlock[Index] xor OuterPad;
  end;
  BeginDigest(Context.Inner, Algorithm);
  UpdateDigest(Context.Inner, @InnerKeyBlock[0], QWord(BlockSize));
  WipeMemory(@KeyBlock[0], SizeOf(KeyBlock));
  WipeMemory(@InnerKeyBlock[0], SizeOf(InnerKeyBlock));
end;

procedure UpdateHmac(var Context: THmacContext; Data: PByte; Count: QWord);
begin
  UpdateDigest(Context.Inner, Data, Count);
end;

procedure FinishHmac(var Context: THmacContext; out Output: TDigestOutput);
var
  Algorithm: TDigestAlgorithm;
  InnerHash: TDigestOutput;
  Outer: TDigestContext;
begin
  Algorithm := Context.Inner.Algorithm;
  FinishDigest(Context.Inner, InnerHash);
  BeginDigest(Outer, Algorithm);
  UpdateDigest(Outer, @Context.OuterKeyBlock[0], QWord(DigestBlockSize(Algorithm)));
  UpdateDigest(Outer, @InnerHash[0], QWord(DigestSize(Algorithm)));
  FinishDigest(Outer, Output);
  WipeMemory(@InnerHash[0], SizeOf(InnerHash));
  WipeMemory(@Context, SizeOf(Context));
end;

procedure ComputeHmac(Algorithm: TDigestAlgorithm; Key: PByte; KeyLength: QWord; Data: PByte;
  Count: QWord; out Output: TDigestOutput);
var
  Context: THmacContext;
begin
  BeginHmac(Context, Algorithm, Key, KeyLength);
  UpdateHmac(Context, Data, Count);
  FinishHmac(Context, Output);
end;

end.
