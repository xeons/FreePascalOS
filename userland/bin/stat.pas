{
  stat - display file status

  stat [-L] [-c FORMAT] FILE...

  FORMAT conversions: %n name  %s size  %F file type  %i node number
  %h link count  %a mode in octal  %A mode as text  %Y modification time
  (seconds since 1970)  %y modification time  %%
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
  Util.Messages,
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
    'FORMAT: %n %s %F %i %h %a %A %Y %y %%'#10;

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
  else
    Result := 'unknown';
  end;
end;

procedure WriteModeText(const Information: TFileInformation);
const
  Letters: array[0..8] of Char = ('r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x');
var
  Bit: Integer;
begin
  case Information.Kind of
    KindDirectory: WriteCharacter(StandardOutput, 'd');
    KindSymbolicLink: WriteCharacter(StandardOutput, 'l');
  else
    WriteCharacter(StandardOutput, '-');
  end;
  for Bit := 0 to 8 do
  begin
    if (Information.Mode and (1 shl (8 - Bit))) <> 0 then
      WriteCharacter(StandardOutput, Letters[Bit])
    else
      WriteCharacter(StandardOutput, '-');
  end;
end;

procedure WriteTime(Time: Int64);
var
  DateTime: TDateTime;
begin
  DecodeTime(Time, DateTime);
  WriteFormatted(StandardOutput, '%04d-%02d-%02d %02d:%02d:%02d +0000', [
    ArgumentNumber(DateTime.Year), ArgumentNumber(DateTime.Month), ArgumentNumber(DateTime.Day),
    ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute), ArgumentNumber(DateTime.Second)]);
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
      'h': WriteUnsigned(StandardOutput, Information.LinkCount);
      'a': WriteFormatted(StandardOutput, '%o', [ArgumentUnsigned(Information.Mode and $FFF)]);
      'A': WriteModeText(Information);
      'Y': WriteDecimal(StandardOutput, Information.ModificationTime);
      'y': WriteTime(Information.ModificationTime);
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
  WriteFormatted(StandardOutput, '  Size: %-15u Type: %s'#10, [ArgumentUnsigned(Information.SizeInBytes),
    ArgumentText(KindName(Information))]);
  WriteFormatted(StandardOutput, '  Node: %-15u Links: %u'#10, [ArgumentUnsigned(Information.NodeNumber),
    ArgumentUnsigned(Information.LinkCount)]);
  WriteFormatted(StandardOutput, 'Access: (%04o/', [ArgumentUnsigned(Information.Mode and $FFF)]);
  WriteModeText(Information);
  WriteLine(StandardOutput, ')');
  WriteText(StandardOutput, 'Modify: ');
  WriteTime(Information.ModificationTime);
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
