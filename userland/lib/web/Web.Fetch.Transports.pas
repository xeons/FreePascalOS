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
  The network when it is in another process. A browser's content
  process (a renderer) never opens a socket or a file itself: its
  network context (Web.Fetch.NetworkContexts) has a transport instead
  of an HTTP client, which hands each HTTP exchange ("hop": one request,
  its redirects decided by the fetcher here), each local file and each
  document.cookie to the browser's network service and brings the
  answers back. Everything the fetcher decides (CORS, mixed content,
  CSP, referrers, redirects, sniffing) is still decided here; the
  browser keeps the cookie jar, the HTTP cache, the connections and the
  HSTS list, and refuses what the process's site may not have.
}
unit Web.Fetch.Transports;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.Records,
  Http.Messages,
  Http.HeaderFields,
  Http.Results;

type
  { Hears one hop's results, from any thread (THopRunner). }
  THopResultSink = class
  public
    procedure HopHead(HopId: QWord; Status: Integer; const Reason: string; const Fields: THttpHeaderFieldArray;
      constref Url: TUrlRecord; FromCache: Boolean; const Protocol: string); virtual; abstract;
    procedure HopData(HopId: QWord; Data: Pointer; Count: PtrUInt); virtual; abstract;
    procedure HopDone(HopId: QWord; constref Outcome: THttpResult); virtual; abstract;
  end;

  TNetworkTransport = class
  public
    { Sends Request (taken over) as Sink's hop HopId. Its head, body and
      outcome come to Sink; the outcome always comes, once. }
    procedure StartHop(Request: THttpRequest; HopId: QWord; Urgent: Boolean; Sink: THopResultSink); virtual; abstract;
    { Stops the hop: its outcome (canceled) comes at once, nothing after. }
    procedure CancelHop(Sink: THopResultSink; HopId: QWord); virtual; abstract;
    { Sink is going: nothing more is told to it. }
    procedure ForgetSink(Sink: THopResultSink); virtual; abstract;
    { document.cookie for a document at Url. }
    function DocumentCookie(constref Url: TUrlRecord; Secure: Boolean): string; virtual; abstract;
    procedure SetDocumentCookie(constref Url: TUrlRecord; const Cookie: string; Secure: Boolean); virtual; abstract;
    { A file: URL's contents (a folder: the folder's index page as HTML);
      False with Error when it cannot be read or may not be. }
    function ReadLocalFile(constref Url: TUrlRecord; out Contents: TBytes; out IsFolder: Boolean;
      out Error: string): Boolean; virtual; abstract;
  end;

implementation

end.
