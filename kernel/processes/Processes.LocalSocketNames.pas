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
  The names local sockets are bound to.

  A name is either a path or a name in the abstract namespace (its
  first byte 0; every byte of its length counts). Binding to a path
  makes a socket node there (NodeKindSocket, which only ext and memory
  volumes can hold); the socket is then known by the node - its volume
  number and node number - so connecting through another path to the
  same node (a hard link, a symbolic link, a relative path) finds it.
  Removing the node leaves the socket bound but unreachable; closing
  the socket leaves the node (as on Unix: programs remove it before
  binding again). Abstract names are gone with their socket.

  The bound sockets are a list kept under the local sockets' lock.
}
unit Processes.LocalSocketNames;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Processes.LocalSockets;

{ Binds Socket to Name (Length 0: an abstract name made up here). A
  path is made into a socket node first; Mode is applied less the
  caller's umask (the VFS does that). Returns ErrorNone or an Abi
  error: ErrorAddressInUse (the name is taken, the path exists),
  ErrorInvalidArgument (Socket is bound already). }
function BindLocalSocketName(Socket: PLocalSocket; var Name: TAbiLocalSocketName): LongInt;
{ The socket bound to Name, referenced. A path needs write permission
  on its node. ErrorConnectionRefused if nobody is bound there,
  ErrorNotFound if there is no such path. }
function FindLocalSocketByName(constref Name: TAbiLocalSocketName; out Socket: PLocalSocket): LongInt;
{ Takes a released socket off the list. Lock held. }
procedure ForgetLocalSocketNameLocked(Socket: PLocalSocket);
{ Checks a name from a program: its length, and a path ended within it
  (the end is made a zero). }
function ValidateLocalSocketName(var Name: TAbiLocalSocketName): LongInt;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Kernel.Random,
  Objects.Manager,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Security,
  Processes.Process,
  Processes.Thread,
  Processes.Paths,
  Processes.UserAccess;

const
  AbstractNameDigits = 5;
  HexDigits: array[0..15] of Char = '0123456789abcdef';

type
  TKernelPath = array[0..ProcessPathCapacity - 1] of Char;
  PKernelPath = ^TKernelPath;

var
  BoundSockets: PLocalSocket = nil;

