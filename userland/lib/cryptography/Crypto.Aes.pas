{
  The AES block cipher (FIPS 197) with 128, 192 and 256 bit keys, and
  two modes of operation:

    CBC  with PKCS#7 padding (SP 800-38A); the output is longer than the
         input by 1 to 16 bytes
    CTR  a stream mode: the same call encrypts and decrypts

  The S-box is a table, so the time taken can depend on the data; this
  implementation is meant for files at rest, not for situations where an
  attacker can time it.
}
unit Crypto.Aes;

{$mode objfpc}
{$pointermath on}

interface

const
  AesBlockSize = 16;

type
  TAesBlock = array[0..AesBlockSize - 1] of Byte;

  TAesKey = record
    RoundCount: Integer;
    { Round keys for encryption and decryption, 4 words per round. }
    EncryptionKeys: array[0..59] of LongWord;
    DecryptionKeys: array[0..59] of LongWord;
  end;

{ KeyLength is 16, 24 or 32 bytes; returns False otherwise. }
function ExpandAesKey(out Key: TAesKey; KeyBytes: PByte; KeyLength: Integer): Boolean;
procedure WipeAesKey(var Key: TAesKey);

procedure EncryptAesBlock(const Key: TAesKey; Source, Destination: PByte);
procedure DecryptAesBlock(const Key: TAesKey; Source, Destination: PByte);

{ CBC: Destination needs room for Count rounded up to the next whole
  block (a full extra block when Count is a multiple of 16). Returns the
  number of bytes written. }
function EncryptAesCbc(const Key: TAesKey; const InitialVector: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte): QWord;
{ Returns the plaintext length, or -1 if the length or padding is wrong. }
function DecryptAesCbc(const Key: TAesKey; const InitialVector: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte): Int64;

{ CTR with a 16-byte initial counter block, incremented as a big endian
  number. }
procedure ApplyAesCtr(const Key: TAesKey; const InitialCounter: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte);

implementation

uses
  Runtime.Memory,
  Crypto.Bits;

var
  SubstitutionBox: array[0..255] of Byte;
  InverseSubstitutionBox: array[0..255] of Byte;
  TablesReady: Boolean = False;

{ Multiplication by x in GF(2^8). }
function TimesX(Value: Byte): Byte;
begin
  if (Value and $80) <> 0 then
    Result := Byte((Value shl 1) xor $1B)
  else
    Result := Byte(Value shl 1);
end;

function Multiply(A, B: Byte): Byte;
begin
  Result := 0;
  while B <> 0 do
  begin
    if (B and 1) <> 0 then
      Result := Result xor A;
    A := TimesX(A);
    B := B shr 1;
  end;
end;

{ Builds the S-boxes from their definition: the multiplicative inverse
  in GF(2^8) followed by an affine transformation. }
procedure PrepareTables;
var
  Value: Integer;
  Inverse: Byte;
  Candidate: Integer;
  Transformed: Byte;
  Bit: Integer;
begin
  for Value := 0 to 255 do
  begin
    Inverse := 0;
    if Value <> 0 then
      for Candidate := 1 to 255 do
        if Multiply(Byte(Value), Byte(Candidate)) = 1 then
        begin
          Inverse := Byte(Candidate);
          Break;
        end;
    Transformed := $63;
    for Bit := 0 to 7 do
    begin
      if (((Inverse shr Bit) xor (Inverse shr ((Bit + 4) mod 8)) xor (Inverse shr ((Bit + 5) mod 8)) xor
           (Inverse shr ((Bit + 6) mod 8)) xor (Inverse shr ((Bit + 7) mod 8))) and 1) <> 0 then
        Transformed := Transformed xor (1 shl Bit);
    end;
    SubstitutionBox[Value] := Transformed;
    InverseSubstitutionBox[Transformed] := Byte(Value);
  end;
  TablesReady := True;
end;

function SubstituteWord(Value: LongWord): LongWord;
begin
  Result := (LongWord(SubstitutionBox[Value shr 24]) shl 24) or
    (LongWord(SubstitutionBox[(Value shr 16) and $FF]) shl 16) or
    (LongWord(SubstitutionBox[(Value shr 8) and $FF]) shl 8) or
    LongWord(SubstitutionBox[Value and $FF]);
end;

{ InvMixColumns of one word, used to derive the decryption keys. }
function InverseMixWord(Value: LongWord): LongWord;
var
  A0, A1, A2, A3: Byte;
begin
  A0 := Byte(Value shr 24);
  A1 := Byte(Value shr 16);
  A2 := Byte(Value shr 8);
  A3 := Byte(Value);
  Result := (LongWord(Multiply(A0, 14) xor Multiply(A1, 11) xor Multiply(A2, 13) xor Multiply(A3, 9)) shl 24) or
    (LongWord(Multiply(A0, 9) xor Multiply(A1, 14) xor Multiply(A2, 11) xor Multiply(A3, 13)) shl 16) or
    (LongWord(Multiply(A0, 13) xor Multiply(A1, 9) xor Multiply(A2, 14) xor Multiply(A3, 11)) shl 8) or
    LongWord(Multiply(A0, 11) xor Multiply(A1, 13) xor Multiply(A2, 9) xor Multiply(A3, 14));
