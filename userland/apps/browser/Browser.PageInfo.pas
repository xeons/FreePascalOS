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
  Tools > Page Info (Ctrl+I): a window of its own about the page shown,
  in tabs:
  - General: the address, type, render mode, encoding, referring URL,
    when it was modified, the page's meta tags, how many forms and
    links it has;
  - Media: every image (address, type, alternate text, size) with a
    preview of the one chosen, and Save As...;
  - Permissions: whether the site may set cookies (the cookie
    exceptions);
  - Security: the site's identity (who verified it), privacy and
    history (visits before today, cookies, saved passwords), and the
    technical details of the connection, with View Certificate (the
    chain the browser was given).
  The page's process answers with what it knows (TWebView.RequestPageInfo);
  the browser process knows the connection.
}
unit Browser.PageInfo;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  WebView.Control,
  WebView.Types;

const
  PageInfoGeneral = 0;
  PageInfoMedia = 1;
  PageInfoPermissions = 2;
  PageInfoSecurity = 3;

procedure ShowPageInfo(View: TWebView; Owner: TWindow; Tab: Integer);
{ What View's process answered (the window waiting for it fills in). }
procedure PageInfoArrived(View: TWebView; constref Info: TWebPageInfo);

implementation

uses
  Windowing.Messages,
  Controls.LayoutRules,
  SysUtils,
  Classes,
  Controls.Base,
  Controls.Window,
  Controls.Labels,
  Controls.Buttons,
  Controls.ListView,
  Controls.TabControl,
  Controls.ComboBox,
  Controls.Dialogs,
  Controls.FileDialog,
  WebView.Network,
  Browser.History,
  Browser.Downloads,
  Browser.Settings,
  Browser.Application,
  Browser.Options.Dialogs,
  Browser.Output;

type
  TPageInfoWindow = class(TControlWindow)
  private
    FView: TWebView;
    FUrl: string;
    FInfo: TWebPageInfo;
    FTabs: TTabControl;
    FGeneral: TListView;
    FMeta: TListView;
    FMedia: TListView;
    FPreview: TWebView;
    FCookies: TComboBox;
    FSecurity: TListView;
    FSecurityInfo: TConnectionSecurity;
    FHasSecurity: Boolean;
    procedure BuildGeneral(Page: TControl);
    procedure BuildMedia(Page: TControl);
    procedure BuildPermissions(Page: TControl);
    procedure BuildSecurity(Page: TControl);
    procedure FillGeneral;
    procedure FillMedia;
    procedure FillSecurity;
    procedure MediaChosen(Sender: TControl);
    procedure SaveMediaClicked(Sender: TControl);
    procedure CookiesChosen(Sender: TControl);
    procedure CertificateClicked(Sender: TControl);
    procedure ViewCookiesClicked(Sender: TControl);
    procedure SavedPasswordsClicked(Sender: TControl);
  protected
    procedure CloseRequested; override;
  public
    constructor CreateFor(View: TWebView; Tab: Integer);
    procedure TakeInfo(constref Info: TWebPageInfo);
  end;

var
  OpenWindows: TList;

function AddLabelTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.ShowsMnemonic := False;
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 18);
end;

function AddButtonTo(Parent: TControl; const Text: string; Left, Top, Width: LongInt; Handler: TControlEvent): TButton;
begin
  Result := TButton.Create(Parent);
  Result.Text := Text;
  Result.SetBounds(Left, Top, Width, 23);
  Result.OnClick := Handler;
end;

constructor TPageInfoWindow.CreateFor(View: TWebView; Tab: Integer);
begin
  inherited Create('Page Info - ' + View.Url, 140, 100, 600, 500);
  IconName := 'app-web-browser';
  FView := View;
  FUrl := View.Url;
  FInfo := Default(TWebPageInfo);
  FInfo.Url := View.Url;
  FInfo.Title := View.Title;
  FTabs := TTabControl.Create(Root);
  FTabs.Align := AlignClient;
  FTabs.Margins := MakeSpacing(6, 6, 6, 6);
  BuildGeneral(FTabs.AddPage('&General'));
  BuildMedia(FTabs.AddPage('&Media'));
  BuildPermissions(FTabs.AddPage('&Permissions'));
  BuildSecurity(FTabs.AddPage('&Security'));
  FHasSecurity := ConnectionSecurityOf(FUrl, FSecurityInfo);
  FillGeneral;
  FillMedia;
  FillSecurity;
  FTabs.PageIndex := Tab;
  OpenWindows.Add(Self);
  View.RequestPageInfo;
