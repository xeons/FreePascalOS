{
  Allocator for page aligned ranges of kernel virtual address space.

  The kernel dynamic region is handed out with a first-fit search over a
  sorted table of free ranges. Freed ranges are merged with their
  neighbours, so the table stays small in practice. The table has a fixed
  size so this allocator never needs memory itself.

  This only manages addresses; mapping physical pages behind them is up to
  the caller.
}
unit Memory.VirtualRanges;

{$mode objfpc}

interface

procedure InitializeVirtualRanges;

{ Returns the start of a free range of PageCount pages, or zero. }
function AllocateVirtualRange(PageCount: QWord): QWord;

procedure FreeVirtualRange(StartAddress: QWord; PageCount: QWord);

function FreeVirtualRangeCount: LongWord;

implementation

uses
  Memory.Layout,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Panic;

const
  MaximumFreeRanges = 1024;

type
  TFreeRange = record
    StartAddress: QWord;
    PageCount: QWord;
  end;

var
  FreeRanges: array[0..MaximumFreeRanges - 1] of TFreeRange;
  RangeCount: LongWord;
  RangeLock: TSpinLock;

procedure InitializeVirtualRanges;
begin
  InitializeSpinLock(RangeLock);
  FreeRanges[0].StartAddress := DynamicRegionBase;
  FreeRanges[0].PageCount := DynamicRegionSize shr PageShift;
  RangeCount := 1;
end;

function FreeVirtualRangeCount: LongWord;
begin
  Result := RangeCount;
end;

procedure RemoveRangeAt(Index: LongWord);
begin
  while Index + 1 < RangeCount do
  begin
    FreeRanges[Index] := FreeRanges[Index + 1];
    Inc(Index);
  end;
  Dec(RangeCount);
end;

procedure InsertRangeAt(Index: LongWord; StartAddress, PageCount: QWord);
var
  MoveIndex: LongWord;
begin
  if RangeCount >= MaximumFreeRanges then
    KernelPanicWithCode(PanicOutOfPhysicalMemory,
      'kernel virtual range table is full', StartAddress, PageCount, 0, 0);

  MoveIndex := RangeCount;
  while MoveIndex > Index do
  begin
    FreeRanges[MoveIndex] := FreeRanges[MoveIndex - 1];
    Dec(MoveIndex);
  end;
  FreeRanges[Index].StartAddress := StartAddress;
  FreeRanges[Index].PageCount := PageCount;
  Inc(RangeCount);
end;

function AllocateVirtualRange(PageCount: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Index: LongWord;
begin
  Result := 0;
  if PageCount = 0 then
    Exit;

  PreviousLevel := AcquireSpinLock(RangeLock);

  Index := 0;
  while Index < RangeCount do
  begin
    if FreeRanges[Index].PageCount >= PageCount then
    begin
      Result := FreeRanges[Index].StartAddress;
      FreeRanges[Index].StartAddress := FreeRanges[Index].StartAddress + PageCount * PageSize;
      FreeRanges[Index].PageCount := FreeRanges[Index].PageCount - PageCount;
      if FreeRanges[Index].PageCount = 0 then
        RemoveRangeAt(Index);
      Break;
    end;
    Inc(Index);
  end;

  ReleaseSpinLock(RangeLock, PreviousLevel);
end;

procedure FreeVirtualRange(StartAddress: QWord; PageCount: QWord);
var
  PreviousLevel: TPriorityLevel;
  InsertIndex: LongWord;
  EndAddress: QWord;
  MergesWithPrevious: Boolean;
  MergesWithNext: Boolean;
begin
  if PageCount = 0 then
    Exit;
  EndAddress := StartAddress + PageCount * PageSize;

  PreviousLevel := AcquireSpinLock(RangeLock);

  { Find the first free range that starts after the one being freed. }
  InsertIndex := 0;
  while (InsertIndex < RangeCount) and (FreeRanges[InsertIndex].StartAddress < StartAddress) do
    Inc(InsertIndex);

  MergesWithPrevious := (InsertIndex > 0) and
    (FreeRanges[InsertIndex - 1].StartAddress +
     FreeRanges[InsertIndex - 1].PageCount * PageSize = StartAddress);
  MergesWithNext := (InsertIndex < RangeCount) and
    (FreeRanges[InsertIndex].StartAddress = EndAddress);

  if MergesWithPrevious and MergesWithNext then
  begin
    FreeRanges[InsertIndex - 1].PageCount := FreeRanges[InsertIndex - 1].PageCount +
      PageCount + FreeRanges[InsertIndex].PageCount;
    RemoveRangeAt(InsertIndex);
  end
  else if MergesWithPrevious then
    FreeRanges[InsertIndex - 1].PageCount := FreeRanges[InsertIndex - 1].PageCount + PageCount
  else if MergesWithNext then
  begin
    FreeRanges[InsertIndex].StartAddress := StartAddress;
    FreeRanges[InsertIndex].PageCount := FreeRanges[InsertIndex].PageCount + PageCount;
  end
  else
    InsertRangeAt(InsertIndex, StartAddress, PageCount);

  ReleaseSpinLock(RangeLock, PreviousLevel);
end;

end.
