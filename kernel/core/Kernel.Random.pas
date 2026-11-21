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
  The kernel's random numbers: address space layout randomization
  (Processes.AddressLayout), the network stack (temporary interface
  identifiers, stable-privacy secrets, fragment identifications, TCP
  initial sequence numbers, timer jitter), /dev/random and made-up MAC
  addresses.

  The generator is ChaCha20 (Kernel.ChaCha20) with "fast key erasure":
  every block it makes gives the next key (its first half) and 32 bytes
  of output (its second half), so a key found later says nothing about
  numbers given out before. The key is seeded at boot from:

    * the processor's entropy source where there is one: RDSEED, else
      RDRAND (x86-64), RNDRRS, else RNDR (AArch64, FEAT_RNG),
    * timing jitter: the low bits of the cycle counter around short
      runs of work whose duration varies with caches, the pipeline,
      interrupts and (in a virtual machine) the host,
    * boot entropy: the boot information (memory map, firmware time,
      framebuffer, command line), and the device tree's /chosen
      rng-seed and kaslr-seed, which the Raspberry Pi firmware fills
      from its hardware generator,

  and every block after that also takes in a fresh hardware number (when
  there is a generator) and the cycle counter, as does AddRandomEntropy
  for drivers that see unpredictable events.

  It is usable from any context (the lock is taken at HighLevel) and
  seeds itself on first use if nothing called InitializeRandom yet.
}
unit Kernel.Random;

{$mode objfpc}
{$rangechecks off}
{$overflowchecks off}

interface

uses
  Boot.Information;

{ Seeds the generator. Called once at boot, after memory management (the
  device tree is read through the physical memory window). }
procedure InitializeRandom(const BootInformation: TBootInformation);

