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
  stat - display file status

  stat [-L] [-c FORMAT] FILE...

  FORMAT conversions: %n name  %s size  %F file type  %i node number
  %h link count  %a mode in octal  %A mode as text  %u %g owner and group
  ids  %U %G their names  %x %y %z access, modification and change time
  %X %Y %Z the same in seconds since 1970  %w %W the time it was made
  (birth; "-" and 0 where the file system does not keep it)  %b allocated blocks  %B the
  size of those blocks (512)  %d the volume's number (two files are on
  one volume when their numbers are equal)  %%
}
program stat;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Time,
  Sys.LocalTime,
  Sys.Mounts,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Util.Modes,
  Sys.Streams,
  Util.Paths;

const
  Usage = 'Usage: stat [OPTION]... FILE...'#10 +
    'Display file status.'#10 +
    #10 +
    '  -L, --dereference     follow links'#10 +
    '  -c  --format=FORMAT   use the specified FORMAT instead of the default;'#10 +
    '                        output a newline after each use of FORMAT'#10 +
    '  -t, --terse           print the information in terse form'#10 +
    #10 +
    'FORMAT: %n %s %F %i %h %a %A %u %U %g %G %x %X %y %Y %z %Z %w %W %b %B %%'#10;

  OptionDereference = 1;
  OptionFormat = 2;
  OptionTerse = 3;

function KindName(const Information: TFileInformation): string;
begin
  case Information.Kind of
    KindFile:
      if Information.SizeInBytes = 0 then
        Result := 'regular empty file'
      else
        Result := 'regular file';
    KindDirectory: Result := 'directory';
    KindSymbolicLink: Result := 'symbolic link';
    KindFifo: Result := 'fifo';
    KindCharacterDevice: Result := 'character special file';
    KindBlockDevice: Result := 'block special file';
  else
    Result := 'unknown';
  end;
end;

function ModeText(const Information: TFileInformation): string;
begin
  case Information.Kind of
    KindDirectory: Result := 'd';
    KindSymbolicLink: Result := 'l';
    KindFifo: Result := 'p';
    KindCharacterDevice: Result := 'c';
    KindBlockDevice: Result := 'b';
  else
    Result := '-';
  end;
  Result := Result + FormatModeText(Information.Mode);
end;

{ The permission bits in octal, at least MinimumDigits long. }
function OctalModeText(const Information: TFileInformation; MinimumDigits: Integer): string;
begin
  Result := OctStr(Information.Mode and $FFF, 4);
  while (Length(Result) > MinimumDigits) and (Result[1] = '0') do
    Delete(Result, 1, 1);
end;

function TimeText(Time: Int64): string;
var
  Local: TLocalTime;
  DateTime: Sys.Time.TDateTime;
begin
  DecodeLocalTime(Time, Local);
  DateTime := Local.DateTime;
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d %s', [DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute, DateTime.Second, FormatUtcOffset(Local.Offset)]);
end;

{ A time to the nanosecond, as the default view shows them. }
function PreciseTimeText(const Time: TAbiPreciseTime): string;
var
  Local: TLocalTime;
  DateTime: Sys.Time.TDateTime;
begin
  DecodeLocalTime(Time.Seconds, Local);
  DateTime := Local.DateTime;
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d.%.9d %s', [DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute, DateTime.Second, Time.Nanoseconds, FormatUtcOffset(Local.Offset)]);
end;

var
  { The times of the file being described, for %w %W and the default
    view; HaveTimes is False where they could not be read. }
  CurrentTimes: TFileTimes;
  HaveTimes: Boolean;

function HasBirthTime: Boolean;
begin
  Result := HaveTimes and ((CurrentTimes.Flags and FileTimesHasBirthTime) <> 0);
end;

function UserNameOrUnknown(UserId: LongWord): string;
begin
  if not FindUserName(UserId, Result) then
    Result := 'UNKNOWN';
end;

function GroupNameOrUnknown(GroupId: LongWord): string;
begin
  if not FindGroupName(GroupId, Result) then
    Result := 'UNKNOWN';
end;

function BlockCount(const Information: TFileInformation): QWord;
begin
  Result := (Information.AllocatedBytes + 511) div 512;
end;

