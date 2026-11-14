{
  Paths as user programs see them.

  The kernel's file namespace has the mounted volumes at its root
  (/disk1p2/...). User programs instead see a Unix style tree: "/" is the
  root of the system volume (the one holding /bin and /lib), and every
  volume is also reachable as /volumes/<name>. Relative paths start at the
  process's current directory.

  The system volume is the one named by the kernel option "root=", or else
  the first volume labelled FPOSROOT.
}
unit Processes.Paths;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.Process;

const
  SystemVolumeLabel = 'FPOSROOT';
  VolumesDirectoryName = 'volumes';

{ Picks the system volume. Returns False if there is none. }
function SelectSystemVolume: Boolean;
function SystemVolumeName: PChar;

{ Turns a user path (absolute or relative to Process's current directory)
  into a normalized absolute user path, resolving "." and "..".
  Returns 0 or an Abi error code. }
function NormalizeUserPath(Process: PProcess; UserPath: PChar; Normalized: PChar;
  Capacity: PtrUInt): LongInt;

{ Turns a user path into the kernel's form, ready for the VFS. }
function TranslateUserPath(Process: PProcess; UserPath: PChar; KernelPath: PChar;
  Capacity: PtrUInt): LongInt;

{ The kernel path of a file in the system volume, e.g. "/lib/libsystem.so". }
procedure SystemVolumePath(SystemRelativePath: PChar; KernelPath: PChar; Capacity: PtrUInt);

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Options,
  FileSystem.Types,
  FileSystem.Volumes;

const
  MaximumComponents = 128;

var
  SystemVolume: array[0..VolumeNameLength - 1] of Char;

function SelectSystemVolume: Boolean;
var
  RequestedName: array[0..VolumeNameLength - 1] of Char;
  Index: Integer;
  Volume: PVolume;
begin
  SystemVolume[0] := #0;
  if GetKernelOptionValue('root', @RequestedName[0], VolumeNameLength) and
     (FindVolumeByName(@RequestedName[0]) <> nil) then
  begin
    CopyText(@SystemVolume[0], @RequestedName[0], VolumeNameLength);
    Exit(True);
  end;

  for Index := 0 to VolumeCount - 1 do
  begin
    Volume := VolumeAt(Index);
    if TextIsEqual(@Volume^.VolumeLabel[0], SystemVolumeLabel) then
    begin
      CopyText(@SystemVolume[0], @Volume^.Name[0], VolumeNameLength);
      Exit(True);
    end;
  end;
  Result := False;
end;

function SystemVolumeName: PChar;
begin
  Result := @SystemVolume[0];
end;

procedure AppendText(Destination: PChar; Capacity: PtrUInt; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  CopyText(Destination + Length, Text, Capacity - Length);
end;

function NormalizeUserPath(Process: PProcess; UserPath: PChar; Normalized: PChar;
  Capacity: PtrUInt): LongInt;
var
  Combined: PChar;
  Components: array[0..MaximumComponents - 1] of PChar;
  ComponentCount: Integer;
  Position: PtrUInt;
  Start: PChar;
  Index: Integer;
begin
  if (UserPath = nil) or (UserPath^ = #0) then
    Exit(ErrorNotFound);
  Combined := PChar(AllocateKernelMemory(2 * ProcessPathCapacity));
  if Combined = nil then
    Exit(ErrorOutOfMemory);

  Combined[0] := #0;
  if UserPath^ <> '/' then
  begin
    AppendText(Combined, 2 * ProcessPathCapacity, @Process^.CurrentDirectory[0]);
    AppendText(Combined, 2 * ProcessPathCapacity, '/');
  end;
  if TextLength(Combined) + TextLength(UserPath) >= 2 * ProcessPathCapacity then
  begin
    FreeKernelMemory(Combined);
    Exit(ErrorNameTooLong);
  end;
  AppendText(Combined, 2 * ProcessPathCapacity, UserPath);

  { Split in place at '/', dropping "." and resolving "..". }
  ComponentCount := 0;
  Position := 0;
  Result := ErrorNone;
  while Combined[Position] <> #0 do
  begin
    while Combined[Position] = '/' do
    begin
      Combined[Position] := #0;
      Inc(Position);
    end;
    if Combined[Position] = #0 then
      Break;
    Start := @Combined[Position];
    while (Combined[Position] <> '/') and (Combined[Position] <> #0) do
      Inc(Position);
    if Combined[Position] = '/' then
    begin
      Combined[Position] := #0;
      Inc(Position);
    end;

    if TextIsEqual(Start, '.') then
      Continue;
    if TextIsEqual(Start, '..') then
    begin
      if ComponentCount > 0 then
        Dec(ComponentCount);
      Continue;
    end;
    if ComponentCount >= MaximumComponents then
    begin
      Result := ErrorNameTooLong;
      Break;
    end;
    Components[ComponentCount] := Start;
    Inc(ComponentCount);
  end;

  if Result = ErrorNone then
  begin
    Normalized[0] := #0;
    for Index := 0 to ComponentCount - 1 do
    begin
      AppendText(Normalized, Capacity, '/');
      AppendText(Normalized, Capacity, Components[Index]);
    end;
    if ComponentCount = 0 then
      CopyText(Normalized, '/', Capacity);
    if TextLength(Normalized) + 1 >= Capacity then
      Result := ErrorNameTooLong;
  end;
  FreeKernelMemory(Combined);
end;

function TranslateUserPath(Process: PProcess; UserPath: PChar; KernelPath: PChar;
  Capacity: PtrUInt): LongInt;
var
  Normalized: array[0..ProcessPathCapacity - 1] of Char;
  PrefixLength: PtrUInt;
begin
  Result := NormalizeUserPath(Process, UserPath, @Normalized[0], ProcessPathCapacity);
  if Result <> ErrorNone then
    Exit;

  { "/volumes" and "/volumes/<name>/..." lead into the kernel namespace. }
  PrefixLength := TextLength('/' + VolumesDirectoryName);
  if MemoryIsEqual(@Normalized[0], PChar('/' + VolumesDirectoryName), PrefixLength) and
     ((Normalized[PrefixLength] = #0) or (Normalized[PrefixLength] = '/')) then
  begin
    if Normalized[PrefixLength] = #0 then
      CopyText(KernelPath, '/', Capacity)
    else
      CopyText(KernelPath, @Normalized[PrefixLength], Capacity);
    Exit(ErrorNone);
  end;

  if SystemVolume[0] = #0 then
    Exit(ErrorNotFound);
  KernelPath[0] := #0;
  AppendText(KernelPath, Capacity, '/');
  AppendText(KernelPath, Capacity, @SystemVolume[0]);
  if not TextIsEqual(@Normalized[0], '/') then
    AppendText(KernelPath, Capacity, @Normalized[0]);
  if TextLength(KernelPath) + 1 >= Capacity then
    Result := ErrorNameTooLong;
end;

procedure SystemVolumePath(SystemRelativePath: PChar; KernelPath: PChar; Capacity: PtrUInt);
begin
  KernelPath[0] := #0;
  AppendText(KernelPath, Capacity, '/');
  AppendText(KernelPath, Capacity, @SystemVolume[0]);
  AppendText(KernelPath, Capacity, SystemRelativePath);
end;

end.
