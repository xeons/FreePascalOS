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
  Mounting what the mount table (/etc/fstab, Sys.MountTable) says: the
  service manager does it at start, "mount -a" on request, and coretest
  (which runs as the first program) before its checks.

  A LABEL= source is looked up among the volumes; an entry whose target
  already has a volume mounted on it is left alone, so mounting all
  twice does no harm; entries marked noauto are skipped. Every entry
  tried gives a line saying what happened.
}
unit Sys.MountAll;

{$mode objfpc}
{$H+}

interface

uses
  Sys.MountTable;

type
  TMountMessages = array of string;

{ Reads a whole (small) text file; False if it cannot be read. }
function ReadMountTableText(const Path: string; out Text: string): Boolean;
{ Mounts one entry: ErrorNone, or an Abi error code. }
function MountTableEntry(const Entry: TMountTableEntry): LongInt;
{ The /volumes path of the volume labelled VolumeLabel. }
function FindLabelledVolume(const VolumeLabel: string; out Source: string): Boolean;
{ True if a volume is mounted on the directory Target. }
function IsMountedAt(const Target: string): Boolean;
{ Mounts every entry of the table at Path (not noauto ones); returns
  how many failed (nofail entries whose source is missing do not
  count). Messages say what happened to each, and the table's problems. }
function MountAllFromTable(const Path: string; out Messages: TMountMessages): Integer;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Mounts,
  Sys.Volumes;

const
  LabelPrefix = 'LABEL=';

procedure AddMessage(var Messages: TMountMessages; const Message: string);
begin
  SetLength(Messages, Length(Messages) + 1);
  Messages[High(Messages)] := Message;
end;

function ReadMountTableText(const Path: string; out Text: string): Boolean;
var
  Handle: Int64;
  Buffer: array[0..4095] of Char;
  Count: Int64;
  Previous: Integer;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(False);
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count > 0 then
    begin
      Previous := Length(Text);
      SetLength(Text, Previous + Count);
      Move(Buffer[0], Text[Previous + 1], Count);
    end;
  until Count <= 0;
  CloseFile(Handle);
  Result := Count = 0;
end;

{ /volumes/NAME of the volume labelled VolumeLabel, or ''. }
function VolumeWithLabel(const VolumeLabel: string): string;
var
  Index: Integer;
  Description: TVolumeDescription;
begin
  Result := '';
  Index := 0;
  while GetVolumeDescription(Index, Description) do
  begin
    if string(PChar(@Description.VolumeLabel[0])) = VolumeLabel then
      Exit(VolumesFolder + '/' + string(PChar(@Description.Name[0])));
    Inc(Index);
  end;
end;

function FindLabelledVolume(const VolumeLabel: string; out Source: string): Boolean;
begin
  Source := VolumeWithLabel(VolumeLabel);
  Result := Source <> '';
end;

function IsMountedAt(const Target: string): Boolean;
var
  Index: Integer;
  Description: TMountDescription;
begin
  Index := 0;
  while GetMountDescription(Index, Description) do
  begin
    if Description.IsAtDirectory and (Description.MountPoint = Target) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function MountTableEntry(const Entry: TMountTableEntry): LongInt;
var
  Source: string;
  FileSystemType: string;
begin
  Source := Entry.Source;
  if Copy(Source, 1, Length(LabelPrefix)) = LabelPrefix then
  begin
    Source := VolumeWithLabel(Copy(Source, Length(LabelPrefix) + 1, Length(Source)));
    if Source = '' then
      Exit(ErrorNotFound);
  end;
  FileSystemType := Entry.FileSystemType;
  if FileSystemType = 'auto' then
    FileSystemType := '';
  if Entry.Target = 'none' then
    Result := MountVolume(Source, '', FileSystemType, Entry.Options)
  else
    Result := MountVolume(Source, Entry.Target, FileSystemType, Entry.Options);
end;

function LineText(Value: Integer): string;
begin
  Str(Value, Result);
end;

function MountAllFromTable(const Path: string; out Messages: TMountMessages): Integer;
var
  Text: string;
  Entries: TMountTableEntries;
  Problems: TMountTableProblems;
  Entry: TMountTableEntry;
  Problem: string;
  Error: LongInt;
begin
  Messages := nil;
  Result := 0;
  if not ReadMountTableText(Path, Text) then
    Exit;
  ParseMountTable(Text, Entries, Problems);
  for Problem in Problems do
    AddMessage(Messages, Path + ': ' + Problem);
  for Entry in Entries do
  begin
    if Entry.NoAuto then
      Continue;
    if (Entry.Target <> 'none') and IsMountedAt(Entry.Target) then
    begin
      AddMessage(Messages, Entry.Target + ': already mounted');
      Continue;
    end;
    Error := MountTableEntry(Entry);
    if Error = ErrorNone then
      AddMessage(Messages, 'mounted ' + Entry.Source + ' at ' + Entry.Target)
    else
    begin
      AddMessage(Messages, Path + ': line ' + LineText(Entry.LineNumber) + ': cannot mount ' + Entry.Source +
        ' at ' + Entry.Target + ': ' + string(ErrorMessage(Error)));
      if not (Entry.NoFail and (Error = ErrorNotFound)) then
        Inc(Result);
    end;
  end;
end;

end.