function ConversionText(Conversion: Char; const Name: string; const Information: TFileInformation): string;
begin
  case Conversion of
    'n': Result := Name;
    's': Result := IntToStr(Information.SizeInBytes);
    'F': Result := KindName(Information);
    'i': Result := IntToStr(Information.NodeNumber);
    'd': Result := IntToStr(Information.VolumeNumber);
    'b': Result := IntToStr(BlockCount(Information));
    'B': Result := '512';
    'h': Result := IntToStr(Information.LinkCount);
    'a': Result := OctalModeText(Information, 1);
    'A': Result := ModeText(Information);
    'u': Result := IntToStr(Information.OwnerId);
    'g': Result := IntToStr(Information.GroupId);
    'U': Result := UserNameOrUnknown(Information.OwnerId);
    'G': Result := GroupNameOrUnknown(Information.GroupId);
    'X': Result := IntToStr(Information.AccessTime);
    'x': Result := TimeText(Information.AccessTime);
    'Y': Result := IntToStr(Information.ModificationTime);
    'y': Result := TimeText(Information.ModificationTime);
    'Z': Result := IntToStr(Information.ChangeTime);
    'z': Result := TimeText(Information.ChangeTime);
    'W':
      if HasBirthTime then
        Result := IntToStr(CurrentTimes.Birth.Seconds)
      else
        Result := '0';
    'w':
      if HasBirthTime then
        Result := TimeText(CurrentTimes.Birth.Seconds)
      else
        Result := '-';
    '%': Result := '%';
  else
    Result := '%' + Conversion;
  end;
end;

procedure WriteWithFormat(const FormatText, Name: string; const Information: TFileInformation);
var
  Position: Integer;
  Line: string;
begin
  Line := '';
  Position := 1;
  while Position <= Length(FormatText) do
  begin
    if (FormatText[Position] <> '%') or (Position = Length(FormatText)) then
    begin
      Line := Line + FormatText[Position];
      Inc(Position);
      Continue;
    end;
    Line := Line + ConversionText(FormatText[Position + 1], Name, Information);
    Inc(Position, 2);
  end;
  PrintStringLine(Line);
end;

procedure WriteDefault(const Name: string; const Information: TFileInformation);
var
  Target: string;
begin
  if (Information.Kind = KindSymbolicLink) and (ReadLinkTarget(Name, Target) = ErrorNone) then
    PrintStringLine('  File: ' + Name + ' -> ' + Target)
  else
    PrintStringLine('  File: ' + Name);
  PrintStringLine(Format('  Size: %-15d Blocks: %-10d Type: %s', [Information.SizeInBytes, BlockCount(Information),
    KindName(Information)]));
  PrintStringLine(Format('  Node: %-15d Links: %-10d Volume: %d', [Information.NodeNumber, Information.LinkCount,
    Information.VolumeNumber]));
  PrintStringLine(Format('Access: (%s/%s)  Uid: (%5d/%8s)   Gid: (%5d/%8s)', [OctalModeText(Information, 4),
    ModeText(Information), Information.OwnerId, UserNameOrUnknown(Information.OwnerId),
    Information.GroupId, GroupNameOrUnknown(Information.GroupId)]));
  if not HaveTimes then
  begin
    PrintStringLine('Access: ' + TimeText(Information.AccessTime));
    PrintStringLine('Modify: ' + TimeText(Information.ModificationTime));
    PrintStringLine('Change: ' + TimeText(Information.ChangeTime));
    Exit;
  end;
  PrintStringLine('Access: ' + PreciseTimeText(CurrentTimes.Access));
  PrintStringLine('Modify: ' + PreciseTimeText(CurrentTimes.Modification));
  PrintStringLine('Change: ' + PreciseTimeText(CurrentTimes.Change));
  if HasBirthTime then
    PrintStringLine(' Birth: ' + PreciseTimeText(CurrentTimes.Birth))
  else
    PrintStringLine(' Birth: -');
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Dereference: Boolean;
  UseFormat: Boolean;
  FormatText: string;
  Operand: string;
  Information: TFileInformation;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Dereference := False;
  FormatText := '';
  CommandLine := TCommandLine.Create([
    CommandOption('L', 'dereference', False, OptionDereference),
    CommandOption('c', 'format', True, OptionFormat),
    CommandOption('t', 'terse', False, OptionTerse)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionDereference: Dereference := True;
      OptionFormat: FormatText := Value;
      OptionTerse: FormatText := '%n %s %i %h %a %Y';
    end;
  UseFormat := CommandLine.OptionGiven(OptionFormat) or CommandLine.OptionGiven(OptionTerse);
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    if Dereference then
      Error := GetFileInformation(PChar(Operand), Information)
    else
      Error := GetLinkInformation(PChar(Operand), Information);
    if Error <> ErrorNone then
    begin
      ReportError(Error, Format('cannot stat ''%s''', [Operand]));
      ExitStatus := 1;
      Continue;
    end;
    HaveTimes := GetFileTimes(Operand, Dereference, CurrentTimes) = ErrorNone;
    if UseFormat then
      WriteWithFormat(FormatText, Operand, Information)
    else
      WriteDefault(Operand, Information);
  end;
  Halt(ExitStatus);
end.
