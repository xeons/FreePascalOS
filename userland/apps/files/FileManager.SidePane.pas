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
  The pane at the right, showing the selection in one of two ways
  (Alt+Shift+P, Alt+P):

  * details: the thumbnail (or a large icon), the name, and its
    properties: type, size, the dates, the dimensions of a picture, the
    length of a sound, where it is, owner and permissions; for several
    items their number and total size; with nothing selected, the page;
  * preview: what the file holds (Controls.PreviewHost): a web page in
    a web view (libwebview, scripts off), a picture, text or code; a
    sound's format and length, a folder's contents, as a summary; an
    item in an archive or the recycle bin, its details.

  It prints "preview KIND PATH" when it shows a file (image, text, web,
  summary or none) for tests.
}
unit FileManager.SidePane;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.Base,
  Controls.PreviewHost,
  Controls.ItemViewItems,
  FileManager.Entries,
  FileManager.Locations;

type
  TSidePaneKind = (SidePaneDetails, SidePanePreview);

  TSidePane = class(TPreviewHost)
  private
    FKind: TSidePaneKind;
    procedure ShowDetailsOf(Entry: TFolderEntry; Item: TItemViewItem);
    procedure ShowSummaryOfMany(Entries: TList);
    procedure ShowLocationSummary(const Location: TLocation; Count: LongInt);
    procedure PreviewEntry(Entry: TFolderEntry; Item: TItemViewItem);
    function FolderSummary(Entry: TFolderEntry): TPreviewSummary;
  public
    constructor Create(AParent: TControl); override;
    { Shows the selection: Entries (with their items, for thumbnails),
      or the page when none is selected. }
    procedure ShowSelection(Entries: TList; Items: TList; const Location: TLocation; ItemCount: LongInt);
    property Kind: TSidePaneKind read FKind write FKind;
  end;

implementation

uses
  SysUtils,
  Controls.Icons,
  Controls.FolderListing,
  WebView.Control,
  FileManager.Items,
  FileManager.FileKinds,
  FileManager.FolderReading,
  FileManager.ItemColumns,
  FileManager.AudioInfo,
  FileManager.Paths,
  FileManager.FolderView,
  FileManager.Output;

type
  { Controls.FolderListing has a TFolderEntry of its own. }
  TFolderEntry = FileManager.Entries.TFolderEntry;

type
  { Web pages in a web view, its scripts off: a preview must not run
    anything. }
  TWebPagePreviewProvider = class(TPreviewProvider)
  public
    function CanPreview(const Path, Extension: string): Boolean; override;
    function CreatePreview(Parent: TControl; const Path: string): TControl; override;
  end;

function TWebPagePreviewProvider.CanPreview(const Path, Extension: string): Boolean;
begin
  Result := (Extension = 'html') or (Extension = 'htm') or (Extension = 'xhtml');
end;

function TWebPagePreviewProvider.CreatePreview(Parent: TControl; const Path: string): TControl;
var
  View: TWebView;
begin
  View := TWebView.Create(Parent);
  View.ScriptingEnabled := False;
  if not View.Navigate('file://' + Path) then
  begin
    View.Free;
    Exit(nil);
  end;
  Result := View;
end;

constructor TSidePane.Create(AParent: TControl);
begin
  inherited Create(AParent);
  AddProvider(TWebPagePreviewProvider.Create);
  AddProvider(TImagePreviewProvider.Create);
  AddProvider(TTextPreviewProvider.Create);
end;

function NewSummary(Host: TControl; Entry: TFolderEntry; Item: TItemViewItem): TPreviewSummary;
begin
  Result := TPreviewSummary.Create(Host);
  Result.SetTitle(Entry.Item.Name, EntryIconName(Entry), StockIconFile);
  if (Item <> nil) and Item.HasThumbnail then
    Result.SetPicture(Item.Thumbnail);
end;

