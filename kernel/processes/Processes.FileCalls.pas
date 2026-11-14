{
  System calls for files, directories, handles and volumes.

  Each routine takes the raw argument values of the call and returns the
  value for RAX: zero or more on success, minus an Abi error code on
  failure. Paths arrive as user pointers and are translated from the
  program's view (see Processes.Paths) to the kernel's.
}
unit Processes.FileCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformOpenFile(PathAddress: QWord; Flags: QWord): Int64;
function PerformCloseHandle(Handle: Int64): Int64;
function PerformReadHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
function PerformWriteHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
function PerformSeekHandle(Handle: Int64; Offset: Int64; Origin: QWord): Int64;
function PerformSetFileSize(Handle: Int64; Size: QWord): Int64;
function PerformGetHandleInformation(Handle: Int64; InformationAddress: QWord): Int64;
function PerformGetHandleKind(Handle: Int64): Int64;
function PerformGetPathInformation(PathAddress: QWord; InformationAddress: QWord; FollowLinks: QWord): Int64;
function PerformReadDirectory(Handle: Int64; EntryAddress: QWord): Int64;
function PerformCreateDirectory(PathAddress: QWord): Int64;
function PerformRemovePath(PathAddress: QWord): Int64;
function PerformRenamePath(SourceAddress: QWord; TargetAddress: QWord): Int64;
function PerformCreateSymbolicLink(TargetAddress: QWord; PathAddress: QWord): Int64;
function PerformReadSymbolicLink(PathAddress: QWord; BufferAddress: QWord; Capacity: QWord): Int64;
function PerformGetCurrentDirectory(BufferAddress: QWord; Capacity: QWord): Int64;
function PerformSetCurrentDirectory(PathAddress: QWord): Int64;
function PerformCreatePipe(HandlesAddress: QWord): Int64;
function PerformDuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;
function PerformListVolumes(Index: QWord; InformationAddress: QWord): Int64;
function PerformSetPathAttributes(PathAddress: QWord; ChangesAddress: QWord; FollowLinks: QWord): Int64;
function PerformCreateHardLink(ExistingAddress: QWord; NewAddress: QWord): Int64;
function PerformSetRootDirectory(PathAddress: QWord): Int64;
function PerformControlHandle(Handle: Int64; Request: QWord; Argument: QWord): Int64;
function PerformSync: Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Volumes,
  Io.Console,
  Io.NullDevice,
  Io.Pipes,
  Objects.Manager,
  Processes.Process,
  Processes.Handles,
  Processes.Paths,
  Processes.Thread,
  Processes.UserAccess;

const
  PathCapacity = ProcessPathCapacity;

type
  TPathBuffer = array[0..PathCapacity - 1] of Char;
  PPathBuffer = ^TPathBuffer;

{ Copies a user path and translates it. The kernel path buffer comes from
  the heap and must be freed by the caller. }
function FetchKernelPath(PathAddress: QWord; out KernelPath: PPathBuffer): LongInt;
var
  UserPath: TPathBuffer;
begin
  KernelPath := nil;
  Result := CopyStringFromUser(PathAddress, @UserPath[0], PathCapacity);
  if Result <> ErrorNone then
    Exit;
  KernelPath := PPathBuffer(AllocateKernelMemory(SizeOf(TPathBuffer)));
  if KernelPath = nil then
    Exit(ErrorOutOfMemory);
  Result := TranslateUserPath(CurrentProcess, @UserPath[0], @KernelPath^[0], PathCapacity);
  if Result <> ErrorNone then
  begin
    FreeKernelMemory(KernelPath);
    KernelPath := nil;
  end;
end;

{ True if the user path names the null device. }
function IsNullDevicePath(PathAddress: QWord): Boolean;
var
  UserPath: TPathBuffer;
  Normalized: TPathBuffer;
begin
  Result := (CopyStringFromUser(PathAddress, @UserPath[0], PathCapacity) = ErrorNone) and
    (NormalizeUserPath(CurrentProcess, @UserPath[0], @Normalized[0], PathCapacity) = ErrorNone) and
    TextIsEqual(@Normalized[0], NullDeviceUserPath);
