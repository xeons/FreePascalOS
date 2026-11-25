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
  Named objects and the object namespace (calls 200-207), and mutexes.

  Objects have names in a tree of directories written with backslashes,
  \Shared\editor\lock; programs name theirs under \Shared (or a
  directory of their own made there). The CreateNamed* routines create
  or open: the first program to ask makes the object, the others open
  it (Created says which), so two programs agree on one event,
  semaphore, mutex or section by its name alone. A name lasts while
  any handle to its object is open.

  A mutex is owned by the thread whose wait took it (WaitForHandle,
  WaitForHandles); that thread may take it again and releases each take
  with ReleaseMutex. A wait that returns MutexAbandoned took a mutex
  whose previous owner ended holding it.

  Routines returning LongInt return ErrorNone or an error code; those
  returning Int64 a handle (or count) or minus an error code.
}
unit Sys.NamedObjects;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

const
  { WaitForHandle's result for an abandoned mutex it took. }
  MutexAbandoned = -1000;
  DefaultObjectMode = $1B6;      { rw-rw-rw-, less the umask }
  DefaultDirectoryMode = $1FF;   { rwxrwxrwx, less the umask }
  KeepObjectSecurity = -1;

type
  TObjectEntry = record
    Name: string;
    TypeName: string;
    Kind: LongWord;
    IsDirectory: Boolean;
    IsPermanent: Boolean;
    OwnerId: LongWord;
    GroupId: LongWord;
    Mode: LongWord;
    EntryCount: LongWord;
    ReferenceCount: QWord;
  end;
  TObjectEntryArray = array of TObjectEntry;

function CreateObjectDirectory(const Path: string; Mode: LongWord = DefaultDirectoryMode): LongInt;
{ Gives the object behind Handle the name Path. }
function NameObject(Handle: Int64; const Path: string; Mode: LongWord = DefaultObjectMode): LongInt;
{ A handle to the object named Path, of handle kind Kind (0: any). }
function OpenNamedObject(const Path: string; Kind: LongWord = 0): Int64;
{ Every entry of directory Path. }
function ListObjectDirectory(const Path: string; out Entries: TObjectEntryArray): LongInt;
function RemoveObjectName(const Path: string): LongInt;
{ chmod and chown of a name (KeepObjectSecurity leaves a field). }
function SetObjectSecurity(const Path: string; Mode, OwnerId, GroupId: Int64): LongInt;

function CreateMutex(InitiallyOwned: Boolean): Int64;
{ Gives up one take; RemainingHolds is how many the thread still has. }
function ReleaseMutex(Handle: Int64; out RemainingHolds: LongInt): LongInt;
{ Waits at most Timeout for one handle: ErrorNone, MutexAbandoned (it
  took an abandoned mutex, which it owns now) or an error. }
function WaitForObject(Handle: Int64; Timeout: Int64): LongInt;

{ Create or open by name. }
function CreateNamedEvent(const Path: string; ManualReset, Signaled: Boolean; out Created: Boolean): Int64;
function CreateNamedSemaphore(const Path: string; InitialCount, Limit: LongInt; out Created: Boolean): Int64;
function CreateNamedMutex(const Path: string; out Created: Boolean): Int64;
function CreateNamedSection(const Path: string; Length: QWord; out Created: Boolean): Int64;

{ The text of an entry's mode, as ls shows a file's: drwxrwxrwt. }
function ObjectModeText(const Entry: TObjectEntry): string;

implementation

uses
  Sys.Errors,
  Sys.Objects;

const
  ListBatch = 32;
  { How often create-or-open tries again when the name it found went
    away before it could open it. }
  CreateOrOpenAttempts = 8;

function CallError(CallResult: Int64): LongInt;
begin
  Result := ErrorCodeOf(CallResult);
end;

function CreateObjectDirectory(const Path: string; Mode: LongWord): LongInt;
begin
  Result := CallError(SystemCall(CallCreateObjectDirectory, QWord(PChar(Path)), Mode, 0, 0, 0, 0));
end;

function NameObject(Handle: Int64; const Path: string; Mode: LongWord): LongInt;
begin
  Result := CallError(SystemCall(CallNameObject, QWord(Handle), QWord(PChar(Path)), Mode, 0, 0, 0));
end;

function OpenNamedObject(const Path: string; Kind: LongWord): Int64;
begin
  Result := SystemCall(CallOpenNamedObject, QWord(PChar(Path)), Kind, 0, 0, 0, 0);
end;

function EntryOf(const Raw: TAbiObjectDirectoryEntry): TObjectEntry;
begin
  Result.Name := PChar(@Raw.Name[0]);
  Result.TypeName := PChar(@Raw.TypeName[0]);
  Result.Kind := Raw.Kind;
  Result.IsDirectory := (Raw.Flags and ObjectEntryDirectory) <> 0;
  Result.IsPermanent := (Raw.Flags and ObjectEntryPermanent) <> 0;
  Result.OwnerId := Raw.OwnerId;
  Result.GroupId := Raw.GroupId;
  Result.Mode := Raw.Mode;
  Result.EntryCount := Raw.EntryCount;
  Result.ReferenceCount := Raw.ReferenceCount;
end;

function ListObjectDirectory(const Path: string; out Entries: TObjectEntryArray): LongInt;
var
  Batch: array[0..ListBatch - 1] of TAbiObjectDirectoryEntry;
  Total: Int64;
  Got: Int64;
  Index: Int64;
begin
  Entries := nil;
  repeat
    Total := SystemCall(CallListObjectDirectory, QWord(PChar(Path)), QWord(@Batch[0]), ListBatch,
      QWord(Length(Entries)), 0, 0);
    if Total < 0 then
      Exit(CallError(Total));
    Got := Total - Length(Entries);
    if Got > ListBatch then
      Got := ListBatch;
    { Entries removed meanwhile: what is there is all. }
    if Got <= 0 then
      Break;
    for Index := 0 to Got - 1 do
    begin
      SetLength(Entries, Length(Entries) + 1);
      Entries[High(Entries)] := EntryOf(Batch[Index]);
    end;
  until Length(Entries) >= Total;
  Result := ErrorNone;
end;

function RemoveObjectName(const Path: string): LongInt;
begin
  Result := CallError(SystemCall(CallRemoveObjectName, QWord(PChar(Path)), 0, 0, 0, 0, 0));
end;

function SetObjectSecurity(const Path: string; Mode, OwnerId, GroupId: Int64): LongInt;
begin
  Result := CallError(SystemCall(CallSetObjectSecurity, QWord(PChar(Path)), QWord(Mode), QWord(OwnerId),
    QWord(GroupId), 0, 0));
end;

function CreateMutex(InitiallyOwned: Boolean): Int64;
var
  Flags: QWord;
begin
  Flags := 0;
  if InitiallyOwned then
    Flags := MutexInitiallyOwned;
  Result := SystemCall(CallCreateMutex, Flags, 0, 0, 0, 0, 0);
end;

function ReleaseMutex(Handle: Int64; out RemainingHolds: LongInt): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallReleaseMutex, QWord(Handle), 0, 0, 0, 0, 0);
  RemainingHolds := 0;
  if CallResult >= 0 then
    RemainingHolds := LongInt(CallResult);
  Result := CallError(CallResult);