end;

procedure TPageInfoWindow.CloseRequested;
begin
  OpenWindows.Remove(Self);
  Hide;
  PostMessage(BrowserApp, MessageCloseWindowLater, PtrInt(Self));
end;

procedure TPageInfoWindow.TakeInfo(constref Info: TWebPageInfo);
begin
  FInfo := Info;
  FillGeneral;
  FillMedia;
  Say('page-info ' + IntToStr(Length(Info.Media)) + ' media');
end;

{ ---- General ---- }

procedure TPageInfoWindow.BuildGeneral(Page: TControl);
begin
  FGeneral := TListView.Create(Page);
  FGeneral.SetBounds(8, 8, 560, 180);
  FGeneral.Anchors := [akLeft, akTop, akRight];
  FGeneral.AddColumn('', 140);
  FGeneral.AddColumn('', 400);
  AddLabelTo(Page, 'Meta (the page''s meta tags):', 8, 196, 300);
  FMeta := TListView.Create(Page);
  FMeta.SetBounds(8, 216, 560, 180);
  FMeta.Anchors := [akLeft, akTop, akRight, akBottom];
  FMeta.AddColumn('Name', 160);
  FMeta.AddColumn('Content', 380);
end;

procedure TPageInfoWindow.FillGeneral;
var
  Index: Integer;
begin
  FGeneral.Clear;
  FGeneral.AddRow(['Title:', FInfo.Title]);
  FGeneral.AddRow(['Address:', FUrl]);
  FGeneral.AddRow(['Type:', FInfo.ContentType]);
  FGeneral.AddRow(['Render Mode:', FInfo.RenderMode]);
  FGeneral.AddRow(['Encoding:', FInfo.Encoding]);
  FGeneral.AddRow(['Referring URL:', FInfo.Referrer]);
  FGeneral.AddRow(['Modified:', FInfo.LastModified]);
  FGeneral.AddRow(['Forms, links:', IntToStr(FInfo.FormCount) + ', ' + IntToStr(FInfo.LinkCount)]);
  FMeta.Clear;
  for Index := 0 to High(FInfo.Meta) do
    FMeta.AddRow([FInfo.Meta[Index].Name, FInfo.Meta[Index].Content]);
end;

{ ---- Media ---- }

procedure TPageInfoWindow.BuildMedia(Page: TControl);
begin
  FMedia := TListView.Create(Page);
  FMedia.SetBounds(8, 8, 560, 170);
  FMedia.Anchors := [akLeft, akTop, akRight];
  FMedia.AddColumn('Address', 300);
  FMedia.AddColumn('Type', 90);
  FMedia.AddColumn('Alternate Text', 150);
  FMedia.OnChange := @MediaChosen;
  AddButtonTo(Page, 'S&ave As...', 8, 184, 100, @SaveMediaClicked);
  AddLabelTo(Page, 'Media Preview:', 8, 214, 200);
  FPreview := TWebView.Create(Page);
  FPreview.ProcessModel := ProcessModelInProcess;
  FPreview.ScriptingEnabled := False;
  FPreview.SetBounds(8, 234, 560, 160);
  FPreview.Anchors := [akLeft, akTop, akRight, akBottom];
end;

procedure TPageInfoWindow.FillMedia;
var
  Index: Integer;
begin
  FMedia.Clear;
  for Index := 0 to High(FInfo.Media) do
    FMedia.AddRow([FInfo.Media[Index].Url, FInfo.Media[Index].Kind, FInfo.Media[Index].AltText]);
end;

procedure TPageInfoWindow.MediaChosen(Sender: TControl);
var
  Index: Integer;
  Url: string;
begin
  Index := FMedia.ItemIndex;
  if (Index < 0) or (Index > High(FInfo.Media)) then
    Exit;
  Url := FInfo.Media[Index].Url;
  FPreview.LoadHtml('<!DOCTYPE html><body style="margin:4px;background:#fff"><img src="' +
    StringReplace(Url, '"', '%22', [rfReplaceAll]) + '" style="max-width:100%;max-height:150px"><p style="font:12px ' +
    'sans-serif">' + IntToStr(FInfo.Media[Index].Width) + ' x ' + IntToStr(FInfo.Media[Index].Height) + ' px</p>', Url);
