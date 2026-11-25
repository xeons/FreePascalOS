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
  What starting a program takes from its caller: the argument and
  environment lists copied into the kernel, the file name of its path,
  and whether the caller may run it (and as whom: set-user-ID and
  set-group-ID programs). Used by CallCreateProcess and by exec
  (Processes.Execution).
}
unit Processes.ProgramArguments;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.ImageLoader;

const
  MaximumArgumentBytes = 64 * 1024;

type
  { Kernel copies of an argument or environment list. }
  TStringList = record
    Items: PPChar;
    Count: Integer;
    Storage: PChar;
  end;


procedure FreeStringList(var List: TStringList);
{ Copies a nil terminated array of user strings into kernel memory. }
function CopyStringListFromUser(ListAddress: QWord; out List: TStringList): LongInt;
{ The last part of a path. }
function FileNameOf(Path: PChar): PChar;
{ Running a program needs execute permission (root: any execute bit) and
  a volume not mounted noexec. A set-user-ID or set-group-ID program
  runs as its owner or group, unless its volume is mounted nosuid.
  Identity names the file checked: the caller loads the program by path
  again and must refuse if that is another file (ModuleIsProgram). }
function CheckMayExecute(Caller: PProcess; KernelPath: PChar;
  var Credentials: TProcessCredentials; out Identity: TProgramIdentity): LongInt;

implementation

uses
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Security,
  Processes.UserAccess,
  Processes.Security;

procedure FreeStringList(var List: TStringList);
begin
  FreeKernelMemory(List.Items);
  FreeKernelMemory(List.Storage);
  List.Items := nil;
  List.Storage := nil;
  List.Count := 0;
end;

{ Copies a nil terminated array of user strings into kernel memory. }
function CopyStringListFromUser(ListAddress: QWord; out List: TStringList): LongInt;
var
  Pointers: array[0..MaximumArguments] of QWord;
  Index: Integer;
  Used: QWord;
  Length: QWord;
begin
  List.Items := nil;
  List.Count := 0;
  List.Storage := nil;
  if ListAddress = 0 then
    Exit(ErrorNone);

  Index := 0;
  repeat
    if Index > MaximumArguments then
      Exit(ErrorNameTooLong);
    Result := CopyFromUser(@Pointers[Index], ListAddress + QWord(Index) * 8, 8);
    if Result <> ErrorNone then
      Exit;
    Inc(Index);
  until Pointers[Index - 1] = 0;
  List.Count := Index - 1;

  List.Items := PPChar(AllocateZeroedKernelMemory((List.Count + 1) * SizeOf(PChar)));
  List.Storage := PChar(AllocateKernelMemory(MaximumArgumentBytes));
  if (List.Items = nil) or (List.Storage = nil) then
  begin
    FreeStringList(List);
    Exit(ErrorOutOfMemory);
  end;

  Used := 0;
  for Index := 0 to List.Count - 1 do
  begin
    Result := CopyStringFromUser(Pointers[Index], List.Storage + Used, MaximumArgumentBytes - Used);
    if Result <> ErrorNone then
    begin
      FreeStringList(List);
      Exit;
    end;
    List.Items[Index] := List.Storage + Used;
    Length := TextLength(List.Storage + Used) + 1;
    Used := Used + Length;
  end;
  Result := ErrorNone;
end;

function FileNameOf(Path: PChar): PChar;
var
  Index: PtrUInt;
begin
  Result := Path;
  Index := 0;
  while Path[Index] <> #0 do
  begin
    if (Path[Index] = '/') and (Path[Index + 1] <> #0) then
      Result := @Path[Index + 1];
    Inc(Index);
  end;
end;

const
  ModeSetUserId = $800;
  ModeSetGroupId = $400;

{ Running a program needs execute permission (root: any execute bit) and
  a volume not mounted noexec. A set-user-ID or set-group-ID program
  runs as its owner or group, unless its volume is mounted nosuid. }
function CheckMayExecute(Caller: PProcess; KernelPath: PChar;
  var Credentials: TProcessCredentials; out Identity: TProgramIdentity): LongInt;
var
  Information: TNodeInformation;
begin
  Result := ErrorNone;
  Identity.IsKnown := False;
  Identity.VolumeNumber := 0;
  Identity.NodeNumber := 0;
  if not Caller^.IsUserProcess then
    Exit;
  { A missing program is reported by the loader. }
  if DescribePath(KernelPath, True, Information) <> StatusSuccess then
    Exit;
  Identity.IsKnown := True;
  Identity.VolumeNumber := Information.VolumeNumber;
  Identity.NodeNumber := Information.NodeNumber;
  if (Information.Kind <> NodeKindFile) or
     ((Information.VolumeFlags and VolumeFlagNoExecute) <> 0) or
     not CredentialsMayAccess(Credentials, Information, AccessExecute) then
    Exit(ErrorAccessDenied);
  if (Information.VolumeFlags and VolumeFlagNoSetId) <> 0 then
    Exit;
  if (Information.Mode and ModeSetUserId) <> 0 then
  begin
    Credentials.EffectiveUserId := Information.OwnerId;
    Credentials.SavedUserId := Information.OwnerId;
  end;
  if (Information.Mode and ModeSetGroupId) <> 0 then
  begin
    Credentials.EffectiveGroupId := Information.GroupId;
    Credentials.SavedGroupId := Information.GroupId;
  end;
end;


end.
