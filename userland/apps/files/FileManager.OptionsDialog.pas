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
  The file manager's options, on two pages:

    General  open each folder in the same window or a new one; open an
             item with one click or two; Home shows recent files and
             favourites; privacy: clear the recent files, the search
             history and the thumbnails kept
    View     hidden items, file name extensions, item check boxes,
             compact view, the preview or details pane at start, and
             Reset views (every folder back to the defaults)

  The clearing and resetting happen at once; the rest when OK is
  pressed (FileManager.Settings keeps them).
}
unit FileManager.OptionsDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  FileManager.Settings;

{ Shows the options; True (Options changed) if OK was pressed. }
function ShowOptionsDialog(Owner: TWindow; var Options: TFileManagerOptions): Boolean;

implementation

uses
  SysUtils,
  Controls.Base,
  Controls.Window,
  Controls.Dialogs,
  Controls.Panels,
  Controls.Buttons,
  Controls.Toggles,
  Controls.TabControl,
  Controls.MessageBoxes,
  Controls.ThumbnailCache,
  FileManager.UserLists,
  FileManager.TestPlaces,
  FileManager.Output;

const
  DialogWidth = 420;
  DialogHeight = 380;

type
  TOptionsHelper = class
  public
    Dialog: TDialog;
    procedure ClearClicked(Sender: TControl);
    procedure ResetClicked(Sender: TControl);
  end;

procedure TOptionsHelper.ClearClicked(Sender: TControl);
begin
  ClearUserList(ListRecent);
  ClearUserList(ListSearchHistory);
  ClearThumbnailCache;
  Say('privacy cleared');
  ShowMessageBox('Options', 'The recent files, the search history and the thumbnails were cleared.', MessageOk,
    SignInformation, Dialog);
end;

procedure TOptionsHelper.ResetClicked(Sender: TControl);
begin
  ForgetViews;
  Say('views reset');
  ShowMessageBox('Options', 'Every folder is back to the default view.', MessageOk, SignInformation, Dialog);
end;

function NewGroup(Parent: TControl; const Caption: string; Top, Height: LongInt): TGroupBox;
begin
  Result := TGroupBox.Create(Parent);
  Result.Text := Caption;
  Result.SetBounds(8, Top, DialogWidth - 40, Height);
end;

function NewCheck(Parent: TControl; const Caption: string; Top: LongInt; Checked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Parent);
  Result.Text := Caption;
  Result.Checked := Checked;
  Result.SetBounds(12, Top, DialogWidth - 64, 20);
end;

function NewRadio(Parent: TControl; const Caption: string; Top: LongInt; Checked: Boolean): TRadioButton;
begin
  Result := TRadioButton.Create(Parent);
  Result.Text := Caption;
  Result.Checked := Checked;
  Result.SetBounds(12, Top, DialogWidth - 64, 20);
end;

function ShowOptionsDialog(Owner: TWindow; var Options: TFileManagerOptions): Boolean;
var
  Dialog: TDialog;
  Pages: TTabControl;
  General: TControl;
  View: TControl;
  Group: TGroupBox;
  SameWindow: TRadioButton;
  NewWindow: TRadioButton;
  SingleClick: TRadioButton;
  DoubleClick: TRadioButton;
  ShowRecent: TCheckBox;
  ShowFavorites: TCheckBox;
  ClearButton: TButton;
  Hidden: TCheckBox;
  Extensions: TCheckBox;
  CheckBoxes: TCheckBox;
  Compact: TCheckBox;
  PreviewPane: TCheckBox;
  DetailsPane: TCheckBox;
  ResetButton: TButton;
  Helper: TOptionsHelper;
begin
  Dialog := TDialog.CreateDialog('Folder options', DialogWidth, DialogHeight, Owner);
  Helper := TOptionsHelper.Create;
  Helper.Dialog := Dialog;
  try
    Pages := TTabControl.Create(Dialog.Root);
    Pages.SetBounds(8, 8, DialogWidth - 16, DialogHeight - 52);
    General := Pages.AddPage('General');
    View := Pages.AddPage('View');

    Group := NewGroup(General, 'Open folders', 8, 70);
    SameWindow := NewRadio(Group, 'Open each folder in the &same window', 20, not Options.OpenInNewWindow);
    NewWindow := NewRadio(Group, 'Open each folder in a &new window', 42, Options.OpenInNewWindow);
    Group := NewGroup(General, 'Click items as follows', 84, 70);
    SingleClick := NewRadio(Group, 'Single-click to &open an item', 20, Options.SingleClick);
    DoubleClick := NewRadio(Group, '&Double-click to open an item', 42, not Options.SingleClick);
    Group := NewGroup(General, 'Privacy', 160, 110);
    ShowRecent := NewCheck(Group, 'Show &recent files on Home', 20, Options.ShowRecent);
    ShowFavorites := NewCheck(Group, 'Show &favorites on Home', 42, Options.ShowFavorites);
    ClearButton := TButton.Create(Group);
    ClearButton.Text := '&Clear';
    ClearButton.SetBounds(12, 72, 90, 24);
    ClearButton.OnClick := @Helper.ClearClicked;

    Hidden := NewCheck(View, 'Show &hidden files and folders', 12, Options.ShowHidden);
    Extensions := NewCheck(View, 'Hide &extensions of file names', 36, not Options.ShowExtensions);
    CheckBoxes := NewCheck(View, 'Use check &boxes to select items', 60, Options.ShowCheckBoxes);
    Compact := NewCheck(View, 'De&crease space between items (compact view)', 84, Options.Compact);
    PreviewPane := NewCheck(View, 'Show the &preview pane at start', 108, Options.ShowPreviewPane);
    DetailsPane := NewCheck(View, 'Show the &details pane at start', 132, Options.ShowDetailsPane);
    ResetButton := TButton.Create(View);
    ResetButton.Text := '&Reset views';
    ResetButton.SetBounds(12, 168, 110, 24);
    ResetButton.OnClick := @Helper.ResetClicked;

    Dialog.AddButton('OK', ResultOk, DialogWidth - 8 - 2 * 75 - 8, DialogHeight - 8 - 26, 75, 26, True);
    Dialog.AddButton('Cancel', ResultCancel, DialogWidth - 8 - 75, DialogHeight - 8 - 26, 75, 26, False, True);
    Say('options-dialog');
    TellControlPlace('options-clear', ClearButton);
    Result := Dialog.ShowModal = ResultOk;
    if not Result then
      Exit;
    Options.OpenInNewWindow := NewWindow.Checked and not SameWindow.Checked;
    Options.SingleClick := SingleClick.Checked and not DoubleClick.Checked;
    Options.ShowRecent := ShowRecent.Checked;
    Options.ShowFavorites := ShowFavorites.Checked;
    Options.ShowHidden := Hidden.Checked;
    Options.ShowExtensions := not Extensions.Checked;
    Options.ShowCheckBoxes := CheckBoxes.Checked;
    Options.Compact := Compact.Checked;
    Options.ShowPreviewPane := PreviewPane.Checked;
    Options.ShowDetailsPane := DetailsPane.Checked and not PreviewPane.Checked;
  finally
    Helper.Free;
    Dialog.Free;
  end;
end;

end.
