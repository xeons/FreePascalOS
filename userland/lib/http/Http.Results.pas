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
  How a request (or a piece of one) ended: success, or which failure,
  with the words for it (the resolver's, the socket's or TLS's message,
  or the protocol problem) and the system or TLS error code behind it.
  HTTP error statuses (404, 500) are responses, not failures.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Results;

{$mode objfpc}
{$H+}

interface

type
  THttpResultCode = (
    HttpSuccess,
    { The host's addresses could not be found. }
    HttpLookupFailed,
    HttpConnectFailed,
    { Connecting or waiting for the server took longer than allowed. }
    HttpTimedOut,
    HttpTlsFailed,
    HttpCertificateFailed,
    HttpSendFailed,
    { A connection ended before any response came. }
    HttpNoResponse,
    HttpReadFailed,
    HttpMalformedResponse,
    HttpUnsupportedTransferCoding,
    HttpHeadTooLarge,
    { The body ended before its length said (the connection closed). }
    HttpBodyEndedEarly,
    HttpMalformedBody,
    HttpDecodeFailed,
    HttpWriteFailed,
    HttpTooManyRedirects,
    HttpRedirectRefused,
    { The peer reset the request or refused it (HTTP/2 RST_STREAM,
      GOAWAY); Retryable says whether it was never processed. }
    HttpStreamReset,
    HttpProtocolError,
    HttpCanceled,
    { only-if-cached and nothing in the cache. }
    HttpNotCached,
    HttpUnsupportedScheme);

  THttpResult = record
    Code: THttpResultCode;
    Text: string;
    { The system's or libtls's error code, if one was behind it. }
    ErrorCode: LongInt;
    { The request can go again on another connection unchanged (it was
      refused before the server acted on it). }
    Retryable: Boolean;
  end;

function HttpOk: THttpResult;
function HttpFailure(Code: THttpResultCode; const Text: string; ErrorCode: LongInt = 0): THttpResult;
function HttpSucceeded(constref Result_: THttpResult): Boolean;

implementation

function HttpOk: THttpResult;
begin
  Result := Default(THttpResult);
end;

function HttpFailure(Code: THttpResultCode; const Text: string; ErrorCode: LongInt): THttpResult;
begin
  Result := Default(THttpResult);
  Result.Code := Code;
  Result.Text := Text;
  Result.ErrorCode := ErrorCode;
end;

function HttpSucceeded(constref Result_: THttpResult): Boolean;
begin
  Result := Result_.Code = HttpSuccess;
end;

end.