end;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function LookupCurrentHandle(Handle: Int64; out Kind: THandleKind; out ObjectBody: Pointer): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := LookupHandle(Process^.Handles, Handle, Kind, ObjectBody);
  ReleaseMutex(Process^.Lock);
end;

function InsertCurrentHandle(Kind: THandleKind; ObjectBody: Pointer): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := InsertHandle(Process^.Handles, Kind, ObjectBody, 0);
  ReleaseMutex(Process^.Lock);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

procedure DescribeNodeForUser(const Information: TNodeInformation; out UserInformation: TAbiFileInformation);
begin
  FillMemory(@UserInformation, SizeOf(UserInformation), 0);
  case Information.Kind of
    NodeKindFile: UserInformation.Kind := KindFile;
    NodeKindDirectory: UserInformation.Kind := KindDirectory;
    NodeKindSymbolicLink: UserInformation.Kind := KindSymbolicLink;
  else
    UserInformation.Kind := KindOther;
  end;
  UserInformation.Mode := Information.Mode;
  UserInformation.SizeInBytes := Information.SizeInBytes;
  UserInformation.NodeNumber := Information.NodeNumber;
  UserInformation.LinkCount := Information.LinkCount;
  UserInformation.OwnerId := Information.OwnerId;
  UserInformation.GroupId := Information.GroupId;
  UserInformation.ModificationTime := Information.ModificationTime;
  UserInformation.AccessTime := Information.AccessTime;
  UserInformation.ChangeTime := Information.ChangeTime;
end;

{ --- Handles --------------------------------------------------------- }

function PerformOpenFile(PathAddress: QWord; Flags: QWord): Int64;
var
  KernelPath: PPathBuffer;
  OpenedFile: POpenFile;
  Status: TFileSystemStatus;
  Error: LongInt;
begin
  if IsNullDevicePath(PathAddress) then
    Exit(InsertCurrentHandle(HandleKindNull, NullDeviceObject));
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { The Abi open flags have the same values as the VFS ones. }
  Status := OpenFile(@KernelPath^[0], LongWord(Flags), OpenedFile);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));

  Result := InsertCurrentHandle(HandleKindFile, OpenedFile);
  { The handle table took its own reference. }
  CloseFile(OpenedFile);
end;

function PerformCloseHandle(Handle: Int64): Int64;
var
  Process: PProcess;
  Closed: Boolean;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Closed := CloseHandle(Process^.Handles, Handle);
  ReleaseMutex(Process^.Lock);
  if Closed then
    Result := 0
  else
    Result := Failure(ErrorBadHandle);
end;

function PerformReadHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  BytesRead: QWord;
  Status: TFileSystemStatus;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if not UserRangeIsValid(BufferAddress, ByteCount, True) then
    Exit(Failure(ErrorBadAddress));

  case Kind of
    HandleKindFile:
      begin
        Status := ReadFromFile(POpenFile(ObjectBody), Pointer(BufferAddress), ByteCount, BytesRead);
        if Status <> StatusSuccess then
          Exit(Failure(ErrorFromStatus(Status)));
        Result := Int64(BytesRead);
      end;
    HandleKindConsole:
      Result := Int64(ReadFromConsole(PByte(BufferAddress), ByteCount));
    HandleKindPipeReadEnd:
      Result := Int64(ReadFromPipe(PPipe(ObjectBody), PByte(BufferAddress), ByteCount));
    HandleKindNull:
      Result := 0;
  else
    Result := Failure(ErrorBadHandle);
  end;
end;

function PerformWriteHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Written: QWord;
  Status: TFileSystemStatus;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if not UserRangeIsValid(BufferAddress, ByteCount, False) then
    Exit(Failure(ErrorBadAddress));

  case Kind of
    HandleKindFile:
      begin
        Status := WriteToFile(POpenFile(ObjectBody), Pointer(BufferAddress), ByteCount, Written);
        if (Status <> StatusSuccess) and (Written = 0) then
          Exit(Failure(ErrorFromStatus(Status)));
        Result := Int64(Written);
      end;
    HandleKindConsole:
      begin
        WriteToConsole(PByte(BufferAddress), ByteCount);
        Result := Int64(ByteCount);
      end;
    HandleKindPipeWriteEnd:
      begin
        Result := WriteToPipe(PPipe(ObjectBody), PByte(BufferAddress), ByteCount);
        if Result < 0 then
          Result := Failure(ErrorBrokenPipe);
      end;
    HandleKindNull:
      Result := Int64(ByteCount);
  else
    Result := Failure(ErrorBadHandle);
  end;
