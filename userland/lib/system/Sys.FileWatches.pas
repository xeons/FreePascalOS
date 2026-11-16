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
  Watching files and folders for changes.

  WatchPath gives a handle that is ready (WaitForHandles, or a window
  program's handle watches) whenever changes wait in it, made by any
  program: names created, removed or renamed, files written, attributes
  changed - with WatchSubtree also in every folder below. A watch on
  "/volumes" reports volumes arriving and going away (Sys.Volumes).

  Reading takes the waiting changes into a TFileChangeReader, and
  NextFileChange hands them out one by one:

    Watch := WatchPath('/home/user', WatchNames);
    ...
    if ReadFileChanges(Reader, Watch) = ErrorNone then
      while NextFileChange(Reader, Change) do
        ...Change.Kind, Change.Name...

  Names are relative to the watched folder; a change to the watched item
  itself has an empty name. A watch keeps at most
  MaximumQueuedWatchRecords changes; when more came than were read, the
  last one is FileChangeOverflow, and the folder should be looked at
  again. Changes of the kinds FileChangeWatchedItemRemoved and
  FileChangeVolumeGone end the watch.

  The watch is closed with CloseHandle (Sys.Objects).
}
unit Sys.FileWatches;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  FileChangeCreated = WatchChangeCreated;
  FileChangeRemoved = WatchChangeRemoved;
  FileChangeRenamed = WatchChangeRenamed;
  FileChangeWritten = WatchChangeWritten;
  FileChangeAttributes = WatchChangeAttributes;
  FileChangeWatchedItemRemoved = WatchChangeWatchedItemRemoved;
  FileChangeWatchedItemMoved = WatchChangeWatchedItemMoved;
  FileChangeVolumeGone = WatchChangeVolumeGone;
  FileChangeOverflow = WatchChangeOverflow;

  { Room for a full read: the most a watch hands out at once. }
  FileChangeBufferSize = 8192;

type
  TFileChange = record
    { FileChange*. }
    Kind: LongWord;
    IsDirectory: Boolean;
    { Point into the reader's buffer: valid until the next read. }
    Name: PChar;
    { Renames: the name before. nil otherwise. }
    OldName: PChar;
  end;

  TFileChangeReader = record
    Buffer: array[0..FileChangeBufferSize - 1] of Byte;
    Length: QWord;
    Position: QWord;
  end;

{ A watch on Path (Flags: WatchNames, WatchContents, WatchAttributes,
  WatchSubtree), or minus an error code. }
function WatchPath(Path: PChar; Flags: LongWord): Int64;

{ Takes the changes waiting in Watch into Reader. Does not wait:
  ErrorWouldBlock if there are none. }
function ReadFileChanges(var Reader: TFileChangeReader; Watch: Int64): LongInt;
{ The next change read; False when every one was handed out. }
function NextFileChange(var Reader: TFileChangeReader; out Change: TFileChange): Boolean;

{ "created", "removed", ... }
function FileChangeKindText(Kind: LongWord): PChar;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function WatchPath(Path: PChar; Flags: LongWord): Int64;
begin
  Result := KernelCreateWatch(Path, Flags);
end;

function ReadFileChanges(var Reader: TFileChangeReader; Watch: Int64): LongInt;
var
  CallResult: Int64;
begin
  Reader.Length := 0;
  Reader.Position := 0;
  CallResult := KernelReadWatch(Watch, @Reader.Buffer[0], SizeOf(Reader.Buffer));
  if CallResult < 0 then
    Exit(ErrorCodeOf(CallResult));
  Reader.Length := QWord(CallResult);
  Result := ErrorNone;
end;

function NextFileChange(var Reader: TFileChangeReader; out Change: TFileChange): Boolean;
var
  ChangeRecord: PAbiWatchRecord;
  Names: PChar;
begin
  Change.Kind := 0;
  Change.IsDirectory := False;
  Change.Name := nil;
  Change.OldName := nil;
  if Reader.Position + SizeOf(TAbiWatchRecord) > Reader.Length then
    Exit(False);
  ChangeRecord := PAbiWatchRecord(@Reader.Buffer[Reader.Position]);
  if (ChangeRecord^.Size < SizeOf(TAbiWatchRecord)) or (Reader.Position + ChangeRecord^.Size > Reader.Length) then
    Exit(False);
  Names := PChar(ChangeRecord) + SizeOf(TAbiWatchRecord);
  Change.Kind := ChangeRecord^.Kind;
  Change.IsDirectory := (ChangeRecord^.Flags and WatchRecordDirectory) <> 0;
  Change.Name := Names;
  if ChangeRecord^.Kind = WatchChangeRenamed then
    Change.OldName := Names + ChangeRecord^.NameLength + 1;
  Reader.Position := Reader.Position + ChangeRecord^.Size;
  Result := True;
end;

function FileChangeKindText(Kind: LongWord): PChar;
begin
  case Kind of
    FileChangeCreated: Result := 'created';
    FileChangeRemoved: Result := 'removed';
    FileChangeRenamed: Result := 'renamed';
    FileChangeWritten: Result := 'written';
    FileChangeAttributes: Result := 'attributes';
    FileChangeWatchedItemRemoved: Result := 'watched item removed';
    FileChangeWatchedItemMoved: Result := 'watched item moved';
    FileChangeVolumeGone: Result := 'volume gone';
    FileChangeOverflow: Result := 'overflow';
  else
    Result := 'unknown';
  end;
end;

end.
