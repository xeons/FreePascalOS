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
  parser and the DOM, styling (through libcss), text (through libfont),
  layout and painting (through libdrawing and libimage). Compiling this
  unit compiles all of them.
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
  Web.Layout.Table,
  Web.Layout.Positioned,
  Web.Layout.Dispatch,
  Web.Layout.Document,
  Web.Layout.Dump,
  Web.Paint.DisplayList,
  Web.Paint.Gradients,
  Web.Paint.Builder,
  Web.Paint.Raster,
  Web.Paint.Painter;

implementation

end.
