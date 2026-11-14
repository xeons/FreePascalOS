{
  ln - make links between files

  ln -s [-fnTv] TARGET LINK_NAME
  ln -s [-fnv] TARGET... DIRECTORY

  Only symbolic links are supported (-s); the file systems' hard links
  are not exposed to programs.
}
program ln;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: ln -s [OPTION]... TARGET LINK_NAME'#10 +
    '  or:  ln -s [OPTION]... TARGET... DIRECTORY'#10 +
    'Create symbolic links to TARGET(s).'#10 +
    #10 +
    '  -f, --force                remove existing destination files'#10 +
    '  -n, --no-dereference       treat LINK_NAME as a normal file if it is a'#10 +
    '                               symbolic link to a directory'#10 +
    '  -s, --symbolic             make symbolic links instead of hard links'#10 +
    '  -T, --no-target-directory  treat LINK_NAME as a normal file always'#10 +
    '  -v, --verbose              print name of each linked file'#10;

  OptionForce = 1;
  OptionNoDereference = 2;
  OptionSymbolic = 3;
  OptionNoTargetDirectory = 4;
  OptionVerbose = 5;

var
  Force: Boolean;
  Verbose: Boolean;

function LinkOne(Target, LinkName: PChar): Boolean;
var
  Error: LongInt;
begin
  if Force and PathExists(LinkName) and not IsDirectory(LinkName) then
    RemovePath(LinkName);
  Error := CreateSymbolicLink(Target, LinkName);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'failed to create symbolic link ''%s''', [ArgumentText(LinkName)]);
    Exit(False);
  end;
  if Verbose then
    WriteFormatted(StandardOutput, '''%s'' -> ''%s'''#10, [ArgumentText(LinkName), ArgumentText(Target)]);
  Result := True;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Symbolic: Boolean;
  NoDereference: Boolean;
  NoTargetDirectory: Boolean;
  Destination: PChar;
  Index: Integer;
  Base: PChar;
  LinkName: PChar;
  ExitStatus: LongInt;
  Information: TFileInformation;
  DestinationIsDirectory: Boolean;
begin
  Force := False;
  Verbose := False;
  Symbolic := False;
  NoDereference := False;
  NoTargetDirectory := False;
  BeginOptions(Parser, [
    OptionDefinition('f', 'force', False, OptionForce),
    OptionDefinition('n', 'no-dereference', False, OptionNoDereference),
    OptionDefinition('s', 'symbolic', False, OptionSymbolic),
    OptionDefinition('T', 'no-target-directory', False, OptionNoTargetDirectory),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionForce: Force := True;
      OptionNoDereference: NoDereference := True;
      OptionSymbolic: Symbolic := True;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;
  if not Symbolic then
    Fail(1, 'hard links are not supported; use ln -s', []);
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);

  if Parser.OperandCount = 1 then
  begin
    { "ln -s TARGET" links into the current directory. }
    Base := BaseName(Parser.Operands[0]);
    if LinkOne(Parser.Operands[0], Base) then
      Halt(0);
    Halt(1);
  end;

  Destination := Parser.Operands[Parser.OperandCount - 1];
  DestinationIsDirectory := IsDirectory(Destination);
  if DestinationIsDirectory and NoDereference and
     (GetLinkInformation(Destination, Information) = ErrorNone) and (Information.Kind = KindSymbolicLink) then
    DestinationIsDirectory := False;
  if NoTargetDirectory or ((Parser.OperandCount = 2) and not DestinationIsDirectory) then
  begin
    if Parser.OperandCount > 2 then
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
    if LinkOne(Parser.Operands[0], Destination) then
      Halt(0);
    Halt(1);
  end;
  if not DestinationIsDirectory then
    Fail(1, 'target ''%s'' is not a directory', [ArgumentText(Destination)]);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 2 do
  begin
    Base := BaseName(Parser.Operands[Index]);
    LinkName := JoinPath(Destination, Base);
    if not LinkOne(Parser.Operands[Index], LinkName) then
      ExitStatus := 1;
    FreeMemory(Base);
    FreeMemory(LinkName);
  end;
  Halt(ExitStatus);
end.
