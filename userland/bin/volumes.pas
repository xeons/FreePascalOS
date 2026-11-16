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

uses
  Abi.SystemCalls,
  Runtime.Text,
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

procedure WriteFlags(const Volume: TVolumeDescription);
begin
  if Volume.IsSystemVolume then
    WriteText(StandardOutput, ' system');
  if Volume.IsReadOnly then
    WriteText(StandardOutput, ' read-only');
  if Volume.IsRemovable then
    WriteText(StandardOutput, ' removable');
end;

procedure WriteVolume(const Volume: TVolumeDescription);
var
  SizeText: array[0..31] of Char;
  FreeText: array[0..31] of Char;
begin
  FormatHumanSize(Volume.TotalBytes, @SizeText[0]);
  if Volume.HasFreeSpace then
    FormatHumanSize(Volume.FreeBytes, @FreeText[0])
  else
    CopyText(@FreeText[0], '-', SizeOf(FreeText));
  WriteFormatted(StandardOutput, '%-10s %-12s %-6s %6s %6s %s', [ArgumentText(@Volume.Name[0]),
    ArgumentText(@Volume.VolumeLabel[0]), ArgumentText(@Volume.FileSystemType[0]),
    ArgumentText(@SizeText[0]), ArgumentText(@FreeText[0]), ArgumentText(@Volume.MountPoint[0])]);
  WriteFlags(Volume);
  WriteText(StandardOutput, #10);
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

procedure WriteArrival(Name: PChar);
var
  Volume: TVolumeDescription;
  SizeText: array[0..31] of Char;
begin
  WriteFormatted(StandardOutput, 'arrived: %s', [ArgumentText(Name)]);
  if FindVolumeDescription(Name, Volume) then
  begin
    FormatHumanSize(Volume.TotalBytes, @SizeText[0]);
    WriteFormatted(StandardOutput, ' %s "%s" %s at %s', [ArgumentText(@Volume.FileSystemType[0]),
      ArgumentText(@Volume.VolumeLabel[0]), ArgumentText(@SizeText[0]), ArgumentText(@Volume.MountPoint[0])]);
  end;
  WriteText(StandardOutput, #10);
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
        FileChangeRemoved: WriteFormatted(StandardOutput, 'removed: %s'#10, [ArgumentText(Change.Name)]);
      else
        WriteFormatted(StandardOutput, '%s'#10, [ArgumentText(FileChangeKindText(Change.Kind))]);
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