end;

procedure TPageInfoWindow.SaveMediaClicked(Sender: TControl);
var
  Index: Integer;
  Path: string;
begin
  Index := FMedia.ItemIndex;
  if (Index < 0) or (Index > High(FInfo.Media)) then
    Exit;
  if ChooseFileToSave('Save Image', DownloadsFolder, '*', Path, FileNameOfUrl(FInfo.Media[Index].Url)) then
    BrowserApp.StartDownload(FInfo.Media[Index].Url, ExtractFileName(Path), Path);
end;

{ ---- Permissions ---- }

procedure TPageInfoWindow.BuildPermissions(Page: TControl);
begin
  AddLabelTo(Page, 'Permissions for: ' + HostOfUrl(FUrl), 8, 8, 540);
  AddLabelTo(Page, 'Set Cookies:', 8, 40, 120);
  FCookies := TComboBox.Create(Page);
  FCookies.Items.Add('Use Default');
  FCookies.Items.Add('Allow');
  FCookies.Items.Add('Block');
  FCookies.SetBounds(140, 36, 200, 22);
  FCookies.ItemIndex := 0;
  if Pos(HostOfUrl(FUrl) + ',', BrowserApp.Settings.CookiesAllowed + ',') > 0 then
    FCookies.ItemIndex := 1
  else if Pos(HostOfUrl(FUrl) + ',', BrowserApp.Settings.CookiesBlocked + ',') > 0 then
    FCookies.ItemIndex := 2;
  FCookies.OnChange := @CookiesChosen;
end;

function WithoutHost(const List, Host: string): string;
var
  Parts: TStringArray;
  Index: Integer;
begin
  Result := '';
  Parts := List.Split([',', ' '], TStringSplitOptions.ExcludeEmpty);
  for Index := 0 to High(Parts) do
    if not SameText(Parts[Index], Host) then
      Result := Result + Parts[Index] + ',';
end;

procedure TPageInfoWindow.CookiesChosen(Sender: TControl);
var
  Settings: TBrowserSettings;
  Host: string;
begin
  Host := HostOfUrl(FUrl);
  if Host = '' then
    Exit;
  Settings := BrowserApp.Settings;
  Settings.CookiesAllowed := WithoutHost(Settings.CookiesAllowed, Host);
  Settings.CookiesBlocked := WithoutHost(Settings.CookiesBlocked, Host);
  case FCookies.ItemIndex of
    1: Settings.CookiesAllowed := Settings.CookiesAllowed + Host + ',';
    2: Settings.CookiesBlocked := Settings.CookiesBlocked + Host + ',';
  end;
  BrowserApp.Settings := Settings;
  BrowserApp.SaveSettings;
  BrowserApp.ApplySettings;
end;

{ ---- Security ---- }

procedure TPageInfoWindow.BuildSecurity(Page: TControl);
begin
  FSecurity := TListView.Create(Page);
  FSecurity.SetBounds(8, 8, 560, 330);
  FSecurity.Anchors := [akLeft, akTop, akRight, akBottom];
  FSecurity.AddColumn('', 200);
  FSecurity.AddColumn('', 340);
  AddButtonTo(Page, 'View C&ertificate', 8, 346, 130, @CertificateClicked);
  AddButtonTo(Page, 'View Coo&kies', 146, 346, 120, @ViewCookiesClicked);
  AddButtonTo(Page, 'View Saved &Passwords', 274, 346, 160, @SavedPasswordsClicked);
end;

procedure TPageInfoWindow.FillSecurity;
var
  Place: THistoryPlace;
  Visits, Index: Integer;
  Cookies: TCookieInfoList;
  Host, Text: string;
  Leaf: TCertificateSummary;
