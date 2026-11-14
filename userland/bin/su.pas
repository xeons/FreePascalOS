{
  su - run a command with a substitute user and group ID

  su [-] [-l] [-m] [-s SHELL] [-c COMMAND] [USER]

  Becomes USER (root by default) and runs its shell, or "SHELL -c
  COMMAND". Callers other than root must type USER's password (checked
  against /etc/shadow, see Util.Passwords); su is installed set-user-ID
  root so that it can read that file and change ids.

  HOME, SHELL, USER and LOGNAME are set for the new user unless -m is
  given; with - or -l the command starts in USER's home directory.
}
program su;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Util.Accounts,
  Util.Commands,
  Util.Messages,
  Util.Options,
  Util.Passwords;

const
  Usage: PChar = 'Usage: su [OPTION]... [-] [USER]'#10 +
    'Change the effective user ID and group ID to that of USER (root by default).'#10#10 +
    '  -, -l, --login                 start in USER''s home directory'#10 +
    '  -c, --command=COMMAND          pass COMMAND to the shell with -c'#10 +
    '  -m, -p, --preserve-environment do not reset environment variables'#10 +
    '  -s, --shell=SHELL              run SHELL instead of USER''s shell'#10;

  OptionLogin = 1;
  OptionCommand = 2;
  OptionPreserve = 3;
  OptionShell = 4;
  MaximumGroups = 32;
  StatusFailed = 1;
  StatusCannotRun = 126;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Login: Boolean;
  Preserve: Boolean;
  Command: PChar;
  Shell: PChar;
  TargetName: PChar;
  TargetId: LongWord;
  TargetGroup: LongWord;
  Groups: array[0..MaximumGroups - 1] of LongWord;
  GroupCount: Integer;
  Password: PChar;
  Check: TPasswordCheck;
  Arguments: array[0..3] of PChar;
  Options: TProcessOptions;
  Index: Integer;
  Home: PChar;
begin
  Login := False;
  Preserve := False;
  Command := nil;
  Shell := nil;
  BeginOptions(Parser, [
    OptionDefinition('l', 'login', False, OptionLogin),
    OptionDefinition('c', 'command', True, OptionCommand),
    OptionDefinition('m', 'preserve-environment', False, OptionPreserve),
    OptionDefinition('p', nil, False, OptionPreserve),
    OptionDefinition('s', 'shell', True, OptionShell)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionLogin: Login := True;
      OptionCommand: Command := Value;
      OptionPreserve: Preserve := True;
      OptionShell: Shell := Value;
    end;

  TargetName := nil;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if TextIsEqual(Parser.Operands[Index], '-') then
      Login := True
    else if TargetName = nil then
      TargetName := Parser.Operands[Index]
    else
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[Index])]);
  end;
  if TargetName = nil then
    TargetName := 'root';

  if not FindUserId(TargetName, TargetId) or (UserNameOf(TargetId) = nil) then
    Fail(StatusFailed, 'user %s does not exist', [ArgumentText(TargetName)]);
  TargetName := UserNameOf(TargetId);
  if not PrimaryGroupOf(TargetId, TargetGroup) then
    TargetGroup := TargetId;

  { Root may become anyone; others must know the password. }
  if CurrentRealUserId <> RootId then
  begin
    Check := CheckPassword(TargetName, '');
    if Check <> PasswordAccepted then
    begin
      Password := ReadPassword('Password: ');
      if Password = nil then
        Check := PasswordRejected
      else
      begin
        Check := CheckPassword(TargetName, Password);
        ZeroMemory(Password, TextLength(Password));
        FreeMemory(Password);
      end;
    end;
    if Check <> PasswordAccepted then
      Fail(StatusFailed, 'Authentication failure', []);
  end;

  GroupCount := GroupsOfUser(TargetId, @Groups[0], MaximumGroups);
  if (KernelSetGroups(LongWord(GroupCount), @Groups[0]) < 0) or
     (KernelSetGroupIds(TargetGroup, TargetGroup, TargetGroup) < 0) or
     (KernelSetUserIds(TargetId, TargetId, TargetId) < 0) then
    Fail(StatusFailed, 'cannot set user id: %s', [ArgumentText(ErrorMessage(ErrorNotPermitted))]);

  if Shell = nil then
    Shell := ShellOf(TargetId);
  Home := HomeDirectoryOf(TargetId);
  if Home = nil then
    Home := '/';
  if not Preserve then
  begin
    SetVariable('HOME', Home);
    SetVariable('SHELL', Shell);
    SetVariable('USER', TargetName);
    SetVariable('LOGNAME', TargetName);
  end;

  DefaultProcessOptions(Options);
  if Login then
    Options.WorkingDirectory := Home;
  Arguments[0] := Shell;
  if Command <> nil then
  begin
    Arguments[1] := '-c';
    Arguments[2] := Command;
    Arguments[3] := nil;
  end
  else
  begin
    Arguments[1] := '-i';
    Arguments[2] := nil;
  end;
  RunCommandAndExit(@Arguments[0], Options);
end.
