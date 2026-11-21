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
  Options > Applications: what a download of each content type does -
  saved to the downloads folder, or always asking where. The list (a
  content type and its action) with a search box; the chosen row's
  action is changed in the box under it. Kept as ContentActions
  ("type=save;type=ask"); ContentActionFor answers for a download.
}
unit Browser.Options.Applications;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.EditBox,
  Controls.ListView,
  Controls.ComboBox,
  Browser.Settings,
  Browser.Options.Pane;

type
  TApplicationsPane = class(TOptionsPane)
  private
    FSearch: TEditBox;
    FList: TListView;
    FAction: TComboBox;
    FActions: array of string;
    procedure Fill;
    procedure SearchChanged(Sender: TControl);
    procedure RowChosen(Sender: TControl);
    procedure ActionChosen(Sender: TControl);
  public
    procedure Build; override;
    procedure Load(constref Settings: TBrowserSettings); override;
    procedure Store(var Settings: TBrowserSettings); override;
  end;

{ 'ask' or 'save' for a download of MimeType named FileName. }
function ContentActionFor(constref Settings: TBrowserSettings; const MimeType, FileName: string): string;

implementation

uses
  SysUtils;

type
  TContentType = record
    Mime: string;
    Description: string;
    Extensions: string;
  end;

const
  ContentTypes: array[0..9] of TContentType = (
    (Mime: 'application/pdf'; Description: 'PDF document'; Extensions: '.pdf'),
    (Mime: 'application/zip'; Description: 'ZIP archive'; Extensions: '.zip'),
    (Mime: 'application/x-tar'; Description: 'Tape archive'; Extensions: '.tar.gz.tgz.xz.bz2'),
    (Mime: 'application/octet-stream'; Description: 'Binary file'; Extensions: '.bin.exe.img.iso'),
    (Mime: 'audio/mpeg'; Description: 'Audio'; Extensions: '.mp3.ogg.wav.flac'),
    (Mime: 'video/mp4'; Description: 'Video'; Extensions: '.mp4.webm.mkv.avi'),
    (Mime: 'image/png'; Description: 'Image'; Extensions: '.png.jpg.jpeg.gif.bmp.webp'),
    (Mime: 'text/plain'; Description: 'Text document'; Extensions: '.txt.log.md'),
    (Mime: 'application/msword'; Description: 'Office document'; Extensions: '.doc.docx.odt.xls.xlsx.ods'),
    (Mime: 'font/ttf'; Description: 'Font'; Extensions: '.ttf.otf.woff'));
  ActionNames: array[0..1] of string = ('Save File', 'Always ask');
  ActionValues: array[0..1] of string = ('save', 'ask');

function StoredAction(const Text, Mime: string): string;
var
  Pairs: TStringArray;
  Index: Integer;
begin
  Result := '';
  Pairs := Text.Split([';']);
  for Index := 0 to High(Pairs) do
    if SameText(Copy(Pairs[Index], 1, Length(Mime) + 1), Mime + '=') then
      Exit(Copy(Pairs[Index], Length(Mime) + 2, MaxInt));
end;

function ContentActionFor(constref Settings: TBrowserSettings; const MimeType, FileName: string): string;
var
  Index: Integer;
  Extension: string;
begin
  Extension := LowerCase(ExtractFileExt(FileName));
  for Index := 0 to High(ContentTypes) do
    if SameText(ContentTypes[Index].Mime, MimeType) or
       ((Extension <> '') and (Pos(Extension + '.', ContentTypes[Index].Extensions + '.') > 0)) then
    begin
      Result := StoredAction(Settings.ContentActions, ContentTypes[Index].Mime);
      if Result <> '' then
        Exit;
    end;
  if Settings.AskWhereToSave then
    Result := 'ask'
  else
    Result := 'save';
end;

procedure TApplicationsPane.Build;
begin
  FSearch := AddEdit(Page, PaneMargin, 10, PaneWidth - 2 * PaneMargin);
  FSearch.Placeholder := 'Search';
  FSearch.OnChange := @SearchChanged;
  FList := TListView.Create(Page);
  FList.SetBounds(PaneMargin, 38, PaneWidth - 2 * PaneMargin, 230);
  FList.AddColumn('Content Type', 300);
  FList.AddColumn('Action', 200);
  FList.OnChange := @RowChosen;
  AddLabel(Page, '&Action for the chosen type:', PaneMargin, 276, 200);
  FAction := AddCombo(Page, ActionNames, 210, 276, 160);
  FAction.OnChange := @ActionChosen;
end;

procedure TApplicationsPane.Fill;
var
  Index, Row, Action: Integer;
begin
  FList.Clear;
  for Index := 0 to High(ContentTypes) do
  begin
    if (Trim(FSearch.Text) <> '') and (Pos(LowerCase(Trim(FSearch.Text)), LowerCase(ContentTypes[Index].Description +
       ' ' + ContentTypes[Index].Mime)) = 0) then
      Continue;
    Action := 0;
    if FActions[Index] = 'ask' then
      Action := 1;
    Row := FList.AddRow([ContentTypes[Index].Description + ' (' + ContentTypes[Index].Mime + ')',
      ActionNames[Action]]);
    FList.Items[Row].Data := Pointer(PtrInt(Index + 1));
  end;
end;

procedure TApplicationsPane.Load(constref Settings: TBrowserSettings);
var
  Index: Integer;
begin
  SetLength(FActions, Length(ContentTypes));
  for Index := 0 to High(ContentTypes) do
  begin
    FActions[Index] := StoredAction(Settings.ContentActions, ContentTypes[Index].Mime);
    if FActions[Index] = '' then
      if Settings.AskWhereToSave then
        FActions[Index] := 'ask'
      else
        FActions[Index] := 'save';
  end;
  Fill;
end;

procedure TApplicationsPane.Store(var Settings: TBrowserSettings);
var
  Index: Integer;
  Text: string;
begin
  Text := '';
  for Index := 0 to High(ContentTypes) do
  begin
    if Text <> '' then
      Text := Text + ';';
    Text := Text + ContentTypes[Index].Mime + '=' + FActions[Index];
  end;
  Settings.ContentActions := Text;
end;

procedure TApplicationsPane.SearchChanged(Sender: TControl);
begin
  Fill;
end;

procedure TApplicationsPane.RowChosen(Sender: TControl);
var
  Index: PtrInt;
begin
  if FList.ItemIndex < 0 then
    Exit;
  Index := PtrInt(FList.Items[FList.ItemIndex].Data) - 1;
  if (Index >= 0) and (Index <= High(FActions)) then
    if FActions[Index] = 'ask' then
      FAction.ItemIndex := 1
    else
      FAction.ItemIndex := 0;
end;

procedure TApplicationsPane.ActionChosen(Sender: TControl);
var
  Index: PtrInt;
  Row: Integer;
begin
  Row := FList.ItemIndex;
  if Row < 0 then
    Exit;
  Index := PtrInt(FList.Items[Row].Data) - 1;
  if (Index < 0) or (Index > High(FActions)) then
    Exit;
  FActions[Index] := ActionValues[FAction.ItemIndex];
  FList.Cells[Row, 1] := ActionNames[FAction.ItemIndex];
end;

end.
