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
  Locking the screen and suspending, for the Start menu and the keys
  Super+L and Ctrl+Alt+L.

  Both are the session manager's (Windowing.Sessions): it shows the
  lock screen and checks the password (it can read the passwords; the
  user cannot), and it may ask the kernel to suspend (only root may). A
  desktop started by hand, with no session manager, cannot lock the
  screen, and suspends only if its user is root.
}
unit Desktop.Locking;

{$mode objfpc}
{$H+}

interface

{ Asks the session manager to lock the screen. }
procedure LockDesktop;
{ Asks the session manager to suspend the computer to RAM. }
procedure SuspendComputer;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Windowing.Sessions,
  Desktop.Report;

procedure LockDesktop;
var
  Error: LongInt;
begin
  Say('locking');
  Error := AskSessionManager(SessionRequestLock);
  if Error <> ErrorNone then
    ShowMessageBox('Lock', 'The screen could not be locked: ' + string(ErrorMessage(Error)) + '.', MessageOk,
      SignError);
end;

procedure SuspendComputer;
var
  Status: Int64;
begin
  Say('suspending');
  if AskSessionManager(SessionRequestSuspend) = ErrorNone then
    Exit;
  { Without a session manager (a desktop started by hand) the kernel is
    asked directly, which only root may. }
  Status := KernelSuspend;
  if Status < 0 then
    ShowMessageBox('Suspend', 'The computer could not be suspended: ' + string(ErrorMessage(ErrorCodeOf(Status))) +
      '.', MessageOk, SignError);
end;

end.
