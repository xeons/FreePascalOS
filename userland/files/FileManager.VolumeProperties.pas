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
  The properties of a volume (Sys.Volumes): its label, name, file
  system, where it is, whether it can be unplugged or only read, its
  size, and how much of it is used and free, with a bar. It prints
  "properties-volume NAME TYPE TOTAL FREE" when it opens.
}
unit FileManager.VolumeProperties;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

procedure ShowVolumeProperties(const VolumeName: string; Owner: TWindow);

implementation

uses
  SysUtils,
  Sys.Volumes,
  Controls.Base,
  Controls.Labels,
  Controls.ProgressBar,
  Controls.Dialogs,
  Controls.MessageBoxes,
  Controls.FolderListing,
  FileManager.TestPlaces,
  FileManager.Output;

const
  DialogWidth = 360;
  Margin = 12;
  RowHeight = 20;
  CaptionWidth = 100;
  RowCount = 8;
  BarSteps = 1000;

procedure AddRow(Dialog: TDialog; Row: LongInt; const Caption, Value: string);
var
  CaptionLabel: TLabel;
  ValueLabel: TLabel;
begin
  CaptionLabel := TLabel.Create(Dialog.Root);
  CaptionLabel.ShowsMnemonic := False;
  CaptionLabel.Text := Caption;
  CaptionLabel.SetBounds(Margin, Margin + Row * RowHeight, CaptionWidth, RowHeight);
  ValueLabel := TLabel.Create(Dialog.Root);
  ValueLabel.ShowsMnemonic := False;
  ValueLabel.Text := Value;
  ValueLabel.SetBounds(Margin + CaptionWidth, Margin + Row * RowHeight, DialogWidth - 2 * Margin - CaptionWidth,
    RowHeight);
end;

function YesOrNo(Value: Boolean): string;
begin
  if Value then
    Result := 'Yes'
  else
    Result := 'No';
end;

procedure ShowVolumeProperties(const VolumeName: string; Owner: TWindow);
var
  Description: TVolumeDescription;
  Dialog: TDialog;
  Bar: TProgressBar;
  Height: LongInt;
  VolumeLabel: string;
  Used: QWord;
begin
  if not FindVolumeDescription(PChar(VolumeName), Description) then
  begin
    ShowMessageBox('Properties', 'The volume ' + VolumeName + ' is not there any more.', MessageOk, SignError, Owner);
    Exit;
  end;
  VolumeLabel := StrPas(@Description.VolumeLabel[0]);
  if VolumeLabel = '' then
    VolumeLabel := '(none)';
  Height := Margin + RowCount * RowHeight + 8 + 18 + Margin + 23 + Margin;
  Dialog := TDialog.CreateDialog(VolumeName + ' Properties', DialogWidth, Height, Owner);
  try
    AddRow(Dialog, 0, 'Label:', VolumeLabel);
    AddRow(Dialog, 1, 'Name:', VolumeName);
    AddRow(Dialog, 2, 'File system:', StrPas(@Description.FileSystemType[0]));
    AddRow(Dialog, 3, 'Location:', StrPas(@Description.MountPoint[0]));
    AddRow(Dialog, 4, 'Removable:', YesOrNo(Description.IsRemovable));
    AddRow(Dialog, 5, 'Read only:', YesOrNo(Description.IsReadOnly));
    AddRow(Dialog, 6, 'Size:', SizeText(Description.TotalBytes));
    Used := 0;
    if Description.HasFreeSpace then
    begin
      Used := Description.TotalBytes - Description.FreeBytes;
      AddRow(Dialog, 7, 'Free:', SizeText(Description.FreeBytes) + ' (' + SizeText(Used) + ' used)');
    end
    else
      AddRow(Dialog, 7, 'Free:', 'Unknown');
    Bar := TProgressBar.Create(Dialog.Root);
    Bar.Maximum := BarSteps;
    if Description.TotalBytes > 0 then
      Bar.Position := Used * BarSteps div Description.TotalBytes;
    Bar.SetBounds(Margin, Margin + RowCount * RowHeight + 8, DialogWidth - 2 * Margin, 18);
    Dialog.AddButton('Close', ResultOk, DialogWidth - Margin - 75, Height - Margin - 23, 75, 23, True, True);
    Dialog.FocusControl(Dialog.DefaultControl);
    Say('properties-volume ' + VolumeName + ' ' + StrPas(@Description.FileSystemType[0]) + ' ' +
      IntToStr(Description.TotalBytes) + ' ' + IntToStr(Description.FreeBytes));
    TellControlPlace('properties-close', Dialog.DefaultControl);
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

end.
