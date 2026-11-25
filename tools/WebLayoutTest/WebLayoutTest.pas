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
  libweb's style, layout and painting on the host.

    WebLayoutTest RENDER-DIRECTORY FONT-DIRECTORY [--update]

  Each RENDER-DIRECTORY/*.html is laid out (at the width a first line
  comment "<!-- width=N -->" gives, else 800) and its layout tree dump
  compared with the .txt beside it (--update writes the .txt files).
  Then: incremental restyle and relayout after DOM changes give the
  same tree as a fresh layout (and skip clean boxes), hit testing,
  painting (pixels of known boxes, a damaged rectangle painted alone
  matching the full paint), the speed and memory of a large page, and
  font matching with the system's fonts and configuration
  (WebLayoutTest.Fonts; WEB_HOST_FONTS names the fonts directory).
}
program WebLayoutTest;

{$mode objfpc}
{$H+}

uses
  SysUtils, Classes, DateUtils, TestChecks, WebLayoutTest.Pages, WebLayoutTest.Dynamic, WebLayoutTest.Painting,
  WebLayoutTest.StyleSheets, WebLayoutTest.Transforms, WebLayoutTest.Fonts;

var
  Update: Boolean;

begin
  if ParamCount < 2 then
  begin
    WriteLn('usage: WebLayoutTest RENDER-DIRECTORY FONT-DIRECTORY [--update]');
    Halt(2);
  end;
  Update := (ParamCount >= 3) and (ParamStr(3) = '--update');
  SetFontDirectory(ParamStr(2));
  CheckReferencePages(ParamStr(1), Update);
  CheckIncrementalLayout;
  CheckStateInvalidation;
  CheckHitTesting;
  CheckPainting;
  CheckStickyPainting;
  CheckMaskPainting;
  CheckLayerPainting;
  CheckStyleSheetChanges;
  CheckTransforms;
  CheckAnimations;
  ReportPerformance;
  CheckSystemFonts;
  FinishChecks('web layout test');
end.
