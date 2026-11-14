{
  Safe access to the calling process's memory from system calls.

  User programs pass pointers to buffers and strings. Before the kernel
  touches one, the whole range is checked against the process's regions;
  pages in on-demand regions are then provided by the page fault resolver
  if needed, and anything outside a region is refused with ErrorBadAddress
  instead of crashing the kernel.

  The kernel touches user memory only through the routines here, which
  copy with Kernel.Arch.UserCopy: if another thread frees the memory
  between the check and the copy, the copy fails with ErrorBadAddress
  instead of faulting. Drivers and file systems never see user pointers;
  reads and writes go through a kernel buffer (AllocateTransferBuffer).
}
unit Processes.UserAccess;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types;

function UserRangeIsValid(Address: QWord; Length: QWord; NeedWrite: Boolean): Boolean;

{ Copies a zero terminated string of at most Capacity - 1 bytes. }
function CopyStringFromUser(UserAddress: QWord; Destination: PChar; Capacity: PtrUInt): LongInt;
function CopyToUser(UserAddress: QWord; Source: Pointer; Length: QWord): LongInt;
function CopyFromUser(Destination: Pointer; UserAddress: QWord; Length: QWord): LongInt;

{ Maps a file system status to an Abi error code. }
function ErrorFromStatus(Status: TFileSystemStatus): LongInt;

const
  { Reads and writes larger than this are done in pieces. }
  TransferChunkSize = 16384;

{ A kernel buffer for one piece of a read or write of ByteCount bytes:
  ByteCount or TransferChunkSize, whichever is smaller. nil if out of
  memory. Free it with FreeTransferBuffer. }
function AllocateTransferBuffer(ByteCount: QWord; out Size: QWord): Pointer;
procedure FreeTransferBuffer(Buffer: Pointer);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Arch.UserCopy,
  Memory.Layout,
  Memory.KernelHeap,
  Processes.Process,
  Processes.AddressSpace,
  Processes.Thread;

function UserRangeIsValid(Address: QWord; Length: QWord; NeedWrite: Boolean): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Result := Process^.IsUserProcess and
    ValidateUserRange(Process^.AddressSpace, Address, Length, NeedWrite);
end;

function CopyStringFromUser(UserAddress: QWord; Destination: PChar; Capacity: PtrUInt): LongInt;
var
  Index: PtrUInt;
  PieceLength: QWord;
  Copied: Int64;
begin
  if (UserAddress = 0) or (Capacity = 0) then
    Exit(ErrorBadAddress);
  Index := 0;
  { A page at a time: each page is checked before the string reaches it. }
  while Index < Capacity do
  begin
    PieceLength := PageSize - ((UserAddress + Index) and PageOffsetMask);
    if PieceLength > Capacity - Index then
      PieceLength := Capacity - Index;
    if not UserRangeIsValid(UserAddress + Index, PieceLength, False) then
      Exit(ErrorBadAddress);
    Copied := ArchCopyUserString(Destination + Index, PChar(UserAddress + Index), PieceLength);
    if Copied = UserCopyFaulted then
      Exit(ErrorBadAddress);
    if Copied <> UserCopyTooLong then
      Exit(ErrorNone);
    Index := Index + PieceLength;
  end;
  Destination[Capacity - 1] := #0;
  Result := ErrorNameTooLong;
end;

function CopyToUser(UserAddress: QWord; Source: Pointer; Length: QWord): LongInt;
begin
  if not UserRangeIsValid(UserAddress, Length, True) then
    Exit(ErrorBadAddress);
  if ArchCopyUserMemory(Pointer(UserAddress), Source, Length) <> 0 then
    Exit(ErrorBadAddress);
  Result := ErrorNone;
end;

function CopyFromUser(Destination: Pointer; UserAddress: QWord; Length: QWord): LongInt;
begin
  if not UserRangeIsValid(UserAddress, Length, False) then
    Exit(ErrorBadAddress);
  if ArchCopyUserMemory(Destination, Pointer(UserAddress), Length) <> 0 then
    Exit(ErrorBadAddress);
  Result := ErrorNone;
end;

function AllocateTransferBuffer(ByteCount: QWord; out Size: QWord): Pointer;
begin
  Size := ByteCount;
  if Size > TransferChunkSize then
    Size := TransferChunkSize;
  if Size = 0 then
    Size := 1;
  Result := AllocateKernelMemory(Size);
end;

procedure FreeTransferBuffer(Buffer: Pointer);
begin
  FreeKernelMemory(Buffer);
end;

function ErrorFromStatus(Status: TFileSystemStatus): LongInt;
begin
  case Status of
    StatusSuccess, StatusEndOfDirectory: Result := ErrorNone;
    StatusNotFound: Result := ErrorNotFound;
    StatusNotADirectory: Result := ErrorNotDirectory;
    StatusIsADirectory: Result := ErrorIsDirectory;
    StatusInvalidPath, StatusInvalidName: Result := ErrorInvalidArgument;
    StatusNameTooLong: Result := ErrorNameTooLong;
    StatusTooManyLinks: Result := ErrorTooManyLinks;
    StatusIoError: Result := ErrorIo;
    StatusCorrupted: Result := ErrorCorrupted;
    StatusUnsupported: Result := ErrorUnsupported;
    StatusOutOfMemory: Result := ErrorOutOfMemory;
    StatusReadOnly: Result := ErrorReadOnly;
    StatusAlreadyExists: Result := ErrorExists;
    StatusDirectoryNotEmpty: Result := ErrorDirectoryNotEmpty;
    StatusNoSpace: Result := ErrorNoSpace;
    StatusInUse: Result := ErrorBusy;
    StatusAccessDenied: Result := ErrorAccessDenied;
  else
    Result := ErrorIo;
  end;
end;

end.
