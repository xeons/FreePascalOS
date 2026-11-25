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
  Reading archives whatever their format: TArchiveReader, the list of
  members and their extraction, which TZipReader and TTarReader
  implement, and OpenArchive, which tells the format by the content.
}
unit Archive.Readers;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Archive.Entries,
  Archive.Progress;

type
  TArchiveFormat = (ArchiveUnknown, ArchiveZip, ArchiveTar, ArchiveTarGzip, ArchiveTarZstd, ArchiveTarXz);

  TArchiveReader = class
  private
    FEntries: TArchiveEntryArray;
    FCount: Integer;
    function GetEntry(Index: Integer): TArchiveEntry;
  protected
    FFormat: TArchiveFormat;
    procedure AddEntry(const Entry: TArchiveEntry);
    procedure SetEntryLinkTarget(Index: Integer; const Target: string);
    procedure CheckIndex(Index: Integer);
    { Writes the member's data (for a symbolic link: its target) to
      Destination, checked, counting the bytes on Progress. }
    procedure WriteEntryData(Index: Integer; Destination: TStream; Progress: TProgressCounter); virtual; abstract;
  public
    { The member named Name; a folder is found with or without its final
      '/'. -1 if there is none. }
    function IndexOf(const Name: string): Integer;
    procedure ExtractToStream(Index: Integer; Destination: TStream; OnProgress: TArchiveProgressEvent = nil);
    { Creates Path: a folder (and its parents), a symbolic link, or a
      file with the member's data (a partly written file is deleted on
      failure); then sets its time and mode where it can. }
    procedure ExtractToFile(Index: Integer; const Path: string; OnProgress: TArchiveProgressEvent = nil);
    { The same, counting on a counter shared by several extractions. }
    procedure ExtractToStreamCounted(Index: Integer; Destination: TStream; Progress: TProgressCounter);
    procedure ExtractToFileCounted(Index: Integer; const Path: string; Progress: TProgressCounter);
    property Count: Integer read FCount;
    property Entries[Index: Integer]: TArchiveEntry read GetEntry; default;
    property Format: TArchiveFormat read FFormat;
  end;

{ The format by the content: zip by its end of central directory record
  (or a local header at the start), tar.gz and tar.zst by the gzip or
  Zstandard magic with a tar header in it, tar.xz by the xz magic (and
  the size its index gives), tar by "ustar" or a right header checksum. }
function DetectArchiveFormat(const FileName: string): TArchiveFormat;
function DetectArchiveFormat(Stream: TStream): TArchiveFormat;
function IsArchiveFile(const FileName: string): Boolean;
{ A reader of the archive; EArchiveError if it is not one this library
  reads (or cannot be opened). }
function OpenArchive(const FileName: string): TArchiveReader;

implementation

uses
  Archive.FileSystem,
  Archive.Detection,
  Archive.ZipReader,
  Archive.TarReader;

function TArchiveReader.GetEntry(Index: Integer): TArchiveEntry;
begin
  CheckIndex(Index);
  Result := FEntries[Index];
end;

procedure TArchiveReader.AddEntry(const Entry: TArchiveEntry);
begin
  if FCount >= Length(FEntries) then
    SetLength(FEntries, 2 * FCount + 16);
  FEntries[FCount] := Entry;
  Inc(FCount);
end;

procedure TArchiveReader.SetEntryLinkTarget(Index: Integer; const Target: string);
begin
  CheckIndex(Index);
  FEntries[Index].LinkTarget := Target;
end;

procedure TArchiveReader.CheckIndex(Index: Integer);
begin
  if (Index < 0) or (Index >= FCount) then
    raise EArchiveError.CreateFmt('No archive member %d', [Index]);
end;

function TArchiveReader.IndexOf(const Name: string): Integer;
var
  Index: Integer;
  AsFolder: string;