function IsAbstract(constref Name: TAbiLocalSocketName): Boolean;
begin
  Result := (Name.Length > 0) and (Name.Bytes[0] = #0);
end;

function ValidateLocalSocketName(var Name: TAbiLocalSocketName): LongInt;
var
  Index: LongWord;
begin
  if Name.Length > LocalSocketNameCapacity then
    Exit(ErrorInvalidArgument);
  if (Name.Length = 0) or IsAbstract(Name) then
    Exit(ErrorNone);
  { A path: up to its first zero, which must come within the name or
    right after it. }
  Index := 0;
  while (Index < Name.Length) and (Name.Bytes[Index] <> #0) do
    Inc(Index);
  if Index = LocalSocketNameCapacity then
    Exit(ErrorNameTooLong);
  Name.Bytes[Index] := #0;
  Name.Length := Index;
  if Index = 0 then
    Exit(ErrorInvalidArgument);
  Result := ErrorNone;
end;

function NamesAreEqual(constref First, Second: TAbiLocalSocketName): Boolean;
begin
  Result := (First.Length = Second.Length) and
    MemoryIsEqual(@First.Bytes[0], @Second.Bytes[0], First.Length);
end;

{ Lock held. }
function FindAbstractLocked(constref Name: TAbiLocalSocketName): PLocalSocket;
begin
  Result := BoundSockets;
  while Result <> nil do
  begin
    if not Result^.NamedByPath and NamesAreEqual(Result^.Name, Name) then
      Exit;
    Result := Result^.NextBound;
  end;
end;

function FindNodeLocked(VolumeNumber: LongWord; NodeNumber: QWord): PLocalSocket;
begin
  Result := BoundSockets;
  while Result <> nil do
  begin
    if Result^.NamedByPath and (Result^.NameVolume = VolumeNumber) and (Result^.NameNode = NodeNumber) then
      Exit;
    Result := Result^.NextBound;
  end;
end;

procedure AddBoundLocked(Socket: PLocalSocket);
begin
  Socket^.Bound := True;
  Socket^.NextBound := BoundSockets;
  BoundSockets := Socket;
end;

procedure ForgetLocalSocketNameLocked(Socket: PLocalSocket);
var
  Link: ^PLocalSocket;
begin
  if not Socket^.Bound then
    Exit;
  Link := @BoundSockets;
  while Link^ <> nil do
  begin
    if Link^ = Socket then
    begin
      Link^ := Socket^.NextBound;
      Break;
    end;
    Link := @Link^^.NextBound;
  end;
  { It keeps its name for getsockname, but is found no more. }
  Socket^.NextBound := nil;
end;

{ A path name in the kernel's form; nil (and Error) on failure. }
function KernelPathOf(constref Name: TAbiLocalSocketName; out Error: LongInt): PKernelPath;
begin
  Result := PKernelPath(AllocateKernelMemory(SizeOf(TKernelPath)));
  if Result = nil then
  begin
    Error := ErrorOutOfMemory;
    Exit;
  end;
  Error := TranslateUserPath(CurrentProcess, @Name.Bytes[0], @Result^[0], SizeOf(TKernelPath));
  if Error <> ErrorNone then
  begin
    FreeKernelMemory(Result);
    Result := nil;
  end;
end;

procedure MakeAbstractName(out Name: TAbiLocalSocketName);
var
  Value: QWord;
  Index: Integer;
begin
  FillMemory(@Name, SizeOf(Name), 0);
  Value := RandomQWord;
  Name.Length := 1 + AbstractNameDigits;
  for Index := AbstractNameDigits downto 1 do
  begin
    Name.Bytes[Index] := HexDigits[Value and 15];
    Value := Value shr 4;
  end;
end;

function BindAbstract(Socket: PLocalSocket; var Name: TAbiLocalSocketName): LongInt;
var
  Attempts: Integer;
  Chosen: Boolean;
begin
  Chosen := Name.Length = 0;
  Attempts := 0;
  LockLocalSockets;
  repeat
    if Chosen then
      MakeAbstractName(Name);
    if Socket^.Bound or Socket^.Released then
      Result := ErrorInvalidArgument
    else if FindAbstractLocked(Name) <> nil then
      Result := ErrorAddressInUse
    else
    begin
      Socket^.Name := Name;
      Socket^.NamedByPath := False;
      AddBoundLocked(Socket);
      Result := ErrorNone;
    end;
    Inc(Attempts);
  until (Result <> ErrorAddressInUse) or not Chosen or (Attempts >= 16);
  UnlockLocalSockets;
end;

function BindPath(Socket: PLocalSocket; constref Name: TAbiLocalSocketName): LongInt;
var
  KernelPath: PKernelPath;
  Status: TFileSystemStatus;
  Information: TNodeInformation;
begin
  LockLocalSockets;
  if Socket^.Bound or Socket^.Released then
    Result := ErrorInvalidArgument
  else
    Result := ErrorNone;
  UnlockLocalSockets;
  if Result <> ErrorNone then
    Exit;
  KernelPath := KernelPathOf(Name, Result);
  if KernelPath = nil then
    Exit;
  Status := CreateSocketNode(@KernelPath^[0]);
  if Status = StatusSuccess then
    Status := GetLinkInformation(@KernelPath^[0], Information);
  FreeKernelMemory(KernelPath);
  if Status = StatusAlreadyExists then
    Exit(ErrorAddressInUse);
  if Status <> StatusSuccess then
    Exit(ErrorFromStatus(Status));
  LockLocalSockets;
  if Socket^.Bound or Socket^.Released then
    Result := ErrorInvalidArgument
  else
  begin
    { A node of that number left by a socket whose node was removed
      (and the number used again) is found no more. }
    if FindNodeLocked(Information.VolumeNumber, Information.NodeNumber) <> nil then
      ForgetLocalSocketNameLocked(FindNodeLocked(Information.VolumeNumber, Information.NodeNumber));
    Socket^.Name := Name;
    Socket^.NamedByPath := True;
    Socket^.NameVolume := Information.VolumeNumber;
    Socket^.NameNode := Information.NodeNumber;
    AddBoundLocked(Socket);
    Result := ErrorNone;
  end;
  UnlockLocalSockets;
end;

function BindLocalSocketName(Socket: PLocalSocket; var Name: TAbiLocalSocketName): LongInt;
begin
  Result := ValidateLocalSocketName(Name);
  if Result <> ErrorNone then
    Exit;
  if (Name.Length = 0) or IsAbstract(Name) then
    Result := BindAbstract(Socket, Name)
  else
    Result := BindPath(Socket, Name);
end;

function FindByPath(constref Name: TAbiLocalSocketName; out Socket: PLocalSocket): LongInt;
var
  KernelPath: PKernelPath;
  Status: TFileSystemStatus;
  Information: TNodeInformation;
begin
  Socket := nil;
  KernelPath := KernelPathOf(Name, Result);
  if KernelPath = nil then
    Exit;
  Status := GetPathInformation(@KernelPath^[0], Information);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(ErrorFromStatus(Status));
  if Information.Kind <> NodeKindSocket then
    Exit(ErrorConnectionRefused);
  if not MayAccess(Information, AccessWrite) then
    Exit(ErrorAccessDenied);
  LockLocalSockets;
  Socket := FindNodeLocked(Information.VolumeNumber, Information.NodeNumber);
  if Socket <> nil then
    ReferenceObject(Socket);
  UnlockLocalSockets;
  if Socket = nil then
    Result := ErrorConnectionRefused
  else
    Result := ErrorNone;
end;

function FindLocalSocketByName(constref Name: TAbiLocalSocketName; out Socket: PLocalSocket): LongInt;
begin
  Socket := nil;
  if Name.Length = 0 then
    Exit(ErrorInvalidArgument);
  if not IsAbstract(Name) then
    Exit(FindByPath(Name, Socket));
  LockLocalSockets;
  Socket := FindAbstractLocked(Name);
  if Socket <> nil then
    ReferenceObject(Socket);
  UnlockLocalSockets;
  if Socket = nil then
    Result := ErrorConnectionRefused
  else
    Result := ErrorNone;
end;

end.