begin
  Host := HostOfUrl(FUrl);
  FSecurity.Clear;
  FSecurity.AddRow(['Web Site Identity', '']);
  FSecurity.AddRow(['Web site:', Host]);
  if FHasSecurity and (Length(FSecurityInfo.Chain) > 0) then
  begin
    Leaf := FSecurityInfo.Chain[0];
    FSecurity.AddRow(['Owner:', Leaf.Organization]);
    FSecurity.AddRow(['Verified by:', FSecurityInfo.Chain[High(FSecurityInfo.Chain)].Organization]);
  end
  else if Pos('https://', LowerCase(FUrl)) = 1 then
    FSecurity.AddRow(['Verified by:', '(the connection''s certificate is not known here)'])
  else
    FSecurity.AddRow(['Verified by:', 'Not specified: this site does not supply identity information']);
  FSecurity.AddRow(['Privacy & History', '']);
  Visits := 0;
  if BrowserApp.History.FindPlace(FUrl, Place) then
    Visits := Place.VisitCount;
  if Visits > 1 then
    Text := 'Yes, ' + IntToStr(Visits - 1) + ' times'
  else
    Text := 'No';
  FSecurity.AddRow(['Have I visited this page before?', Text]);
  Cookies := ListCookies;
  Text := 'No';
  for Index := 0 to High(Cookies) do
    if (Host <> '') and ((Cookies[Index].Host = Host) or (Pos(Cookies[Index].Host, Host) > 0)) then
      Text := 'Yes';
  FSecurity.AddRow(['Is this web site storing cookies?', Text]);
  Text := 'No';
  for Index := 0 to BrowserApp.Passwords.Count - 1 do
    if Pos(Host, BrowserApp.Passwords.Logins[Index].Site) > 0 then
      Text := 'Yes';
  FSecurity.AddRow(['Have I saved any passwords for it?', Text]);
  FSecurity.AddRow(['Technical Details', '']);
  if FHasSecurity and FSecurityInfo.Secure then
  begin
    FSecurity.AddRow(['Connection:', 'Encrypted (' + FSecurityInfo.Protocol + ', ' + FSecurityInfo.Cipher + ')']);
    FSecurity.AddRow(['', 'The page was encrypted before it was sent over the Internet.']);
  end
  else
    FSecurity.AddRow(['Connection:', 'Not encrypted']);
end;

procedure TPageInfoWindow.CertificateClicked(Sender: TControl);
var
  Dialog: TDialog;
  List: TListView;
  Index: Integer;
  Item: TCertificateSummary;
begin
  Dialog := TDialog.CreateDialog('Certificate Viewer: "' + HostOfUrl(FUrl) + '"', 560, 420, Self);
  try
    List := TListView.Create(Dialog.Root);
    List.SetBounds(8, 8, 544, 370);
    List.AddColumn('Field', 150);
    List.AddColumn('Value', 380);
    if not FHasSecurity or (Length(FSecurityInfo.Chain) = 0) then
      List.AddRow(['', 'No certificate: the page did not come over a TLS connection the browser knows of.']);
    for Index := 0 to High(FSecurityInfo.Chain) do
    begin
      Item := FSecurityInfo.Chain[Index];
      List.AddRow(['Certificate ' + IntToStr(Index + 1), Item.CommonName]);
      List.AddRow(['Issued To', Item.Subject]);
      List.AddRow(['Organization', Item.Organization]);
      List.AddRow(['Issued By', Item.Issuer]);
      List.AddRow(['Serial Number', Item.SerialNumber]);
      List.AddRow(['Issued On', Item.ValidFrom]);
      List.AddRow(['Expires On', Item.ValidUntil]);
      List.AddRow(['SHA-256 Fingerprint', Item.Sha256Fingerprint]);
    end;
    Dialog.AddButton('&Close', ResultOk, 560 - 8 - 75, 420 - 8 - 23, 75, 23, True, True);
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

procedure TPageInfoWindow.ViewCookiesClicked(Sender: TControl);
begin
  ShowCookies(Self);
end;

procedure TPageInfoWindow.SavedPasswordsClicked(Sender: TControl);
begin
  ShowSavedPasswords(Self);
end;

procedure ShowPageInfo(View: TWebView; Owner: TWindow; Tab: Integer);
var
  Window: TPageInfoWindow;
begin
  if View = nil then
    Exit;
  Window := TPageInfoWindow.CreateFor(View, Tab);
  Window.Show;
  Say('page-info open ' + View.Url);
end;

procedure PageInfoArrived(View: TWebView; constref Info: TWebPageInfo);
var
  Index: Integer;
begin
  for Index := OpenWindows.Count - 1 downto 0 do
    if TPageInfoWindow(OpenWindows[Index]).FView = View then
    begin
      TPageInfoWindow(OpenWindows[Index]).TakeInfo(Info);
      TPageInfoWindow(OpenWindows[Index]).FView := nil;
    end;
end;

initialization
  OpenWindows := TList.Create;
finalization
  OpenWindows.Free;
end.
