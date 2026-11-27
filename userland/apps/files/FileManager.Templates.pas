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
  What "New" can make besides a folder: a text document, a Markdown
  document, a web page, an empty compressed (ZIP) folder, and whatever
  files the user keeps in ~/Templates (copied, the name kept). Each is
  made under its name ("New text document.txt", numbered if taken) and
  put up for renaming at once.
}
unit FileManager.Templates;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TFileTemplate = record
    Caption: string;
    { The name a new one gets ("New text document.txt"). }
    FileName: string;
    Content: string;
    { A file of ~/Templates to copy ('' for Content). }
    SourcePath: string;
    IconName: string;
  end;
  TFileTemplates = array of TFileTemplate;

function FileTemplates: TFileTemplates;
{ Makes a file from Template at Path; ErrorNone or why not. }
function MakeFromTemplate(const Template: TFileTemplate; const Path: string): LongInt;

implementation

uses
  Classes,
  Abi.SystemCalls,
  Sys.Files,
  Controls.FileNames,
  FileManager.Items,
  FileManager.Locations,
  FileManager.FolderReading;

const
  EmptyZip = 'PK'#5#6#0#0#0#0#0#0#0#0#0#0#0#0#0#0#0#0#0#0;
  WebPage = '<!DOCTYPE html>'#10'<html>'#10'<head>'#10'  <meta charset="utf-8">'#10'  <title>New page</title>'#10 +
    '</head>'#10'<body>'#10'</body>'#10'</html>'#10;

procedure Add(var List: TFileTemplates; const Caption, FileName, Content, SourcePath, IconName: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Caption := Caption;
  List[High(List)].FileName := FileName;
  List[High(List)].Content := Content;
  List[High(List)].SourcePath := SourcePath;
  List[High(List)].IconName := IconName;
end;

function FileTemplates: TFileTemplates;
var
  Items: TFolderItems;
  Index: LongInt;
  Folder: string;
begin
  Result := nil;
  Add(Result, '&Text document', 'New text document.txt', '', '', 'file-text');
  Add(Result, '&Markdown document', 'New document.md', '', '', 'file-text');
  Add(Result, '&Web page', 'New page.html', WebPage, '', 'file-document');
  Add(Result, '&Compressed (ZIP) folder', 'New compressed folder.zip', EmptyZip, '', 'folder-compressed');
  Folder := CombinePath(HomeFolder, 'Templates');
  if ReadFolderItems(Folder, False, Items) = ErrorNone then
    for Index := 0 to High(Items) do
      if Items[Index].Kind = ItemFile then
        Add(Result, Items[Index].Name, Items[Index].Name, '', CombinePath(Folder, Items[Index].Name), 'file');
end;

function MakeFromTemplate(const Template: TFileTemplate; const Path: string): LongInt;
var
  Handle: Int64;
  Source: TFileStream;
  Target: TFileStream;
begin
  if Template.SourcePath <> '' then
  begin
    Result := ErrorNone;
    try
      Source := TFileStream.Create(Template.SourcePath, fmOpenRead or fmShareDenyNone);
      try
        Target := TFileStream.Create(Path, fmCreate);
        try
          Target.CopyFrom(Source, 0);
        finally
          Target.Free;
        end;
      finally
        Source.Free;
      end;
    except
      on Exception do
        Result := ErrorIo;
    end;
    Exit;
  end;
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenExclusive);
  if Handle < 0 then
    Exit(LongInt(Handle));
  Result := ErrorNone;
  if Template.Content <> '' then
    Result := WriteAll(Handle, @Template.Content[1], Length(Template.Content));
  CloseFile(Handle);
end;

end.
