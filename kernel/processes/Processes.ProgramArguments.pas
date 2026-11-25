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
  FileSystem.Files,
  Processes.Process;

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
{ Opens the program at KernelPath for running it and checks that file,
  the one the loader then loads (a name swapped meanwhile changes
  nothing): running a program needs execute permission (root: any
  execute bit) and a volume not mounted noexec. A set-user-ID or
  set-group-ID program runs as its owner or group, unless its volume is
  mounted nosuid. ProgramFile is the caller's to close (CloseFile).
  Read permission is not needed: the kernel opens the file on its own
  authority once execute permission is checked (a program of mode 0711
  runs, and nobody but the kernel reads it). ImageUnreadable says that
  the new program's user may not read it: the program then must not
  trust its environment (AT_SECURE: its dynamic linker ignores
  LD_PRELOAD, which could otherwise load code that reads it), and it is
  marked so (TProcess.ImageUnreadable) for anything that would look
  into its memory. }
function OpenProgramFile(Caller: PProcess; KernelPath: PChar; var Credentials: TProcessCredentials;
  out ProgramFile: POpenFile; out ImageUnreadable: Boolean): LongInt;
{ Opens a library at KernelPath for loading it at run time: it must be
  a file the caller may read and run, on a volume not mounted noexec. }
function OpenLibraryFile(Caller: PProcess; KernelPath: PChar; out LibraryFile: POpenFile): LongInt;

implementation

uses
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  FileSystem.Types,
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

{ Opens KernelPath for reading as a file (the caller's read
  permission, or with OpenForExecution in Flags its execute permission,
  is the file system's to check). }
function OpenRegularFile(KernelPath: PChar; Flags: LongWord; out OpenedFile: POpenFile;
  out Information: TNodeInformation): LongInt;
begin
  OpenedFile := nil;
  case OpenFile(KernelPath, OpenForReading or Flags, OpenedFile) of
    StatusSuccess: ;
    StatusAccessDenied: Exit(ErrorAccessDenied);
  else
    Exit(ErrorNotFound);
  end;
  GetFileInformation(OpenedFile, Information);
  if (OpenedFile^.Volume = nil) or (Information.Kind <> NodeKindFile) then
  begin
    CloseFile(OpenedFile);
    OpenedFile := nil;
    Exit(ErrorAccessDenied);
  end;
  Result := ErrorNone;
end;

function OpenProgramFile(Caller: PProcess; KernelPath: PChar; var Credentials: TProcessCredentials;
  out ProgramFile: POpenFile; out ImageUnreadable: Boolean): LongInt;
var
  Information: TNodeInformation;
begin
  ImageUnreadable := False;
  Result := OpenRegularFile(KernelPath, OpenForExecution, ProgramFile, Information);
  if (Result <> ErrorNone) or not Caller^.IsUserProcess then
    Exit;
  { Judged for whom it runs as before a set-user-ID change (that user
    started it; the owner may read it anyway). }
  ImageUnreadable := not CredentialsMayAccess(Credentials, Information, AccessRead);
  if ((Information.VolumeFlags and VolumeFlagNoExecute) <> 0) or
     not CredentialsMayAccess(Credentials, Information, AccessExecute) then
  begin
    CloseFile(ProgramFile);
    ProgramFile := nil;
    Exit(ErrorAccessDenied);
  end;
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

function OpenLibraryFile(Caller: PProcess; KernelPath: PChar; out LibraryFile: POpenFile): LongInt;
var
  Information: TNodeInformation;
begin
  Result := OpenRegularFile(KernelPath, 0, LibraryFile, Information);
  if (Result <> ErrorNone) or not Caller^.IsUserProcess then
    Exit;
  if ((Information.VolumeFlags and VolumeFlagNoExecute) <> 0) or
     not CredentialsMayAccess(Caller^.Credentials, Information, AccessRead or AccessExecute) then
  begin
    CloseFile(LibraryFile);
    LibraryFile := nil;
    Result := ErrorAccessDenied;
  end;
end;


end.
