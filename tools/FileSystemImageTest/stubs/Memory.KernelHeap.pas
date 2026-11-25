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
  Host stand-in for the kernel heap (FileSystemImageTest). Every block
  has a guard area on both sides; CheckKernelHeap finds blocks whose
  guards were written over (a driver wrote outside what it allocated),
  and blocks still allocated. Requests above MaximumAllocation fail, as
  they would on a kernel heap of modest size.
}
unit Memory.KernelHeap;

{$mode objfpc}

interface

const
  MaximumAllocation = 64 * 1024 * 1024;

function AllocateKernelMemory(ByteCount: QWord): Pointer;
function AllocateZeroedKernelMemory(ByteCount: QWord): Pointer;
procedure FreeKernelMemory(Block: Pointer);

{ Number of damaged blocks found (each reported on the console with
  Context); all blocks are checked, live ones too. }
function CheckKernelHeap(Context: PChar): Integer;
{ Forgets every live block (after a test was cut short) and returns how
  many there were. }
function ForgetKernelHeap: Integer;
function LiveKernelBlocks: Integer;

implementation

const
  GuardBytes = 64;
  GuardByte = $A5;
  HeaderMagic = QWord($5AFE5AFE5AFE5AFE);

type
  PBlockHeader = ^TBlockHeader;
  TBlockHeader = record
    Magic: QWord;
    Size: QWord;
    Previous: PBlockHeader;
    Next: PBlockHeader;
    { Padding up to the guard. }
    Spare: array[0..1] of QWord;
  end;

var
  FirstBlock: PBlockHeader = nil;
  BlockCount: Integer = 0;

function UserArea(Header: PBlockHeader): PByte;
begin
  Result := PByte(Header) + SizeOf(TBlockHeader) + GuardBytes;
end;

function HeaderOf(Block: Pointer): PBlockHeader;
begin
  Result := PBlockHeader(PByte(Block) - GuardBytes - SizeOf(TBlockHeader));
end;

function GuardsAreIntact(Header: PBlockHeader): Boolean;
var
  Index: Integer;
  Before: PByte;
  After: PByte;
begin
  if Header^.Magic <> HeaderMagic then
    Exit(False);
  Before := PByte(Header) + SizeOf(TBlockHeader);
  After := UserArea(Header) + Header^.Size;
  for Index := 0 to GuardBytes - 1 do
    if (Before[Index] <> GuardByte) or (After[Index] <> GuardByte) then
      Exit(False);
  Result := True;
end;

function AllocateKernelMemory(ByteCount: QWord): Pointer;
var
  Header: PBlockHeader;
begin
  if ByteCount > MaximumAllocation then
    Exit(nil);
  Header := PBlockHeader(GetMem(SizeOf(TBlockHeader) + 2 * GuardBytes + ByteCount));
  Header^.Magic := HeaderMagic;
  Header^.Size := ByteCount;
  FillChar((PByte(Header) + SizeOf(TBlockHeader))^, GuardBytes, GuardByte);
  FillChar((UserArea(Header) + ByteCount)^, GuardBytes, GuardByte);
  { Fresh memory holds garbage, as the kernel heap's does. }
  FillChar(UserArea(Header)^, ByteCount, $CC);
  Header^.Previous := nil;
  Header^.Next := FirstBlock;
  if FirstBlock <> nil then
    FirstBlock^.Previous := Header;
  FirstBlock := Header;
  Inc(BlockCount);
  Result := UserArea(Header);
end;

function AllocateZeroedKernelMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocateKernelMemory(ByteCount);
  if Result <> nil then
    FillChar(Result^, ByteCount, 0);
end;

procedure Unlink(Header: PBlockHeader);
begin
  if Header^.Previous <> nil then
    Header^.Previous^.Next := Header^.Next
  else
    FirstBlock := Header^.Next;
  if Header^.Next <> nil then
    Header^.Next^.Previous := Header^.Previous;
  Dec(BlockCount);
end;

procedure FreeKernelMemory(Block: Pointer);
var
  Header: PBlockHeader;
begin
  if Block = nil then
    Exit;
  Header := HeaderOf(Block);
  if not GuardsAreIntact(Header) then
  begin
    WriteLn('FAIL heap: a block of ', Header^.Size, ' bytes was written outside its bounds (found on free)');
    Halt(2);
  end;
  Unlink(Header);
  Header^.Magic := 0;
  FreeMem(Header);
end;

function CheckKernelHeap(Context: PChar): Integer;
var
  Header: PBlockHeader;
begin
  Result := 0;
  Header := FirstBlock;
  while Header <> nil do
  begin
    if not GuardsAreIntact(Header) then
    begin
      WriteLn('FAIL heap (', Context, '): a block of ', Header^.Size, ' bytes was written outside its bounds');
      Inc(Result);
    end;
    Header := Header^.Next;
  end;
end;

function ForgetKernelHeap: Integer;
begin
  Result := BlockCount;
  FirstBlock := nil;
  BlockCount := 0;
end;

function LiveKernelBlocks: Integer;
begin
  Result := BlockCount;
end;

end.
