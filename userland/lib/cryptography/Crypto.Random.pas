{
  Random numbers for programs (shuf, mktemp, shred, keys).

  A ChaCha20 key stream generator, seeded on first use from the
  processor's hardware generator (RDRAND) when it has one, mixed through
  SHA-256 with the clock, the uptime and the process id. Without RDRAND
  the seed is guessable; such numbers are fine for shuffling and file
  names but not for keys, which RandomIsStrong reports.
}
unit Crypto.Random;

{$mode objfpc}
{$asmmode intel}
{$pointermath on}

interface

procedure RandomBytes(Destination: PByte; Count: QWord);
function RandomQWord: QWord;
{ A uniformly distributed number in 0 .. Bound - 1 (Bound > 0). }
function RandomBelow(Bound: QWord): QWord;
{ True if the generator was seeded from a hardware source. }
function RandomIsStrong: Boolean;

implementation

uses
  Sys.Kernel,
  Crypto.Bits,
  Crypto.Digests,
  Crypto.ChaCha20;

var
  Generator: TChaCha20Context;
  IsSeeded: Boolean = False;
  HasHardwareSeed: Boolean = False;
  BytesSinceRekey: QWord = 0;

const
  RekeyInterval = 1024 * 1024;

function ProcessorHasRdrand: Boolean; assembler; nostackframe;
asm
  push rbx
  mov eax, 1
  cpuid
  xor eax, eax
  bt ecx, 30
  setc al
  pop rbx
end;

{ One hardware random value; False if the generator did not deliver. }
function ReadRdrand(out Value: QWord): Boolean; assembler; nostackframe;
asm
  mov ecx, 10
@Retry:
  { rdrand rax }
  db $48, $0F, $C7, $F0
  jc @Delivered
  dec ecx
  jnz @Retry
  xor eax, eax
  mov qword ptr [rdi], 0
  ret
@Delivered:
  mov qword ptr [rdi], rax
  mov eax, 1
end;

procedure Seed;
var
  Context: TDigestContext;
  Material: array[0..7] of QWord;
  Index: Integer;
  Key: TDigestOutput;
  Nonce: array[0..11] of Byte;
  HardwareCount: Integer;
begin
  HardwareCount := 0;
  if ProcessorHasRdrand then
    for Index := 0 to 7 do
      if ReadRdrand(Material[Index]) then
        Inc(HardwareCount);
  HasHardwareSeed := HardwareCount = 8;

  BeginDigest(Context, DigestSha256);
  UpdateDigest(Context, @Material[0], SizeOf(Material));
  Material[0] := QWord(KernelGetTime(0));
  Material[1] := QWord(KernelGetTime(1));
  Material[2] := QWord(KernelGetProcessId(-1));
  Material[3] := QWord(@Material[0]);
  UpdateDigest(Context, @Material[0], 4 * SizeOf(QWord));
  FinishDigest(Context, Key);

  for Index := 0 to 11 do
    Nonce[Index] := 0;
  BeginChaCha20(Generator, @Key[0], @Nonce[0], 0);
  WipeMemory(@Key[0], SizeOf(Key));
  WipeMemory(@Material[0], SizeOf(Material));
  IsSeeded := True;
end;

{ Replaces the key with generator output, so earlier output cannot be
  reconstructed from a later state. }
procedure Rekey;
var
  NewKey: array[0..31] of Byte;
  Nonce: array[0..11] of Byte;
  Index: Integer;
begin
  for Index := 0 to 31 do
    NewKey[Index] := 0;
  ApplyChaCha20(Generator, @NewKey[0], @NewKey[0], SizeOf(NewKey));
  for Index := 0 to 11 do
    Nonce[Index] := 0;
  BeginChaCha20(Generator, @NewKey[0], @Nonce[0], 0);
  WipeMemory(@NewKey[0], SizeOf(NewKey));
  BytesSinceRekey := 0;
end;

procedure RandomBytes(Destination: PByte; Count: QWord);
var
  Index: QWord;
begin
  if not IsSeeded then
    Seed;
  Index := 0;
  while Index < Count do
  begin
    Destination[Index] := 0;
    Inc(Index);
  end;
  ApplyChaCha20(Generator, Destination, Destination, Count);
  BytesSinceRekey := BytesSinceRekey + Count;
  if BytesSinceRekey >= RekeyInterval then
    Rekey;
end;

function RandomQWord: QWord;
begin
  RandomBytes(@Result, SizeOf(Result));
end;

function RandomBelow(Bound: QWord): QWord;
var
  Limit: QWord;
  Value: QWord;
begin
  if Bound <= 1 then
    Exit(0);
  { Reject values from the incomplete last range, avoiding bias. }
  Limit := High(QWord) - (High(QWord) mod Bound);
  repeat
    Value := RandomQWord;
  until Value < Limit;
  Result := Value mod Bound;
end;

function RandomIsStrong: Boolean;
begin
  if not IsSeeded then
    Seed;
  Result := HasHardwareSeed;
end;

end.