function RandomQWord: QWord;
{ A random number from 0 to Limit - 1, without bias (Limit > 0). }
function RandomBelow(Limit: QWord): QWord;
procedure FillRandom(Buffer: PByte; Length: QWord);
{ Mixes Value (an unpredictable event's timing, a device's noise) into
  the generator's key. }
procedure AddRandomEntropy(Value: QWord);

{ True if the processor's generator took part in the seed. }
function RandomHasHardwareSource: Boolean;

implementation

uses
  Runtime.Memory,
  DeviceTree.Blob,
  Kernel.ChaCha20,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Memory.Layout;

const
  OutputWords = 8;
  JitterSamples = 4096;
  HardwareSeedWords = 8;

var
  GeneratorLock: TSpinLock;
  Key: TChaChaKey;
  Nonce: TChaChaNonce;
  BlockCounter: LongWord;
  { Output not given out yet: Output[OutputUsed .. OutputWords - 1]. }
  Output: array[0..OutputWords - 1] of LongWord;
  OutputUsed: Integer = OutputWords;
  IsSeeded: Boolean = False;
  HasHardwareGenerator: Boolean = False;

{ --- Mixing ------------------------------------------------------------- }

{ Folds Value into the key; ChaCha's block function spreads it over the
  whole key with the next block. }
procedure MixIntoKey(Value: QWord; Position: Integer);
var
  Index: Integer;
begin
  Index := (Position * 2) mod ChaChaKeyWords;
  Key[Index] := Key[Index] xor LongWord(Value);
  Key[(Index + 1) mod ChaChaKeyWords] := Key[(Index + 1) mod ChaChaKeyWords] xor LongWord(Value shr 32);
end;

{ Makes the next block: a new key from its first half, output from its
  second. Lock held (or before anyone else can call). }
procedure RefillOutput;
var
  Block: TChaChaBlock;
  Index: Integer;
  Value: QWord;
begin
  if HasHardwareGenerator and ReadHardwareRandom(Value) then
    MixIntoKey(Value, 0);
  MixIntoKey(ReadTimeStampCounter, 3);
  ChaChaBlock(Key, BlockCounter, Nonce, Block);
  Inc(BlockCounter);
  if BlockCounter = 0 then
    Inc(Nonce[0]);
  for Index := 0 to ChaChaKeyWords - 1 do
    Key[Index] := Block[Index];
  for Index := 0 to OutputWords - 1 do
    Output[Index] := Block[ChaChaKeyWords + Index];
  FillMemory(@Block, SizeOf(Block), 0);
  OutputUsed := 0;
end;

{ Mixes Length bytes at Data into the key, eight at a time, stirring the
  generator after every key's worth. }
procedure MixBytes(Data: PByte; Length: QWord);
var
  Offset: QWord;
  Value: QWord;
  Part: Integer;
  Position: Integer;
begin
  Offset := 0;
  Position := 0;
  while Offset < Length do
  begin
    Value := 0;
    for Part := 0 to 7 do
      if Offset + QWord(Part) < Length then
        Value := Value or (QWord(Data[Offset + QWord(Part)]) shl (Part * 8));
    MixIntoKey(Value, Position);
    Inc(Position);
    if Position = ChaChaKeyWords div 2 then
    begin
      RefillOutput;
      Position := 0;
    end;
    Offset := Offset + 8;
  end;
  RefillOutput;
end;

{ --- Entropy sources ---------------------------------------------------- }

procedure CollectHardwareSeed;
var
  Index: Integer;
  Value: QWord;
begin
  for Index := 0 to HardwareSeedWords - 1 do
  begin
    if ReadHardwareSeed(Value) or ReadHardwareRandom(Value) then
    begin
      HasHardwareGenerator := True;
      MixIntoKey(Value, Index);
    end;
  end;
  if HasHardwareGenerator then
    RefillOutput;
end;

{ The low bits of the time taken by a little work that varies with
  everything going on in the machine, accumulated into the key. }
procedure CollectTimingJitter;
var
  Sample: Integer;
  Before: QWord;
  Delta: QWord;
  Accumulator: QWord;
  Work: QWord;
  Spin: Integer;
begin
  Accumulator := 0;
  Work := ReadTimeStampCounter;
  for Sample := 1 to JitterSamples do
  begin
    Before := ReadTimeStampCounter;
    for Spin := 0 to Integer(Work and 15) do
      Work := Work * QWord($5851F42D4C957F2D) + QWord(Spin);
    Delta := ReadTimeStampCounter - Before;
    Accumulator := ((Accumulator shl 5) or (Accumulator shr 59)) xor Delta xor (Before shl 32);
    if (Sample and 63) = 0 then
      MixIntoKey(Accumulator, Sample div 64);
    if (Sample and 511) = 0 then
      RefillOutput;
  end;
  MixIntoKey(Work, 1);
  RefillOutput;
end;

{ /chosen rng-seed and kaslr-seed of a device tree boot. }
procedure CollectDeviceTreeSeed(const BootInformation: TBootInformation);
var
  Tree: TDeviceTree;
  Chosen: LongInt;
  Prop: TDeviceTreeProperty;
begin
  if (BootInformation.DeviceTreePhysicalBase = 0) or (BootInformation.DeviceTreeSizeInBytes = 0) then
    Exit;
  if not OpenDeviceTree(PhysicalToVirtual(BootInformation.DeviceTreePhysicalBase), Tree) then
    Exit;
  Chosen := FindChildNode(Tree, RootNode(Tree), 'chosen', 6);
  if Chosen < 0 then
    Exit;
  if FindProperty(Tree, Chosen, 'rng-seed', Prop) then
    MixBytes(Prop.Value, Prop.Length);
  if FindProperty(Tree, Chosen, 'kaslr-seed', Prop) then
    MixBytes(Prop.Value, Prop.Length);
end;

procedure SeedGenerator(BootInformation: PBootInformation);
begin
  { An arbitrary start; everything after this is mixed in. }
  FillMemory(@Key, SizeOf(Key), 0);
  FillMemory(@Nonce, SizeOf(Nonce), 0);
  Key[0] := $243F6A88;
  Key[1] := $85A308D3;
  BlockCounter := 0;
  MixIntoKey(ReadTimeStampCounter, 2);
  RefillOutput;

  CollectHardwareSeed;
  if BootInformation <> nil then
  begin
    MixBytes(PByte(BootInformation), SizeOf(TBootInformation) - SizeOf(BootInformation^.MemoryRegions) +
      BootInformation^.MemoryRegionCount * SizeOf(TMemoryRegion));
    CollectDeviceTreeSeed(BootInformation^);
  end;
  CollectTimingJitter;
  IsSeeded := True;
end;

{ --- Public routines ---------------------------------------------------- }

procedure InitializeRandom(const BootInformation: TBootInformation);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLockAtLevel(GeneratorLock, HighLevel);
  SeedGenerator(@BootInformation);
  ReleaseSpinLock(GeneratorLock, PreviousLevel);
end;

function NextWordLocked: LongWord;
begin
  if not IsSeeded then
    SeedGenerator(nil);
  if OutputUsed >= OutputWords then
    RefillOutput;
  Result := Output[OutputUsed];
  Output[OutputUsed] := 0;
  Inc(OutputUsed);
end;

function RandomQWord: QWord;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLockAtLevel(GeneratorLock, HighLevel);
  Result := QWord(NextWordLocked) or (QWord(NextWordLocked) shl 32);
  ReleaseSpinLock(GeneratorLock, PreviousLevel);
end;

function RandomBelow(Limit: QWord): QWord;
var
  Rejected: QWord;
  Value: QWord;
begin
  if Limit <= 1 then
    Exit(0);
  { Values below 2^64 mod Limit would make the low results likelier. }
  Rejected := (QWord(0) - Limit) mod Limit;
  repeat
    Value := RandomQWord;
  until Value >= Rejected;
  Result := Value mod Limit;
end;

procedure FillRandom(Buffer: PByte; Length: QWord);
var
  Value: QWord;
  Index: QWord;
  Part: Integer;
begin
  Index := 0;
  while Index < Length do
  begin
    Value := RandomQWord;
    for Part := 0 to 7 do
    begin
      if Index >= Length then
        Break;
      Buffer[Index] := Byte(Value shr (Part * 8));
      Inc(Index);
    end;
  end;
end;

procedure AddRandomEntropy(Value: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLockAtLevel(GeneratorLock, HighLevel);
  MixIntoKey(Value xor ReadTimeStampCounter, 1);
  ReleaseSpinLock(GeneratorLock, PreviousLevel);
end;

function RandomHasHardwareSource: Boolean;
begin
  Result := HasHardwareGenerator;
end;

end.
