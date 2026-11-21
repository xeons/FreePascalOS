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
  Content of a replaced box that is a document of its own (an iframe's
  child navigable): laid out at the box's content size with its own
  layout, painted into the parent's surface where the box is. The
  parent's layout only knows this interface: its owner (Web.Frames.Views)
  keeps it in the parent document's resources under the frame element,
  the parent's TDocumentLayout gives it the content box's size after
  each layout and brings it up to date, and the raster asks it to paint
  itself clipped to the box (Web.Paint.Raster).
}
unit Web.Layout.EmbeddedContent;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces,
  Drawing.Rectangles,
  Web.Dom;

type
  TEmbeddedContent = class
  public
    { The content box in CSS pixels and the device pixels per CSS pixel
      (the parent's: zoom and DPI are inherited). }
    procedure SetViewport(Width, Height, Scale: Single); virtual; abstract;
    function NeedsUpdate: Boolean; virtual; abstract;
    { Brings style, boxes and layout up to date (and those of frames
      inside). }
    procedure Update; virtual; abstract;
    { Changes whenever painting the content would draw something else
      (its own frames included). }
    function PaintVersion: LongWord; virtual; abstract;
    { Draws the content with its top left at device pixel (OriginX,
      OriginY) of Surface, only within Clip (device pixels of Surface). }
    procedure PaintInto(const Surface: TSurface; OriginX, OriginY: LongInt; const Clip: TRectangle); virtual;
      abstract;
    { The document shown (nil between documents). }
    function ContentDocument: TDocument; virtual; abstract;
  end;

implementation

end.
