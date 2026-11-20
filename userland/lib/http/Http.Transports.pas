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
  The byte stream an HTTP/1.1 or HTTP/2 connection runs over: a TCP
  connection, with TLS for https (Http.SocketTransports), or anything
  else that moves bytes (the host test's in-memory pipes). HTTP/3 runs
  over QUIC instead and does not use this.

  Read waits at most TimeoutMilliseconds (0: no limit) and returns the
  bytes read, 0 at the end of the stream, or -1 on a failure (Failure
  and ErrorText say which); Write sends everything or fails. Shutdown
  wakes a thread blocked in Read (cancelation from another thread).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Transports;

{$mode objfpc}
{$H+}

interface

type
  THttpTransportFailure = (TransportFailureNone, TransportFailureTimeout, TransportFailureTransfer,
    TransportFailureTls, TransportFailureClosed);

  THttpTransport = class
  protected
    FTimeoutMilliseconds: Int64;
    FFailure: THttpTransportFailure;
    FErrorCode: LongInt;
    FErrorText: string;
    FNegotiatedProtocol: string;
    procedure SetFailure(Failure: THttpTransportFailure; Code: LongInt; const Text: string);
  public
    function Read(Buffer: Pointer; Count: PtrUInt): Int64; virtual; abstract;
    function Write(Buffer: Pointer; Count: PtrUInt): Boolean; virtual; abstract;
    { Ends the stream; a Read blocked in another thread returns. }
    procedure Shutdown; virtual; abstract;
    { Sends what ends the stream cleanly (TLS close_notify) and closes. }
    procedure Close; virtual; abstract;
    property TimeoutMilliseconds: Int64 read FTimeoutMilliseconds write FTimeoutMilliseconds;
    { The ALPN protocol the server chose ("h2", "http/1.1"), or ''. }
    property NegotiatedProtocol: string read FNegotiatedProtocol;
    property Failure: THttpTransportFailure read FFailure;
    property ErrorCode: LongInt read FErrorCode;
    property ErrorText: string read FErrorText;
  end;

implementation

procedure THttpTransport.SetFailure(Failure: THttpTransportFailure; Code: LongInt; const Text: string);
begin
  FFailure := Failure;
  FErrorCode := Code;
  FErrorText := Text;
end;

end.
