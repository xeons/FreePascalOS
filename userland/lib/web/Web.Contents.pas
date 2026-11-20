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
  parser and the DOM (layout, painting, loading and the script bindings
  come in later phases). Compiling this unit compiles all of them.
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
  Web.Html.TreeDump;

implementation

end.