begin
  if NameIsFolder(Name) then
    AsFolder := Name
  else
    AsFolder := Name + '/';
  for Index := 0 to FCount - 1 do
    if (FEntries[Index].Name = Name) or (FEntries[Index].IsFolder and (FEntries[Index].Name = AsFolder)) then
      Exit(Index);
  Result := -1;
end;

procedure TArchiveReader.ExtractToStreamCounted(Index: Integer; Destination: TStream; Progress: TProgressCounter);
begin
  CheckIndex(Index);
  if FEntries[Index].IsFolder then
    Exit;
  WriteEntryData(Index, Destination, Progress);
end;

procedure TArchiveReader.ExtractToStream(Index: Integer; Destination: TStream; OnProgress: TArchiveProgressEvent);
var
  Progress: TProgressCounter;
begin
  Progress := TProgressCounter.Create(OnProgress);
  try
    ExtractToStreamCounted(Index, Destination, Progress);
  finally
    Progress.Free;
  end;
end;

procedure TArchiveReader.ExtractToFileCounted(Index: Integer; const Path: string; Progress: TProgressCounter);
var
  Entry: TArchiveEntry;
  Output: TFileStream;
  Parent: string;
begin
  CheckIndex(Index);
  Entry := FEntries[Index];
  if Entry.IsFolder then
  begin
    if not ForceDirectories(Path) then
      raise EArchiveError.CreateFmt('Cannot create the folder %s', [Path]);
  end
  else
  begin
    Parent := ExtractFileDir(Path);
    if (Parent <> '') and not DirectoryExists(Parent) and not ForceDirectories(Parent) then
      raise EArchiveError.CreateFmt('Cannot create the folder %s', [Parent]);
    if Entry.IsLink then
    begin
      if not CreateSymbolicLink(Entry.LinkTarget, Path) then
        raise EArchiveError.CreateFmt('Cannot create the link %s', [Path]);
      Exit;
    end;
    try
      Output := TFileStream.Create(Path, fmCreate);
    except
      on Error: Exception do
        raise EArchiveError.CreateFmt('Cannot create %s: %s', [Path, Error.Message]);
    end;
    try
      try
        WriteEntryData(Index, Output, Progress);
      finally
        Output.Free;
      end;
    except
      DeleteFile(Path);
      raise;
    end;
  end;
  if Entry.Mode <> 0 then
    SetPathMode(Path, Entry.Mode);
  SetPathModificationTime(Path, Entry.ModificationTime);
end;

procedure TArchiveReader.ExtractToFile(Index: Integer; const Path: string; OnProgress: TArchiveProgressEvent);
var
  Progress: TProgressCounter;
begin
  Progress := TProgressCounter.Create(OnProgress);
  try
    ExtractToFileCounted(Index, Path, Progress);
  finally
    Progress.Free;
  end;
end;

function DetectArchiveFormat(Stream: TStream): TArchiveFormat;
begin
  Result := Archive.Detection.DetectFormat(Stream);
end;

function DetectArchiveFormat(const FileName: string): TArchiveFormat;
var
  Stream: TFileStream;
begin
  Result := ArchiveUnknown;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  except
    Exit;
  end;
  try
    try
      Result := DetectArchiveFormat(Stream);
    except
      Result := ArchiveUnknown;
    end;
  finally
    Stream.Free;
  end;
end;

function IsArchiveFile(const FileName: string): Boolean;
begin
  Result := DetectArchiveFormat(FileName) <> ArchiveUnknown;
end;

function OpenArchive(const FileName: string): TArchiveReader;
var
  Format: TArchiveFormat;
begin
  Format := DetectArchiveFormat(FileName);
  case Format of
    ArchiveZip: Result := TZipReader.Create(FileName);
    ArchiveTar, ArchiveTarGzip, ArchiveTarZstd, ArchiveTarXz:
      Result := TTarReader.Create(FileName, Format);
  else
    if not FileExists(FileName) then
      raise EArchiveError.CreateFmt('Cannot open %s', [FileName]);
    raise EArchiveError.CreateFmt('%s is not an archive this system reads', [ExtractFileName(FileName)]);
  end;
end;

end.
