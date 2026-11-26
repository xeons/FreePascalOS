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
  CSS Overflow 3.3: the root's overflow, or the body's when the root's
  is visible, applies to the viewport; that element does not clip.
}
unit WebLayoutTest.ViewportOverflow;

{$mode objfpc}
{$H+}

interface

procedure CheckViewportOverflow;

implementation

uses
  SysUtils, TestChecks, Web.Dom, Web.Layout.Document, Web.Layout.Boxes, Web.Paint.Painter, WebLayoutTest.Pages;

function IsScrollContainer(Layout: TDocumentLayout; Element: TElement): Boolean;
var
  Box: TLayoutBox;
begin
  Box := Layout.BoxOf(Element);
  Result := (Box <> nil) and (bfScrollContainer in Box.Flags);
end;

procedure CheckViewportOverflow;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Hit: THitTestResult;
  Scrollers: TScrollContainerArray;
begin
  { body { overflow-y: scroll } over only positioned content: the body
    box is 0 px tall, and must not clip the page to nothing. }
  Layout := LayoutText('<!doctype html><body style="margin:0;overflow-y:scroll">' +
    '<div id=app style="position:absolute;top:0;left:0;width:100px;height:300px"></div>', 400, Document);
  Painter := TDocumentPainter.Create(Layout);
  try
    Check(not IsScrollContainer(Layout, Document.Body), 'viewport overflow: the body does not scroll itself');
    Hit := Painter.HitTest(10, 200);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 'app'), 'viewport overflow: the body clips nothing');
    Scrollers := Layout.ScrollContainers;
    Check((Length(Scrollers) >= 1) and Scrollers[0].BarY, 'viewport overflow: the viewport has the scroll bar');
  finally
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
  { The root's overflow hidden goes to the viewport (no bars); the body's
    then stays its own. }
  Layout := LayoutText('<!doctype html><html style="overflow:hidden"><body style="margin:0;height:50px;' +
    'overflow:auto"><div style="height:200px"></div>', 400, Document);
  try
    Check(not IsScrollContainer(Layout, Document.DocumentElement), 'viewport overflow: the root does not clip');
    Check(IsScrollContainer(Layout, Document.Body), 'viewport overflow: the body keeps its overflow');
    Scrollers := Layout.ScrollContainers;
    Check((Length(Scrollers) >= 1) and not Scrollers[0].BarX and not Scrollers[0].BarY,
      'viewport overflow: hidden on the root hides the viewport''s bars');
  finally
    FreeLayout(Layout, Document);
  end;
end;

end.
