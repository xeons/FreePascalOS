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
  What kind of file an item is, from what can be told without reading
  it: folders, programs (a file with an execute permission bit), text
  documents (by their extension), pipes and devices, and other files.
  The Type column's words come from here, and so does the icon.

  Whether a file without a telling extension is text is decided when it
  is opened, by looking at its first bytes (FileManager.Associations).

  Plain logic: the host checks it (make files-test).
}
unit FileManager.FileTypes;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items;

type
  TFileType = (FileTypeFolder, FileTypeProgram, FileTypeText, FileTypePipe, FileTypeDevice, FileTypeBrokenLink,
    FileTypeOther);

function FileTypeOf(const Item: TFolderItem): TFileType;
{ The Type column: "Folder", "Program", "Text document", "PNG file",
  "File", ... }
function TypeTextOf(const Item: TFolderItem): string;
{ Extensions whose files are text to edit (small letters, no dot). }
function IsTextExtension(const Extension: string): Boolean;

implementation

uses
  SysUtils,
  FileManager.Paths;

const
  TextExtensions: array[0..31] of string = ('txt', 'text', 'md', 'markdown', 'log', 'conf', 'cfg', 'ini',
    'settings', 'pas', 'pp', 'inc', 'lpr', 'c', 'h', 'cpp', 'hpp', 'sh', 'py', 'json', 'xml', 'html', 'htm', 'css',
    'js', 'csv', 'tsv', 'asm', 's', 'mk', 'yaml', 'toml');

function IsTextExtension(const Extension: string): Boolean;
var
  Index: LongInt;
begin
  for Index := Low(TextExtensions) to High(TextExtensions) do
    if TextExtensions[Index] = Extension then
      Exit(True);
  Result := False;
end;

function FileTypeOf(const Item: TFolderItem): TFileType;
begin
  if Item.IsBrokenLink then
    Exit(FileTypeBrokenLink);
  case Item.Kind of
    ItemFolder: Result := FileTypeFolder;
    ItemPipe: Result := FileTypePipe;
    ItemDevice: Result := FileTypeDevice;
    ItemFile:
      if IsTextExtension(ExtensionOf(Item.Name)) then
        Result := FileTypeText
      else if (Item.Mode and ExecutePermissionBits) <> 0 then
        Result := FileTypeProgram
      else
        Result := FileTypeOther;
  else
    Result := FileTypeOther;
  end;
end;

function TypeTextOf(const Item: TFolderItem): string;
var
  Extension: string;
begin
  case FileTypeOf(Item) of
    FileTypeFolder: Result := 'Folder';
    FileTypeProgram: Result := 'Program';
    FileTypeText: Result := 'Text document';
    FileTypePipe: Result := 'Pipe';
    FileTypeDevice: Result := 'Device';
    FileTypeBrokenLink: Result := 'Broken link';
  else
    begin
      Extension := ExtensionOf(Item.Name);
      if (Item.Kind = ItemFile) and (Extension <> '') and (Length(Extension) <= 8) then
        Result := UpperCase(Extension) + ' file'
      else
        Result := 'File';
    end;
  end;
  if Item.IsLink and not Item.IsBrokenLink then
    Result := Result + ' (link)';
end;

end.
