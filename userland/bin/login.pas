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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Console,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Util.Accounts,
  Util.Logins,
  Util.Messages,
  Util.Options,
  Util.Passwords;

const
  Usage: PChar = 'Usage: login [-a] [-f USER] [-e PROGRAM]'#10 +
    'Log a user in and run their shell.'#10#10 +
    '  -a          log in the user the kernel option autologin= names'#10 +
    '  -f USER     log USER in without a password'#10 +
    '  -e PROGRAM  run PROGRAM instead of the user''s shell'#10;
  Prompt: PChar = 'fpos login: ';
  OptionAutomatic = 1;
  OptionUser = 2;
  OptionProgram = 3;
  MaximumTries = 3;
  PauseAfterWrongMilliseconds = 1000;
  StatusNobodyLoggedIn = 1;

var
  Automatic: Boolean;
  GivenUser: PChar;
  ProgramPath: PChar;

procedure ReadOptions;
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
begin
  Automatic := False;
  GivenUser := nil;
  ProgramPath := nil;
  BeginOptions(Parser, [
    OptionDefinition('a', 'automatic', False, OptionAutomatic),
    OptionDefinition('f', nil, True, OptionUser),
    OptionDefinition('e', 'program', True, OptionProgram)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAutomatic: Automatic := True;
      OptionUser: GivenUser := Value;
      OptionProgram: ProgramPath := Value;
    end;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('no operands are taken', []);
end;

{ A line typed for Prompt; nil at the end of input. The caller frees it. }
function AskForName: PChar;
var
  HadLineEnd: Boolean;
begin
  WriteText(StandardOutput, Prompt);
  FlushStream(StandardOutput);
  if not ReadLine(StandardInput, Result, HadLineEnd) then
    Result := nil;
end;

{ Asks until someone gives a right name and password. False at the end
  of input or after MaximumTries. }
function AskForAccount(out Account: TLoginAccount): Boolean;
var
  Attempt: Integer;
  Name: PChar;
  Password: PChar;
  Known: Boolean;
  Right: Boolean;
begin
  Result := False;
  for Attempt := 1 to MaximumTries do
  begin
    Name := AskForName;
    if Name = nil then
      Exit;
    if Name^ = #0 then
    begin
      { An empty line asks again, and is not a wrong try. }
      FreeMemory(Name);
      Continue;
    end;
    Known := FindLoginAccount(Name, Account);
    FreeMemory(Name);
    Password := ReadPassword('Password: ');
    if Password = nil then
      Exit;
    Right := Known and PasswordIsRight(Account, Password);
    ZeroMemory(Password, TextLength(Password));
    FreeMemory(Password);
    if Right then
      Exit(True);
    WriteLine(StandardOutput, 'Login incorrect');
    FlushStream(StandardOutput);
    SleepMilliseconds(PauseAfterWrongMilliseconds);
  end;
end;

{ The account to log in: given, automatic, or asked for. }
function ChooseAccount(out Account: TLoginAccount): Boolean;
var
  AutomaticName: array[0..LoginNameCapacity - 1] of Char;
begin
  if GivenUser <> nil then
  begin
    if not FindLoginAccount(GivenUser, Account) then
      Fail(StatusNobodyLoggedIn, 'user %s does not exist', [ArgumentText(GivenUser)]);
    Exit(True);
  end;
  if Automatic and AutomaticLoginUser(@AutomaticName[0], LoginNameCapacity) then
  begin
    if FindLoginAccount(@AutomaticName[0], Account) then
      Exit(True);
    Report('automatic login: user %s does not exist', [ArgumentText(@AutomaticName[0])]);
  end;
  Result := AskForAccount(Account);
end;

function RunUserProgram(const Account: TLoginAccount): LongInt;
var
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Environment: TLoginEnvironment;
  OnTerminal: Boolean;
  Process: Int64;
begin
  OnTerminal := IsConsole(StandardInputHandle);
  DefaultProcessOptions(Options);
  if ProgramPath <> nil then
  begin
    Arguments[0] := ProgramPath;
    Arguments[1] := nil;
  end
  else
  begin
    Arguments[0] := @Account.Shell[0];
    if OnTerminal then
    begin
      Arguments[1] := '-i';
      Arguments[2] := nil;
    end
    else
      Arguments[1] := nil;
  end;
  { On a terminal the user's program has its foreground; Ctrl-C there
    must not end login, which waits for it. }
  if OnTerminal then
    Options.GroupId := GroupNewInForeground;
  IgnoreInterrupts(True);
  Process := StartAsUser(Account, Arguments[0], @Arguments[0], Options, Environment);
  if Process < 0 then
    FailWithError(StatusNobodyLoggedIn, LongInt(-Process), 'cannot run %s', [ArgumentText(Arguments[0])]);
  Result := WaitForProgram(Process);
end;

var
  Account: TLoginAccount;
begin
  ReadOptions;
  if CurrentUserId <> RootId then
    Fail(StatusNobodyLoggedIn, 'only root may log users in', []);
  if not ChooseAccount(Account) then
    Halt(StatusNobodyLoggedIn);
  Halt(RunUserProgram(Account));
end.
