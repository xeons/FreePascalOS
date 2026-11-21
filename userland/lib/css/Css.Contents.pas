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
  The contents of libcss.so, the style engine: CSS syntax, selectors,
  values, the property table, style sheets, media queries, the cascade
  and computed styles, matched against any document through an element
  adapter. Compiling this unit compiles all of them.
}
unit Css.Contents;

{$mode objfpc}

interface

uses
  Css.Atoms,
  Css.Keywords,
  Css.Tokens,
  Css.Tokenizer,
  Css.Serialization,
  Css.Units,
  Css.Calc,
  Css.Colors,
  Css.Values,
  Css.ValueParser,
  Css.ColorParser,
  Css.Images,
  Css.Transforms,
  Css.TransformMatrices,
  Css.Easing,
  Css.Interpolation,
  Css.PropertyIds,
  Css.PropertyTable,
  Css.Properties,
  Css.Grammar,
  Css.BoxParsers,
  Css.GridParsers,
  Css.TextParsers,
  Css.SvgParsers,
  Css.PropertyParsers,
  Css.InitialValues,
  Css.Shorthands,
  Css.Declarations,
  Css.Selectors,
  Css.SelectorParser,
  Css.PointerMaps,
  Css.ElementAdapter,
  Css.BloomFilter,
  Css.SelectorMatching,
  Css.MediaQueries,
  Css.Supports,
  Css.Stylesheets,
  Css.Parser,
  Css.UserAgentStyleSheet,
  Css.RuleIndex,
  Css.StateInvalidation,
  Css.Cascade,
  Css.ComputedValues,
  Css.StyleStructs,
  Css.CustomProperties,
  Css.ComputedStyle,
  Css.StyleCompute,
  Css.StyleEngine;

implementation

end.
