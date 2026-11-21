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
  The binding tables make-bindings.py generates from bindings/*.webidl
  (Web.Bindings.Tables.inc): types, arguments, overloads, members,
  interfaces, dictionaries, enums and the element interfaces by local
  name. The members name the implementation routines of the
  Web.Bindings.<File> units, so a routine missing on either side is a
  compile error.
}
unit Web.Bindings.Tables;

{$mode objfpc}
{$H+}

interface

uses
  Web.Bindings.Types,
  Web.Bindings.Events,
  Web.Bindings.Nodes,
  Web.Bindings.Documents,
  Web.Bindings.Elements,
  Web.Bindings.Collections,
  Web.Bindings.HtmlElements,
  Web.Bindings.Window,
  Web.Bindings.DomExceptions,
  Web.Bindings.Encoding,
  Web.Bindings.Urls,
  Web.Bindings.MutationObservers,
  Web.Bindings.Style,
  Web.Bindings.Ranges;

{$I Web.Bindings.Tables.inc}

implementation

end.
