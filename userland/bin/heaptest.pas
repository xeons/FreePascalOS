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
  heaptest - checks the heap checking of the runtime (HEAP_CHECKS)

  HEAP_CHECKS=all heaptest
      Checks what the checking heap promises without breaking it: new
      blocks hold the allocation fill and freed ones the free fill,
      AllocMem and AllocateZeroedMemory still zero, ReAllocMem keeps the
      contents, MemSize is the size asked for, and several threads can
      allocate and free at once. Prints "heaptest: N passed, M failed"
      and exits with 1 if anything failed.

  HEAP_CHECKS=all heaptest --use-after-free | --write-after-free |
                           --double-free | --write-past-end
      Makes that mistake on purpose. Each must end the program: the use
      after free with runtime error 216 (the method table of a freed
      object is the free fill, not an address), the others with the heap
      check report and exit status 204. coretest runs them.
}
program heaptest;

{$mode objfpc}
{$H+}
{$pointermath on}

uses
  Sys.Environment,
  Sys.Memory,
  Sys.Threads,
  SysUtils,
  Sys.Streams,
  Runtime.Text;

const
  AllocationFill = Byte($A5);
  FreeFill = Byte($DF);
  ThreadCount = 4;
  RoundsPerThread = 3000;

type
  TVictim = class
  public
    Value: Integer;
    function Describe: Integer; virtual;
  end;

var
  PassedCount: Integer = 0;
  FailedCount: Integer = 0;

function TVictim.Describe: Integer;
begin
  Result := Value;
end;

