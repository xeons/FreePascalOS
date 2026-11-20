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
  The contents of libhttp.so: the URL Standard (Url.*) and an HTTP
  client (Http.*) speaking HTTP/1.1 and HTTP/2 over TCP and TLS, with
  cookies, a cache, authentication, redirects, content decoding,
  alternative services (where HTTP/3 plugs in) and fetches on threads.
  Compiling this unit compiles all of them.

  Everything but Http.SocketTransports and Http.SocketConnector is
  plain Pascal and builds on the host too (make http-test).
}
unit Http.Contents;

{$mode objfpc}

interface

uses
  Url.Records,
  Url.PercentEncoding,
  Url.IpAddresses,
  Url.Punycode,
  Url.DomainNames,
  Url.Hosts,
  Url.Parser,
  Url.Accessors,
  Url.FormEncoding,
  Url.SearchParams,
  Url.Origins,
  Http.ByteBuffers,
  Http.HeaderFields,
  Http.FieldValues,
  Http.Dates,
  Http.StatusCodes,
  Http.Methods,
  Http.Results,
  Http.Priorities,
  Http.Chunks,
  Http.ResponseHeads,
  Http.RequestBodies,
  Http.BodySinks,
  Http.ContentDecoding,
  Http.HpackHuffman,
  Http.HpackTables,
  Http.HpackDecoder,
  Http.HpackEncoder,
  Http.Transports,
  Http.Connections,
  Http.Http1Connections,
  Http.Http2Frames,
  Http.Http2Streams,
  Http.Http2Connections,
  Http.Observers,
  Http.Connectors,
  Http.ConnectionPool,
  Http.AltServices,
  Http.CookieDates,
  Http.PublicSuffixes,
  Http.Cookies,
  Http.CookieFiles,
  Http.Challenges,
  Http.Digest,
  Http.Authentication,
  Http.CacheControl,
  Http.Cache,
  Http.DiskCache,
  Http.Redirects,
  Http.Messages,
  Http.Client,
  Http.FetchTasks,
  Http.SocketTransports,
  Http.SocketConnector;

implementation

end.