procedure AddIfThere(Summary: TPreviewSummary; const Name, Value: string);
begin
  if Value <> '' then
    Summary.AddLine(Name, Value);
end;

procedure TSidePane.ShowDetailsOf(Entry: TFolderEntry; Item: TItemViewItem);
var
  Summary: TPreviewSummary;
  Audio: TAudioInfo;
begin
  Summary := NewSummary(Self, Entry, Item);
  AddIfThere(Summary, 'Type', EntryTypeText(Entry));
  if Entry.Kind = EntryVolume then
  begin
    AddIfThere(Summary, 'File system', Entry.FileSystemType);
    AddIfThere(Summary, 'Total size', SizeText(Entry.TotalBytes));
    AddIfThere(Summary, 'Free space', SizeText(Entry.FreeBytes));
    AddIfThere(Summary, 'Opens at', Entry.FullPath);
  end
  else
  begin
    AddIfThere(Summary, 'Size', ColumnText(Entry, ColumnSize));
    AddIfThere(Summary, 'Dimensions', ColumnText(Entry, ColumnDimensions));
    if (Entry.Kind = EntryFile) and (FileKindOfName(Entry.Item.Name) = FileKindMusic) and
       ReadAudioInfo(Entry.FullPath, Audio) then
    begin
      AddIfThere(Summary, 'Length', DurationText(Audio.DurationSeconds));
      AddIfThere(Summary, 'Format', Format('%d Hz, %d channels, %d bits', [Audio.SampleRate, Audio.Channels,
        Audio.BitsPerSample]));
    end;
    AddIfThere(Summary, 'Date modified', ColumnText(Entry, ColumnModified));
    AddIfThere(Summary, 'Date created', ColumnText(Entry, ColumnCreated));
    AddIfThere(Summary, 'Date accessed', ColumnText(Entry, ColumnAccessed));
    if Entry.Kind = EntryTrashed then
    begin
      AddIfThere(Summary, 'Original location', ColumnText(Entry, ColumnOriginalLocation));
      AddIfThere(Summary, 'Date deleted', ColumnText(Entry, ColumnDeleted));
    end
    else
      AddIfThere(Summary, 'Location', Entry.Folder);
    AddIfThere(Summary, 'Owner', ColumnText(Entry, ColumnOwner));
    AddIfThere(Summary, 'Permissions', ColumnText(Entry, ColumnPermissions));
    if Entry.Item.IsLink then
      AddIfThere(Summary, 'Points to', Entry.Item.LinkTarget);
  end;
  ShowControl(Summary);
end;

procedure TSidePane.ShowSummaryOfMany(Entries: TList);
var
  Summary: TPreviewSummary;
  Index: LongInt;
  Total: QWord;
  Folders: LongInt;
  Entry: TFolderEntry;
begin
  Summary := TPreviewSummary.Create(Self);
  Summary.SetTitle(IntToStr(Entries.Count) + ' items selected', 'file', StockIconFile);
  Total := 0;
  Folders := 0;
  for Index := 0 to Entries.Count - 1 do
  begin
    Entry := TFolderEntry(Entries[Index]);
    if Entry.IsFolder then
      Inc(Folders)
    else
      Total := Total + Entry.Item.SizeInBytes;
  end;
  Summary.AddLine('Files', IntToStr(Entries.Count - Folders));
  Summary.AddLine('Folders', IntToStr(Folders));
  Summary.AddLine('Size of files', SizeText(Total));
  ShowControl(Summary);
end;

procedure TSidePane.ShowLocationSummary(const Location: TLocation; Count: LongInt);
var
  Summary: TPreviewSummary;
begin
  Summary := TPreviewSummary.Create(Self);
  Summary.SetTitle(LocationTitle(Location), LocationIcon(Location), StockIconFolder);
  if Count = 1 then
    Summary.AddLine('Contains', '1 item')
  else
    Summary.AddLine('Contains', IntToStr(Count) + ' items');
  if Location.Kind in [LocationFolder, LocationArchive] then
    Summary.AddLine('Location', LocationAddress(Location));
  ShowControl(Summary);