procedure Check(Condition: Boolean; Name: PChar);
begin
  if Condition then
  begin
    Inc(PassedCount);
    WriteString(StandardOutput, Format('heaptest: pass: %s'#10, [Name]));
  end
  else
  begin
    Inc(FailedCount);
    WriteString(StandardOutput, Format('heaptest: FAIL: %s'#10, [Name]));
  end;
end;

function AllBytesAre(Block: PByte; Count: PtrUInt; Value: Byte): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < Count do
  begin
    if Block[Index] <> Value then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

procedure TestFills;
var
  Block: PByte;
begin
  Block := GetMem(100);
  Check(AllBytesAre(Block, 100, AllocationFill), 'a new block holds the allocation fill');
  Check(MemSize(Block) = 100, 'MemSize is the size asked for');
  FreeMem(Block);
  { Reading freed memory on purpose: it waits in the quarantine. }
  Check(AllBytesAre(Block, 100, FreeFill), 'a freed block holds the free fill');
end;

procedure TestZeroedMemory;
var
  Freed: PByte;
  Zeroed: PByte;
  Index: Integer;
begin
  { Blocks of the same size that were freed (full of the free fill) are
    around; zeroed ones must still be zero. }
  for Index := 1 to 50 do
  begin
    Freed := GetMem(200);
    FillByte(Freed^, 200, $77);
    FreeMem(Freed);
  end;
  Zeroed := AllocMem(200);
  Check(AllBytesAre(Zeroed, 200, 0), 'AllocMem memory is zero');
  FreeMem(Zeroed);
  Zeroed := AllocateZeroedMemory(3000);
  Check(AllBytesAre(Zeroed, 3000, 0), 'AllocateZeroedMemory memory is zero');
  FreeMemory(Zeroed);
end;

procedure TestReallocation;
var
  Block: Pointer;
  Bytes: PByte;
  Size: PtrUInt;
  Index: PtrUInt;
  Intact: Boolean;
begin
  Block := GetMem(10);
  Bytes := Block;
  for Index := 0 to 9 do
    Bytes[Index] := Byte(Index);
  Size := 10;
  Intact := True;
  { Grows past every size class, then shrinks; the bytes written first
    must survive every move. }
  while Size < 200000 do
  begin
    Size := Size * 3;
    ReAllocMem(Block, Size);
    Bytes := Block;
    for Index := 0 to 9 do
      if Bytes[Index] <> Byte(Index) then
        Intact := False;
  end;
  Check(Intact, 'ReAllocMem keeps the contents while growing');
  Check(AllBytesAre(Bytes + Size div 3, Size - Size div 3, AllocationFill),
    'the part ReAllocMem added holds the allocation fill');
  ReAllocMem(Block, 5);
  Bytes := Block;
  Check((Bytes[0] = 0) and (Bytes[4] = 4) and (MemSize(Block) = 5), 'ReAllocMem keeps the contents while shrinking');
  Block := ReallocateMemory(Block, 7);
  Bytes := Block;
  Check((Bytes[0] = 0) and (Bytes[4] = 4) and (Bytes[5] = AllocationFill), 'ReallocateMemory keeps the contents');
  FreeMemory(Block);
end;

procedure TestStringsAndObjects;
var
  Text: string;
  Index: Integer;
  Numbers: array of Integer;
  Victim: TVictim;
begin
  Text := '';
  for Index := 1 to 2000 do
    Text := Text + Char(Ord('a') + Index mod 26);
  Check((Length(Text) = 2000) and (Text[27] = 'b'), 'a string grown one character at a time');
  SetLength(Numbers, 0);
  for Index := 0 to 4999 do
  begin
    SetLength(Numbers, Index + 1);
    Numbers[Index] := Index;
  end;
  Check((Numbers[0] = 0) and (Numbers[4999] = 4999), 'a dynamic array grown one element at a time');
  Victim := TVictim.Create;
  Check(Victim.Value = 0, 'the fields of a new object are zero');
  Victim.Free;
end;

function AllocateAndFreeInThread(Argument: Pointer): LongInt;
var
  Round: Integer;
  Blocks: array[0..7] of PByte;
  Index: Integer;
begin
  Result := 0;
  for Round := 1 to RoundsPerThread do
  begin
    for Index := 0 to High(Blocks) do
    begin
      Blocks[Index] := GetMem(PtrUInt(16 + (Round * 7 + Index * 13) mod 700));
      Blocks[Index][0] := Byte(Index);
    end;
    for Index := 0 to High(Blocks) do
    begin
      if Blocks[Index][0] <> Byte(Index) then
        Result := 1;
      FreeMem(Blocks[Index]);
    end;
  end;
end;

procedure TestThreads;
var
  Handles: array[0..ThreadCount - 1] of Int64;
  Index: Integer;
  ExitCode: LongInt;
  AllWell: Boolean;
begin
  for Index := 0 to ThreadCount - 1 do
    Handles[Index] := CreateThread(@AllocateAndFreeInThread, nil);
  AllWell := True;
  for Index := 0 to ThreadCount - 1 do
  begin
    if (Handles[Index] < 0) or (WaitForThread(Handles[Index], -1, ExitCode) <> 0) or (ExitCode <> 0) then
      AllWell := False;
    if Handles[Index] >= 0 then
      CloseThreadHandle(Handles[Index]);
  end;
  Check(AllWell, 'threads allocate and free at the same time');
end;

{ --- Mistakes made on purpose ------------------------------------------ }

procedure UseAfterFree;
var
  Victim: TVictim;
begin
  Victim := TVictim.Create;
  Victim.Free;
  { The method table pointer is now $DFDFDFDFDFDFDFDF. }
  WriteString(StandardOutput, Format('not reached %d'#10, [Victim.Describe]));
end;

{ Frees enough other blocks that the damaged one leaves the quarantine
  and is checked. }
procedure PushOutOfQuarantine;
var
  Index: Integer;
begin
  for Index := 1 to 3000 do
    FreeMem(GetMem(100));
end;

procedure WriteAfterFree;
var
  Block: PByte;
begin
  Block := GetMem(100);
  FreeMem(Block);
  Block[10] := 0;
  PushOutOfQuarantine;
end;

procedure DoubleFree;
var
  Block: PByte;
begin
  Block := GetMem(100);
  FreeMem(Block);
  FreeMem(Block);
end;

procedure WritePastEnd;
var
  Block: PByte;
begin
  Block := GetMem(20);
  Block[20] := 0;
  FreeMem(Block);
end;

begin
  if ArgumentTotal > 1 then
  begin
    if TextIsEqual(Argument(1), '--use-after-free') then
      UseAfterFree
    else if TextIsEqual(Argument(1), '--write-after-free') then
      WriteAfterFree
    else if TextIsEqual(Argument(1), '--double-free') then
      DoubleFree
    else if TextIsEqual(Argument(1), '--write-past-end') then
      WritePastEnd
    else
    begin
      WriteString(StandardError, Format('heaptest: unknown option %s'#10, [Argument(1)]));
      Halt(2);
    end;
    WriteString(StandardOutput, Format('heaptest: the mistake was not caught'#10, []));
    Halt(3);
  end;

  TestFills;
  TestZeroedMemory;
  TestReallocation;
  TestStringsAndObjects;
  TestThreads;
  WriteString(StandardOutput, Format('heaptest: %d passed, %d failed'#10,
    [PassedCount, FailedCount]));
  if FailedCount > 0 then
    Halt(1);
end.
