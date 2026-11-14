{
  cp - copy files and directories

  cp [-afinPrRTv] SOURCE DEST
  cp [-afinPrRv] SOURCE... DIRECTORY
  cp [-afinPrRv] -t DIRECTORY SOURCE...
}
program cp;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Util.FileTree,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: cp [OPTION]... [-T] SOURCE DEST'#10 +
    '  or:  cp [OPTION]... SOURCE... DIRECTORY'#10 +
    '  or:  cp [OPTION]... -t DIRECTORY SOURCE...'#10 +
    'Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.'#10 +
    #10 +
    '  -a, --archive                same as -dR --preserve'#10 +
    '  -d, -P, --no-dereference     never follow symbolic links in SOURCE'#10 +
    '  -f, --force                  overwrite existing files (the default)'#10 +
    '  -n, --no-clobber             do not overwrite an existing file'#10 +
    '  -p, --preserve               keep mode, ownership and timestamps'#10 +
    '  -R, -r, --recursive          copy directories recursively'#10 +
    '  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY'#10 +
    '  -T, --no-target-directory    treat DEST as a normal file'#10 +
    '  -v, --verbose                explain what is being done'#10;

  OptionArchive = 1;
  OptionNoDereference = 2;
  OptionForce = 3;
  OptionNoClobber = 4;
  OptionRecursive = 5;
  OptionTargetDirectory = 6;
  OptionNoTargetDirectory = 7;
  OptionVerbose = 8;
  OptionPreserve = 9;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Options: TCopyOptions;
  TargetDirectory: PChar;
  NoTargetDirectory: Boolean;
  SourceCount: Integer;
  Index: Integer;
  Base: PChar;
  Target: PChar;
  ExitStatus: LongInt;
begin
  Options.Recursive := False;
  Options.KeepLinks := False;
  Options.NoClobber := False;
  Options.Verbose := False;
  Options.PreserveAttributes := False;
  TargetDirectory := nil;
  NoTargetDirectory := False;
  BeginOptions(Parser, [
    OptionDefinition('a', 'archive', False, OptionArchive),
    OptionDefinition('d', nil, False, OptionNoDereference),
    OptionDefinition('P', 'no-dereference', False, OptionNoDereference),
    OptionDefinition('f', 'force', False, OptionForce),
    OptionDefinition('n', 'no-clobber', False, OptionNoClobber),
    OptionDefinition('R', 'recursive', False, OptionRecursive),
    OptionDefinition('r', nil, False, OptionRecursive),
    OptionDefinition('t', 'target-directory', True, OptionTargetDirectory),
    OptionDefinition('T', 'no-target-directory', False, OptionNoTargetDirectory),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('p', 'preserve', False, OptionPreserve)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionArchive:
        begin
          Options.Recursive := True;
          Options.KeepLinks := True;
          Options.PreserveAttributes := True;
        end;
      OptionPreserve: Options.PreserveAttributes := True;
      OptionNoDereference: Options.KeepLinks := True;
      OptionForce: Options.NoClobber := False;
      OptionNoClobber: Options.NoClobber := True;
      OptionRecursive:
        begin
          Options.Recursive := True;
          { Like GNU cp, -R copies links inside the tree as links. }
          Options.KeepLinks := True;
        end;
      OptionTargetDirectory: TargetDirectory := Value;
      OptionNoTargetDirectory: NoTargetDirectory := True;
      OptionVerbose: Options.Verbose := True;
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
      if CopyPath(Parser.Operands[0], Target, Options) then
        Halt(0);
      Halt(1);
    end;
    TargetDirectory := Target;
  end;

  if not IsDirectory(TargetDirectory) then
    Fail(1, 'target ''%s'' is not a directory', [ArgumentText(TargetDirectory)]);
  ExitStatus := 0;
  for Index := 0 to SourceCount - 1 do
  begin
    Base := BaseName(Parser.Operands[Index]);
    Target := JoinPath(TargetDirectory, Base);
    if not CopyPath(Parser.Operands[Index], Target, Options) then
      ExitStatus := 1;
    FreeMemory(Base);
    FreeMemory(Target);
  end;
  Halt(ExitStatus);
end.
