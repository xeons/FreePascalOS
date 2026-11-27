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
  The icon files themselves: every icon the system's programs ask for
  is there, and every file listed in the theme's index holds the eight
  sizes exactly (16, 20, 24, 32, 40, 48, 64, 96, square), each decoding
  with libimage, with a real alpha channel (clear corners, opaque
  middle). The pointer's cursor files hold their sizes with a hotspot
  inside each picture.
}
unit IconTest.Files;

{$mode objfpc}
{$H+}

interface

procedure CheckIconFiles(const IconDirectory: string);
procedure CheckPointerFiles(const PointerDirectory: string);

implementation

uses
  SysUtils,
  Classes,
  Image.Model,
  Image.Errors,
  Image.Files,
  Image.StandardCodecs,
  Image.Ico.Directory,
  Image.Ico.Reading,
  IconTest.Checks;

const
  IconSizes: array[0..7] of LongInt = (16, 20, 24, 32, 40, 48, 64, 96);
  PointerSizes: array[0..5] of LongInt = (24, 32, 40, 48, 64, 96);
  { Every icon the system's code draws (Controls.Icons' stock icons and
    overlays, the message boxes' signs, the taskbar's pictures, the
    programs' icons, the toolbars' and the Start menu's), and the rest
    of the set's list. }
  RequiredIcons: array[0..110] of string = (
    'computer', 'home', 'network', 'internet', 'drive', 'drive-removable', 'drive-optical', 'drive-usb',
    'memory-card', 'drive-ssd', 'trash-empty', 'trash-full', 'applications', 'favourites', 'library',
    'folder', 'folder-open', 'folder-documents', 'folder-pictures', 'folder-music', 'folder-videos',
    'folder-downloads', 'folder-projects', 'folder-public', 'folder-templates', 'folder-compressed',
    'overlay-shortcut', 'overlay-locked', 'overlay-synced', 'overlay-updating', 'overlay-attention',
    'file', 'file-text', 'file-document', 'file-spreadsheet', 'file-presentation', 'file-pdf', 'file-image',
    'file-audio', 'file-video', 'file-archive', 'file-executable', 'file-settings', 'file-font', 'file-unknown',
    'app-file-manager', 'app-terminal', 'app-text-editor', 'app-web-browser', 'app-mail', 'app-calendar',
    'app-contacts', 'app-media-player', 'app-image-viewer', 'app-paint', 'app-calculator', 'app-control-panel',
    'app-task-manager', 'app-help', 'app-system-info', 'app-volume-control', 'app-components', 'app-themes',
    'app-dialogs', 'app-game', 'app-generic',
    'action-back', 'action-forward', 'action-up', 'action-refresh', 'action-delete', 'action-add',
    'action-remove', 'action-search', 'action-find', 'action-options', 'action-info', 'action-warning',
    'action-error', 'action-question', 'action-new', 'action-open', 'action-save', 'action-print', 'action-cut',
    'action-copy', 'action-paste', 'action-undo', 'action-redo', 'action-bold', 'action-play', 'action-stop',
    'action-zoom', 'action-lock', 'action-log-off', 'action-suspend', 'action-shut-down',
    'dialog-information', 'dialog-warning', 'dialog-error', 'dialog-question',
    'status-network-online', 'status-network-offline', 'status-network-connecting', 'status-network-limited',
    'status-network-no-link', 'status-sound-on', 'status-sound-muted', 'status-battery-full',
    'status-battery-medium', 'status-battery-low');
  RequiredStatusAndDevices: array[0..13] of string = (
    'status-ac-power', 'status-security-ok', 'status-security-warning', 'status-notification',
    'device-printer', 'device-scanner', 'device-camera', 'device-webcam', 'device-audio', 'device-keyboard',
    'device-mouse', 'device-display', 'status-battery-empty', 'status-battery-charging');
  { The file manager's commands and places (iconkit/browsing.py). }
  RequiredBrowsingIcons: array[0..23] of string = ('action-rename', 'action-share', 'action-sort', 'action-view',
    'action-filter', 'action-more', 'action-pin', 'action-unpin', 'action-star', 'action-compress', 'action-extract',
    'action-properties', 'action-select-all', 'action-new-folder', 'action-new-tab', 'action-close',
    'action-preview-pane', 'action-details-pane', 'action-undo-history', 'folder-desktop', 'gallery', 'recent',
    'drive-network', 'network-share');
  RequiredPointers: array[0..10] of string = ('arrow', 'resize-horizontal', 'resize-vertical',
    'resize-diagonal-down', 'resize-diagonal-up', 'text-beam', 'busy', 'hand', 'move', 'not-allowed', 'crosshair');

function ReadBytes(const FileName: string; out Data: TBytes): Boolean;
begin
  Result := True;
  try
    Data := ReadFileBytes(FileName);
  except
    on Exception do
      Result := False;
  end;
end;

{ The theme's index: the names after the comment and "sizes" lines. }
function IndexNames(const IconDirectory: string): TStringList;
var
  Lines: TStringList;
  Index: LongInt;
  Line: string;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    if FileExists(IconDirectory + '/index.txt') then
      Lines.LoadFromFile(IconDirectory + '/index.txt');
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[Index]);
      if (Line = '') or (Line[1] = '#') or (Copy(Line, 1, 6) = 'sizes ') then
        Continue;
      Result.Add(Line);
    end;
  finally
    Lines.Free;
  end;
end;

function AlphaOf(Pixel: LongWord): LongWord;
begin
  Result := Pixel shr 24;
end;

{ Clear somewhere and opaque somewhere: a real alpha channel. }
function HasRealAlpha(Picture: TImage): Boolean;
var
  X: LongInt;
  Y: LongInt;
  Clear: Boolean;
  Opaque: Boolean;
  Alpha: LongWord;
begin
  Clear := False;
  Opaque := False;
  for Y := 0 to Picture.Height - 1 do
    for X := 0 to Picture.Width - 1 do
    begin
      Alpha := AlphaOf(Picture.Line(Y)[X]);
      if Alpha = 0 then
        Clear := True
      else if Alpha = 255 then
        Opaque := True;
    end;
  Result := Clear and Opaque;
end;

{ Has the entry of each size in Sizes once, square, and each decodes to
  that size with real alpha. }
function CheckEntries(const Name: string; Directory: TIconDirectory; const Sizes: array of LongInt;
  out Problem: string): Boolean;
var
  SizeIndex: LongInt;
  Entry: LongInt;
  Found: LongInt;
  Picture: TImage;
begin
  Result := False;
  Problem := '';
  if Directory.Count <> Length(Sizes) then
  begin
    Problem := Format('%d entries', [Directory.Count]);
    Exit;
  end;
  for SizeIndex := 0 to High(Sizes) do
  begin
    Found := -1;
    for Entry := 0 to Directory.Count - 1 do
      if (Directory.Entries[Entry].Width = Sizes[SizeIndex]) and (Directory.Entries[Entry].Height = Sizes[SizeIndex]) then
        Found := Entry;
    if Found < 0 then
    begin
      Problem := Format('no %d pixel entry', [Sizes[SizeIndex]]);
      Exit;
    end;
    try
      Picture := DecodeIconEntry(Directory, Found);
    except
      on E: EImageError do
      begin
        Problem := Format('%d pixels: %s', [Sizes[SizeIndex], E.Message]);
        Exit;
      end;
    end;
    try
      if (Picture.Width <> Sizes[SizeIndex]) or (Picture.Height <> Sizes[SizeIndex]) then
      begin
        Problem := Format('%d pixel entry decodes to %dx%d', [Sizes[SizeIndex], Picture.Width, Picture.Height]);
        Exit;
      end;
      if not HasRealAlpha(Picture) then
      begin
        Problem := Format('%d pixels: no alpha', [Sizes[SizeIndex]]);
        Exit;
      end;
      if Directory.IsCursor and ((Directory.Entries[Found].HotspotX >= Sizes[SizeIndex]) or
         (Directory.Entries[Found].HotspotY >= Sizes[SizeIndex])) then
      begin
        Problem := Format('%d pixels: hotspot outside', [Sizes[SizeIndex]]);
        Exit;
      end;
    finally
      Picture.Free;
    end;
  end;
  Result := True;
end;

function CheckOneFile(const FileName, Name: string; ExpectedType: LongInt; const Sizes: array of LongInt): Boolean;
var
  Data: TBytes;
  Directory: TIconDirectory;
  Problem: string;
begin
  Result := False;
  if not ReadBytes(FileName, Data) then
  begin
    WriteLn('     ', Name, ': missing');
    Exit;
  end;
  if not LooksLikeIconFile(Data, ExpectedType) then
  begin
    WriteLn('     ', Name, ': not an icon file of its type');
    Exit;
  end;
  try
    Directory := TIconDirectory.Create(Data);
  except
    on E: EImageError do
    begin
      WriteLn('     ', Name, ': ', E.Message);
      Exit;
    end;
  end;
  try
    Result := CheckEntries(Name, Directory, Sizes, Problem);
    if not Result then
      WriteLn('     ', Name, ': ', Problem);
  finally
    Directory.Free;
  end;
end;

procedure CheckIconFiles(const IconDirectory: string);
var
  Names: TStringList;
  Index: LongInt;
  AllGood: Boolean;
  Missing: LongInt;
begin
  RegisterStandardImageCodecs;
  Names := IndexNames(IconDirectory);
  try
    Check(Names.Count >= Length(RequiredIcons) + Length(RequiredStatusAndDevices), 'the theme''s index lists the icons');
    Missing := 0;
    for Index := 0 to High(RequiredIcons) do
      if Names.IndexOf(RequiredIcons[Index]) < 0 then
      begin
        WriteLn('     not in the index: ', RequiredIcons[Index]);
        Inc(Missing);
      end;
    for Index := 0 to High(RequiredStatusAndDevices) do
      if Names.IndexOf(RequiredStatusAndDevices[Index]) < 0 then
      begin
        WriteLn('     not in the index: ', RequiredStatusAndDevices[Index]);
        Inc(Missing);
      end;
    for Index := 0 to High(RequiredBrowsingIcons) do
      if Names.IndexOf(RequiredBrowsingIcons[Index]) < 0 then
      begin
        WriteLn('     not in the index: ', RequiredBrowsingIcons[Index]);
        Inc(Missing);
      end;
    CheckEqual(Missing, 0, 'every icon the system draws is in the theme');
    AllGood := True;
    for Index := 0 to Names.Count - 1 do
      if not CheckOneFile(IconDirectory + '/' + Names[Index] + '.ico', Names[Index], IconTypeIcon, IconSizes) then
        AllGood := False;
    Check(AllGood, Format('all %d icon files: 16 to 96 pixels exactly, each decoding with alpha', [Names.Count]));
  finally
    Names.Free;
  end;
end;

procedure CheckPointerFiles(const PointerDirectory: string);
var
  Index: LongInt;
  AllGood: Boolean;
  Data: TBytes;
  Directory: TIconDirectory;
  Entry: LongInt;
  ArrowHotspot: Boolean;
begin
  RegisterStandardImageCodecs;
  AllGood := True;
  for Index := 0 to High(RequiredPointers) do
    if not CheckOneFile(PointerDirectory + '/' + RequiredPointers[Index] + '.cur', RequiredPointers[Index],
       IconTypeCursor, PointerSizes) then
      AllGood := False;
  Check(AllGood, 'every pointer shape''s cursor file: 24 to 96 pixels, alpha, the hotspot inside');
  { The arrow points with its tip: the hotspot is near the top left at
    every size. }
  ArrowHotspot := ReadBytes(PointerDirectory + '/arrow.cur', Data) and LooksLikeIconFile(Data, IconTypeCursor);
  if ArrowHotspot then
  begin
    Directory := TIconDirectory.Create(Data);
    try
      for Entry := 0 to Directory.Count - 1 do
        if (Directory.Entries[Entry].HotspotX > Directory.Entries[Entry].Width div 8) or
           (Directory.Entries[Entry].HotspotY > Directory.Entries[Entry].Height div 8) then
          ArrowHotspot := False;
    finally
      Directory.Free;
    end;
  end;
  Check(ArrowHotspot, 'the arrow''s hotspot is its tip at every size');
end;

end.