end;

function WaitForObject(Handle: Int64; Timeout: Int64): LongInt;
var
  CallResult: Int64;
begin
  CallResult := WaitForHandles([Handle], Timeout);
  if CallResult < 0 then
    Exit(CallError(CallResult));
  if (CallResult and WaitAbandoned) <> 0 then
    Exit(MutexAbandoned);
  Result := ErrorNone;
end;

{ Names NewHandle Path, or if the name is taken opens what has it
  (closing NewHandle). }
function NameOrOpen(const Path: string; Kind: LongWord; NewHandle: Int64; out Created: Boolean): Int64;
var
  Error: LongInt;
  Attempt: LongInt;
begin
  Created := False;
  if NewHandle < 0 then
    Exit(NewHandle);
  for Attempt := 1 to CreateOrOpenAttempts do
  begin
    Error := NameObject(NewHandle, Path, DefaultObjectMode);
    if Error = ErrorNone then
    begin
      Created := True;
      Exit(NewHandle);
    end;
    if Error <> ErrorExists then
      Break;
    Result := OpenNamedObject(Path, Kind);
    { Gone between the two calls: name ours after all. }
    if Result <> -ErrorNotFound then
    begin
      CloseHandle(NewHandle);
      Exit;
    end;
  end;
  CloseHandle(NewHandle);
  if Error = ErrorNone then
    Error := ErrorBusy;
  Result := -Int64(Error);
end;

function CreateNamedEvent(const Path: string; ManualReset, Signaled: Boolean; out Created: Boolean): Int64;
begin
  Result := NameOrOpen(Path, HandleKindEvent, CreateEvent(ManualReset, Signaled), Created);
end;

function CreateNamedSemaphore(const Path: string; InitialCount, Limit: LongInt; out Created: Boolean): Int64;
begin
  Result := NameOrOpen(Path, HandleKindSemaphore, CreateSemaphore(InitialCount, Limit), Created);
end;

function CreateNamedMutex(const Path: string; out Created: Boolean): Int64;
begin
  Result := NameOrOpen(Path, HandleKindMutex, CreateMutex(False), Created);
end;

function CreateNamedSection(const Path: string; Length: QWord; out Created: Boolean): Int64;
begin
  Result := NameOrOpen(Path, HandleKindSection, CreateSection(Length), Created);
end;

function ObjectModeText(const Entry: TObjectEntry): string;
const
  Letters: array[0..2] of Char = ('r', 'w', 'x');
var
  Bit: LongInt;
begin
  if Entry.IsDirectory then
    Result := 'd'
  else
    Result := '-';
  for Bit := 8 downto 0 do
    if (Entry.Mode and (LongWord(1) shl Bit)) <> 0 then
      Result := Result + Letters[(8 - Bit) mod 3]
    else
      Result := Result + '-';
  if (Entry.Mode and ObjectModeSticky) <> 0 then
  begin
    if Result[10] = 'x' then
      Result[10] := 't'
    else
      Result[10] := 'T';
  end;
end;

end.
