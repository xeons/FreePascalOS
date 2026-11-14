{
  System calls about attributes of open files and volumes:
  CallSetHandleAttributes (times, mode, owner of an open file, by handle)
  and CallGetVolumeInformation (the volume a path is on). Also the checks
  and conversions they share with the path based calls
  (Processes.FileCalls).
}
unit Processes.FileAttributeCalls;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  FileSystem.Types,
  FileSystem.Volumes;

{ Root and kernel threads may change anything. }
function CallerMaySetAnyAttributes: Boolean;
{ May the calling process make Changes to a node described by
  Information? Fields are the Abi fields asked for. Returns ErrorNone,
  ErrorNotPermitted or ErrorAccessDenied. }
function CheckAttributeChangesFor(const Information: TNodeInformation; Fields: LongWord;
  const Changes: TAttributeChanges): LongInt;
{ The kernel form of Abi attribute changes ("now" times filled in). }
procedure ConvertAttributeChanges(const UserChanges: TAbiAttributeChanges; out Changes: TAttributeChanges);
procedure FillVolumeInformation(Volume: PVolume; out Information: TAbiVolumeInformation);

function PerformSetHandleAttributes(Handle: Int64; ChangesAddress: QWord): Int64;
function PerformGetVolumeInformation(PathAddress: QWord; InformationAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Clock,
  Kernel.Mutex,
  FileSystem.Files,
  FileSystem.Security,
  Processes.Process,
  Processes.Handles,
  Processes.Paths,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Security,
  Processes.FileCalls;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerMaySetAnyAttributes: Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Result := not Process^.IsUserProcess or (Process^.Credentials.EffectiveUserId = RootUserId);
end;

function CheckAttributeChangesFor(const Information: TNodeInformation; Fields: LongWord;
  const Changes: TAttributeChanges): LongInt;
var
  Process: PProcess;
  IsOwner: Boolean;
begin
  if CallerMaySetAnyAttributes then
    Exit(ErrorNone);
  Process := CurrentProcess;
  IsOwner := Information.OwnerId = Process^.Credentials.EffectiveUserId;
  Result := ErrorNone;
  if ((Changes.Fields and AttributeChangeMode) <> 0) and not IsOwner then
    Exit(ErrorNotPermitted);
  if ((Changes.Fields and AttributeChangeOwner) <> 0) and (Changes.OwnerId <> Information.OwnerId) then
    Exit(ErrorNotPermitted);
  if ((Changes.Fields and AttributeChangeGroup) <> 0) and (Changes.GroupId <> Information.GroupId) and
     (not IsOwner or not IsInGroup(Process^.Credentials, Changes.GroupId)) then
    Exit(ErrorNotPermitted);
  if ((Changes.Fields and (AttributeChangeModificationTime or AttributeChangeAccessTime)) <> 0) and
     not IsOwner then
  begin
    if (Fields and ChangeFieldTimesAreNow) = 0 then
      Exit(ErrorNotPermitted);
    if not CredentialsMayAccess(Process^.Credentials, Information, AccessWrite) then
      Exit(ErrorAccessDenied);
  end;
end;

procedure ConvertAttributeChanges(const UserChanges: TAbiAttributeChanges; out Changes: TAttributeChanges);
begin
  { The Abi field flags have the same values as the VFS ones. }
  Changes.Fields := UserChanges.Fields;
  Changes.Mode := UserChanges.Mode;
  Changes.OwnerId := UserChanges.OwnerId;
  Changes.GroupId := UserChanges.GroupId;
  Changes.ModificationTime := UserChanges.ModificationTime;
  Changes.AccessTime := UserChanges.AccessTime;
  if (UserChanges.Fields and ChangeFieldTimesAreNow) <> 0 then
  begin
    Changes.Fields := Changes.Fields and not ChangeFieldTimesAreNow;
    Changes.ModificationTime := CurrentWallClockTime;
    Changes.AccessTime := Changes.ModificationTime;
  end;
end;

procedure FillVolumeInformation(Volume: PVolume; out Information: TAbiVolumeInformation);
begin
  FillMemory(@Information, SizeOf(Information), 0);
  CopyText(@Information.Name[0], @Volume^.Name[0], AbiTextCapacity);
  CopyText(@Information.FileSystemType[0], @Volume^.TypeName[0], AbiTextCapacity);
  CopyText(@Information.VolumeLabel[0], @Volume^.VolumeLabel[0], AbiTextCapacity);
  Information.TotalBytes := Volume^.TotalBytes;
  Information.HasFreeSpace := Ord(GetVolumeFreeSpace(Volume, Information.FreeBytes));
  Information.IsReadOnly := Ord(Volume^.IsReadOnly);
  Information.IsSystemVolume := Ord(TextIsEqual(@Volume^.Name[0], SystemVolumeName));
end;

function PerformSetHandleAttributes(Handle: Int64; ChangesAddress: QWord): Int64;
var
  UserChanges: TAbiAttributeChanges;
  Changes: TAttributeChanges;
  Kind: THandleKind;
  ObjectBody: Pointer;
  Information: TNodeInformation;
  Error: LongInt;
  Process: PProcess;
  Found: Boolean;
begin
  Error := CopyFromUser(@UserChanges, ChangesAddress, SizeOf(UserChanges));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Found := LookupHandle(Process^.Handles, Handle, Kind, ObjectBody);
  ReleaseMutex(Process^.Lock);
  if not Found then
    Exit(Failure(ErrorBadHandle));
  if Kind <> HandleKindFile then
    Exit(Failure(ErrorUnsupported));
  ConvertAttributeChanges(UserChanges, Changes);
  GetFileInformation(POpenFile(ObjectBody), Information);
  Error := CheckAttributeChangesFor(Information, UserChanges.Fields, Changes);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := -Int64(ErrorFromStatus(SetFileAttributes(POpenFile(ObjectBody), Changes)));
end;

{ The volume name a kernel path starts with: "/disk2p1/bin" gives
  "disk2p1"; "/" names no volume. }
function VolumeOfKernelPath(Path: PChar): PVolume;
var
  Name: array[0..AbiTextCapacity - 1] of Char;
  Length: Integer;
begin
  Length := 0;
  if Path[0] = '/' then
    Inc(Path);
  while (Path[Length] <> '/') and (Path[Length] <> #0) and (Length < AbiTextCapacity - 1) do
  begin
    Name[Length] := Path[Length];
    Inc(Length);
  end;
  Name[Length] := #0;
  if Length = 0 then
    Exit(nil);
  Result := FindVolumeByName(@Name[0]);
end;

function PerformGetVolumeInformation(PathAddress: QWord; InformationAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Information: TAbiVolumeInformation;
  Volume: PVolume;
  Error: LongInt;
begin
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Volume := VolumeOfKernelPath(@KernelPath^[0]);
  FreeKernelMemory(KernelPath);
  if Volume = nil then
    Exit(Failure(ErrorNotFound));
  FillVolumeInformation(Volume, Information);
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

end.
