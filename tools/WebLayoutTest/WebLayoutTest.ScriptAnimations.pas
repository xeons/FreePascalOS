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
  Web Animations' keyframe effects in styling (Web.Style.ScriptAnimations,
  what Element.animate drives each frame), by their pixels: a color
  half way, a per keyframe easing, an implicit keyframe taking the
  underlying value, nothing once the effect is out of effect, and an
  effect removed.
}
unit WebLayoutTest.ScriptAnimations;

{$mode objfpc}
{$H+}

interface

procedure CheckScriptAnimations;

implementation

uses
  SysUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom, Web.Layout.Document,
  Web.Paint.Painter, Web.Style.ScriptAnimations, WebLayoutTest.Pages;

const
  AnimatedPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div id=box style="width:50px;height:50px;background:#0000ff"></div></body>';

function NearColor(const Surface: TSurface; Expected: TColor; const What: string): Boolean;
var
  Actual: TColor;
begin
  Actual := GetSurfacePixel(Surface, 20, 20) or $FF000000;
  Result := (Abs(Integer(RedOf(Actual)) - RedOf(Expected)) <= 4) and
    (Abs(Integer(GreenOf(Actual)) - GreenOf(Expected)) <= 4) and
    (Abs(Integer(BlueOf(Actual)) - BlueOf(Expected)) <= 4);
  if not Result then
    WriteLn('  ', What, ': pixel is ', IntToHex(Actual, 8), ', expected ', IntToHex(Expected, 8));
end;

procedure CheckScriptAnimations;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Box: TElement;

  procedure Repaint;
  begin
    if Layout.NeedsUpdate then
      Layout.Update;
    Painter.Paint(Surface, MakeRectangle(0, 0, 100, 100));
  end;

begin
  Layout := LayoutText(AnimatedPage, 100, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 100, 100, ColorBlack);
  try
    Box := Document.GetElementById('box');
    Repaint;
    SetEffectKeyframes(Box, 1, [0, 1], ['', ''], ['background-color: #000000', 'background-color: #ffffff']);
    SetEffectProgress(Box, 1, True, 0.5);
    Check(Layout.NeedsUpdate, 'web animations: progress makes style due');
    Repaint;
    Check(NearColor(Surface, RgbColor(128, 128, 128), 'half way'), 'web animations: a color half way');
    SetEffectKeyframes(Box, 1, [0, 1], ['steps(1, end)', ''], ['background-color: #000000',
      'background-color: #ffffff']);
    SetEffectProgress(Box, 1, True, 0.75);
    Repaint;
    Check(NearColor(Surface, RgbColor(0, 0, 0), 'steps'), 'web animations: a keyframe''s easing');
    SetEffectKeyframes(Box, 1, [1], [''], ['background-color: #ff0000']);
    SetEffectProgress(Box, 1, True, 0.5);
    Repaint;
    Check(NearColor(Surface, RgbColor(128, 0, 128), 'implicit'),
      'web animations: an implicit 0% keyframe is the underlying value');
    SetEffectProgress(Box, 1, False, 0);
    Repaint;
    Check(NearColor(Surface, RgbColor(0, 0, 255), 'out of effect'), 'web animations: out of effect shows nothing');
    SetEffectProgress(Box, 1, True, 1);
    RemoveEffect(Box, 1);
    Repaint;
    Check(NearColor(Surface, RgbColor(0, 0, 255), 'removed'), 'web animations: a removed effect');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
