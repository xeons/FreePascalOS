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
  login - log a user in on a terminal

  login [-a] [-f USER] [-e PROGRAM]

  Asks for a user name and a password on standard input (on a terminal
  the password is not shown), up to three times, and runs the user's
  shell as that user - their user and group ids and supplementary
  groups from /etc/passwd and /etc/group, HOME, SHELL, USER, LOGNAME,
  PATH and TERM, in their home directory - then waits for it. On a
  terminal the shell is interactive and has the terminal's foreground.
  The service manager runs login on the console (Util.Logins has the
  details); it must run as root.

    -a          log in the user the kernel option autologin= names
                without asking (when it names one): the text mode's
                automatic login
    -f USER     log USER in without a password
    -e PROGRAM  run PROGRAM instead of the user's shell

  Exits with the status of the user's program, or 1 when nobody logged
  in (end of input, or three wrong tries).
}
program login;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Processes,
  Sys.Streams,
  Util.Accounts,
  Util.CommandLine,
  Util.Commands,
  Util.Input,
  Util.Logins,
  Util.Messages,
  Util.Output,
  Util.Passwords;

const
  Usage = 'Usage: login [-a] [-f USER] [-e PROGRAM]'#10 +
    'Log a user in and run their shell.'#10#10 +
    '  -a          log in the user the kernel option autologin= names'#10 +
    '  -f USER     log USER in without a password'#10 +
    '  -e PROGRAM  run PROGRAM instead of the user''s shell'#10;
  Prompt = 'fpos login: ';
  OptionAutomatic = 1;
  OptionUser = 2;
  OptionProgram = 3;
  MaximumTries = 3;
  PauseAfterWrongMilliseconds = 1000;
  StatusNobodyLoggedIn = 1;

var
  Automatic: Boolean;
  GivenUser: string;
  HasGivenUser: Boolean;
  ProgramPath: string;
  HasProgramPath: Boolean;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  Automatic := False;
  HasGivenUser := False;
  HasProgramPath := False;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'automatic', False, OptionAutomatic),
    CommandOption('f', '', True, OptionUser),
    CommandOption('e', 'program', True, OptionProgram)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionAutomatic: Automatic := True;
        OptionUser:
          begin
            GivenUser := Value;
            HasGivenUser := True;
          end;
        OptionProgram:
          begin
            ProgramPath := Value;
            HasProgramPath := True;
          end;
      end;
    if CommandLine.OperandCount > 0 then
      FailWithUsageHint('no operands are taken');
  finally
    CommandLine.Free;
  end;
end;

{ A line typed for Prompt; False at the end of input. }
function AskForName(out Name: string): Boolean;
var
  HadLineEnd: Boolean;
begin
  PrintString(Prompt);
  FlushStream(StandardOutput);
  Result := ReadTextLine(StandardInput, Name, HadLineEnd);
end;

{ Overwrites a password in memory once it has been checked. }
procedure ErasePassword(var Password: string);
begin
  if Password = '' then
    Exit;
  UniqueString(Password);
  FillChar(Password[1], Length(Password), 0);
  Password := '';
end;

{ Asks until someone gives a right name and password. False at the end
  of input or after MaximumTries. }
function AskForAccount(out Account: TLoginAccount): Boolean;
var
  Attempt: Integer;
  Name: string;
  Password: string;
  Known: Boolean;
  Right: Boolean;
begin
  Result := False;
  for Attempt := 1 to MaximumTries do
  begin
    if not AskForName(Name) then
      Exit;
    { An empty line asks again, and is not a wrong try. }
    if Name = '' then
      Continue;
    Known := FindLoginAccount(PChar(Name), Account);
    if not ReadPassword('Password: ', Password) then
      Exit;
    Right := Known and PasswordIsRight(Account, PChar(Password));
    ErasePassword(Password);
    if Right then
      Exit(True);
    PrintStringLine('Login incorrect');
    FlushStream(StandardOutput);
    SleepMilliseconds(PauseAfterWrongMilliseconds);
  end;
end;

{ The user the kernel option autologin= names; False when none is named. }
function AutomaticLoginName(out Name: string): Boolean;
var
  Buffer: array[0..LoginNameCapacity - 1] of Char;
begin
  Result := AutomaticLoginUser(@Buffer[0], LoginNameCapacity);
  if Result then
    Name := PChar(@Buffer[0])
  else
    Name := '';
end;

{ The account to log in: given, automatic, or asked for. }
function ChooseAccount(out Account: TLoginAccount): Boolean;
var
  AutomaticName: string;
begin
  if HasGivenUser then
  begin
    if not FindLoginAccount(PChar(GivenUser), Account) then
      Fail(StatusNobodyLoggedIn, Format('user %s does not exist', [GivenUser]));
    Exit(True);
  end;
  if Automatic and AutomaticLoginName(AutomaticName) then
  begin
    if FindLoginAccount(PChar(AutomaticName), Account) then
      Exit(True);
    Report(Format('automatic login: user %s does not exist', [AutomaticName]));
  end;
  Result := AskForAccount(Account);
end;

function RunUserProgram(const Account: TLoginAccount): LongInt;
var
  Arguments: TTextVector;
  Shell: string;
  Options: TProcessOptions;
  Environment: TLoginEnvironment;
  OnTerminal: Boolean;
  Process: Int64;
begin
  OnTerminal := IsConsole(StandardInputHandle);
  DefaultProcessOptions(Options);
  Shell := PChar(@Account.Shell[0]);
  if HasProgramPath then
    Arguments := TextVector([ProgramPath])
  else if OnTerminal then
    Arguments := TextVector([Shell, '-i'])
  else
    Arguments := TextVector([Shell]);
  { On a terminal the user's program has its foreground; Ctrl-C there
    must not end login, which waits for it. }
  if OnTerminal then
    Options.GroupId := GroupNewInForeground;
  IgnoreInterrupts(True);
  Process := StartAsUser(Account, Arguments[0], PPChar(@Arguments[0]), Options, Environment);
  if Process < 0 then
    FailWithError(StatusNobodyLoggedIn, LongInt(-Process), Format('cannot run %s', [string(Arguments[0])]));
  Result := WaitForProgram(Process);
end;

var
  Account: TLoginAccount;
begin
  ReadOptions;
  if CurrentUserId <> RootId then
    Fail(StatusNobodyLoggedIn, 'only root may log users in');
  if not ChooseAccount(Account) then
    Halt(StatusNobodyLoggedIn);
  Halt(RunUserProgram(Account));
end.
