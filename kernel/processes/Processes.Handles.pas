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
  Per-process handle tables.

  User programs refer to kernel objects (open files, the console, pipe
  ends, other processes) through handles: small integers that index the
  process's handle table. Handles 0, 1 and 2 are standard input, output
  and error by convention. A table entry holds a reference to its object,
  which is dropped when the handle is closed.
}
unit Processes.Handles;

{$mode objfpc}

interface

const
  MaximumHandles = 64;

type
  THandleKind = (
    HandleKindFree,
    HandleKindFile,
    { An open device (Io.Manager), the console included, or /dev. }
    HandleKindDevice,
    HandleKindPipeReadEnd,
    HandleKindPipeWriteEnd,
    HandleKindProcess,
    { A thread of the same process (see Processes.ThreadCalls). }
    HandleKindThread,
    { Objects for programs that work together (Processes.ObjectCalls). }
    HandleKindEvent,
    HandleKindTimer,
    HandleKindSection,
    HandleKindPort,
    HandleKindChannel,
    { A watch on a folder or file (Processes.WatchCalls). }
    HandleKindWatch
  );

  THandleEntry = record
    Kind: THandleKind;
    ObjectBody: Pointer;
  end;

  THandleTable = record
    Entries: array[0..MaximumHandles - 1] of THandleEntry;
  end;
  PHandleTable = ^THandleTable;

procedure InitializeHandleTable(out Table: THandleTable);

{ Stores ObjectBody (taking a new reference) in the lowest free slot at or
  above FirstSlot. Returns the handle, or -1 if the table is full. }
function InsertHandle(var Table: THandleTable; Kind: THandleKind; ObjectBody: Pointer;
  FirstSlot: Integer): Integer;

{ Stores into a specific slot, closing what was there before. }
procedure SetHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer);

function LookupHandle(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;

function CloseHandle(var Table: THandleTable; Handle: Int64): Boolean;
procedure CloseAllHandles(var Table: THandleTable);

{ What a handle holds on its object, taken and given back outside a
  handle table: by a message carrying the handle (Processes.Channels). A
  reference, and for pipe ends an open end. }
procedure TakeHandleReference(Kind: THandleKind; ObjectBody: Pointer);
procedure DropHandleReference(Kind: THandleKind; ObjectBody: Pointer);

implementation

uses
  Objects.Manager,
  Io.Pipes;

procedure InitializeHandleTable(out Table: THandleTable);
var
  Index: Integer;
begin
  for Index := 0 to MaximumHandles - 1 do
  begin
    Table.Entries[Index].Kind := HandleKindFree;
    Table.Entries[Index].ObjectBody := nil;
  end;
end;

{ Pipes count their open ends separately from object references, so
  readers can see end of file once every writer is gone. }
procedure NoteHandleOpened(Kind: THandleKind; ObjectBody: Pointer);
begin
  case Kind of
    HandleKindPipeReadEnd: OpenPipeEnd(PPipe(ObjectBody), False);
    HandleKindPipeWriteEnd: OpenPipeEnd(PPipe(ObjectBody), True);
  end;
end;

procedure NoteHandleClosed(Kind: THandleKind; ObjectBody: Pointer);
begin
  case Kind of
    HandleKindPipeReadEnd: ClosePipeEnd(PPipe(ObjectBody), False);
    HandleKindPipeWriteEnd: ClosePipeEnd(PPipe(ObjectBody), True);
  end;
end;

procedure TakeHandleReference(Kind: THandleKind; ObjectBody: Pointer);
begin
  ReferenceObject(ObjectBody);
  NoteHandleOpened(Kind, ObjectBody);
end;

procedure DropHandleReference(Kind: THandleKind; ObjectBody: Pointer);
begin
  NoteHandleClosed(Kind, ObjectBody);
  DereferenceObject(ObjectBody);
end;

function InsertHandle(var Table: THandleTable; Kind: THandleKind; ObjectBody: Pointer;
  FirstSlot: Integer): Integer;
var
  Index: Integer;
begin
  for Index := FirstSlot to MaximumHandles - 1 do
  begin
    if Table.Entries[Index].Kind = HandleKindFree then
    begin
      ReferenceObject(ObjectBody);
      NoteHandleOpened(Kind, ObjectBody);
      Table.Entries[Index].Kind := Kind;
      Table.Entries[Index].ObjectBody := ObjectBody;
      Exit(Index);
    end;
  end;
  Result := -1;
end;

procedure SetHandle(var Table: THandleTable; Handle: Integer; Kind: THandleKind; ObjectBody: Pointer);
begin
  if (Handle < 0) or (Handle >= MaximumHandles) then
    Exit;
  CloseHandle(Table, Handle);
  ReferenceObject(ObjectBody);
  NoteHandleOpened(Kind, ObjectBody);
  Table.Entries[Handle].Kind := Kind;
  Table.Entries[Handle].ObjectBody := ObjectBody;
end;

function LookupHandle(var Table: THandleTable; Handle: Int64; out Kind: THandleKind;
  out ObjectBody: Pointer): Boolean;
begin
  Kind := HandleKindFree;
  ObjectBody := nil;
  if (Handle < 0) or (Handle >= MaximumHandles) then
    Exit(False);
  Kind := Table.Entries[Handle].Kind;
  ObjectBody := Table.Entries[Handle].ObjectBody;
  Result := Kind <> HandleKindFree;
end;

function CloseHandle(var Table: THandleTable; Handle: Int64): Boolean;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if not LookupHandle(Table, Handle, Kind, ObjectBody) then
    Exit(False);
  Table.Entries[Handle].Kind := HandleKindFree;
  Table.Entries[Handle].ObjectBody := nil;
  NoteHandleClosed(Kind, ObjectBody);
  DereferenceObject(ObjectBody);
  Result := True;
end;

procedure CloseAllHandles(var Table: THandleTable);
var
  Index: Integer;
begin
  for Index := 0 to MaximumHandles - 1 do
    CloseHandle(Table, Index);
end;

end.
