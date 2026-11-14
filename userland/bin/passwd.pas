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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Accounts,
  Util.Messages,
  Util.Options,
  Util.Passwords;

const
  Usage: PChar = 'Usage: passwd [USER]'#10 +
    'Change the password of USER (by default, the user running passwd).'#10;
  StatusFailed = 1;

procedure Forget(var Text: PChar);
begin
  if Text = nil then
    Exit;
  ZeroMemory(Text, TextLength(Text));
  FreeMemory(Text);
  Text := nil;
end;

var
  Parser: TOptionParser;
  TargetId: LongWord;
  TargetName: PChar;
  Current: PChar;
  NewPassword: PChar;
  Repeated: PChar;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if Parser.OperandCount = 1 then
  begin
    if not FindUserId(Parser.Operands[0], TargetId) or (UserNameOf(TargetId) = nil) then
      Fail(StatusFailed, 'user ''%s'' does not exist', [ArgumentText(Parser.Operands[0])]);
  end
  else
    TargetId := CurrentRealUserId;
  TargetName := UserNameOf(TargetId);
  if TargetName = nil then
    Fail(StatusFailed, 'cannot find name for user ID %u', [ArgumentUnsigned(TargetId)]);

  if CurrentRealUserId <> RootId then
  begin
    if TargetId <> CurrentRealUserId then
      Fail(StatusFailed, 'You may not view or modify password information for %s.', [ArgumentText(TargetName)]);
    if not HasEmptyPassword(TargetName) then
    begin
      Current := ReadPassword('Current password: ');
      if (Current = nil) or (CheckPassword(TargetName, Current) <> PasswordAccepted) then
      begin
        Forget(Current);
        Fail(StatusFailed, 'Authentication token manipulation error', []);
      end;
      Forget(Current);
    end;
  end;

  WriteFormatted(StandardOutput, 'Changing password for %s.'#10, [ArgumentText(TargetName)]);
  FlushStream(StandardOutput);
  NewPassword := ReadPassword('New password: ');
  Repeated := ReadPassword('Retype new password: ');
  if (NewPassword = nil) or (Repeated = nil) or not TextIsEqual(NewPassword, Repeated) then
  begin
    Forget(NewPassword);
    Forget(Repeated);
    Fail(StatusFailed, 'Passwords do not match', []);
  end;
  Error := SetPassword(TargetName, NewPassword);
  Forget(NewPassword);
  Forget(Repeated);
  if Error <> ErrorNone then
    FailWithError(StatusFailed, Error, 'cannot update ''%s''', [ArgumentText(ShadowPath)]);
  PrintLine('passwd: password updated successfully');
end.
