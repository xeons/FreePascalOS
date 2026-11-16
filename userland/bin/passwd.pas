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
  passwd - change a user's password

  passwd [USER]

  Asks for the current password (unless run by root), then for the new
  one twice, and stores its salted hash in /etc/shadow. Only root may
  change another user's password. passwd is installed set-user-ID root.
}
program passwd;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Memory,
  Sys.Streams,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Util.Output,
  Util.Passwords;

const
  Usage = 'Usage: passwd [USER]'#10 +
    'Change the password of USER (by default, the user running passwd).'#10;
  StatusFailed = 1;

var
  CommandLine: TCommandLine;
  TargetId: LongWord;
  TargetName: string;
  Current: PChar;
  NewPassword: PChar;
  Repeated: PChar;
  Error: LongInt;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if CommandLine.OperandCount = 1 then
  begin
    if not FindUserId(CommandLine.Operands[0], TargetId) or not FindUserName(TargetId, TargetName) then
      Fail(StatusFailed, Format('user ''%s'' does not exist', [CommandLine.Operands[0]]));
  end
  else
    TargetId := CurrentRealUserId;
  if not FindUserName(TargetId, TargetName) then
    Fail(StatusFailed, Format('cannot find name for user ID %u', [TargetId]));

  if CurrentRealUserId <> RootId then
  begin
    if TargetId <> CurrentRealUserId then
      Fail(StatusFailed, Format('You may not view or modify password information for %s.', [TargetName]));
    if not HasEmptyPassword(TargetName) then
    begin
      Current := ReadPassword('Current password: ');
      if (Current = nil) or (CheckPassword(TargetName, Current) <> PasswordAccepted) then
      begin
        ForgetPassword(Current);
        Fail(StatusFailed, 'Authentication token manipulation error');
      end;
      ForgetPassword(Current);
    end;
  end;

  PrintString('Changing password for ' + TargetName + '.'#10);
  FlushStream(StandardOutput);
  NewPassword := ReadPassword('New password: ');
  Repeated := ReadPassword('Retype new password: ');
  if (NewPassword = nil) or (Repeated = nil) or (StrComp(NewPassword, Repeated) <> 0) then
  begin
    ForgetPassword(NewPassword);
    ForgetPassword(Repeated);
    Fail(StatusFailed, 'Passwords do not match');
  end;
  Error := SetPassword(TargetName, NewPassword);
  ForgetPassword(NewPassword);
  ForgetPassword(Repeated);
  if Error <> ErrorNone then
    FailWithError(StatusFailed, Error, Format('cannot update ''%s''', [ShadowPath]));
  PrintStringLine('passwd: password updated successfully');
end.
