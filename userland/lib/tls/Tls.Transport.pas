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
  What a TLS connection runs over: two routines that move bytes, so the
  protocol code does not care whether they go through a socket
  (Tls.SocketTransport) or a test's memory.

  Send writes all Length bytes and returns Length, or a TlsError code.
  Receive waits for at least one byte and returns how many it read
  (at most Length), 0 at the end of the stream, or a TlsError code
  (TlsErrorTimedOut when the peer is silent too long).
}
unit Tls.Transport;

{$mode objfpc}

interface

type
  TTlsSendRoutine = function(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
  TTlsReceiveRoutine = function(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;

  TTlsTransport = record
    Context: Pointer;
    Send: TTlsSendRoutine;
    Receive: TTlsReceiveRoutine;
  end;

implementation

end.