end;

function TSidePane.FolderSummary(Entry: TFolderEntry): TPreviewSummary;
var
  Items: TFolderItems;
  Index: LongInt;
  Files: LongInt;
  Folders: LongInt;
  Total: QWord;
begin
  Result := NewSummary(Self, Entry, nil);
  Result.SetTitle(Entry.Item.Name, EntryIconName(Entry), StockIconFolder);
  if ReadFolderItems(Entry.FullPath, False, Items) <> 0 then
  begin
    Result.AddLine('Contains', 'Cannot be read');
    Exit;
  end;
  Files := 0;
  Folders := 0;
  Total := 0;
  for Index := 0 to High(Items) do
    if IsFolderItem(Items[Index]) then
      Inc(Folders)
    else
    begin
      Inc(Files);
      Total := Total + Items[Index].SizeInBytes;
    end;
  Result.AddLine('Files', IntToStr(Files));
  Result.AddLine('Folders', IntToStr(Folders));
  Result.AddLine('Size of files', SizeText(Total));
  Result.AddLine('Date modified', ColumnText(Entry, ColumnModified));
end;

procedure TSidePane.PreviewEntry(Entry: TFolderEntry; Item: TItemViewItem);
var
  Summary: TPreviewSummary;
  Audio: TAudioInfo;
  Shown: string;
begin
  if (Entry.Kind = EntryFile) and Entry.IsFolder then
  begin
    ShowControl(FolderSummary(Entry));
    Say('preview summary ' + Entry.FullPath);
    Exit;
  end;
  if (Entry.Kind <> EntryFile) or (Entry.Item.Kind <> ItemFile) then
  begin
    ShowDetailsOf(Entry, Item);
    Say('preview summary ' + Entry.FullPath);
    Exit;
  end;
  if (FileKindOfName(Entry.Item.Name) = FileKindMusic) then
  begin
    Summary := NewSummary(Self, Entry, Item);
    if ReadAudioInfo(Entry.FullPath, Audio) then
    begin
      AddIfThere(Summary, 'Length', DurationText(Audio.DurationSeconds));
      Summary.AddLine('Sample rate', IntToStr(Audio.SampleRate) + ' Hz');
      Summary.AddLine('Channels', IntToStr(Audio.Channels));
      Summary.AddLine('Bits per sample', IntToStr(Audio.BitsPerSample));
    end;
    Summary.AddLine('Size', SizeText(Entry.Item.SizeInBytes));
    ShowControl(Summary);
    Say('preview summary ' + Entry.FullPath);
    Exit;
  end;
  if ShowFile(Entry.FullPath) then
  begin
    if Preview is TWebView then
      Shown := 'web'
    else if Preview.ClassName = 'TPictureBox' then
      Shown := 'image'
    else
      Shown := 'text';
    Say('preview ' + Shown + ' ' + Entry.FullPath);
  end
  else
    Say('preview none ' + Entry.FullPath);
end;

procedure TSidePane.ShowSelection(Entries: TList; Items: TList; const Location: TLocation; ItemCount: LongInt);
var
  Item: TItemViewItem;
begin
  if Entries.Count = 0 then
  begin
    if FKind = SidePaneDetails then
      ShowLocationSummary(Location, ItemCount)
    else
      ShowMessage('Select a file to preview.');
    Exit;
  end;
  if Entries.Count > 1 then
  begin
    ShowSummaryOfMany(Entries);
    Exit;
  end;
  Item := nil;
  if Items.Count > 0 then
    Item := TItemViewItem(Items[0]);
  if FKind = SidePaneDetails then
    ShowDetailsOf(TFolderEntry(Entries[0]), Item)
  else
    PreviewEntry(TFolderEntry(Entries[0]), Item);
end;

end.
