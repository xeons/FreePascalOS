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
  df - report file system space usage

  df [-hT] [FILE]...

  Lists the mounted volumes with their size, used and available space.
  A volume whose driver cannot tell its free space shows "-".
}
program df;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Information,
  Sys.Mounts,
  Util.CommandLine,
  Sys.Streams,
  Util.Sizes;

const
  Usage = 'Usage: df [OPTION]...'#10 +
    'Show information about the mounted volumes.'#10 +
    #10 +
    '  -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)'#10 +
    '  -T, --print-type      print file system type'#10;

  OptionHumanReadable = 1;
  OptionPrintType = 2;

var
  HumanReadable: Boolean;

function UsageColumns(const Volume: TVolumeInformation): string;
var
  Used: QWord;
  Percent: QWord;
begin
  Used := 0;
  if Volume.TotalBytes > Volume.FreeBytes then
    Used := Volume.TotalBytes - Volume.FreeBytes;
  Percent := 0;
  if Volume.TotalBytes > 0 then
    Percent := (Used * 100 + Volume.TotalBytes - 1) div Volume.TotalBytes;
  if HumanReadable then
    Result := Format(' %5s %9s', [FormatHumanSize(Used), FormatHumanSize(Volume.FreeBytes)])
  else
    Result := Format(' %5d %9d', [Used div 1024, Volume.FreeBytes div 1024]);
  Result := Result + Format(' %3d%%', [Percent]);
end;

{ Where the volume is mounted: its directory, else /volumes/NAME. }
function MountPointOf(const Volume: TVolumeInformation): string;
var
  Index: Integer;
  Description: TMountDescription;
begin
  Index := 0;
  while GetMountDescription(Index, Description) do
  begin
    if Description.Name = PChar(@Volume.Name[0]) then
      Exit(Description.MountPoint);
    Inc(Index);
  end;
  if Volume.IsSystemVolume <> 0 then
    Result := '/'
  else
    Result := '/volumes/' + PChar(@Volume.Name[0]);
end;

function VolumeLine(const Volume: TVolumeInformation; PrintType: Boolean): string;
begin
  Result := Format('%-15s ', [PChar(@Volume.Name[0])]);
  if PrintType then
    Result := Result + Format('%-6s ', [PChar(@Volume.FileSystemType[0])]);
  if HumanReadable then
    Result := Result + Format('%5s', [FormatHumanSize(Volume.TotalBytes)])
  else
    Result := Result + Format('%10d', [Volume.TotalBytes div 1024]);
  if Volume.HasFreeSpace <> 0 then
    Result := Result + UsageColumns(Volume)
  else
    Result := Result + '     -         -    -';
  Result := Result + ' ' + MountPointOf(Volume);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  PrintType: Boolean;
  Volume: TVolumeInformation;
  Index: Integer;
  Header: string;
begin
  HumanReadable := False;
  PrintType := False;
  CommandLine := TCommandLine.Create([
    CommandOption('h', 'human-readable', False, OptionHumanReadable),
    CommandOption('T', 'print-type', False, OptionPrintType)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionHumanReadable: HumanReadable := True;
      OptionPrintType: PrintType := True;
    end;

  Header := 'Filesystem      ';
  if PrintType then
    Header := Header + 'Type   ';
  if HumanReadable then
    Header := Header + ' Size'
  else
    Header := Header + ' 1K-blocks';
  PrintStringLine(Header + '  Used Available Use% Mounted on');

  Index := 0;
  while GetVolume(Index, Volume) do
  begin
    PrintStringLine(VolumeLine(Volume, PrintType));
    Inc(Index);
  end;
  CommandLine.Free;
end.
