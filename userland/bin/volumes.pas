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
  volumes - list the volumes, and watch them come and go

  volumes [-w] [-n COUNT] [-t MILLISECONDS]

  Lists every mounted volume: its name, label, file system, size, free
  space, where it is mounted, and whether it is the system volume,
  read-only or removable. With -w it then waits and prints each volume
  that arrives (a USB disk plugged in) or goes away:

    arrived: disk7p1 fat32 "FAT32TEST" 64M at /volumes/disk7p1
    removed: disk7p1

  ending after COUNT of them (-n) or MILLISECONDS without one (-t:
  status 2 if none came at all).
}
program volumes;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.FileWatches,
  Sys.Format,
  Sys.Objects,
  Sys.Streams,
  Sys.Text,
  Sys.Volumes,
  Util.Messages,
  Util.Options,
  Util.Sizes;

const
  Usage: PChar = 'Usage: volumes [OPTION]...'#10 +
    'List the mounted volumes.'#10 +
    #10 +
    '  -w, --wait             then print volumes arriving and going away'#10 +
    '  -n, --count=COUNT      end after COUNT of them'#10 +
    '  -t, --timeout=MS       end after MS milliseconds without one'#10;

  OptionWait = 1;
  OptionCount = 2;
  OptionTimeout = 3;

  ExitNothingCame = 2;

procedure ParseNumberOption(Value: PChar; out Number: QWord);
begin
  if not ParseUnsigned(Value, Number) then
    FailWithUsageHint('invalid number: ''%s''', [ArgumentText(Value)]);
end;

procedure PrintText(const Text: string);
begin
  WriteText(StandardOutput, PChar(Text));
end;

function HumanSize(Size: QWord): string;
var
  Buffer: array[0..31] of Char;
begin
  Result := FormatHumanSize(Size, @Buffer[0]);
end;

function FlagsText(const Volume: TVolumeDescription): string;
begin
  Result := '';
  if Volume.IsSystemVolume then
    Result := Result + ' system';
  if Volume.IsReadOnly then
    Result := Result + ' read-only';
  if Volume.IsRemovable then
    Result := Result + ' removable';
end;

procedure WriteVolume(const Volume: TVolumeDescription);
var
  FreeText: string;
begin
  if Volume.HasFreeSpace then
    FreeText := HumanSize(Volume.FreeBytes)
  else
    FreeText := '-';
  PrintText(Format('%-10s %-12s %-6s %6s %6s %s', [string(PChar(@Volume.Name[0])),
    string(PChar(@Volume.VolumeLabel[0])), string(PChar(@Volume.FileSystemType[0])),
    HumanSize(Volume.TotalBytes), FreeText, string(PChar(@Volume.MountPoint[0]))]) +
    FlagsText(Volume) + #10);
end;

procedure ListVolumes;
var
  Volume: TVolumeDescription;
  Index: Integer;
begin
  WriteLine(StandardOutput, 'Name       Label        Type     Size   Free Mounted on');
  Index := 0;
  while GetVolumeDescription(Index, Volume) do
  begin
    WriteVolume(Volume);
    Inc(Index);
  end;
end;

procedure WriteArrival(const Name: string);
var
  Volume: TVolumeDescription;
  Line: string;
begin
  Line := 'arrived: ' + Name;
  if FindVolumeDescription(PChar(Name), Volume) then
    Line := Line + Format(' %s "%s" %s at %s', [string(PChar(@Volume.FileSystemType[0])),
      string(PChar(@Volume.VolumeLabel[0])), HumanSize(Volume.TotalBytes),
      string(PChar(@Volume.MountPoint[0]))]);
  PrintText(Line + #10);
end;

{ Prints volumes arriving and going away; returns how many. }
function WatchArrivals(Wanted: QWord; Timeout: Int64): QWord;
var
  Watch: Int64;
  Reader: TFileChangeReader;
  Change: TFileChange;
begin
  Result := 0;
  Watch := WatchVolumes;
  if Watch < 0 then
    FailWithError(1, ErrorCodeOf(Watch), '%s', [ArgumentText(VolumesFolder)]);
  { Said once the watch is in place, so a test can plug a disk in. }
  WriteLine(StandardOutput, 'waiting for volumes');
  FlushStream(StandardOutput);
  while (Wanted = 0) or (Result < Wanted) do
  begin
    if WaitForHandle(Watch, Timeout) <> ErrorNone then
      Break;
    if ReadFileChanges(Reader, Watch) <> ErrorNone then
      Continue;
    while NextFileChange(Reader, Change) do
    begin
      case Change.Kind of
        FileChangeCreated: WriteArrival(Change.Name);
        FileChangeRemoved: PrintText('removed: ' + string(Change.Name) + #10);
      else
        PrintText(string(FileChangeKindText(Change.Kind)) + #10);
      end;
      FlushStream(StandardOutput);
      Inc(Result);
    end;
  end;
  CloseHandle(Watch);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ShouldWait: Boolean;
  Wanted: QWord;
  Number: QWord;
  Timeout: Int64;
begin
  ShouldWait := False;
  Wanted := 0;
  Timeout := InfiniteWait;
  BeginOptions(Parser, [
    OptionDefinition('w', 'wait', False, OptionWait),
    OptionDefinition('n', 'count', True, OptionCount),
    OptionDefinition('t', 'timeout', True, OptionTimeout)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionWait: ShouldWait := True;
      OptionCount: ParseNumberOption(Value, Wanted);
      OptionTimeout:
        begin
          ParseNumberOption(Value, Number);
          Timeout := Int64(Number);
        end;
    end;
  ListVolumes;
  FlushStream(StandardOutput);
  if ShouldWait and (WatchArrivals(Wanted, Timeout) = 0) then
    Halt(ExitNothingCame);
end.