end;

function ExpandAesKey(out Key: TAesKey; KeyBytes: PByte; KeyLength: Integer): Boolean;
var
  KeyWords: Integer;
  TotalWords: Integer;
  Index: Integer;
  Temporary: LongWord;
  RoundConstant: Byte;
  Round: Integer;
  Column: Integer;
begin
  ZeroMemory(@Key, SizeOf(Key));
  if not (KeyLength in [16, 24, 32]) then
    Exit(False);
  if not TablesReady then
    PrepareTables;
  KeyWords := KeyLength div 4;
  Key.RoundCount := KeyWords + 6;
  TotalWords := 4 * (Key.RoundCount + 1);

  for Index := 0 to KeyWords - 1 do
    Key.EncryptionKeys[Index] := LoadBigEndian32(KeyBytes + Index * 4);
  RoundConstant := 1;
  for Index := KeyWords to TotalWords - 1 do
  begin
    Temporary := Key.EncryptionKeys[Index - 1];
    if Index mod KeyWords = 0 then
    begin
      Temporary := SubstituteWord((Temporary shl 8) or (Temporary shr 24)) xor (LongWord(RoundConstant) shl 24);
      RoundConstant := TimesX(RoundConstant);
    end
    else if (KeyWords > 6) and (Index mod KeyWords = 4) then
      Temporary := SubstituteWord(Temporary);
    Key.EncryptionKeys[Index] := Key.EncryptionKeys[Index - KeyWords] xor Temporary;
  end;

  { The equivalent inverse cipher uses the round keys in reverse order,
    with InvMixColumns applied to all but the first and last. }
  for Round := 0 to Key.RoundCount do
    for Column := 0 to 3 do
    begin
      Temporary := Key.EncryptionKeys[4 * (Key.RoundCount - Round) + Column];
      if (Round > 0) and (Round < Key.RoundCount) then
        Temporary := InverseMixWord(Temporary);
      Key.DecryptionKeys[4 * Round + Column] := Temporary;
    end;
  Result := True;
end;

procedure WipeAesKey(var Key: TAesKey);
begin
  WipeMemory(@Key, SizeOf(Key));
end;

procedure AddRoundKey(var State: TAesBlock; const Keys: array of LongWord; Round: Integer);
var
  Column: Integer;
  Word: LongWord;
begin
  for Column := 0 to 3 do
  begin
    Word := Keys[4 * Round + Column];
    State[4 * Column] := State[4 * Column] xor Byte(Word shr 24);
    State[4 * Column + 1] := State[4 * Column + 1] xor Byte(Word shr 16);
    State[4 * Column + 2] := State[4 * Column + 2] xor Byte(Word shr 8);
    State[4 * Column + 3] := State[4 * Column + 3] xor Byte(Word);
  end;
end;

procedure SubstituteBytes(var State: TAesBlock; const Box: array of Byte);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    State[Index] := Box[State[Index]];
end;

{ Row R of the state is bytes R, R+4, R+8, R+12; it moves left by R
  (or right by R when Inverse). }
procedure ShiftRows(var State: TAesBlock; Inverse: Boolean);
var
  Original: TAesBlock;
  Row: Integer;
  Column: Integer;
  SourceColumn: Integer;
begin
  Original := State;
  for Row := 1 to 3 do
    for Column := 0 to 3 do
    begin
      if Inverse then
        SourceColumn := (Column - Row + 4) mod 4
      else
        SourceColumn := (Column + Row) mod 4;
      State[4 * Column + Row] := Original[4 * SourceColumn + Row];
    end;
end;

procedure MixColumns(var State: TAesBlock; Inverse: Boolean);
var
  Column: Integer;
  A0, A1, A2, A3: Byte;
begin
  for Column := 0 to 3 do
  begin
    A0 := State[4 * Column];
    A1 := State[4 * Column + 1];
    A2 := State[4 * Column + 2];
    A3 := State[4 * Column + 3];
    if Inverse then
    begin
      State[4 * Column] := Multiply(A0, 14) xor Multiply(A1, 11) xor Multiply(A2, 13) xor Multiply(A3, 9);
      State[4 * Column + 1] := Multiply(A0, 9) xor Multiply(A1, 14) xor Multiply(A2, 11) xor Multiply(A3, 13);
      State[4 * Column + 2] := Multiply(A0, 13) xor Multiply(A1, 9) xor Multiply(A2, 14) xor Multiply(A3, 11);
      State[4 * Column + 3] := Multiply(A0, 11) xor Multiply(A1, 13) xor Multiply(A2, 9) xor Multiply(A3, 14);
    end
    else
    begin
      State[4 * Column] := TimesX(A0) xor (TimesX(A1) xor A1) xor A2 xor A3;
      State[4 * Column + 1] := A0 xor TimesX(A1) xor (TimesX(A2) xor A2) xor A3;
      State[4 * Column + 2] := A0 xor A1 xor TimesX(A2) xor (TimesX(A3) xor A3);
      State[4 * Column + 3] := (TimesX(A0) xor A0) xor A1 xor A2 xor TimesX(A3);
    end;
  end;
