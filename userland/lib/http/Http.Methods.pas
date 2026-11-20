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
  Request methods (RFC 9110 section 9): a method is a token, compared
  with case; the standard ones are normalized to upper case as Fetch
  does (DELETE, GET, HEAD, OPTIONS, POST, PUT); safe and idempotent
  ones are known (a request that may be repeated after a connection
  broke is idempotent).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Methods;

{$mode objfpc}
{$H+}

interface

const
  MethodGet = 'GET';
  MethodHead = 'HEAD';
  MethodPost = 'POST';
  MethodPut = 'PUT';
  MethodDelete = 'DELETE';
  MethodOptions = 'OPTIONS';

function IsMethodValid(const Method: string): Boolean;
function NormalizeMethod(const Method: string): string;
function MethodIsSafe(const Method: string): Boolean;
function MethodIsIdempotent(const Method: string): Boolean;

implementation

uses
  SysUtils,
  Http.FieldValues;

function IsMethodValid(const Method: string): Boolean;
begin
  Result := IsToken(Method);
end;

function NormalizeMethod(const Method: string): string;
var
  Upper: string;
begin
  Upper := UpperCase(Method);
  if (Upper = 'DELETE') or (Upper = 'GET') or (Upper = 'HEAD') or (Upper = 'OPTIONS') or (Upper = 'POST') or
     (Upper = 'PUT') then
    Result := Upper
  else
    Result := Method;
end;

function MethodIsSafe(const Method: string): Boolean;
begin
  Result := (Method = 'GET') or (Method = 'HEAD') or (Method = 'OPTIONS') or (Method = 'TRACE');
end;

function MethodIsIdempotent(const Method: string): Boolean;
begin
  Result := MethodIsSafe(Method) or (Method = 'PUT') or (Method = 'DELETE');
end;

end.
