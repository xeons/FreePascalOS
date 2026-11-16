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
  What sysinfo tells: a list of facts about the system, each a label and
  a value ("Memory", "1.2 GiB / 3.9 GiB (31%)"), gathered from the
  kernel, the accounts, the volumes and (when the display server runs)
  the displays. A fact that cannot be found is left out.
}
unit SystemInfo.Facts;

{$mode objfpc}{$H+}

interface

type
  TFact = record
    Name: string;
    Value: string;
  end;
  TFactList = array of TFact;

{ "user@host": who is asking, on which machine. }
function UserAndHost: string;
{ Every fact that could be found, in the order shown. }
function GatherFacts: TFactList;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Information,
  Sys.SystemUsage,
  Sys.Processor,
  Sys.Volumes,
  Sys.LocalTime,
  Sys.TimeZones,
  Sys.Time,
  Sys.Files,
  Sys.Console,
  Sys.PseudoTerminals,
  Util.Accounts,
  Windowing.Connection,
  Windowing.Displays;

const
  ProgramFolder = '/bin';
  Kibibyte = QWord(1024);
  Mebibyte = Kibibyte * 1024;
  Gibibyte = Mebibyte * 1024;

procedure AddFact(var Facts: TFactList; const Name, Value: string);
var
  Count: LongInt;
begin
  if Value = '' then
    Exit;
  Count := Length(Facts);
  SetLength(Facts, Count + 1);
  Facts[Count].Name := Name;
  Facts[Count].Value := Value;
end;

{ 512 MiB, 3.94 GiB. }
function SizeText(Bytes: QWord): string;
begin
  if Bytes >= Gibibyte then
    Result := Format('%d.%.2d GiB', [Bytes div Gibibyte, (Bytes mod Gibibyte) * 100 div Gibibyte])
  else
    Result := Format('%d MiB', [Bytes div Mebibyte]);
end;

{ "1.20 GiB / 3.94 GiB (30%)". }
function UsageText(Used, Total: QWord): string;
var
  Percent: QWord;
begin
  if Total = 0 then
    Exit('');
  Percent := Used * 100 div Total;
  Result := SizeText(Used) + ' / ' + SizeText(Total) + ' (' + IntToStr(Percent) + '%)';
end;

function PluralText(Count: QWord; const Singular: string): string;
begin
  Result := IntToStr(Count) + ' ' + Singular;
  if Count <> 1 then
    Result := Result + 's';
end;

{ "2 days, 3 hours, 5 mins". }
function UptimeText(Milliseconds: QWord): string;
var
  Seconds, Days, Hours, Minutes: QWord;
begin
  Seconds := Milliseconds div 1000;
  Days := Seconds div 86400;
  Hours := (Seconds mod 86400) div 3600;
  Minutes := (Seconds mod 3600) div 60;
  Result := '';
  if Days > 0 then
    Result := PluralText(Days, 'day');
  if Hours > 0 then
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + PluralText(Hours, 'hour');
  end;
  if (Minutes > 0) or (Result = '') then
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + PluralText(Minutes, 'min');
  end;
end;

function UserAndHost: string;
var
  Information: TSystemInformation;
begin
  Result := UserNameOrNumber(CurrentUserId);
  if GetSystemInformation(Information) = 0 then
    Result := Result + '@' + string(PChar(@Information.NodeName[0]));
end;

{ How many programs /bin holds. }
function CountPrograms: LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
begin
  Result := 0;
  Handle := OpenFile(ProgramFolder, OpenRead);
  if Handle < 0 then
    Exit;
  while ReadDirectoryEntry(Handle, Entry) do
    if (Entry.Name[0] <> '.') and (Entry.Kind <> KindDirectory) then
      Inc(Result);
  CloseFile(Handle);
end;

{ The terminal standard input comes from: a pseudo-terminal's path,
  the console, or nothing. }
function TerminalText: string;
var
  Number: Int64;
begin
  Number := TerminalNumber(StandardInputHandle);
  if Number >= 0 then
    Exit(PseudoTerminalPath(Number));
  if IsConsole(StandardInputHandle) then
    Result := 'console'
  else
    Result := '';
end;

