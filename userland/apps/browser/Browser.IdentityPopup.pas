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
  The site information pop-up under the site identity button: the
  site's name, whether the connection is encrypted and who verified the
  site (the certificate's issuer, from the browser's connection to it),
  or that the page is a local file, one of the browser's own pages, or
  not encrypted; More Information... opens Page Info's Security tab.
}
unit Browser.IdentityPopup;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  WebView.Control;

procedure ShowIdentityPopup(Owner: TControlWindow; Anchor: TControl; View: TWebView);

implementation

uses
  SysUtils,
  Drawing.Canvas,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Labels,
  Controls.Buttons,
  Controls.Popups,
  Controls.Painting,
  Controls.IconTheme,
  WebView.Network,
  Browser.History,
  Browser.PageInfo,
  Browser.Output;

const
  PopupWidth = 360;
  PopupHeight = 150;

type
  TIdentityFace = class(TControl)
  public
    IconName: string;
  protected
    procedure Paint(var Canvas: TCanvas); override;
  end;

  TIdentityPopup = class
  public
    Popup: TPopupWindow;
    View: TWebView;
    Owner: TControlWindow;
    procedure MoreClicked(Sender: TControl);
    procedure Dismissed(Sender: TControl);
  end;

procedure TIdentityFace.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawRaisedBevel(Canvas, Box);
  DrawThemeIcon(Canvas, IconName, MakeRectangle(Scaled(12), Scaled(14), Scaled(48), Scaled(48)));
end;

procedure TIdentityPopup.MoreClicked(Sender: TControl);
var
  ShownView: TWebView;
  Window: TControlWindow;
begin
  { Dismissing frees this object: what is needed is taken first. }
  ShownView := View;
  Window := Owner;
  Popup.Dismiss;
  ShowPageInfo(ShownView, Window, PageInfoSecurity);
end;

procedure TIdentityPopup.Dismissed(Sender: TControl);
begin
  Free;
end;

procedure AddLine(Parent: TControl; const Text: string; Line: LongInt; Bold: Boolean = False);
var
  Caption: TLabel;
begin
  Caption := TLabel.Create(Parent);
  Caption.ShowsMnemonic := False;
  Caption.Text := Text;
  Caption.SetBounds(72, 12 + Line * 20, PopupWidth - 84, 18);
end;

procedure ShowIdentityPopup(Owner: TControlWindow; Anchor: TControl; View: TWebView);
var
  Info: TIdentityPopup;
  Face: TIdentityFace;
  Security: TConnectionSecurity;
  Url, Host: string;
  Button: TButton;
begin
  Info := TIdentityPopup.Create;
  Info.View := View;
  Info.Owner := Owner;
  Info.Popup := TPopupWindow.CreatePopup(Owner, Owner.ScreenLeft + Unscaled(Anchor.PixelBounds.Left),
    Owner.ScreenTop + Unscaled(Anchor.PixelBounds.Bottom), PopupWidth, PopupHeight);
  Face := TIdentityFace.Create(Info.Popup.Root);
  Face.Align := AlignClient;
  Url := View.Url;
  Host := HostOfUrl(Url);
  if Pos('https://', LowerCase(Url)) = 1 then
  begin
    Face.IconName := 'status-security-ok';
    AddLine(Face, 'You are connected to', 0);
    AddLine(Face, Host, 1, True);
    if ConnectionSecurityOf(Url, Security) and (Length(Security.Chain) > 0) then
      AddLine(Face, 'Verified by: ' + Security.Chain[High(Security.Chain)].Organization, 2)
    else
      AddLine(Face, 'Verified by a certificate authority the system trusts', 2);
    AddLine(Face, 'Your connection to this web site is encrypted.', 3);
  end
  else if Pos('file:', LowerCase(Url)) = 1 then
  begin
    Face.IconName := 'file-document';
    AddLine(Face, 'This is a file on your computer.', 0);
  end
  else if Pos('about:', LowerCase(Url)) = 1 then
  begin
    Face.IconName := 'app-web-browser';
    AddLine(Face, 'This is one of the browser''s own pages.', 0);
  end
  else
  begin
    Face.IconName := 'status-security-warning';
    AddLine(Face, 'This web site does not supply identity information.', 0);
    if Host <> '' then
      AddLine(Face, Host, 1, True);
    AddLine(Face, 'Your connection to this site is not encrypted.', 2);
  end;
  Button := TButton.Create(Face);
  Button.Text := '&More Information...';
  Button.SetBounds(PopupWidth - 160, PopupHeight - 34, 150, 24);
  Button.OnClick := @Info.MoreClicked;
  Info.Popup.OnDismiss := @Info.Dismissed;
  Info.Popup.Popup;
  Say('identity ' + Host);
end;

end.
