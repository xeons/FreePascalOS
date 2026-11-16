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
  %X %Y %Z the same in seconds since 1970  %b allocated blocks  %B the
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
  Sys.Format,
  Sys.Streams,
  Sys.Time,
  Sys.LocalTime,
  Util.Accounts,
  Util.Messages,
  Util.Modes,
  Util.Options;

const
  Usage: PChar = 'Usage: stat [OPTION]... FILE...'#10 +
    'Display file status.'#10 +
    #10 +
    '  -L, --dereference     follow links'#10 +
    '  -c  --format=FORMAT   use the specified FORMAT instead of the default;'#10 +
    '                        output a newline after each use of FORMAT'#10 +
    '  -t, --terse           print the information in terse form'#10 +
    #10 +
    'FORMAT: %n %s %F %i %h %a %A %u %U %g %G %x %X %y %Y %z %Z %b %B %%'#10;

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
var
  Buffer: array[0..15] of Char;
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
  Result := Result + FormatModeText(Information.Mode, @Buffer[0]);
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
  OffsetText: array[0..7] of Char;
begin
  DecodeLocalTime(Time, Local);
  DateTime := Local.DateTime;
  FormatUtcOffset(Local.Offset, @OffsetText[0]);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d %s', [DateTime.Year, DateTime.Month, DateTime.Day,
    DateTime.Hour, DateTime.Minute, DateTime.Second, string(PChar(@OffsetText[0]))]);
end;

function NameOrUnknown(Name: PChar): string;
begin
  if Name = nil then
    Result := 'UNKNOWN'
  else
    Result := Name;
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
    'U': Result := NameOrUnknown(UserNameOf(Information.OwnerId));
    'G': Result := NameOrUnknown(GroupNameOf(Information.GroupId));
    'X': Result := IntToStr(Information.AccessTime);
    'x': Result := TimeText(Information.AccessTime);
    'Y': Result := IntToStr(Information.ModificationTime);
    'y': Result := TimeText(Information.ModificationTime);
    'Z': Result := IntToStr(Information.ChangeTime);
    'z': Result := TimeText(Information.ChangeTime);
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
  WriteLine(StandardOutput, PChar(Line));
end;

function ReadLinkTarget(const Path: string; out Target: string): Boolean;
var
  Buffer: array[0..PathCapacity - 1] of Char;
begin
  Result := ReadSymbolicLink(PChar(Path), @Buffer[0], PathCapacity) = ErrorNone;
  if Result then
    Target := PChar(@Buffer[0])
  else
    Target := '';
end;

procedure OutputLine(const Line: string);
begin
  WriteLine(StandardOutput, PChar(Line));
end;

procedure WriteDefault(const Name: string; const Information: TFileInformation);
var
  Target: string;
begin
  if (Information.Kind = KindSymbolicLink) and ReadLinkTarget(Name, Target) then
    OutputLine('  File: ' + Name + ' -> ' + Target)
  else
    OutputLine('  File: ' + Name);
  OutputLine(Format('  Size: %-15d Blocks: %-10d Type: %s', [Information.SizeInBytes, BlockCount(Information),
    KindName(Information)]));
  OutputLine(Format('  Node: %-15d Links: %-10d Volume: %d', [Information.NodeNumber, Information.LinkCount,
    Information.VolumeNumber]));
  OutputLine(Format('Access: (%s/%s)  Uid: (%5d/%8s)   Gid: (%5d/%8s)', [OctalModeText(Information, 4),
    ModeText(Information), Information.OwnerId, NameOrUnknown(UserNameOf(Information.OwnerId)),
    Information.GroupId, NameOrUnknown(GroupNameOf(Information.GroupId))]));
  OutputLine('Access: ' + TimeText(Information.AccessTime));
  OutputLine('Modify: ' + TimeText(Information.ModificationTime));
  OutputLine('Change: ' + TimeText(Information.ChangeTime));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Dereference: Boolean;
  HasFormat: Boolean;
  FormatText: string;
  Index: Integer;
  Information: TFileInformation;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Dereference := False;
  HasFormat := False;
  FormatText := '';
  BeginOptions(Parser, [
    OptionDefinition('L', 'dereference', False, OptionDereference),
    OptionDefinition('c', 'format', True, OptionFormat),
    OptionDefinition('t', 'terse', False, OptionTerse)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDereference: Dereference := True;
      OptionFormat:
        begin
          HasFormat := True;
          FormatText := Value;
        end;
      OptionTerse:
        begin
          HasFormat := True;
          FormatText := '%n %s %i %h %a %Y';
        end;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if Dereference then
      Error := GetFileInformation(Parser.Operands[Index], Information)
    else
      Error := GetLinkInformation(Parser.Operands[Index], Information);
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'cannot stat ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    if HasFormat then
      WriteWithFormat(FormatText, Parser.Operands[Index], Information)
    else
      WriteDefault(Parser.Operands[Index], Information);
  end;
  Halt(ExitStatus);
end.
