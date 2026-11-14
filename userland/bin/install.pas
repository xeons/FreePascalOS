{
  install - copy files and set attributes

  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] SOURCE DEST
  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] SOURCE... DIRECTORY
  install [-Dpv] [-m MODE] [-o OWNER] [-g GROUP] -t DIRECTORY SOURCE...
  install -d [-m MODE] [-o OWNER] [-g GROUP] DIRECTORY...

  Files get mode 0755 unless -m says otherwise. -D creates the missing
  parent directories of DEST; -p keeps the source's modification time.
}
program install;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Accounts,
  Util.FileTree,
  Util.Messages,
  Util.Modes,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: install [OPTION]... [-T] SOURCE DEST'#10 +
    '  or:  install [OPTION]... SOURCE... DIRECTORY'#10 +
    '  or:  install [OPTION]... -t DIRECTORY SOURCE...'#10 +
    '  or:  install [OPTION]... -d DIRECTORY...'#10 +
    'Copy SOURCE to DEST or multiple SOURCE(s) to the existing DIRECTORY,'#10 +
    'while setting permission modes and owner/group.'#10#10 +
    '  -d, --directory     treat all arguments as directory names; create all'#10 +
    '                        components of the specified directories'#10 +
    '  -D                  create all leading components of DEST except the last'#10 +
    '  -g, --group=GROUP   set group ownership, instead of process'' current group'#10 +
    '  -m, --mode=MODE     set permission mode (as in chmod), instead of rwxr-xr-x'#10 +
    '  -o, --owner=OWNER   set ownership'#10 +
    '  -p, --preserve-timestamps  apply modification time of SOURCE files to'#10 +
    '                        corresponding destination files'#10 +
    '  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY'#10 +
    '  -T, --no-target-directory  treat DEST as a normal file'#10 +
    '  -v, --verbose       print the name of each created file or directory'#10;

  OptionDirectory = 1;
  OptionParents = 2;
  OptionGroup = 3;
  OptionMode = 4;
  OptionOwner = 5;
  OptionPreserve = 6;
  OptionTarget = 7;
  OptionNoTarget = 8;
  OptionVerbose = 9;
  OptionCompare = 10;
  OptionStrip = 11;

var
  ModeChange: TModeChange;
  Owner: Int64;
  Group: Int64;
  PreserveTimes: Boolean;
  Verbose: Boolean;

{ Creates Path and its missing parents. }
function MakeDirectories(Path: PChar): Boolean;
var
  Copy: PChar;
  Position: PtrUInt;
  Error: LongInt;