function ProcessorText(Processors: LongWord): string;
begin
  Result := ProcessorModel;
  if Result = '' then
    Result := ProcessorVendor;
  Result := Result + ' (' + IntToStr(Processors) + ')';
end;

function TimeZoneText: string;
var
  Zone: PTimeZone;
  Local: TLocalTime;
begin
  Zone := CurrentTimeZone;
  if Zone = nil then
    Exit('UTC');
  DecodeTimeInZone(Zone, CurrentTime, Local);
  if string(Zone^.Name) = string(Local.Abbreviation) then
    Result := string(Zone^.Name)
  else
    Result := string(Zone^.Name) + ' (' + string(Local.Abbreviation) + ', UTC' + FormatUtcOffset(Local.Offset) + ')';
end;

{ One fact for each display, if the display server is running (asked
  without waiting for it: in text mode there is none). }
procedure AddDisplayFacts(var Facts: TFactList);
var
  Count: LongInt;
  Number: LongInt;
  Display: TDisplayInformation;
  Name: string;
begin
  if ConnectToDisplay(False) <> ErrorNone then
    Exit;
  Count := CountDisplays;
  for Number := 0 to Count - 1 do
    if DescribeDisplay(Number, Display) then
    begin
      Name := 'Display';
      if Count > 1 then
        Name := Name + ' ' + IntToStr(Number + 1);
      AddFact(Facts, Name, Format('%dx%d @ %d%% (%d DPI)', [Display.Width, Display.Height,
        Display.ScalePercent, Display.Dpi]));
    end;
  DisconnectFromDisplay;
end;

{ One fact for each volume: the system's first, as "Disk (/)". }
procedure AddVolumeFacts(var Facts: TFactList);
var
  Index: Integer;
  Volume: TVolumeDescription;
  Name: string;
  Value: string;
begin
  Index := 0;
  while GetVolumeDescription(Index, Volume) do
  begin
    Inc(Index);
    if not Volume.HasFreeSpace or (Volume.TotalBytes = 0) then
      Continue;
    if Volume.IsSystemVolume then
      Name := 'Disk (/)'
    else
      Name := 'Disk (' + string(PChar(@Volume.MountPoint[0])) + ')';
    Value := UsageText(Volume.TotalBytes - Volume.FreeBytes, Volume.TotalBytes) + ' - ' +
      string(PChar(@Volume.FileSystemType[0]));
    if Volume.IsRemovable then
      Value := Value + ', removable';
    if Volume.IsReadOnly then
      Value := Value + ', read-only';
    AddFact(Facts, Name, Value);
  end;
end;

function GatherFacts: TFactList;
var
  Information: TSystemInformation;
  Usage: TSystemUsage;
  HaveUsage: Boolean;
  Programs: LongInt;
begin
  Result := nil;
  FillChar(Information, SizeOf(Information), 0);
  GetSystemInformation(Information);
  HaveUsage := GetSystemUsage(Usage) = 0;

  AddFact(Result, 'OS', 'FreePascalOS ' + string(PChar(@Information.Machine[0])));
  AddFact(Result, 'Kernel', string(PChar(@Information.SystemName[0])) + ' ' +
    string(PChar(@Information.Release[0])));
  AddFact(Result, 'Uptime', UptimeText(UptimeMilliseconds));
  Programs := CountPrograms;
  if Programs > 0 then
    AddFact(Result, 'Programs', IntToStr(Programs) + ' (' + ProgramFolder + ')');
  { Every account has one (/bin/sh when its entry names none). }
  AddFact(Result, 'Shell', UserShell(CurrentUserId));
  AddDisplayFacts(Result);
  AddFact(Result, 'Terminal', TerminalText);
  AddFact(Result, 'CPU', ProcessorText(Information.ProcessorCount));
  if HaveUsage then
  begin
    AddFact(Result, 'Memory', UsageText(UsedMemory(Usage), Usage.TotalMemory));
    AddFact(Result, 'Processes', IntToStr(Usage.ProcessCount) + ' (' + PluralText(Usage.ThreadCount, 'thread') + ')');
  end
  else
    AddFact(Result, 'Memory', UsageText(Information.TotalMemory - Information.FreeMemory, Information.TotalMemory));
  AddVolumeFacts(Result);
  AddFact(Result, 'Time zone', TimeZoneText);
end;

end.
