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
  document and subresource loading, navigation, styling (through
  libcss), text (through libfont), layout and painting (through
  libdrawing and libimage) and the script
  bindings (through libjavascript). Compiling this unit compiles all of them.
}
unit Web.Contents;

{$mode objfpc}

interface

uses
  Web.TextBuffers,
  Web.Profiling,
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
  Web.Origins,
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
  Web.Style.Atoms,
  Web.Style.NodeData,
  Web.Style.Adapter,
  Web.Style.Hints,
  Web.Style.Sheets,
  Web.Style.UserAgent,
  Web.Style.Resolver,
  Web.Text.Fonts,
  Web.Text.FontInstances,
  Web.Text.Breaking,
  Web.Text.Woff,
  Web.Layout.EmbeddedContent,
  Web.Layout.Resources,
  Web.Layout.Boxes,
  Web.Layout.Values,
  Web.Layout.Context,
  Web.Layout.Floats,
  Web.Layout.TreeBuilder,
  Web.Layout.Counters,
  Web.Layout.InlineItems,
  Web.Layout.Inline,
  Web.Layout.Sizing,
  Web.Layout.Replaced,
  Web.Layout.Block,
  Web.Layout.Flex,
  Web.Layout.Grid,
  Web.Layout.Table,
  Web.Layout.Positioned,
  Web.Layout.Dispatch,
  Web.Layout.Document,
  Web.Layout.Dump,
  Web.Paint.DisplayList,
  Web.Paint.Gradients,
  Web.Paint.Sticky,
  Web.Paint.Builder,
  Web.Paint.Raster,
  Web.Paint.Painter,
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
  Web.Fetch.Monitors,
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
  Web.Navigation.FramePolicy,
  Web.Navigation.Navigables,
  Web.Navigation.Pages,
  Web.Loading.LayoutSink,
  Web.Frames.Views,
  Web.Dom.UiEvents,
  Web.ScriptEnvironment,
  { First of the script units: compiled in the order a program using
    them loads them (the bindings' units use each other in a cycle). }
  Web.Script.PageScripting,
  Web.Bindings.Types,
  Web.Bindings.Strings,
  Web.Bindings.Listeners,
  Web.Bindings.Context,
  Web.Bindings.UrlResolution,
  Web.Bindings.Selectors,
  Web.Bindings.FormControls,
  Web.Bindings.Reflection,
  Web.Bindings.EventHandlers,
  Web.Bindings.Tables,
  Web.Bindings.Conversions,
  Web.Bindings.Dispatch,
  Web.Bindings.Exotic,
  Web.Bindings.Install,
  Web.Script.Timers,
  Web.Script.Prelude,
  Web.Script.Context;

implementation

end.