begin
  Result := True;
  Copy := DuplicateText(Path);
  Position := 1;
  while True do
  begin
    while (Copy[Position] <> '/') and (Copy[Position] <> #0) do
      Inc(Position);
    if Copy[Position] = '/' then
      Copy[Position] := #0;
    if (Copy[0] <> #0) and not IsDirectory(Copy) then
    begin
      Error := CreateDirectory(Copy);
      if Error <> ErrorNone then
      begin
        ReportError(Error, 'cannot create directory ''%s''', [ArgumentText(Copy)]);
        Result := False;
        Break;
      end;
      if Verbose then
        WriteFormatted(StandardOutput, '%s: creating directory ''%s'''#10, [ArgumentText(ProgramName), ArgumentText(Copy)]);
    end;
    if TextLength(Copy) = TextLength(Path) then
      Break;
    Copy[Position] := '/';
    Inc(Position);
    if Copy[Position] = #0 then
      Break;
  end;
  FreeMemory(Copy);
end;

function ApplyAttributes(Path: PChar; IsDirectoryPath: Boolean; ModificationTime: Int64): Boolean;
var
  Error: LongInt;
begin
  Result := True;
  Error := ChangeMode(Path, ApplyModeChange(ModeChange, 0, IsDirectoryPath));
  if Error = ErrorNone then
    Error := ChangeOwner(Path, Owner, Group, True);
  if (Error = ErrorNone) and (ModificationTime >= 0) then
    Error := SetFileTimes(Path, ModificationTime, ModificationTime, True);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot set attributes of ''%s''', [ArgumentText(Path)]);
    Result := False;
  end;
end;

function InstallFile(Source, Target: PChar): Boolean;
var
  Options: TCopyOptions;
  Information: TFileInformation;
  Time: Int64;
begin
  if GetFileInformation(Source, Information) <> ErrorNone then
  begin
    Report('cannot stat ''%s'': No such file or directory', [ArgumentText(Source)]);
    Exit(False);
  end;
  if Information.Kind = KindDirectory then
  begin
    Report('omitting directory ''%s''', [ArgumentText(Source)]);
    Exit(False);
  end;
  { Replace rather than overwrite, so a running copy is not disturbed. }
  if PathExists(Target) and not IsDirectory(Target) then
    RemovePath(Target);
  Options.Recursive := False;
  Options.KeepLinks := False;
  Options.NoClobber := False;
  Options.Verbose := False;
  Options.PreserveAttributes := False;
  if not CopyPath(Source, Target, Options) then
    Exit(False);
  if Verbose then
    WriteFormatted(StandardOutput, '''%s'' -> ''%s'''#10, [ArgumentText(Source), ArgumentText(Target)]);
  Time := -1;
  if PreserveTimes then
    Time := Information.ModificationTime;
  Result := ApplyAttributes(Target, False, Time);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  DirectoryMode: Boolean;
  CreateParents: Boolean;
  TargetDirectory: PChar;
  NoTargetDirectory: Boolean;
  Index: Integer;
  SourceCount: Integer;
  Target: PChar;
  Base: PChar;
  Parent: PChar;
  Id: LongWord;
  ExitStatus: LongInt;
begin
  DirectoryMode := False;
  CreateParents := False;
  TargetDirectory := nil;
  NoTargetDirectory := False;
  Owner := -1;
  Group := -1;
  ParseModeChange('755', ModeChange);
  BeginOptions(Parser, [
    OptionDefinition('d', 'directory', False, OptionDirectory),
    OptionDefinition('D', nil, False, OptionParents),
    OptionDefinition('g', 'group', True, OptionGroup),
    OptionDefinition('m', 'mode', True, OptionMode),
    OptionDefinition('o', 'owner', True, OptionOwner),
    OptionDefinition('p', 'preserve-timestamps', False, OptionPreserve),
    OptionDefinition('t', 'target-directory', True, OptionTarget),
    OptionDefinition('T', 'no-target-directory', False, OptionNoTarget),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('C', 'compare', False, OptionCompare),
    OptionDefinition('s', 'strip', False, OptionStrip)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDirectory: DirectoryMode := True;
      OptionParents: CreateParents := True;
      OptionGroup:
        begin
          if not FindGroupId(Value, Id) then
            Fail(1, 'invalid group ''%s''', [ArgumentText(Value)]);
          Group := Id;
        end;
      OptionMode:
        if not ParseModeChange(Value, ModeChange) then
          Fail(1, 'invalid mode ''%s''', [ArgumentText(Value)]);
      OptionOwner:
        begin
          if not FindUserId(Value, Id) then
            Fail(1, 'invalid user ''%s''', [ArgumentText(Value)]);
          Owner := Id;
        end;
      OptionPreserve: PreserveTimes := True;
      OptionTarget: TargetDirectory := Value;
      OptionNoTarget: NoTargetDirectory := True;
      OptionVerbose: Verbose := True;
    end;

  ExitStatus := 0;
  if DirectoryMode then
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('missing operand', []);
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      if not MakeDirectories(Parser.Operands[Index]) or
         not ApplyAttributes(Parser.Operands[Index], True, -1) then
        ExitStatus := 1;
    end;
    Halt(ExitStatus);
  end;

  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);
  SourceCount := Parser.OperandCount;
  if TargetDirectory = nil then
  begin
    if Parser.OperandCount = 1 then
      FailWithUsageHint('missing destination file operand after ''%s''', [ArgumentText(Parser.Operands[0])]);
    SourceCount := Parser.OperandCount - 1;
    Target := Parser.Operands[SourceCount];
    if NoTargetDirectory or ((SourceCount = 1) and not IsDirectory(Target)) then
    begin
      if SourceCount > 1 then
        FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
      if CreateParents then
      begin
        Parent := DirectoryName(Target);
        if not MakeDirectories(Parent) then
          Halt(1);
        FreeMemory(Parent);
      end;
      if InstallFile(Parser.Operands[0], Target) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;
  if CreateParents and not MakeDirectories(TargetDirectory) then
    Halt(1);
  if not IsDirectory(TargetDirectory) then
    Fail(1, 'target ''%s'' is not a directory', [ArgumentText(TargetDirectory)]);
  for Index := 0 to SourceCount - 1 do
  begin
    Base := BaseName(Parser.Operands[Index]);
    Target := JoinPath(TargetDirectory, Base);
    if not InstallFile(Parser.Operands[Index], Target) then
      ExitStatus := 1;
    FreeMemory(Base);
    FreeMemory(Target);
  end;
  Halt(ExitStatus);
end.
