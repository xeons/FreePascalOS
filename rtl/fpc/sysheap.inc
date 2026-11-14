{
  Memory from the kernel for the heap manager (heap.inc): fresh pages,
  zeroed, freed as a whole.
}

function SysOSAlloc(Size: PtrUInt): Pointer;
var
  Address: Int64;
begin
  Address := SystemCall(CallAllocateMemory, Size, 0, 0, 0, 0, 0);
  if Address <= 0 then
    SysOSAlloc := nil
  else
    SysOSAlloc := Pointer(Address);
end;

{$define HAS_SYSOSFREE}
procedure SysOSFree(P: Pointer; Size: PtrUInt);
begin
  SystemCall(CallFreeMemory, QWord(P), 0, 0, 0, 0, 0);
end;
