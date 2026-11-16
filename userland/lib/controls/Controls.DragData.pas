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
  What is dragged with the mouse from one control to another, and what
  dropping it would do.

  A drag carries its data as text with a format naming what the text
  is, as the clipboard does: "text" for plain text, "file-list" for
  paths (Controls.FileLists has the format), or a program's own. The
  control it came from is kept, so a control can tell a drag of its own
  items (a move within a list) from one that came from elsewhere.

  A control under the pointer says what a drop would do (TDropEffect):
  nothing (it takes no such data, or not there), copy or move; the
  window starting the drag owns the data and frees it when the drag
  ends (Controls.Window).
}
unit Controls.DragData;

{$mode objfpc}
{$H+}

interface

const
  { The formats of the libraries; programs may name their own. }
  DragFormatText = 'text';
  DragFormatFileList = 'file-list';

type
  TDropEffect = (DropNone, DropCopy, DropMove);

  TDragData = class
  private
    FFormat: string;
    FText: string;
    FSource: TObject;
  public
    constructor Create(const AFormat, AText: string; ASource: TObject);
    property Format: string read FFormat;
    property Text: string read FText;
    { The control the drag started from. }
    property Source: TObject read FSource;
  end;

implementation

constructor TDragData.Create(const AFormat, AText: string; ASource: TObject);
begin
  inherited Create;
  FFormat := AFormat;
  FText := AText;
  FSource := ASource;
end;

end.
