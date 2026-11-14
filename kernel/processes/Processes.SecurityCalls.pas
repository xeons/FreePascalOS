{
  System calls for users, process information and priorities
  (CallListProcesses .. CallSetPriority).
}
unit Processes.SecurityCalls;

{$mode objfpc}

interface

function PerformListProcesses(Index: QWord; InformationAddress: QWord): Int64;
function PerformGetCredentials(CredentialsAddress: QWord): Int64;
function PerformSetUserIds(RealId, EffectiveId, SavedId: Int64): Int64;
function PerformSetGroupIds(RealId, EffectiveId, SavedId: Int64): Int64;
function PerformSetGroups(Count: QWord; GroupsAddress: QWord): Int64;
function PerformSetUmask(Mask: QWord): Int64;
{ Returns 20 - nice (1 .. 40), so the result is never negative. }
function PerformGetPriority(ProcessId: QWord): Int64;
function PerformSetPriority(ProcessId: QWord; Nice: Int64): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Mutex,
  Kernel.Scheduler,
  Processes.Process,
  Processes.Thread,
  Processes.UserProcess,
  Processes.UserAccess,
  Processes.Security,
  Objects.Manager;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- Process list -------------------------------------------------- }

type
  TListSearch = record
    Wanted: QWord;
    Seen: QWord;
    Found: Boolean;
    Information: TAbiProcessInformation;
  end;
  PListSearch = ^TListSearch;

procedure DescribeProcess(Process: PProcess; out Information: TAbiProcessInformation);
begin
  FillMemory(@Information, SizeOf(Information), 0);
  Information.ProcessId := Process^.ProcessId;
  Information.ParentProcessId := Process^.ParentProcessId;
  Information.GroupId := Process^.GroupId;
  Information.RealUserId := Process^.Credentials.RealUserId;
  Information.EffectiveUserId := Process^.Credentials.EffectiveUserId;
  Information.Nice := Process^.Credentials.Nice;
  Information.ThreadCount := Process^.ThreadCount;
  if Process^.HasExited or Process^.TerminationRequested then
    Information.State := ProcessStateExiting
  else if ProcessIsRunnable(Process) then
    Information.State := ProcessStateRunning
  else
    Information.State := ProcessStateSleeping;
  if Process^.AddressSpace <> nil then
    Information.MemoryPages := Process^.AddressSpace^.CommittedPages;
  Information.CpuMilliseconds := TicksToMilliseconds(ProcessRunTicks(Process));
  Information.StartTime := Process^.StartTime;
  CopyText(@Information.Name[0], @Process^.Name[0], AbiTextCapacity);
end;

procedure VisitForList(Process: PProcess; Context: Pointer);
var
  Search: PListSearch;
begin
  Search := PListSearch(Context);
  if Search^.Found or not Process^.IsUserProcess then
    Exit;
  if Search^.Seen = Search^.Wanted then
  begin
    DescribeProcess(Process, Search^.Information);
    Search^.Found := True;
  end;
  Inc(Search^.Seen);
end;

function PerformListProcesses(Index: QWord; InformationAddress: QWord): Int64;
var
  Search: TListSearch;
begin
  FillMemory(@Search, SizeOf(Search), 0);
  Search.Wanted := Index;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@VisitForList, @Search);
  UnlockProcessRegistry;
  if not Search.Found then
    Exit(Failure(ErrorNoSuchProcess));
  Result := -Int64(CopyToUser(InformationAddress, @Search.Information, SizeOf(Search.Information)));
end;

{ --- Credentials --------------------------------------------------- }

function PerformGetCredentials(CredentialsAddress: QWord): Int64;
var
  Process: PProcess;
  Credentials: TProcessCredentials;
  Information: TAbiCredentials;
  Index: LongWord;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Credentials := Process^.Credentials;
  ReleaseMutex(Process^.Lock);
  FillMemory(@Information, SizeOf(Information), 0);
  Information.RealUserId := Credentials.RealUserId;
  Information.EffectiveUserId := Credentials.EffectiveUserId;
  Information.SavedUserId := Credentials.SavedUserId;
  Information.RealGroupId := Credentials.RealGroupId;
  Information.EffectiveGroupId := Credentials.EffectiveGroupId;
  Information.SavedGroupId := Credentials.SavedGroupId;
  Information.Umask := Credentials.Umask;
  Information.Nice := Credentials.Nice;
  Information.GroupCount := Credentials.GroupCount;
  Index := 0;
  while Index < Credentials.GroupCount do
  begin
    Information.Groups[Index] := Credentials.Groups[Index];
    Inc(Index);
  end;
  Result := -Int64(CopyToUser(CredentialsAddress, @Information, SizeOf(Information)));
end;

{ Unprivileged processes may only switch among their own three ids. }
function MaySwitchTo(Id: Int64; Real, Effective, Saved: LongWord): Boolean;
begin
  Result := (Id = IdUnchanged) or (LongWord(Id) = Real) or (LongWord(Id) = Effective) or
    (LongWord(Id) = Saved);
end;

function ValidId(Id: Int64): Boolean;
begin
  Result := (Id = IdUnchanged) or ((Id >= 0) and (Id <= $7FFFFFFF));
end;

procedure ApplyId(Id: Int64; var Target: LongWord);
begin
  if Id <> IdUnchanged then
    Target := LongWord(Id);
