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
  The contents of libsvg.so: SVG documents (an XML parser, styling with
  libcss), their rendering with libdrawing (shapes, paths, strokes,
  gradients, patterns, clip paths, masks, text with libfont, images
  with libimage) and SVG as a scalable image in libimage's codec
  registry.

  Compiling this unit compiles every unit of the library; programs use
  the individual units. The units build on the host too (tools/SvgTest).
}
unit Svg.Contents;

{$mode objfpc}

interface

uses
  Svg.Nodes,
  Svg.Xml,
  Svg.Numbers,
  Svg.PathData,
  Svg.Presentation,
  Svg.Styling,
  Svg.Fonts,
  Svg.ImageReferences,
  Svg.Document,
  Svg.Geometry,
  Svg.StyleValues,
  Svg.Text,
  Svg.Renderer,
  Svg.Images;

implementation

end.
