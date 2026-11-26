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
  Where service workers meet the fetch layer (Service Workers, "Handle
  Fetch"; Fetch Standard, HTTP fetch step 5): the fetcher offers every
  http and https request that may be intercepted (not a redirect's, not
  one with service workers' mode "none") to ServiceWorkerFetchHook. The
  hook (Web.Workers.ServiceWorkers) answers True when a service worker
  takes it - a navigation whose URL is in an active registration's
  scope, or a request of a controlled client - and later calls the
  fetcher back on the fetcher's own loop: RespondFromServiceWorker,
  ContinueWithoutServiceWorker or FailFromServiceWorker. FetcherGone
  drops what waits for a fetcher that is freed.

  NewClientId makes the ids of environments (Client.id): a random UUID.
}
unit Web.Fetch.ServiceWorkerHook;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.EventLoop,
  Web.Fetch.Requests;

type
  TServiceWorkerFetchHook = class
  public
    { Fetcher: the TFetcher asking, Loop its loop; Referrer: the
      request's computed Referer ('' for none). }
    function Intercept(Fetcher: TObject; Loop: TEventLoop; JobId: QWord; Request: TFetchRequest;
      const Referrer: string): Boolean; virtual; abstract;
    procedure FetcherGone(Fetcher: TObject); virtual; abstract;
  end;

var
  ServiceWorkerFetchHook: TServiceWorkerFetchHook;

{ A new random (version 4) UUID in its text form. }
function NewClientId: string;

implementation

uses
  Crypto.Random;

function NewClientId: string;
const
  Digits: array[0..15] of Char = '0123456789abcdef';
var
  Bytes: array[0..15] of Byte;
  Index: Integer;
begin
  RandomBytes(@Bytes[0], SizeOf(Bytes));
  Bytes[6] := (Bytes[6] and $0F) or $40;
  Bytes[8] := (Bytes[8] and $3F) or $80;
  Result := '';
  for Index := 0 to 15 do
  begin
    if Index in [4, 6, 8, 10] then
      Result := Result + '-';
    Result := Result + Digits[Bytes[Index] shr 4] + Digits[Bytes[Index] and 15];
  end;
end;

end.
