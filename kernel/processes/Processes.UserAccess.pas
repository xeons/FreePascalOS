{
  Safe access to the calling process's memory from system calls.

  User programs pass pointers to buffers and strings. Before the kernel
  touches one, the whole range is checked against the process's regions;
  pages in on-demand regions are then provided by the page fault resolver
  if needed, and anything outside a region is refused with ErrorBadAddress
  instead of crashing the kernel.
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

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
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
  Source: PChar;
begin
  if (UserAddress = 0) or (Capacity = 0) then
    Exit(ErrorBadAddress);
  Source := PChar(UserAddress);
  Index := 0;
  while Index < Capacity do
  begin
    { Check each page once, as the string reaches it. }
    if (Index = 0) or (((UserAddress + Index) and PageOffsetMask) = 0) then
    begin
      if not UserRangeIsValid(UserAddress + Index, 1, False) then
        Exit(ErrorBadAddress);
    end;
    Destination[Index] := Source[Index];
    if Source[Index] = #0 then
      Exit(ErrorNone);
    Inc(Index);
  end;
  Destination[Capacity - 1] := #0;
  Result := ErrorNameTooLong;
end;

function CopyToUser(UserAddress: QWord; Source: Pointer; Length: QWord): LongInt;
begin
  if not UserRangeIsValid(UserAddress, Length, True) then
    Exit(ErrorBadAddress);
  CopyMemory(Pointer(UserAddress), Source, Length);
  Result := ErrorNone;
end;

function CopyFromUser(Destination: Pointer; UserAddress: QWord; Length: QWord): LongInt;
begin
  if not UserRangeIsValid(UserAddress, Length, False) then
    Exit(ErrorBadAddress);
  CopyMemory(Destination, Pointer(UserAddress), Length);
  Result := ErrorNone;
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
  else
    Result := ErrorIo;
  end;
end;

end.
