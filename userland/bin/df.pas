{
  df - report file system space usage

  df [-hT] [FILE]...

  Lists the mounted volumes. Free space is not tracked per volume yet,
  so Used and Available are shown as "-".
}
program df;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Information,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Util.Sizes;

const
  Usage: PChar = 'Usage: df [OPTION]...'#10 +
    'Show information about the mounted volumes.'#10 +
    #10 +
    '  -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)'#10 +
    '  -T, --print-type      print file system type'#10;

  OptionHumanReadable = 1;
  OptionPrintType = 2;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  HumanReadable: Boolean;
  PrintType: Boolean;
  Volume: TVolumeInformation;
  Index: Integer;
  SizeText: array[0..31] of Char;
  MountPoint: array[0..127] of Char;
begin
  HumanReadable := False;
  PrintType := False;
  BeginOptions(Parser, [
    OptionDefinition('h', 'human-readable', False, OptionHumanReadable),
    OptionDefinition('T', 'print-type', False, OptionPrintType)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionHumanReadable: HumanReadable := True;
      OptionPrintType: PrintType := True;
    end;

  WriteText(StandardOutput, 'Filesystem      ');
  if PrintType then
    WriteText(StandardOutput, 'Type   ');
  if HumanReadable then
    WriteText(StandardOutput, ' Size')
  else
    WriteText(StandardOutput, ' 1K-blocks');
  WriteLine(StandardOutput, '  Used Available Use% Mounted on');

  Index := 0;
  while GetVolume(Index, Volume) do
  begin
    WriteFormatted(StandardOutput, '%-15s ', [ArgumentText(@Volume.Name[0])]);
    if PrintType then
      WriteFormatted(StandardOutput, '%-6s ', [ArgumentText(@Volume.FileSystemType[0])]);
    if HumanReadable then
      WriteFormatted(StandardOutput, '%5s', [ArgumentText(FormatHumanSize(Volume.TotalBytes, @SizeText[0]))])
    else
      WriteFormatted(StandardOutput, '%10u', [ArgumentUnsigned(Volume.TotalBytes div 1024)]);
    if Volume.IsSystemVolume <> 0 then
      CopyText(@MountPoint[0], '/', SizeOf(MountPoint))
    else
    begin
      CopyText(@MountPoint[0], '/volumes/', SizeOf(MountPoint));
      CopyText(@MountPoint[TextLength(@MountPoint[0])], @Volume.Name[0], SizeOf(MountPoint) - TextLength(@MountPoint[0]));
    end;
    WriteFormatted(StandardOutput, '     -         -    - %s'#10, [ArgumentText(@MountPoint[0])]);
    Inc(Index);
  end;
end.
