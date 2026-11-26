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

uses
  Processes.Process;

type
  TPathBuffer = array[0..ProcessPathCapacity - 1] of Char;
  PPathBuffer = ^TPathBuffer;

{ Copies a user path and translates it to a kernel path. The buffer
  comes from the heap and must be freed by the caller. }
function FetchKernelPath(PathAddress: QWord; out KernelPath: PPathBuffer): LongInt;

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
function PerformCreateFifo(PathAddress: QWord): Int64;

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
  Io.LineDiscipline,
  Io.Manager,
  Io.DeviceFiles,
  Io.Pipes,
  Objects.Manager,
  Processes.Handles,
  Processes.Paths,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Security,
  FileSystem.Security,
  Kernel.Clock,
  Processes.Stopping,
  Processes.TerminalCalls,
  Processes.FileAttributeCalls,
  Processes.FileLockCalls,
  Processes.SocketCalls,
  Processes.LocalSocketCalls,
  Processes.Restrictions,
  Processes.EventDescriptorCalls;

const
  PathCapacity = ProcessPathCapacity;

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

{ --- Devices -------------------------------------------------------- }

{ Every device appears under /dev, whatever the program's root directory
  is (Io.Manager). }

const
  DeviceDirectoryPath = '/dev';
  DeviceDirectoryPrefix = '/dev/';
  ControllingTerminalName = 'tty';

type
  TDevicePath = (NotADevicePath, DeviceDirectory, DeviceEntry);

{ Whether the user path names /dev or a device in it; for a device, its
  name goes to Name (DeviceNameLength bytes). }
function ClassifyDevicePath(PathAddress: QWord; Name: PChar): TDevicePath;
var
  UserPath: TPathBuffer;
  Normalized: TPathBuffer;
  Rest: PChar;
  Index: Integer;