end;

procedure EncryptAesBlock(const Key: TAesKey; Source, Destination: PByte);
var
  State: TAesBlock;
  Round: Integer;
begin
  CopyMemory(@State[0], Source, AesBlockSize);
  AddRoundKey(State, Key.EncryptionKeys, 0);
  for Round := 1 to Key.RoundCount do
  begin
    SubstituteBytes(State, SubstitutionBox);
    ShiftRows(State, False);
    if Round < Key.RoundCount then
      MixColumns(State, False);
    AddRoundKey(State, Key.EncryptionKeys, Round);
  end;
  CopyMemory(Destination, @State[0], AesBlockSize);
  WipeMemory(@State[0], SizeOf(State));
end;

procedure DecryptAesBlock(const Key: TAesKey; Source, Destination: PByte);
var
  State: TAesBlock;
  Round: Integer;
begin
  CopyMemory(@State[0], Source, AesBlockSize);
  AddRoundKey(State, Key.DecryptionKeys, 0);
  for Round := 1 to Key.RoundCount do
  begin
    SubstituteBytes(State, InverseSubstitutionBox);
    ShiftRows(State, True);
    if Round < Key.RoundCount then
      MixColumns(State, True);
    AddRoundKey(State, Key.DecryptionKeys, Round);
  end;
  CopyMemory(Destination, @State[0], AesBlockSize);
  WipeMemory(@State[0], SizeOf(State));
end;

function EncryptAesCbc(const Key: TAesKey; const InitialVector: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte): QWord;
var
  Chain: TAesBlock;
  Block: TAesBlock;
  Offset: QWord;
  Remaining: QWord;
  PadValue: Byte;
  Index: Integer;
begin
  Chain := InitialVector;
  Offset := 0;
  repeat
    Remaining := Count - Offset;
    if Remaining >= AesBlockSize then
      CopyMemory(@Block[0], Source + Offset, AesBlockSize)
    else
    begin
      { The last block is padded with N bytes of value N (1..16). }
      PadValue := Byte(AesBlockSize - Remaining);
      CopyMemory(@Block[0], Source + Offset, Remaining);
      for Index := Integer(Remaining) to AesBlockSize - 1 do
        Block[Index] := PadValue;
    end;
    for Index := 0 to AesBlockSize - 1 do
      Block[Index] := Block[Index] xor Chain[Index];
    EncryptAesBlock(Key, @Block[0], Destination + Offset);
    CopyMemory(@Chain[0], Destination + Offset, AesBlockSize);
    Offset := Offset + AesBlockSize;
  until Remaining < AesBlockSize;
  Result := Offset;
end;

function DecryptAesCbc(const Key: TAesKey; const InitialVector: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte): Int64;
var
  Chain: TAesBlock;
  Block: TAesBlock;
  Offset: QWord;
  Index: Integer;
  PadValue: Byte;
begin
  if (Count = 0) or (Count mod AesBlockSize <> 0) then
    Exit(-1);
  Chain := InitialVector;
  Offset := 0;
  while Offset < Count do
  begin
    DecryptAesBlock(Key, Source + Offset, @Block[0]);
    for Index := 0 to AesBlockSize - 1 do
      Destination[Offset + QWord(Index)] := Block[Index] xor Chain[Index];
    CopyMemory(@Chain[0], Source + Offset, AesBlockSize);
    Offset := Offset + AesBlockSize;
  end;
  PadValue := Destination[Count - 1];
  if (PadValue < 1) or (PadValue > AesBlockSize) then
    Exit(-1);
  for Index := 1 to PadValue do
    if Destination[Count - QWord(Index)] <> PadValue then
      Exit(-1);
  Result := Int64(Count) - PadValue;
end;

procedure ApplyAesCtr(const Key: TAesKey; const InitialCounter: TAesBlock; Source: PByte;
  Count: QWord; Destination: PByte);
var
  Counter: TAesBlock;
  KeyStream: TAesBlock;
  Offset: QWord;
  Index: Integer;
begin
  Counter := InitialCounter;
  Offset := 0;
  while Offset < Count do
  begin
    EncryptAesBlock(Key, @Counter[0], @KeyStream[0]);
    Index := 0;
    while (Index < AesBlockSize) and (Offset < Count) do
    begin
      Destination[Offset] := Source[Offset] xor KeyStream[Index];
      Inc(Offset);
      Inc(Index);
    end;
    { Increment the counter as one big endian number. }
    Index := AesBlockSize - 1;
    repeat
      Counter[Index] := Byte(Counter[Index] + 1);
      Dec(Index);
    until (Index < 0) or (Counter[Index + 1] <> 0);
  end;
  WipeMemory(@KeyStream[0], SizeOf(KeyStream));
end;

end.
