{
  The program heap.

  This is the heap of the runtime library (System's memory manager): the
  same blocks GetMem, New, strings, dynamic arrays and objects use, so a
  program and all its libraries share one heap. It is safe to use from
  every thread. Blocks are 16-byte aligned.

  As everywhere in Free Pascal, running out of memory ends the program
  with runtime error 203 (or raises EOutOfMemory where SysUtils is used)
  rather than returning nil.
}
unit Sys.Memory;

{$mode objfpc}
{$pointermath on}

interface

function AllocateMemory(ByteCount: QWord): Pointer;
function AllocateZeroedMemory(ByteCount: QWord): Pointer;
procedure FreeMemory(Block: Pointer);
{ Grows or shrinks a block, keeping its contents; may move it. }
function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
{ The usable size of a block. }
function MemoryBlockSize(Block: Pointer): QWord;

{ A heap copy of Text. }
function DuplicateText(Text: PChar): PChar;

implementation

uses
  Runtime.Memory,
  Runtime.Text;

{ A request for nothing still gets a block, which can be freed. }
function AtLeastOne(ByteCount: QWord): QWord;
begin
  if ByteCount = 0 then
    Result := 1
  else
    Result := ByteCount;
end;

function AllocateMemory(ByteCount: QWord): Pointer;
begin
  Result := GetMem(AtLeastOne(ByteCount));
end;

function AllocateZeroedMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocMem(AtLeastOne(ByteCount));
end;

procedure FreeMemory(Block: Pointer);
begin
  if Block <> nil then
    FreeMem(Block);
end;

function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
begin
  Result := Block;
  ReAllocMem(Result, AtLeastOne(NewByteCount));
end;

function MemoryBlockSize(Block: Pointer): QWord;
begin
  if Block = nil then
    Exit(0);
  Result := MemSize(Block);
end;

function DuplicateText(Text: PChar): PChar;
var
  Length: PtrUInt;
begin
  if Text = nil then
    Text := '';
  Length := TextLength(Text);
  Result := PChar(AllocateMemory(Length + 1));
  CopyMemory(Result, Text, Length + 1);
end;

end.