end;

function PerformSetUserIds(RealId, EffectiveId, SavedId: Int64): Int64;
var
  Process: PProcess;
begin
  if not ValidId(RealId) or not ValidId(EffectiveId) or not ValidId(SavedId) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  with Process^.Credentials do
  begin
    if (EffectiveUserId <> RootUserId) and not (
       MaySwitchTo(RealId, RealUserId, EffectiveUserId, SavedUserId) and
       MaySwitchTo(EffectiveId, RealUserId, EffectiveUserId, SavedUserId) and
       MaySwitchTo(SavedId, RealUserId, EffectiveUserId, SavedUserId)) then
    begin
      ReleaseMutex(Process^.Lock);
      Exit(Failure(ErrorNotPermitted));
    end;
    ApplyId(RealId, RealUserId);
    ApplyId(EffectiveId, EffectiveUserId);
    ApplyId(SavedId, SavedUserId);
  end;
  ReleaseMutex(Process^.Lock);
  Result := 0;
end;

function PerformSetGroupIds(RealId, EffectiveId, SavedId: Int64): Int64;
var
  Process: PProcess;
begin
  if not ValidId(RealId) or not ValidId(EffectiveId) or not ValidId(SavedId) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  with Process^.Credentials do
  begin
    if (EffectiveUserId <> RootUserId) and not (
       MaySwitchTo(RealId, RealGroupId, EffectiveGroupId, SavedGroupId) and
       MaySwitchTo(EffectiveId, RealGroupId, EffectiveGroupId, SavedGroupId) and
       MaySwitchTo(SavedId, RealGroupId, EffectiveGroupId, SavedGroupId)) then
    begin
      ReleaseMutex(Process^.Lock);
      Exit(Failure(ErrorNotPermitted));
    end;
    ApplyId(RealId, RealGroupId);
    ApplyId(EffectiveId, EffectiveGroupId);
    ApplyId(SavedId, SavedGroupId);
  end;
  ReleaseMutex(Process^.Lock);
  Result := 0;
end;

function PerformSetGroups(Count: QWord; GroupsAddress: QWord): Int64;
var
  Process: PProcess;
  Groups: array[0..MaximumProcessGroups - 1] of LongWord;
  Error: LongInt;
  Index: LongWord;
begin
  if Count > MaximumProcessGroups then
    Exit(Failure(ErrorInvalidArgument));
  if Count > 0 then
  begin
    Error := CopyFromUser(@Groups[0], GroupsAddress, Count * SizeOf(LongWord));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  if Process^.Credentials.EffectiveUserId <> RootUserId then
  begin
    ReleaseMutex(Process^.Lock);
    Exit(Failure(ErrorNotPermitted));
  end;
  Index := 0;
  while Index < Count do
  begin
    Process^.Credentials.Groups[Index] := Groups[Index];
    Inc(Index);
  end;
  Process^.Credentials.GroupCount := LongWord(Count);
  ReleaseMutex(Process^.Lock);
  Result := 0;
end;

function PerformSetUmask(Mask: QWord): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := Process^.Credentials.Umask;
  Process^.Credentials.Umask := LongWord(Mask) and $1FF;
  ReleaseMutex(Process^.Lock);
end;

{ --- Priorities ---------------------------------------------------- }

{ Finds a process by id (0 means the caller) with a reference. }
function ReferenceProcess(ProcessId: QWord): PProcess;
begin
  if ProcessId = 0 then
    ProcessId := CurrentProcess^.ProcessId;
  LockProcessRegistry;
  Result := FindRunningProcessLocked(ProcessId);
  if (Result <> nil) and not Result^.IsUserProcess then
    Result := nil;
  if Result <> nil then
    ReferenceObject(Result);
  UnlockProcessRegistry;
end;

function PerformGetPriority(ProcessId: QWord): Int64;
var
  Target: PProcess;
begin
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNoSuchProcess));
  Result := 20 - Target^.Credentials.Nice;
  DereferenceObject(Target);
end;

function PerformSetPriority(ProcessId: QWord; Nice: Int64): Int64;
var
  Caller: PProcess;
  Target: PProcess;
  CallerUserId: LongWord;
begin
  if Nice < NiceLowest then
    Nice := NiceLowest;
  if Nice > NiceHighest then
    Nice := NiceHighest;
  Caller := CurrentProcess;
  CallerUserId := Caller^.Credentials.EffectiveUserId;
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNoSuchProcess));
  AcquireMutex(Target^.Lock);
  if (CallerUserId <> RootUserId) and
     ((CallerUserId <> Target^.Credentials.RealUserId) and
      (CallerUserId <> Target^.Credentials.EffectiveUserId)) then
    Result := Failure(ErrorNotPermitted)
  else if (CallerUserId <> RootUserId) and (Nice < Target^.Credentials.Nice) then
    { Only root may make a process more favoured. }
    Result := Failure(ErrorNotPermitted)
  else
  begin
    Target^.Credentials.Nice := LongInt(Nice);
    Result := 0;
  end;
  ReleaseMutex(Target^.Lock);
  if Result = 0 then
    SetProcessThreadPriorities(Target, ThreadPriorityForNice(LongInt(Nice)));
  DereferenceObject(Target);
end;

end.