begin
  Result := NotADevicePath;
  if (CopyStringFromUser(PathAddress, @UserPath[0], PathCapacity) <> ErrorNone) or
     (NormalizeUserPath(CurrentProcess, @UserPath[0], @Normalized[0], PathCapacity) <> ErrorNone) then
    Exit;
  if TextIsEqual(@Normalized[0], DeviceDirectoryPath) then
    Exit(DeviceDirectory);
  for Index := 0 to Length(DeviceDirectoryPrefix) - 1 do
    if Normalized[Index] <> DeviceDirectoryPrefix[Index + 1] then
      Exit;
  Rest := @Normalized[Length(DeviceDirectoryPrefix)];
  { /dev/pts/N is the pseudo-terminal ptsN (the name C programs use). }
  if (Rest[0] = 'p') and (Rest[1] = 't') and (Rest[2] = 's') and (Rest[3] = '/') and
     (Rest[4] >= '0') and (Rest[4] <= '9') then
  begin
    Index := 4;
    while (Rest[Index] >= '0') and (Rest[Index] <= '9') do
      Inc(Index);
    if (Rest[Index] <> #0) or (Index >= DeviceNameLength) then
      Exit;
    CopyText(Name, 'pts', DeviceNameLength);
    CopyText(@Name[3], @Rest[4], DeviceNameLength - 3);
    Exit(DeviceEntry);
  end;
  if (Rest^ = #0) or (TextLength(Rest) >= DeviceNameLength) then
    Exit;
  Index := 0;
  while Rest[Index] <> #0 do
  begin
    if Rest[Index] = '/' then
      Exit;
    Inc(Index);
  end;
  CopyText(Name, Rest, DeviceNameLength);
  Result := DeviceEntry;
end;

procedure DescribeDeviceForUser(Device: PDeviceObject; out UserInformation: TAbiFileInformation);
begin
  FillMemory(@UserInformation, SizeOf(UserInformation), 0);
  if Device^.Kind = DeviceKindBlock then
    UserInformation.Kind := KindBlockDevice
  else
    UserInformation.Kind := KindCharacterDevice;
  UserInformation.Mode := Device^.Mode;
  UserInformation.OwnerId := Device^.OwnerId;
  UserInformation.GroupId := Device^.GroupId;
  UserInformation.SizeInBytes := Device^.SizeInBytes;
  UserInformation.LinkCount := 1;
end;

procedure DescribeDeviceDirectoryForUser(out UserInformation: TAbiFileInformation);
const
  DirectoryMode = $1ED; { rwxr-xr-x }
begin
  FillMemory(@UserInformation, SizeOf(UserInformation), 0);
  UserInformation.Kind := KindDirectory;
  UserInformation.Mode := DirectoryMode;
  UserInformation.LinkCount := 2;
end;

{ Checks the device's permission bits like a file's. }
function MayOpenDevice(Device: PDeviceObject; Flags: LongWord): Boolean;
var
  Information: TNodeInformation;
  Access: LongWord;
begin
  FillMemory(@Information, SizeOf(Information), 0);
  Information.Mode := Device^.Mode;
  Information.OwnerId := Device^.OwnerId;
  Information.GroupId := Device^.GroupId;
  Access := 0;
  if (Flags and OpenWrite) <> 0 then
    Access := Access or AccessWrite;
  if ((Flags and OpenRead) <> 0) or (Access = 0) then
    Access := Access or AccessRead;
  Result := MayAccess(Information, Access);
end;

function DeviceOfHandle(ObjectBody: Pointer): PDeviceObject;
begin
  Result := PDeviceFile(ObjectBody)^.Device;
end;

{ The line discipline of the terminal a device handle is, or nil. }
function TerminalOfHandle(ObjectBody: Pointer): PLineDiscipline;
var
  Device: PDeviceObject;
begin
  Device := PDeviceObject(TerminalDeviceOf(HandleKindDevice, ObjectBody));
  if Device = nil then
    Exit(nil);
  Result := PLineDiscipline(Device^.Terminal);
end;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function LookupCurrentHandle(Handle: Int64; out Kind: THandleKind; out ObjectBody: Pointer): Boolean;
begin
  { The handle table's shared lock: lookups of a process's threads run
    side by side (Processes.Handles). }
  Result := LookupHandle(CurrentProcess^.Handles, Handle, Kind, ObjectBody);
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
    NodeKindFifo: UserInformation.Kind := KindFifo;
    NodeKindSocket: UserInformation.Kind := KindSocket;
  else
    UserInformation.Kind := KindOther;
  end;
  UserInformation.AllocatedBytes := Information.AllocatedBytes;
  UserInformation.Mode := Information.Mode;
  UserInformation.SizeInBytes := Information.SizeInBytes;
  UserInformation.NodeNumber := Information.NodeNumber;
  UserInformation.LinkCount := Information.LinkCount;
  UserInformation.OwnerId := Information.OwnerId;
  UserInformation.GroupId := Information.GroupId;
  UserInformation.ModificationTime := Information.ModificationTime;
  UserInformation.AccessTime := Information.AccessTime;
  UserInformation.ChangeTime := Information.ChangeTime;
  UserInformation.VolumeNumber := Information.VolumeNumber;
end;

{ --- Handles --------------------------------------------------------- }

{ A named pipe opens as one end of the pipe shared by everyone who has
  the node open, once someone opens the other end. }
function OpenFifo(OpenedFile: POpenFile; Flags: QWord): Int64;
var
  ForWriting: Boolean;
  Pipe: PPipe;
begin
  ForWriting := (Flags and (OpenForWriting or OpenAppend)) <> 0;
  Pipe := OpenNamedPipe(OpenedFile^.Volume, OpenedFile^.Node^.Information.NodeNumber, ForWriting);
  CloseFile(OpenedFile);
  if Pipe = nil then
    Exit(Failure(ErrorInterrupted));
  if ForWriting then
    Result := InsertCurrentHandle(HandleKindPipeWriteEnd, Pipe)
  else
    Result := InsertCurrentHandle(HandleKindPipeReadEnd, Pipe);
  { The handle counts its own end and holds its own reference. }
  ClosePipeEnd(Pipe, ForWriting);
  DereferenceObject(Pipe);
end;

{ Opens Device (nil: the /dev directory) and gives the caller a handle. }
function OpenDeviceForHandle(Device: PDeviceObject; Flags: LongWord): Int64;
var
  OpenFile: PDeviceFile;
  Error: LongInt;
begin
  if Device = nil then
  begin
    if (Flags and OpenWrite) <> 0 then
      Exit(Failure(ErrorIsDirectory));
    Error := OpenDeviceDirectory(OpenFile);
  end
  else
  begin
    if (Flags and (OpenCreate or OpenExclusive)) = (OpenCreate or OpenExclusive) then
      Exit(Failure(ErrorExists));
    if not MayOpenDevice(Device, Flags) then
      Exit(Failure(ErrorAccessDenied));
    Error := OpenDevice(Device, Flags, OpenFile);
  end;
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := InsertCurrentHandle(HandleKindDevice, OpenFile);
  { The handle holds its own reference. }
  DereferenceObject(OpenFile);
end;

const
  { Every open flag a program may pass. }
  AbiOpenFlags = OpenRead or OpenWrite or OpenCreate or OpenExclusive or OpenTruncate or OpenAppend;

function PerformOpenFile(PathAddress: QWord; Flags: QWord): Int64;
var
  DeviceName: array[0..DeviceNameLength - 1] of Char;
  Device: PDeviceObject;
  KernelPath: PPathBuffer;
  OpenedFile: POpenFile;
  Status: TFileSystemStatus;
  Error: LongInt;
begin
  if ((Flags and (OpenWrite or OpenCreate or OpenTruncate or OpenAppend)) <> 0) and
     CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
  case ClassifyDevicePath(PathAddress, @DeviceName[0]) of
    DeviceDirectory:
      begin
        if CallerRestricted(RestrictFileReads) then
          Exit(Failure(ErrorAccessDenied));
        Exit(OpenDeviceForHandle(nil, Flags));
      end;
    DeviceEntry:
      begin
        if CallerRestricted(RestrictFileReads) and not RestrictedDeviceReadable(@DeviceName[0]) then
          Exit(Failure(ErrorAccessDenied));
        Device := FindDevice(@DeviceName[0]);
        { /dev/tty is the program's own terminal. }
        if TextIsEqual(@DeviceName[0], ControllingTerminalName) then
          Device := PDeviceObject(CurrentProcess^.ControllingTerminal);
        if Device = nil then
          Exit(Failure(ErrorNotFound));
        Exit(OpenDeviceForHandle(Device, LongWord(Flags)));
      end;
  end;
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if CallerRestricted(RestrictFileReads) and not RestrictedPathReadable(@KernelPath^[0]) then
  begin
    FreeKernelMemory(KernelPath);
    Exit(Failure(ErrorAccessDenied));
  end;
  { The Abi open flags have the same values as the VFS ones; the VFS's
    own (OpenForExecution, which skips the read check) never come from a
    program. }
  Status := OpenFile(@KernelPath^[0], LongWord(Flags) and AbiOpenFlags, OpenedFile);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));

  if (OpenedFile^.Node <> nil) and (OpenedFile^.Node^.Information.Kind = NodeKindFifo) then
    Exit(OpenFifo(OpenedFile, Flags));
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

{ A program outside the foreground group of its controlling terminal
  may not read that terminal: its group is stopped instead (like
  SIGTTIN), and the read runs again once a shell has continued it in the
  foreground. Reading another terminal is not checked. }
function StopIfReadingInBackground(Terminal: PLineDiscipline): Boolean;
var
  Process: PProcess;
  Foreground: QWord;
begin
  Result := False;
  Process := CurrentProcess;
  if (Terminal = nil) or not Process^.IsUserProcess or (Process^.ControllingTerminal = nil) or
     (PDeviceObject(Process^.ControllingTerminal)^.Terminal <> Terminal) then
    Exit;
  Foreground := Terminal^.ForegroundGroup;
  Result := (Foreground <> 0) and (Process^.GroupId <> Foreground) and not Process^.IgnoresInterrupt;
  if Result then
    SuspendProcessGroup(Process^.GroupId);
end;

{ Reads and writes never hand a user pointer to a driver or file system:
  data goes through a kernel buffer, a piece at a time (see
  Processes.UserAccess). A read or write that fails after some bytes were
  moved returns that count; the error shows on the next call. }

function ReadFileInPieces(OpenFile: POpenFile; BufferAddress, ByteCount: QWord;
  Buffer: PByte; BufferSize: QWord): Int64;
var
  Total: QWord;
  Piece: QWord;
  BytesRead: QWord;
  Status: TFileSystemStatus;
begin
  Total := 0;
  while Total < ByteCount do
  begin
    Piece := ByteCount - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    Status := ReadFromFile(OpenFile, Buffer, Piece, BytesRead);
    if Status <> StatusSuccess then
    begin
      if Total = 0 then
        Exit(Failure(ErrorFromStatus(Status)));
      Break;
    end;
    if (BytesRead > 0) and (CopyToUser(BufferAddress + Total, Buffer, BytesRead) <> ErrorNone) then
    begin
      if Total = 0 then
        Exit(Failure(ErrorBadAddress));
      Break;
    end;
    Total := Total + BytesRead;
    if BytesRead < Piece then
      Break;
  end;
  Result := Int64(Total);
end;

{ Character devices answer one read with what they have; block devices
  are read in pieces like files. An interrupted read reports
  ErrorInterrupted (and is started again if a stop caused it). }
function ReadDeviceInPieces(OpenFile: PDeviceFile; BufferAddress, ByteCount: QWord;
  Buffer: PByte; BufferSize: QWord): Int64;
var
  Total: QWord;
  Piece: QWord;
  Count: Int64;
begin
  Total := 0;
  repeat
    Piece := ByteCount - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    Count := ReadDevice(OpenFile, Buffer, Piece);
    if Count < 0 then
    begin
      if Total = 0 then
        Exit(Count);
      Break;
    end;
    if (Count > 0) and (CopyToUser(BufferAddress + Total, Buffer, QWord(Count)) <> ErrorNone) then
    begin
      if Total = 0 then
        Exit(Failure(ErrorBadAddress));
      Break;
    end;
    Total := Total + QWord(Count);
  until (OpenFile^.IsDirectory) or (OpenFile^.Device^.Kind <> DeviceKindBlock) or
    (QWord(Count) < Piece) or (Total = ByteCount);
  Result := Int64(Total);
end;

{ After a device read into Buffer: copies Count (if positive) out. }
function FinishDeviceRead(Count: Int64; BufferAddress: QWord; Buffer: PByte): Int64;
begin
  Result := Count;
  if (Count > 0) and (CopyToUser(BufferAddress, Buffer, QWord(Count)) <> ErrorNone) then
    Result := Failure(ErrorBadAddress);
end;

function PerformReadHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Buffer: PByte;
  BufferSize: QWord;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if not UserRangeIsValid(BufferAddress, ByteCount, True) then
    Exit(Failure(ErrorBadAddress));
  if ByteCount = 0 then
    Exit(0);
  Buffer := PByte(AllocateTransferBuffer(ByteCount, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));

  case Kind of
    HandleKindFile:
      Result := ReadFileInPieces(POpenFile(ObjectBody), BufferAddress, ByteCount, Buffer, BufferSize);
    HandleKindDevice:
      if StopIfReadingInBackground(TerminalOfHandle(ObjectBody)) then
        Result := Failure(ErrorInterrupted)
      else
        Result := ReadDeviceInPieces(PDeviceFile(ObjectBody), BufferAddress, ByteCount, Buffer,
          BufferSize);
    HandleKindPipeReadEnd:
      begin
        Result := ReadFromPipe(PPipe(ObjectBody), Buffer, BufferSize);
        if Result = PipeInterrupted then
          Result := Failure(ErrorInterrupted)
        else
          Result := FinishDeviceRead(Result, BufferAddress, Buffer);
      end;
    HandleKindSocket:
      Result := ReadSocketHandle(ObjectBody, BufferAddress, ByteCount);
    HandleKindLocalSocket:
      Result := ReadLocalSocketHandle(ObjectBody, BufferAddress, ByteCount);
    HandleKindEventCounter, HandleKindTimerDescriptor, HandleKindSignalDescriptor, HandleKindEventPoll,
    HandleKindWatchGroup:
      Result := ReadEventDescriptor(Kind, ObjectBody, BufferAddress, ByteCount);
  else
    Result := Failure(ErrorBadHandle);
  end;
  FreeTransferBuffer(Buffer);
end;

type
  TWriteTarget = (WriteToFileTarget, WriteToDeviceTarget, WriteToPipeTarget);

{ Writes one piece; returns the bytes written or a negative Abi error. }
function WritePiece(Target: TWriteTarget; ObjectBody: Pointer; Buffer: PByte; Piece: QWord): Int64;
var
  Written: QWord;
  Status: TFileSystemStatus;
begin
  case Target of
    WriteToFileTarget:
      begin
        Status := WriteToFile(POpenFile(ObjectBody), Buffer, Piece, Written);
        if (Status <> StatusSuccess) and (Written = 0) then
          Exit(Failure(ErrorFromStatus(Status)));
        Result := Int64(Written);
      end;
    WriteToDeviceTarget:
      Result := WriteDevice(PDeviceFile(ObjectBody), Buffer, Piece);
  else
    begin
      Result := WriteToPipe(PPipe(ObjectBody), Buffer, Piece);
      if Result = PipeInterrupted then
        Result := Failure(ErrorInterrupted)
      else if Result < 0 then
        Result := Failure(ErrorBrokenPipe);
    end;
  end;
end;

function WriteInPieces(Target: TWriteTarget; ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Total: QWord;
  Piece: QWord;
  Written: Int64;
begin
  Buffer := PByte(AllocateTransferBuffer(ByteCount, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Total := 0;
  Result := 0;
  while Total < ByteCount do
  begin
    Piece := ByteCount - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    if CopyFromUser(Buffer, BufferAddress + Total, Piece) <> ErrorNone then
      Written := Failure(ErrorBadAddress)
    else
      Written := WritePiece(Target, ObjectBody, Buffer, Piece);
    if Written < 0 then
    begin
      if Total = 0 then
        Result := Written;
      Break;
    end;
    Total := Total + QWord(Written);
    if QWord(Written) < Piece then
      Break;
  end;
  if Total > 0 then
    Result := Int64(Total);
  FreeTransferBuffer(Buffer);
end;

function PerformWriteHandle(Handle: Int64; BufferAddress: QWord; ByteCount: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if not UserRangeIsValid(BufferAddress, ByteCount, False) then
    Exit(Failure(ErrorBadAddress));
  if ByteCount = 0 then
    Exit(0);

  case Kind of
    HandleKindFile:
      Result := WriteInPieces(WriteToFileTarget, ObjectBody, BufferAddress, ByteCount);
    HandleKindDevice:
      Result := WriteInPieces(WriteToDeviceTarget, ObjectBody, BufferAddress, ByteCount);
    HandleKindPipeWriteEnd:
      Result := WriteInPieces(WriteToPipeTarget, ObjectBody, BufferAddress, ByteCount);
    HandleKindSocket:
      Result := WriteSocketHandle(ObjectBody, BufferAddress, ByteCount);
    HandleKindLocalSocket:
      Result := WriteLocalSocketHandle(ObjectBody, BufferAddress, ByteCount);
    HandleKindEventCounter, HandleKindTimerDescriptor, HandleKindSignalDescriptor, HandleKindEventPoll,
    HandleKindWatchGroup:
      Result := WriteEventDescriptor(Kind, ObjectBody, BufferAddress, ByteCount);
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
  if (Kind = HandleKindDevice) and not PDeviceFile(ObjectBody)^.IsDirectory and
     (DeviceOfHandle(ObjectBody)^.Kind = DeviceKindBlock) then
    Exit(SeekDevice(PDeviceFile(ObjectBody), Offset, Origin));
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
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
  else if (Kind = HandleKindDevice) and PDeviceFile(ObjectBody)^.IsDirectory then
    DescribeDeviceDirectoryForUser(UserInformation)
  else if Kind = HandleKindDevice then
    DescribeDeviceForUser(DeviceOfHandle(ObjectBody), UserInformation)
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
    HandleKindDevice:
      if PDeviceFile(ObjectBody)^.IsDirectory then
        Result := Abi.SystemCalls.HandleKindDevice
      else
        Result := DeviceOfHandle(ObjectBody)^.ReportedHandleKind;
    HandleKindPipeReadEnd, HandleKindPipeWriteEnd: Result := HandleKindPipe;
    HandleKindProcess: Result := Abi.SystemCalls.HandleKindProcess;
    HandleKindThread: Result := Abi.SystemCalls.HandleKindThread;
    HandleKindEvent: Result := Abi.SystemCalls.HandleKindEvent;
    HandleKindTimer: Result := Abi.SystemCalls.HandleKindTimer;
    HandleKindSection: Result := Abi.SystemCalls.HandleKindSection;
    HandleKindPort: Result := Abi.SystemCalls.HandleKindPort;
    HandleKindChannel: Result := Abi.SystemCalls.HandleKindChannel;
    HandleKindWatch: Result := Abi.SystemCalls.HandleKindWatch;
    HandleKindSocket, HandleKindLocalSocket: Result := Abi.SystemCalls.HandleKindSocket;
    HandleKindSemaphore: Result := Abi.SystemCalls.HandleKindSemaphore;
    HandleKindMutex: Result := Abi.SystemCalls.HandleKindMutex;
    HandleKindEventCounter: Result := Abi.SystemCalls.HandleKindEventCounter;
    HandleKindTimerDescriptor: Result := Abi.SystemCalls.HandleKindTimerDescriptor;
    HandleKindSignalDescriptor: Result := Abi.SystemCalls.HandleKindSignalDescriptor;
    HandleKindEventPoll: Result := Abi.SystemCalls.HandleKindEventPoll;
    HandleKindWatchGroup: Result := Abi.SystemCalls.HandleKindWatchGroup;
  else
    Result := Failure(ErrorBadHandle);
  end;
end;

{ --- Paths ----------------------------------------------------------- }

function PerformGetPathInformation(PathAddress: QWord; InformationAddress: QWord; FollowLinks: QWord): Int64;
var
  DeviceName: array[0..DeviceNameLength - 1] of Char;
  Device: PDeviceObject;
  KernelPath: PPathBuffer;
  Information: TNodeInformation;
  UserInformation: TAbiFileInformation;
  Status: TFileSystemStatus;
  Error: LongInt;
begin
  case ClassifyDevicePath(PathAddress, @DeviceName[0]) of
    DeviceDirectory:
      begin
        DescribeDeviceDirectoryForUser(UserInformation);
        Exit(-Int64(CopyToUser(InformationAddress, @UserInformation, SizeOf(UserInformation))));
      end;
    DeviceEntry:
      begin
        Device := FindDevice(@DeviceName[0]);
        { /dev/tty is the program's own terminal. }
        if TextIsEqual(@DeviceName[0], ControllingTerminalName) then
          Device := PDeviceObject(CurrentProcess^.ControllingTerminal);
        if Device = nil then
          Exit(Failure(ErrorNotFound));
        DescribeDeviceForUser(Device, UserInformation);
        Exit(-Int64(CopyToUser(InformationAddress, @UserInformation, SizeOf(UserInformation))));
      end;
  end;
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if CallerRestricted(RestrictFileReads) and not RestrictedPathReadable(@KernelPath^[0]) then
  begin
    FreeKernelMemory(KernelPath);
    Exit(Failure(ErrorAccessDenied));
  end;
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

{ The next entry of /dev; 0 at the end, else 1 (like PerformReadDirectory). }
function ReadDeviceDirectory(Directory: PDeviceFile; EntryAddress: QWord): Int64;
var
  Device: PDeviceObject;
  UserEntry: TAbiDirectoryEntry;
  Error: LongInt;
begin
  Device := DeviceAt(Integer(Directory^.ReadDirectoryIndex));
  if Device = nil then
    Exit(0);
  Inc(Directory^.ReadDirectoryIndex);
  FillMemory(@UserEntry, SizeOf(UserEntry), 0);
  if Device^.Kind = DeviceKindBlock then
    UserEntry.Kind := KindBlockDevice
  else
    UserEntry.Kind := KindCharacterDevice;
  CopyText(@UserEntry.Name[0], @Device^.Name[0], SizeOf(UserEntry.Name));
  Error := CopyToUser(EntryAddress, @UserEntry, SizeOf(UserEntry));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 1;
end;

function PerformReadDirectory(Handle: Int64; EntryAddress: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Entry: TDirectoryEntry;
  UserEntry: TAbiDirectoryEntry;
  Status: TFileSystemStatus;
begin
  if not LookupCurrentHandle(Handle, Kind, ObjectBody) then
    Exit(Failure(ErrorBadHandle));
  if (Kind = HandleKindDevice) and PDeviceFile(ObjectBody)^.IsDirectory then
    Exit(ReadDeviceDirectory(PDeviceFile(ObjectBody), EntryAddress));
  if Kind <> HandleKindFile then
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
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
  else if NewHandle >= Process^.Handles.Limit then
    Result := Failure(ErrorBadHandle)
  else if (NewHandle <> Handle) and not SetHandle(Process^.Handles, Integer(NewHandle), Kind, ObjectBody) then
    Result := Failure(ErrorOutOfMemory)
  else
    Result := NewHandle;
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
  { The list closes up when a volume goes away meanwhile. }
  if Volume = nil then
    Exit(0);
  FillVolumeInformation(Volume, Information);
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
  if Result = 0 then
    Result := 1;
end;

function PerformCreateFifo(PathAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Error: LongInt;
begin
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := -Int64(ErrorFromStatus(CreateFifo(@KernelPath^[0])));
  FreeKernelMemory(KernelPath);
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
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
  Error := CopyAttributeChangesFromUser(ChangesAddress, UserChanges);
  if Error = ErrorNone then
    Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  ConvertAttributeChanges(UserChanges, Changes);
  { Who may change what is checked on the node itself, with its volume's
    lock held (Processes.Security.CurrentMayChangeAttributes). }
  Result := -Int64(ErrorFromStatus(SetPathAttributes(@KernelPath^[0], FollowLinks <> 0, Changes)));
  FreeKernelMemory(KernelPath);
end;

function PerformCreateHardLink(ExistingAddress: QWord; NewAddress: QWord): Int64;
var
  ExistingPath: PPathBuffer;
  NewPath: PPathBuffer;
  Error: LongInt;
begin
  if CallerRestricted(RestrictFileWrites) then
    Exit(Failure(ErrorAccessDenied));
  Error := FetchKernelPath(ExistingAddress, ExistingPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := FetchKernelPath(NewAddress, NewPath);
  if Error <> ErrorNone then
  begin
    FreeKernelMemory(ExistingPath);
    Exit(Failure(Error));
  end;
  { Two volumes (mount points included) are refused with ErrorCrossVolume. }
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
  if (Kind = HandleKindFile) and ((Request = ControlLockFile) or (Request = ControlUnlockFile)) then
    Exit(PerformFileLockRequest(Handle, Request, Argument));
  if IsEventDescriptorKind(Kind) then
    Exit(ControlEventDescriptor(Kind, ObjectBody, Request, Argument));
  if Kind <> HandleKindDevice then
    Exit(Failure(ErrorUnsupported));
  { The console's requests are handled by its driver
    (Drivers.ConsoleDevice). }
  Result := ControlDevice(PDeviceFile(ObjectBody), Request, Argument);
end;

end.
