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
  Help > About Tuxcat: the browser's icon on the theme's header band,
  its name and version, what it is built on, and Credits and Licence
  buttons (local pages).
}
unit Browser.AboutDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure ShowAboutBrowser(Owner: TWindow);

implementation

uses
  Drawing.Canvas,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Base,
  Controls.Labels,
  Controls.Buttons,
  Controls.Dialogs,
  Controls.Painting,
  Controls.IconTheme,
  Controls.Text,
  Browser.Application;

const
  Width = 400;
  Height = 300;
  BandHeight = 96;
  Version = '2.0';

type
  TAboutBand = class(TControl)
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

  TAboutDialog = class(TDialog)
  public
    procedure LicenceClicked(Sender: TControl);
  end;

procedure TAboutBand.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Size: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  if Theme.HeaderBandsShown then
    DrawHeaderBand(Canvas, Box, BandHeader)
  else
    FillRectangle(Canvas, Box, Theme.Field);
  Size := Scaled(64);
  DrawThemeIcon(Canvas, 'app-web-browser', MakeRectangle(Scaled(16), (RectangleHeight(Box) - Size) div 2, Size, Size));
  if Theme.HeaderBandsShown then
    DrawTextInBox(Canvas, ControlBoldFace, 'Browser ' + Version, MakeRectangle(Scaled(96), 0, Box.Right - Scaled(100),
      RectangleHeight(Box)), AlignTextLeft, HeaderBandText(BandHeader))
  else
    DrawTextInBox(Canvas, ControlBoldFace, 'Browser ' + Version, MakeRectangle(Scaled(96), 0, Box.Right - Scaled(100),
      RectangleHeight(Box)), AlignTextLeft, Theme.FieldText);
end;

procedure TAboutDialog.LicenceClicked(Sender: TControl);
begin
  BrowserApp.OpenInActiveWindow('about:license');
  EndModal(ResultOk);
end;

procedure AddLine(Dialog: TDialog; const Text: string; Line: LongInt);
var
  Caption: TLabel;
begin
  Caption := TLabel.Create(Dialog.Root);
  Caption.ShowsMnemonic := False;
  Caption.Text := Text;
  Caption.SetBounds(16, BandHeight + 12 + Line * 18, Width - 32, 18);
end;

procedure ShowAboutBrowser(Owner: TWindow);
var
  Dialog: TAboutDialog;
  Band: TAboutBand;
  Licence: TButton;
begin
  Dialog := TAboutDialog.CreateDialog('About Tuxcat', Width, Height, Owner);
  try
    Band := TAboutBand.Create(Dialog.Root);
    Band.SetBounds(0, 0, Width, BandHeight);
    AddLine(Dialog, 'Tuxcat, the web browser of FreePascalOS.', 0);
    AddLine(Dialog, 'Pages run in sandboxed content processes, one per site.', 1);
    AddLine(Dialog, 'Built on libweb (HTML, CSS, layout, JavaScript), libhttp,', 2);
    AddLine(Dialog, 'libtls and libquic (HTTP/1.1, HTTP/2 and HTTP/3).', 3);
    AddLine(Dialog, 'Free software under the GNU General Public License,', 5);
    AddLine(Dialog, 'version 3 or later.', 6);
    Licence := Dialog.AddButton('&Licence', ResultNone, 16, Height - 8 - 23, 90, 23);
    Licence.OnClick := @Dialog.LicenceClicked;
    Dialog.AddButton('&OK', ResultOk, Width - 8 - 75, Height - 8 - 23, 75, 23, True, True);
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

end.
