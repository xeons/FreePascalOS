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
  Status codes (RFC 9110 section 15): their classes, the reason
  phrases RFC 9110 gives (HTTP/2 and HTTP/3 send none, so responses
  over them get these), and which codes are heuristically cacheable
  (RFC 9111 section 4.2.2).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.StatusCodes;

{$mode objfpc}
{$H+}

interface

function ReasonPhrase(StatusCode: Integer): string;
function StatusIsInformational(StatusCode: Integer): Boolean;
function StatusIsSuccess(StatusCode: Integer): Boolean;
function StatusIsRedirect(StatusCode: Integer): Boolean;
{ True for codes that never have a body (1xx, 204, 304). }
function StatusHasNoBody(StatusCode: Integer): Boolean;
function StatusIsHeuristicallyCacheable(StatusCode: Integer): Boolean;

implementation

function ReasonPhrase(StatusCode: Integer): string;
begin
  case StatusCode of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    103: Result := 'Early Hints';
    200: Result := 'OK';
    201: Result := 'Created';
    202: Result := 'Accepted';
    203: Result := 'Non-Authoritative Information';
    204: Result := 'No Content';
    205: Result := 'Reset Content';
    206: Result := 'Partial Content';
    300: Result := 'Multiple Choices';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    402: Result := 'Payment Required';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    406: Result := 'Not Acceptable';
    407: Result := 'Proxy Authentication Required';
    408: Result := 'Request Timeout';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    411: Result := 'Length Required';
    412: Result := 'Precondition Failed';
    413: Result := 'Content Too Large';
    414: Result := 'URI Too Long';
    415: Result := 'Unsupported Media Type';
    416: Result := 'Range Not Satisfiable';
    417: Result := 'Expectation Failed';
    421: Result := 'Misdirected Request';
    422: Result := 'Unprocessable Content';
    425: Result := 'Too Early';
    426: Result := 'Upgrade Required';
    428: Result := 'Precondition Required';
    429: Result := 'Too Many Requests';
    431: Result := 'Request Header Fields Too Large';
    451: Result := 'Unavailable For Legal Reasons';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
    504: Result := 'Gateway Timeout';
    505: Result := 'HTTP Version Not Supported';
  else
    Result := '';
  end;
end;

function StatusIsInformational(StatusCode: Integer): Boolean;
begin
  Result := (StatusCode >= 100) and (StatusCode < 200);
end;

function StatusIsSuccess(StatusCode: Integer): Boolean;
begin
  Result := (StatusCode >= 200) and (StatusCode < 300);
end;

function StatusIsRedirect(StatusCode: Integer): Boolean;
begin
  Result := (StatusCode = 301) or (StatusCode = 302) or (StatusCode = 303) or (StatusCode = 307) or
    (StatusCode = 308);
end;

function StatusHasNoBody(StatusCode: Integer): Boolean;
begin
  Result := StatusIsInformational(StatusCode) or (StatusCode = 204) or (StatusCode = 304);
end;

function StatusIsHeuristicallyCacheable(StatusCode: Integer): Boolean;
begin
  case StatusCode of
    200, 203, 204, 206, 300, 301, 308, 404, 405, 410, 414, 501: Result := True;
  else
    Result := False;
  end;
end;

end.
