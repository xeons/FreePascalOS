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
  Which class each tool is.
}
unit Paint.ToolFactory;

{$mode objfpc}
{$H+}

interface

uses
  Paint.Session,
  Paint.ToolKinds,
  Paint.Tools;

function CreateTool(Kind: TToolKind; Session: TPaintSession): TPaintTool;

implementation

uses
  Paint.FreehandTools,
  Paint.ShapeTools,
  Paint.PolygonTool,
  Paint.CurveTool,
  Paint.FillTools,
  Paint.SelectionTools;

const
  ToolClasses: array[TToolKind] of TPaintToolClass = (TRectangleSelectTool, TFreeFormSelectTool, TEraserTool,
    TFillTool, TPickerTool, TPencilTool, TBrushTool, TAirbrushTool, TTextTool, TLineTool, TCurveTool,
    TRectangleTool, TPolygonTool, TEllipseTool, TRoundedRectangleTool);

function CreateTool(Kind: TToolKind; Session: TPaintSession): TPaintTool;
begin
  Result := ToolClasses[Kind].Create(Session);
end;

end.
