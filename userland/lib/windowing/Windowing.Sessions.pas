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
  Asking the session manager (userland/sessionmanager) to end the
  session or the system.

  The session manager logs a user in on the screen and runs their
  desktop. It serves the port "session"; the desktop's Start menu asks
  it to log off (every program of the session is ended, and the login
  window comes back) or to shut down or restart (the session manager
  runs as root, so a user at the screen may turn the computer off, as
  they could with its power button). Only the session's own user (or
  root) is listened to. Each request is one TSessionRequest answered by
  one TSessionReply.
}
unit Windowing.Sessions;

{$mode objfpc}

interface

const
  SessionPortName = 'session';

  SessionRequestLogOff = 1;
  SessionRequestPowerOff = 2;
  SessionRequestReboot = 3;

type
  TSessionRequest = record
    Code: LongWord;
    Reserved: LongWord;
  end;

  TSessionReply = record
    Error: LongInt;
    Reserved: LongWord;
  end;

{ Sends Code to the session manager and waits for its answer: ErrorNone,
  its refusal, or an error when there is no session manager (a desktop
  started by hand). }
function AskSessionManager(Code: LongWord): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects;

const
  ReplyTimeoutMilliseconds = 10000;

function AskSessionManager(Code: LongWord): LongInt;
var
  Request: TSessionRequest;
  Reply: TSessionReply;
  Channel: Int64;
  ReplyLength: QWord;
begin
  Request.Code := Code;
  Request.Reserved := 0;
  Channel := ConnectPort(SessionPortName);
  if Channel < 0 then
    Exit(ErrorCodeOf(Channel));
  Result := CallChannel(Channel, @Request, SizeOf(Request), @Reply, SizeOf(Reply), ReplyLength,
    ReplyTimeoutMilliseconds);
  CloseHandle(Channel);
  if Result <> ErrorNone then
    Exit;
  if ReplyLength < SizeOf(Reply) then
    Exit(ErrorIo);
  Result := Reply.Error;
end;

end.
