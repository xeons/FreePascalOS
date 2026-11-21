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
  Extracting a whole archive into a folder. Members whose names are not
  safe (SafeEntryPath) are left out. Symbolic links are made last, after
  every file, so that no member is written through a link another
  member made; folder times are set last, after their contents.
}
unit Archive.Extraction;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Archive.Entries,
  Archive.Readers;

type
  { Called before each member is extracted to TargetPath; setting Skip
    leaves it out. }
  TArchiveEntryEvent = procedure(const Entry: TArchiveEntry; const TargetPath: string; var Skip: Boolean) of object;

{ Extracts every member of Reader under DestinationFolder (created if
  needed), creating folders, setting times and modes where it can.
  Returns how many members were left out because their names were not
  safe. Raises EArchiveError on the first member that fails, and
  EArchiveCancelled when OnProgress asks to stop. }
function ExtractAll(Reader: TArchiveReader; const DestinationFolder: string;
  OnProgress: TArchiveProgressEvent = nil; OnEntry: TArchiveEntryEvent = nil): Integer;

implementation

uses
  Archive.FileSystem,
  Archive.Progress;

type
  TPendingPath = record
    Index: Integer;
    Path: string;
  end;

function ExtractAll(Reader: TArchiveReader; const DestinationFolder: string;
  OnProgress: TArchiveProgressEvent; OnEntry: TArchiveEntryEvent): Integer;
var
  Base, Relative, Target, Parent: string;
  Index, PendingIndex: Integer;
  Entry: TArchiveEntry;
  Skip: Boolean;
  Progress: TProgressCounter;
  Folders, Links: array of TPendingPath;
  FolderCount, LinkCount: Integer;

  procedure Remember(var List: array of TPendingPath; var ListCount: Integer);
  begin
    List[ListCount].Index := Index;
    List[ListCount].Path := Target;
    Inc(ListCount);
  end;

begin
  Result := 0;
  Base := ExcludeTrailingPathDelimiter(DestinationFolder);
  if (Base <> '') and not DirectoryExists(Base) and not ForceDirectories(Base) then
    raise EArchiveError.CreateFmt('Cannot create the folder %s', [Base]);
  Folders := nil;
  Links := nil;
  SetLength(Folders, Reader.Count);
  SetLength(Links, Reader.Count);
  FolderCount := 0;
  LinkCount := 0;
  Progress := TProgressCounter.Create(OnProgress);
  try
    for Index := 0 to Reader.Count - 1 do
    begin
      Entry := Reader.Entries[Index];
      Relative := SafeEntryPath(Entry.Name);
      if Relative = '' then
      begin
        Inc(Result);
        Continue;
      end;
      Target := Base + '/' + Relative;
      Skip := False;
      if Assigned(OnEntry) then
        OnEntry(Entry, Target, Skip);
      if Skip then
        Continue;
      if Entry.IsFolder then
      begin
        if not DirectoryExists(Target) and not ForceDirectories(Target) then
          raise EArchiveError.CreateFmt('Cannot create the folder %s', [Target]);
        Remember(Folders, FolderCount);
      end
      else if Entry.IsLink then
        Remember(Links, LinkCount)
      else
        Reader.ExtractToFileCounted(Index, Target, Progress);
    end;

    for PendingIndex := 0 to LinkCount - 1 do
    begin
      Target := Links[PendingIndex].Path;
      Entry := Reader.Entries[Links[PendingIndex].Index];
      if PathIsTaken(Target) or (Entry.LinkTarget = '') then
        Continue;
      Parent := ExtractFileDir(Target);
      if (Parent <> '') and not DirectoryExists(Parent) then
        ForceDirectories(Parent);
      { A system without symbolic links leaves them out. }
      CreateSymbolicLink(Entry.LinkTarget, Target);
    end;

    for PendingIndex := FolderCount - 1 downto 0 do
    begin
      Entry := Reader.Entries[Folders[PendingIndex].Index];
      if Entry.Mode <> 0 then
        SetPathMode(Folders[PendingIndex].Path, Entry.Mode or $1C0);
      SetPathModificationTime(Folders[PendingIndex].Path, Entry.ModificationTime);
    end;
  finally
    Progress.Free;
  end;
end;

end.
