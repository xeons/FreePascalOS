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
  Users and permissions: the policy behind file access checks.

  Every process has real, effective and saved user and group ids, a list
  of supplementary groups, a umask and a nice value (TProcessCredentials,
  in Processes.Process). Children inherit all of them. User id 0 (root)
  passes every check except that running a file needs one execute bit.

  The VFS knows nothing of processes; InitializeProcessSecurity installs
  hooks (FileSystem.Security) that judge accesses as the current process.
  Kernel threads belong to the system process and act as root.
}
unit Processes.Security;

{$mode objfpc}

interface

uses
  FileSystem.Types,
  Processes.Process;

procedure InitializeProcessSecurity;

{ Root, with the default umask and nice 0. }
procedure GetRootCredentials(out Credentials: TProcessCredentials);

{ What a child of Process starts with. }
procedure InheritCredentials(Process: PProcess; out Credentials: TProcessCredentials);

{ May Credentials access a node with this information (FileSystem.Security
  access bits)? }
function CredentialsMayAccess(const Credentials: TProcessCredentials;
  const Information: TNodeInformation; Access: LongWord): Boolean;

function IsInGroup(const Credentials: TProcessCredentials; GroupId: LongWord): Boolean;

{ May Caller end, stop or continue Target? Users may control their own
  processes; root and kernel threads may control any. }
function MayControlProcess(Caller, Target: PProcess): Boolean;

implementation

uses
  Runtime.Memory,
  Kernel.Threads,
  FileSystem.Security,
  Processes.Thread;

const
  ExecuteBits = $49; { --x--x--x }

procedure GetRootCredentials(out Credentials: TProcessCredentials);
begin
  FillMemory(@Credentials, SizeOf(Credentials), 0);
  Credentials.Umask := DefaultUmask;
  Credentials.AffinityMask := AllProcessors;
end;

procedure InheritCredentials(Process: PProcess; out Credentials: TProcessCredentials);
begin
  if Process^.IsUserProcess then
    Credentials := Process^.Credentials
  else
    GetRootCredentials(Credentials);
end;

function IsInGroup(const Credentials: TProcessCredentials; GroupId: LongWord): Boolean;
var
  Index: LongWord;
begin
  if Credentials.EffectiveGroupId = GroupId then
    Exit(True);
  Index := 0;
  while Index < Credentials.GroupCount do
  begin
    if Credentials.Groups[Index] = GroupId then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function CredentialsMayAccess(const Credentials: TProcessCredentials;
  const Information: TNodeInformation; Access: LongWord): Boolean;
var
  Granted: LongWord;
begin
  if Credentials.EffectiveUserId = RootUserId then
  begin
    { Root may search any directory, but runs only files someone may run. }
    if ((Access and AccessExecute) <> 0) and (Information.Kind <> NodeKindDirectory) then
      Exit((Information.Mode and ExecuteBits) <> 0);
    Exit(True);
  end;
  if Credentials.EffectiveUserId = Information.OwnerId then
    Granted := (Information.Mode shr 6) and 7
  else if IsInGroup(Credentials, Information.GroupId) then
    Granted := (Information.Mode shr 3) and 7
  else
    Granted := Information.Mode and 7;
  Result := (Access and not Granted) = 0;
end;

{ --- VFS hooks ----------------------------------------------------- }

{ The hooks run with a volume lock held, so they read the credentials
  without taking the process lock; only the process itself changes them. }
function CurrentMayAccess(const Information: TNodeInformation; Access: LongWord): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if not Process^.IsUserProcess then
    Exit(True);
  Result := CredentialsMayAccess(Process^.Credentials, Information, Access);
end;

function CurrentCreationAttributes(out OwnerId, GroupId, Mask: LongWord): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  OwnerId := 0;
  GroupId := 0;
  Mask := 0;
  if not Process^.IsUserProcess then
    Exit(False);
  OwnerId := Process^.Credentials.EffectiveUserId;
  GroupId := Process^.Credentials.EffectiveGroupId;
  Mask := Process^.Credentials.Umask;
  Result := True;
end;

function MayControlProcess(Caller, Target: PProcess): Boolean;
var
  UserId: LongWord;
begin
  if not Caller^.IsUserProcess then
    Exit(True);
  UserId := Caller^.Credentials.EffectiveUserId;
  Result := (UserId = RootUserId) or (UserId = Target^.Credentials.RealUserId) or
    (Caller^.Credentials.RealUserId = Target^.Credentials.RealUserId);
end;

procedure InitializeProcessSecurity;
begin
  SetFileSecurityHooks(@CurrentMayAccess, @CurrentCreationAttributes);
end;

end.
