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
  The contents of libweb.so, the browser engine: encodings, the HTML
  parser and the DOM, the event loop, the fetch layer over libhttp,
  document and subresource loading, and navigation (layout, painting
  and the script bindings come with other units). Compiling this unit
  compiles all of them.
}
unit Web.Contents;

{$mode objfpc}

interface

uses
  Web.TextBuffers,
  Web.Atoms,
  Web.Namespaces,
  Web.Encoding.Labels,
  Web.Encoding.Decoders,
  Web.Encoding.Utf8Decoder,
  Web.Encoding.Utf16Decoder,
  Web.Encoding.SingleByteDecoder,
  Web.Encoding.DecoderFactory,
  Web.Encoding.Utf8,
  Web.Encoding.Sniffing,
  Web.Dom.Exceptions,
  Web.Dom.Events,
  Web.Dom,
  Web.Html.Tokens,
  Web.Html.NamedReferences,
  Web.Html.InputStream,
  Web.Html.Tokenizer,
  Web.Html.ElementKinds,
  Web.Html.ElementStack,
  Web.Html.FormattingList,
  Web.Html.ForeignContent,
  Web.Html.Quirks,
  Web.Html.TreeBuilder,
  Web.Html.Parser,
  Web.Html.Serializer,
  Web.Html.Markup,
  Web.Html.TreeDump,
  Web.IdMaps,
  Web.EventLoop.Tasks,
  Web.EventLoop.DelayedTasks,
  Web.EventLoop,
  Web.EventLoop.Timers,
  Web.EventLoop.AnimationFrames,
  Web.Fetch.MimeTypes,
  Web.Fetch.DataUrls,
  Web.Fetch.Sniffing,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.Hsts,
  Web.Fetch.ContentSecurityPolicy,
  Web.Fetch.Requests,
  Web.Fetch.Responses,
  Web.Fetch.Cors,
  Web.Fetch.MixedContent,
  Web.Fetch.LocalFiles,
  Web.Fetch.NetworkContexts,
  Web.Fetch.Jobs,
  Web.Fetch.HttpHops,
  Web.Fetch.Fetcher,
  Web.Navigation.Events,
  Web.Navigation.Windows,
  Web.Loading.ResourceSink,
  Web.Loading.Contexts,
  Web.Loading.Priorities,
  Web.Loading.TextDecoding,
  Web.Loading.BufferedFetches,
  Web.Loading.Preloads,
  Web.Loading.StyleSheets,
  Web.Loading.Fonts,
  Web.Loading.Srcset,
  Web.Loading.Images,
  Web.Loading.Icons,
  Web.Loading.Scripts,
  Web.Loading.Observers,
  Web.Loading.Documents,
  Web.Navigation.SessionHistory,
  Web.Navigation.ErrorPages,
  Web.Navigation.Navigables,
  Web.Navigation.Pages;

implementation

end.