end;

function PerformSeekHandle(Handle: Int64; Offset: Int64; Origin: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Information: TNodeInformation;
  Base: Int64;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if Kind <> HandleKindFile then
    Exit(Failure(ErrorIllegalSeek));

  case Origin of
    SeekFromStart: Base := 0;
    SeekFromCurrent: Base := Int64(GetFilePosition(POpenFile(ObjectBody)));
    SeekFromEnd:
      begin
        GetFileInformation(POpenFile(ObjectBody), Information);
        Base := Int64(Information.SizeInBytes);
      end;
  else
    Exit(Failure(ErrorInvalidArgument));
  end;
  if Base + Offset < 0 then
    Exit(Failure(ErrorInvalidArgument));
  SetFilePosition(POpenFile(ObjectBody), QWord(Base + Offset));
  Result := Base + Offset;
end;

function PerformSetFileSize(Handle: Int64; Size: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) or (Kind <> HandleKindFile) then
    Exit(Failure(ErrorBadHandle));
  Result := -Int64(ErrorFromStatus(ChangeFileSize(POpenFile(ObjectBody), Size)));
end;

function PerformGetHandleInformation(Handle: Int64; InformationAddress: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Information: TNodeInformation;
  UserInformation: TAbiFileInformation;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if Kind = HandleKindFile then
  begin
    GetFileInformation(POpenFile(ObjectBody), Information);
    DescribeNodeForUser(Information, UserInformation);
  end
  else
  begin
    FillMemory(@UserInformation, SizeOf(UserInformation), 0);
    UserInformation.Kind := KindOther;
  end;
  Result := -Int64(CopyToUser(InformationAddress, @UserInformation, SizeOf(UserInformation)));
end;

function PerformGetHandleKind(Handle: Int64): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  case Kind of
    HandleKindFile: Result := Abi.SystemCalls.HandleKindFile;
    HandleKindConsole: Result := Abi.SystemCalls.HandleKindConsole;
    HandleKindPipeReadEnd, HandleKindPipeWriteEnd: Result := HandleKindPipe;
    HandleKindProcess: Result := Abi.SystemCalls.HandleKindProcess;
    HandleKindNull: Result := HandleKindNullDevice;
    HandleKindThread: Result := Abi.SystemCalls.HandleKindThread;
  else
    Result := Failure(ErrorBadHandle);
  end;
end;

{ --- Paths ----------------------------------------------------------- }

function PerformGetPathInformation(PathAddress: QWord; InformationAddress: QWord; FollowLinks: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Information: TNodeInformation;
  UserInformation: TAbiFileInformation;
  Status: TFileSystemStatus;
  Error: LongInt;
begin
  if IsNullDevicePath(PathAddress) then
  begin
    FillMemory(@UserInformation, SizeOf(UserInformation), 0);
    UserInformation.Kind := KindOther;
    UserInformation.Mode := $1B6; { rw-rw-rw- }
    UserInformation.LinkCount := 1;
    Exit(-Int64(CopyToUser(InformationAddress, @UserInformation, SizeOf(UserInformation))));
  end;
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if FollowLinks <> 0 then
    Status := GetPathInformation(@KernelPath^[0], Information)
  else
    Status := GetLinkInformation(@KernelPath^[0], Information);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  DescribeNodeForUser(Information, UserInformation);
  Result := -Int64(CopyToUser(InformationAddress, @UserInformation, SizeOf(UserInformation)));
end;

function PerformReadDirectory(Handle: Int64; EntryAddress: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Entry: TDirectoryEntry;
  UserEntry: TAbiDirectoryEntry;
  Status: TFileSystemStatus;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) or (Kind <> HandleKindFile) then
    Exit(Failure(ErrorBadHandle));
  Status := ReadDirectoryEntry(POpenFile(ObjectBody), Entry);
  if Status = StatusEndOfDirectory then
    Exit(0);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));

  FillMemory(@UserEntry, SizeOf(UserEntry), 0);
  case Entry.Kind of
    NodeKindFile: UserEntry.Kind := KindFile;
    NodeKindDirectory: UserEntry.Kind := KindDirectory;
    NodeKindSymbolicLink: UserEntry.Kind := KindSymbolicLink;
  else
    UserEntry.Kind := KindOther;
  end;
  UserEntry.NodeNumber := Entry.NodeNumber;
  CopyText(@UserEntry.Name[0], @Entry.Name[0], AbiNameCapacity);
  Result := -Int64(CopyToUser(EntryAddress, @UserEntry, SizeOf(UserEntry)));
  if Result = 0 then
    Result := 1;
end;

function PerformCreateDirectory(PathAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Error: LongInt;
begin
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := -Int64(ErrorFromStatus(CreateDirectory(@KernelPath^[0])));
  FreeKernelMemory(KernelPath);
end;

function PerformRemovePath(PathAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Error: LongInt;
begin
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := -Int64(ErrorFromStatus(RemovePath(@KernelPath^[0])));
  FreeKernelMemory(KernelPath);
end;

function PerformRenamePath(SourceAddress: QWord; TargetAddress: QWord): Int64;
var
  SourcePath: PPathBuffer;
  TargetPath: PPathBuffer;
  Error: LongInt;
  Status: TFileSystemStatus;
begin
  Error := FetchKernelPath(SourceAddress, SourcePath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := FetchKernelPath(TargetAddress, TargetPath);
  if Error <> ErrorNone then
  begin
    FreeKernelMemory(SourcePath);
    Exit(Failure(Error));
  end;
  Status := RenamePath(@SourcePath^[0], @TargetPath^[0]);
  FreeKernelMemory(SourcePath);
  FreeKernelMemory(TargetPath);
  if Status = StatusUnsupported then
    Exit(Failure(ErrorCrossVolume));
  Result := -Int64(ErrorFromStatus(Status));
end;

function PerformCreateSymbolicLink(TargetAddress: QWord; PathAddress: QWord): Int64;
var
  Target: TPathBuffer;
  KernelPath: PPathBuffer;
  Error: LongInt;
begin
  Error := CopyStringFromUser(TargetAddress, @Target[0], PathCapacity);
  if Error = ErrorNone then
    Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := -Int64(ErrorFromStatus(CreateSymbolicLink(@KernelPath^[0], @Target[0])));
  FreeKernelMemory(KernelPath);
end;

function PerformReadSymbolicLink(PathAddress: QWord; BufferAddress: QWord; Capacity: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Target: TPathBuffer;
  Error: LongInt;
  Status: TFileSystemStatus;
  Length: QWord;
begin
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := ReadSymbolicLinkTarget(@KernelPath^[0], @Target[0], PathCapacity);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  Length := TextLength(@Target[0]);
  if Length + 1 > Capacity then
    Exit(Failure(ErrorNameTooLong));
  Error := CopyToUser(BufferAddress, @Target[0], Length + 1);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Length);
end;

function PerformGetCurrentDirectory(BufferAddress: QWord; Capacity: QWord): Int64;
var
  Process: PProcess;
  Directory: TPathBuffer;
  Length: QWord;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  CopyText(@Directory[0], @Process^.CurrentDirectory[0], PathCapacity);
  ReleaseMutex(Process^.Lock);
  Length := TextLength(@Directory[0]);
  if Length + 1 > Capacity then
    Exit(Failure(ErrorNameTooLong));
  Result := -Int64(CopyToUser(BufferAddress, @Directory[0], Length + 1));
  if Result = 0 then
    Result := Int64(Length);
end;

function PerformSetCurrentDirectory(PathAddress: QWord): Int64;
var
  Process: PProcess;
  UserPath: TPathBuffer;
  Normalized: TPathBuffer;
  KernelPath: TPathBuffer;
  Information: TNodeInformation;
  Error: LongInt;
  Status: TFileSystemStatus;
begin
  Process := CurrentProcess;
  Error := CopyStringFromUser(PathAddress, @UserPath[0], PathCapacity);
  if Error = ErrorNone then
    Error := NormalizeUserPath(Process, @UserPath[0], @Normalized[0], PathCapacity);
  if Error = ErrorNone then
    Error := TranslateUserPath(Process, @Normalized[0], @KernelPath[0], PathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));

  Status := GetPathInformation(@KernelPath[0], Information);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  if Information.Kind <> NodeKindDirectory then
    Exit(Failure(ErrorNotDirectory));

  AcquireMutex(Process^.Lock);
  CopyText(@Process^.CurrentDirectory[0], @Normalized[0], PathCapacity);
  ReleaseMutex(Process^.Lock);
  Result := 0;
end;

{ --- Pipes and duplication ------------------------------------------- }

function PerformCreatePipe(HandlesAddress: QWord): Int64;
var
  Pipe: PPipe;
  Handles: array[0..1] of Int64;
  Process: PProcess;
begin
  if not UserRangeIsValid(HandlesAddress, SizeOf(Handles), True) then
    Exit(Failure(ErrorBadAddress));
  Pipe := CreatePipe;
  if Pipe = nil then
    Exit(Failure(ErrorOutOfMemory));

  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Handles[0] := InsertHandle(Process^.Handles, HandleKindPipeReadEnd, Pipe, 0);
  Handles[1] := InsertHandle(Process^.Handles, HandleKindPipeWriteEnd, Pipe, 0);
  if (Handles[0] < 0) or (Handles[1] < 0) then
  begin
    CloseHandle(Process^.Handles, Handles[0]);
    CloseHandle(Process^.Handles, Handles[1]);
    ReleaseMutex(Process^.Lock);
    DereferenceObject(Pipe);
    Exit(Failure(ErrorTooManyHandles));
  end;
  ReleaseMutex(Process^.Lock);
  DereferenceObject(Pipe);

  Result := -Int64(CopyToUser(HandlesAddress, @Handles[0], SizeOf(Handles)));
end;

function PerformDuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;
var
  Process: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  if not LookupHandle(Process^.Handles, Handle, Kind, ObjectBody) then
    Result := Failure(ErrorBadHandle)
  else if NewHandle < 0 then
  begin
    Result := InsertHandle(Process^.Handles, Kind, ObjectBody, 0);
    if Result < 0 then
      Result := Failure(ErrorTooManyHandles);
  end
  else if NewHandle >= MaximumHandles then
    Result := Failure(ErrorBadHandle)
  else
  begin
    if NewHandle <> Handle then
      SetHandle(Process^.Handles, Integer(NewHandle), Kind, ObjectBody);
    Result := NewHandle;
  end;
  ReleaseMutex(Process^.Lock);
end;

{ --- Volumes --------------------------------------------------------- }

function PerformListVolumes(Index: QWord; InformationAddress: QWord): Int64;
var
  Volume: PVolume;
  Information: TAbiVolumeInformation;
begin
  if Index >= QWord(VolumeCount) then
    Exit(0);
  Volume := VolumeAt(Integer(Index));
  FillMemory(@Information, SizeOf(Information), 0);
  CopyText(@Information.Name[0], @Volume^.Name[0], AbiTextCapacity);
  CopyText(@Information.FileSystemType[0], @Volume^.TypeName[0], AbiTextCapacity);
  CopyText(@Information.VolumeLabel[0], @Volume^.VolumeLabel[0], AbiTextCapacity);
  Information.TotalBytes := Volume^.TotalBytes;
  Information.HasFreeSpace := Ord(GetVolumeFreeSpace(Volume, Information.FreeBytes));
  Information.IsReadOnly := Ord(Volume^.IsReadOnly);
  Information.IsSystemVolume := Ord(TextIsEqual(@Volume^.Name[0], SystemVolumeName));
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
  if Result = 0 then
    Result := 1;
end;

function PerformSync: Int64;
begin
  SyncAllVolumes;
  Result := 0;
end;

{ --- Attributes and links -------------------------------------------- }

function PerformSetPathAttributes(PathAddress: QWord; ChangesAddress: QWord; FollowLinks: QWord): Int64;
var
  UserChanges: TAbiAttributeChanges;
  Changes: TAttributeChanges;
  KernelPath: PPathBuffer;
  Error: LongInt;
begin
  Error := CopyFromUser(@UserChanges, ChangesAddress, SizeOf(UserChanges));
  if Error = ErrorNone then
    Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { The Abi field flags have the same values as the VFS ones. }
  Changes.Fields := UserChanges.Fields;
  Changes.Mode := UserChanges.Mode;
  Changes.OwnerId := UserChanges.OwnerId;
  Changes.GroupId := UserChanges.GroupId;
  Changes.ModificationTime := UserChanges.ModificationTime;
  Changes.AccessTime := UserChanges.AccessTime;
  Result := -Int64(ErrorFromStatus(SetPathAttributes(@KernelPath^[0], FollowLinks <> 0, Changes)));
  FreeKernelMemory(KernelPath);
end;

{ True if two kernel paths start with the same volume name. }
function OnSameVolume(First, Second: PChar): Boolean;
var
  Index: PtrUInt;
begin
  Index := 1;
  while (First[Index] <> '/') and (First[Index] <> #0) do
  begin
    if First[Index] <> Second[Index] then
      Exit(False);
    Inc(Index);
  end;
  Result := (Second[Index] = '/') or (Second[Index] = #0);
end;

function PerformCreateHardLink(ExistingAddress: QWord; NewAddress: QWord): Int64;
var
  ExistingPath: PPathBuffer;
  NewPath: PPathBuffer;
  Error: LongInt;
begin
  Error := FetchKernelPath(ExistingAddress, ExistingPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := FetchKernelPath(NewAddress, NewPath);
  if Error <> ErrorNone then
  begin
    FreeKernelMemory(ExistingPath);
    Exit(Failure(Error));
  end;
  if not OnSameVolume(@ExistingPath^[0], @NewPath^[0]) then
    Result := Failure(ErrorCrossVolume)
  else
    Result := -Int64(ErrorFromStatus(CreateHardLink(@ExistingPath^[0], @NewPath^[0])));
  FreeKernelMemory(ExistingPath);
  FreeKernelMemory(NewPath);
end;

{ chroot: Path becomes the process's "/", and its current directory. }
function PerformSetRootDirectory(PathAddress: QWord): Int64;
var
  Process: PProcess;
  UserPath: TPathBuffer;
  NewRoot: TPathBuffer;
  KernelPath: TPathBuffer;
  Information: TNodeInformation;
  Error: LongInt;
  Status: TFileSystemStatus;
begin
  Process := CurrentProcess;
  Error := CopyStringFromUser(PathAddress, @UserPath[0], PathCapacity);
  if Error = ErrorNone then
    Error := UnrootedUserPath(Process, @UserPath[0], @NewRoot[0], PathCapacity);
  if Error = ErrorNone then
    Error := TranslateUserPath(Process, @UserPath[0], @KernelPath[0], PathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := GetPathInformation(@KernelPath[0], Information);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  if Information.Kind <> NodeKindDirectory then
    Exit(Failure(ErrorNotDirectory));

  AcquireMutex(Process^.Lock);
  CopyText(@Process^.RootDirectory[0], @NewRoot[0], PathCapacity);
  CopyText(@Process^.CurrentDirectory[0], '/', PathCapacity);
  ReleaseMutex(Process^.Lock);
  Result := 0;
end;

{ --- Device control -------------------------------------------------- }

function PerformControlHandle(Handle: Int64; Request: QWord; Argument: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if Kind <> HandleKindConsole then
    Exit(Failure(ErrorUnsupported));
  case Request of
    ControlGetConsoleMode: Result := GetConsoleMode;
    ControlSetConsoleMode:
      begin
        SetConsoleMode(LongWord(Argument));
        Result := 0;
      end;
    ControlGetConsoleSize: Result := (Int64(ConsoleRows) shl 16) or ConsoleColumns;
    ControlSetForegroundGroup:
      begin
        SetConsoleForegroundGroup(Argument);
        Result := 0;
      end;
    ControlGetForegroundGroup: Result := Int64(ConsoleForegroundGroup);
    ControlTakePendingInterrupt:
      if TakePendingInterrupt then
        Result := 1
      else
        Result := 0;
  else
    Result := Failure(ErrorInvalidArgument);
  end;
end;

end.
