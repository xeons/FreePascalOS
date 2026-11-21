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
  CSSOM changes restyle: a rule appended to the last sheet (indexed at
  once, as insertRule at the end does), a rule deleted (indexed again),
  a rule's declarations changed in place, and an adopted constructed
  sheet, each painted.
}
unit WebLayoutTest.StyleSheets;

{$mode objfpc}
{$H+}

interface

procedure CheckStyleSheetChanges;

implementation

uses
  SysUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom, Web.Layout.Document,
  Web.Paint.Painter, Css.Stylesheets, Css.Parser, Css.Declarations, Css.Tokens, Css.Tokenizer,
  Web.Style.DocumentSheets, WebLayoutTest.Pages;

const
  SheetPage =
    '<!doctype html><head><style id=s>div { background: #ff0000 }</style></head>' +
    '<body style="margin:0;background:#ffffff"><div style="width:50px;height:50px"></div></body>';

function PixelIs(const Surface: TSurface; Expected: TColor): Boolean;
var
  Actual: TColor;
begin
  Actual := GetSurfacePixel(Surface, 20, 20) or $FF000000;
  Result := (Abs(Integer(RedOf(Actual)) - RedOf(Expected)) <= 3) and
    (Abs(Integer(GreenOf(Actual)) - GreenOf(Expected)) <= 3) and
    (Abs(Integer(BlueOf(Actual)) - BlueOf(Expected)) <= 3);
  if not Result then
    WriteLn('  pixel is ', IntToHex(Actual, 8), ', expected ', IntToHex(Expected, 8));
end;

procedure CheckStyleSheetChanges;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Sheets: TDocumentSheets;
  Sheet, Made: TCssStyleSheet;
  Rule: TCssRule;
  Adopted: TCssStyleSheetList;

  procedure Repaint;
  begin
    if Layout.NeedsUpdate then
      Layout.Update;
    Painter.Paint(Surface, MakeRectangle(0, 0, 100, 100));
  end;

begin
  Layout := LayoutText(SheetPage, 100, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 100, 100, ColorBlack);
  try
    Repaint;
    Check(PixelIs(Surface, RgbColor(255, 0, 0)), 'cssom: the sheet as parsed');
    Sheets := DocumentSheetsOf(Document);
    Sheet := Sheets.StyleElementSheet(Document.GetElementById('s'));
    Check(Sheet <> nil, 'cssom: the style element''s sheet');
    Rule := ParseSingleRule('div { background: #0000ff }', coAuthor);
    Sheet.InsertRuleAt(Rule, Length(Sheet.Rules));
    Sheets.RuleAppended(Sheet, Rule);
    Check(Layout.NeedsUpdate, 'cssom: an appended rule makes style due');
    Repaint;
    Check(PixelIs(Surface, RgbColor(0, 0, 255)), 'cssom: an appended rule restyles');
    { In place, as CSSStyleRule.style does. }
    TCssStyleRule(Rule).Declarations.Clear;
    TCssStyleRule(Rule).Declarations.AddParsed('background',
      TrimRange(TCssTokenCursor.Create(TokenizeCss('#00ff00'))), False);
    Sheets.ContentsChanged(Sheet);
    Repaint;
    Check(PixelIs(Surface, RgbColor(0, 255, 0)), 'cssom: a rule''s declarations changed in place');
    Sheets.RetireRule(Sheet.ExtractRuleAt(1));
    Sheets.ContentsChanged(Sheet);
    Repaint;
    Check(PixelIs(Surface, RgbColor(255, 0, 0)), 'cssom: a deleted rule no longer applies');
    Made := Sheets.NewConstructedSheet('');
    Rule := ParseSingleRule('div { background: #ffff00 }', coAuthor);
    Made.InsertRuleAt(Rule, 0);
    Adopted := nil;
    SetLength(Adopted, 1);
    Adopted[0] := Made;
    Sheets.SetAdoptedSheets(Adopted);
    Repaint;
    Check(PixelIs(Surface, RgbColor(255, 255, 0)), 'cssom: an adopted sheet comes after the document''s');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
