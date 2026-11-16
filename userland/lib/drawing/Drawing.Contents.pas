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
  The contents of libdrawing.so.

  Compiling this unit compiles every unit of the library; programs use
  the individual units. libdrawing needs nothing but the runtime
  library, so its units build and are tested on the host as well
  (tools/DrawingTest).
}
unit Drawing.Contents;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Shapes,
  Drawing.Rasterizer,
  Drawing.CoverageBlending,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Drawing.Scaling,
  Drawing.Bevels;

implementation

end.
