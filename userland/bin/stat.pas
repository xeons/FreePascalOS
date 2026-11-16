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
  size of those blocks (512)  %%
}
program stat;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
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


function KindName(const Information: TFileInformation): PChar;
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

procedure WriteModeText(const Information: TFileInformation);
var
  Buffer: array[0..15] of Char;
begin
  case Information.Kind of
    KindDirectory: WriteCharacter(StandardOutput, 'd');
    KindSymbolicLink: WriteCharacter(StandardOutput, 'l');
    KindFifo: WriteCharacter(StandardOutput, 'p');
    KindCharacterDevice: WriteCharacter(StandardOutput, 'c');
    KindBlockDevice: WriteCharacter(StandardOutput, 'b');
  else
    WriteCharacter(StandardOutput, '-');
  end;
  WriteText(StandardOutput, FormatModeText(Information.Mode, @Buffer[0]));
end;

procedure WriteTime(Time: Int64);
var
  Local: TLocalTime;
  DateTime: TDateTime;
  OffsetText: array[0..7] of Char;
begin
  DecodeLocalTime(Time, Local);
  DateTime := Local.DateTime;
  FormatUtcOffset(Local.Offset, @OffsetText[0]);
  WriteFormatted(StandardOutput, '%04d-%02d-%02d %02d:%02d:%02d %s', [
    ArgumentNumber(DateTime.Year), ArgumentNumber(DateTime.Month), ArgumentNumber(DateTime.Day),
    ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute), ArgumentNumber(DateTime.Second),
    ArgumentText(@OffsetText[0])]);
end;

function NameOrUnknown(Name: PChar): PChar;
begin
  if Name = nil then
    Result := 'UNKNOWN'
  else
    Result := Name;
end;

procedure WriteWithFormat(Format: PChar; Name: PChar; const Information: TFileInformation);
var
  Position: Integer;
begin
  Position := 0;
  while Format[Position] <> #0 do
  begin
    if (Format[Position] <> '%') or (Format[Position + 1] = #0) then
    begin
      WriteCharacter(StandardOutput, Format[Position]);
      Inc(Position);
      Continue;
    end;
    Inc(Position);
    case Format[Position] of
      'n': WriteText(StandardOutput, Name);
      's': WriteUnsigned(StandardOutput, Information.SizeInBytes);
      'F': WriteText(StandardOutput, KindName(Information));
      'i': WriteUnsigned(StandardOutput, Information.NodeNumber);
      'b': WriteUnsigned(StandardOutput, (Information.AllocatedBytes + 511) div 512);
      'B': WriteText(StandardOutput, '512');
      'h': WriteUnsigned(StandardOutput, Information.LinkCount);
      'a': WriteFormatted(StandardOutput, '%o', [ArgumentUnsigned(Information.Mode and $FFF)]);
      'A': WriteModeText(Information);
      'u': WriteUnsigned(StandardOutput, Information.OwnerId);
      'g': WriteUnsigned(StandardOutput, Information.GroupId);
      'U': WriteText(StandardOutput, NameOrUnknown(UserNameOf(Information.OwnerId)));
      'G': WriteText(StandardOutput, NameOrUnknown(GroupNameOf(Information.GroupId)));
      'X': WriteDecimal(StandardOutput, Information.AccessTime);
      'x': WriteTime(Information.AccessTime);
      'Y': WriteDecimal(StandardOutput, Information.ModificationTime);
      'y': WriteTime(Information.ModificationTime);
      'Z': WriteDecimal(StandardOutput, Information.ChangeTime);
      'z': WriteTime(Information.ChangeTime);
      '%': WriteCharacter(StandardOutput, '%');
    else
      begin
        WriteCharacter(StandardOutput, '%');
        WriteCharacter(StandardOutput, Format[Position]);
      end;
    end;
    Inc(Position);
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure WriteDefault(Name: PChar; const Information: TFileInformation);
var
  Target: array[0..PathCapacity - 1] of Char;
begin
  if (Information.Kind = KindSymbolicLink) and
     (ReadSymbolicLink(Name, @Target[0], PathCapacity) = ErrorNone) then
    WriteFormatted(StandardOutput, '  File: %s -> %s'#10, [ArgumentText(Name), ArgumentText(@Target[0])])
  else
    WriteFormatted(StandardOutput, '  File: %s'#10, [ArgumentText(Name)]);
  WriteFormatted(StandardOutput, '  Size: %-15u Blocks: %-10u Type: %s'#10, [
    ArgumentUnsigned(Information.SizeInBytes), ArgumentUnsigned((Information.AllocatedBytes + 511) div 512),
    ArgumentText(KindName(Information))]);
  WriteFormatted(StandardOutput, '  Node: %-15u Links: %u'#10, [ArgumentUnsigned(Information.NodeNumber),
    ArgumentUnsigned(Information.LinkCount)]);
  WriteFormatted(StandardOutput, 'Access: (%04o/', [ArgumentUnsigned(Information.Mode and $FFF)]);
  WriteModeText(Information);
  WriteFormatted(StandardOutput, ')  Uid: (%5u/%8s)   Gid: (%5u/%8s)'#10, [ArgumentUnsigned(Information.OwnerId),
    ArgumentText(NameOrUnknown(UserNameOf(Information.OwnerId))), ArgumentUnsigned(Information.GroupId),
    ArgumentText(NameOrUnknown(GroupNameOf(Information.GroupId)))]);
  WriteText(StandardOutput, 'Access: ');
  WriteTime(Information.AccessTime);
  WriteCharacter(StandardOutput, #10);
  WriteText(StandardOutput, 'Modify: ');
  WriteTime(Information.ModificationTime);
  WriteCharacter(StandardOutput, #10);
  WriteText(StandardOutput, 'Change: ');
  WriteTime(Information.ChangeTime);
  WriteCharacter(StandardOutput, #10);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Dereference: Boolean;
  Format: PChar;
  Index: Integer;
  Information: TFileInformation;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Dereference := False;
  Format := nil;
  BeginOptions(Parser, [
    OptionDefinition('L', 'dereference', False, OptionDereference),
    OptionDefinition('c', 'format', True, OptionFormat),
    OptionDefinition('t', 'terse', False, OptionTerse)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDereference: Dereference := True;
      OptionFormat: Format := Value;
      OptionTerse: Format := '%n %s %i %h %a %Y';
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
    if Format <> nil then
      WriteWithFormat(Format, Parser.Operands[Index], Information)
    else
      WriteDefault(Parser.Operands[Index], Information);
  end;
  Halt(ExitStatus);
end.
