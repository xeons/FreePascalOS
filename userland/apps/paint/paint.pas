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
  paint - draw and edit pictures

  paint [FILE]

  A window titled with the picture's file name ("Untitled" without
  one): the menu bar, the tool box at the left (the tools' buttons and
  the current tool's options), the picture in a zoomable, scrolling
  view, the colour box along the bottom (the primary and secondary
  colours and the palette: left click for the primary, right click for
  the secondary) and a status bar.

    File     New... (Ctrl+N), Open... (Ctrl+O), Save (Ctrl+S),
             Save As..., Exit
    Edit     Undo (Ctrl+Z), Redo (Ctrl+Y), Cut (Ctrl+X), Copy (Ctrl+C),
             Paste (Ctrl+V), Delete, Select All (Ctrl+A),
             Crop to Selection (Ctrl+Shift+X)
    View     Zoom In (Ctrl+PgUp, Ctrl+=), Zoom Out (Ctrl+PgDn, Ctrl+-),
             Actual Size (Ctrl+0), Pixel Grid (Ctrl+G), Status Bar
    Image    Resize and Skew... (Ctrl+W), Rotate and Flip (right, left,
             180 degrees, horizontally, vertically), Invert Colours
             (Ctrl+I), Properties... (Ctrl+E: the canvas size),
             Clear Image (Ctrl+Shift+N)
    Colours  Edit Primary Colour..., Edit Secondary Colour..., Swap
    Tools    select, free-form select, eraser, fill, colour picker,
             pencil, brush, airbrush, text, line, curve, rectangle,
             polygon, ellipse, rounded rectangle
    Help     About Paint

  Pictures open in any format libimage reads (and when dropped on the
  window from the file manager) and are saved as the name's extension
  says: .png (also for a name without one), .bmp, .jpg (asking for a
  quality), .gif, .tif or .webp. New, Open, a drop, Exit and closing
  the window ask first whether to save changes. FILE is opened at
  start; one that does not exist yet is made when saved. Prints what
  happens, a line each:

    title TEXT              the window's title changed
    place NAME X Y          where something is on the screen, at start:
                            "canvas" (the picture's top left pixel),
                            "tool-WORD" (each tool's button)
    tool WORD               the tool chosen ("tool rectangle")
    opened PATH, new PATH   a file was opened (or a new one named)
    image WIDTH HEIGHT      the picture's size (new, opened, changed)
    saved PATH              the picture was saved
    colours AARRGGBB AARRGGBB  the primary and secondary colours changed
    zoom TEXT               the zoom changed ("200%")
    copied W H, pasted W H  pixels went to or came from the clipboard
    text TEXT               the text tool placed a text
    undone, redone          Undo and Redo
    dialog TITLE            a dialog of Paint's opened
    dropped PATH            a file was dropped on the window
    answer yes|no|cancel    the answer to saving changes
    exit                    the program ends

  The units are in userland/paint: the document and its undo history
  (Paint.Document, Paint.UndoHistory), the selection
  (Paint.Selection, Paint.SelectionEditing), the tools (Paint.Tools and
  the units of each kind, Paint.ToolFactory), what they draw
  (Paint.ShapeDrawing, Paint.Brushes, Paint.ShapeGeometry), the view
  (Paint.CanvasView, Paint.ViewRendering, Paint.ZoomMapping), the tool
  box and colour box, the dialogs, the Image menu's commands
  (Paint.ImageCommands), files (Paint.PictureFiles, Paint.FileFormats),
  what it remembers (Paint.Settings), and the window
  (Paint.DocumentWindow, Paint.MainWindow).
}
program Paint;

{$mode objfpc}
{$H+}

uses
  Windowing.Windows,
  Paint.MainWindow;

var
  Window: TPaintWindow;
begin
  Window := TPaintWindow.Create;
  if ParamCount >= 1 then
    Window.OpenDocument(ParamStr(1));
  Window.Show;
  Window.TellPlaces;
  RunMessageLoop;
end.
