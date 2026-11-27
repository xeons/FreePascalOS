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
  A program's description: the program.info file in its folder
  (/app/notepad/program.info, or /usr/local/app/NAME/program.info for a
  port's program), written as a settings file
  (Configuration.Documents, Configuration.Values) with one section:

    [Program]
    Name = Notepad                       shown in the Start menu
    Description = Write and edit plain text files
    Category = Accessories               one of ProgramCategoryNames
    Icon = app-text-editor               an icon of the theme, or of
                                         the folder's icons/NAME.ico
    Executable = notepad                 the file in the folder
    Keywords = ["text", "editor"]        optional: words to find it by
    Version = 1.0                        optional
    Hidden = false                       optional: true keeps it out
                                         of the menu and the desktop
    Extensions = ["txt", "md"]           optional: the file name
                                         extensions it opens (no dot)
    MimeTypes = ["text/plain"]           optional: the media types it
                                         opens ("image/*" for a family)

  Name, Category and Executable are required; Icon is app-generic
  without one. The category names and keys are case-insensitive when
  read. NoMenu is read as Hidden. Nothing here touches files, so it is
  checked on the host (tools/SettingsTest).
}
unit Configuration.ProgramInfo;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  { The same as Sys.ProgramFolders' (libsystem), which this host-built
    unit cannot use. }
  DefaultProgramFoldersRoot = '/app';
  { Where ported software's programs describe themselves (a port's
    package installs /usr/local/app/NAME/program.info: ports may install
    only under /usr/local). }
  PortProgramFoldersRoot = '/usr/local/app';
  ProgramInfoFileName = 'program.info';
  { The folder of a program's own icons, NAME.ico as in the theme. }
  ProgramIconFolderName = 'icons';
  ProgramInfoSection = 'Program';
  DefaultProgramIcon = 'app-generic';

type
  { In the order the Start menu shows them. }
  TProgramCategory = (CategoryAccessories, CategoryGames, CategoryGraphics, CategoryInternet, CategoryMultimedia,
    CategoryDevelopment, CategorySystem, CategorySettings);

  TProgramInfo = record
    { The folder's full path and its own name (/app/notepad, notepad). }
    Folder: string;
    FolderName: string;
    Name: string;
    Description: string;
    Category: TProgramCategory;
    Icon: string;
    Executable: string;
    Keywords: TStringArray;
    Version: string;
    Hidden: Boolean;
    { The files it opens: extensions in small letters without the dot,
      media types in small letters ("text/plain", "image/*"). }
    Extensions: TStringArray;
    MimeTypes: TStringArray;
  end;

const
  ProgramCategoryNames: array[TProgramCategory] of string = ('Accessories', 'Games', 'Graphics', 'Internet',
    'Multimedia', 'Development', 'System', 'Settings');

{ The category named Name (any case); False if there is none. }
function ProgramCategoryFromName(const Name: string; out Category: TProgramCategory): Boolean;
{ Reads a program.info's Text for the folder named FolderName. False if
  it does not describe a program (a required key missing or wrong);
  Problems says what is wrong, also for what was only ignored (a line
  that cannot be read, an unknown key). }
function ParseProgramInfo(const Text, FolderName: string; out Info: TProgramInfo;
  out Problems: TStringArray): Boolean;
{ Whether Name can be the executable's file in the folder. }
function IsValidExecutableName(const Name: string): Boolean;
{ Whether Name can be an icon's name (a file name, no path). }
function IsValidIconName(const Name: string): Boolean;

implementation

uses
  Configuration.Values,
  Configuration.Documents;

const
  KnownKeys: array[0..10] of string = ('Name', 'Description', 'Category', 'Icon', 'Executable', 'Keywords',
    'Version', 'Hidden', 'NoMenu', 'Extensions', 'MimeTypes');

procedure AddProblem(var Problems: TStringArray; const Text: string);
begin
  SetLength(Problems, Length(Problems) + 1);
  Problems[High(Problems)] := Text;
end;

function ProgramCategoryFromName(const Name: string; out Category: TProgramCategory): Boolean;
var
  Candidate: TProgramCategory;
begin
  for Candidate := Low(TProgramCategory) to High(TProgramCategory) do
    if SameText(ProgramCategoryNames[Candidate], Trim(Name)) then
    begin
      Category := Candidate;
      Exit(True);
    end;
  Category := CategoryAccessories;
  Result := False;
end;

function IsPlainFileName(const Name: string): Boolean;
begin
  Result := (Name <> '') and (Name <> '.') and (Name <> '..') and (Pos('/', Name) = 0) and
    (Pos(#0, Name) = 0);
end;

function IsValidExecutableName(const Name: string): Boolean;
begin
  Result := IsPlainFileName(Name) and (Name <> ProgramInfoFileName) and (Name <> ProgramIconFolderName);
end;

function IsValidIconName(const Name: string): Boolean;
begin
  Result := IsPlainFileName(Name);
end;

{ The section's key written as Key in any case ('' if none). }
function KeyAsWritten(const Keys: TStringArray; const Key: string): string;
var
  Index: Integer;
begin
  for Index := 0 to High(Keys) do
    if SameText(Keys[Index], Key) then
      Exit(Keys[Index]);
  Result := '';
end;

function IsKnownKey(const Key: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(KnownKeys) do
    if SameText(KnownKeys[Index], Key) then
      Exit(True);
  Result := False;
end;

{ The text of Key; False if it is missing or a list. }
function ReadText(Document: TSettingsDocument; const Keys: TStringArray; const Key: string;
  out Text: string): Boolean;
var
  Written: string;
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Text := '';
  Written := KeyAsWritten(Keys, Key);
  Result := (Written <> '') and Document.GetValue(ProgramInfoSection, Written, Value, Fixed) and
    SettingAsString(Value, Text);
  if Result then
    Text := Trim(Text);
end;

{ A list of words (Keywords, Extensions, MimeTypes): a list, or one
  string of words separated by ";" or ",". }
function ReadWordList(Document: TSettingsDocument; const Keys: TStringArray; const Key: string): TStringArray;
var
  Written: string;
  Value: TSettingValue;
  Fixed: Boolean;
  Text: string;
  Words: TStringArray;
  Word: string;
begin
  Result := nil;
  Written := KeyAsWritten(Keys, Key);
  if (Written = '') or not Document.GetValue(ProgramInfoSection, Written, Value, Fixed) then
    Exit;
  if SettingAsList(Value, Words) then
  begin
    for Word in Words do
      if Trim(Word) <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Trim(Word);
      end;
    Exit;
  end;
  if not SettingAsString(Value, Text) then
    Exit;
  Words := Text.Split([';', ',']);
  for Word in Words do
    if Trim(Word) <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Trim(Word);
    end;
end;

{ Words in small letters (a leading dot taken off an extension). }
function LowerCaseWords(const Words: TStringArray; StripDot: Boolean): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Words));
  for Index := 0 to High(Words) do
  begin
    Result[Index] := LowerCase(Words[Index]);
    if StripDot and (Copy(Result[Index], 1, 1) = '.') then
      Delete(Result[Index], 1, 1);
  end;
end;

{ A flag that is false unless written true; a value that is not a
  boolean is a problem. }
function ReadFlag(Document: TSettingsDocument; const Keys: TStringArray; const Key: string;
  var Problems: TStringArray): Boolean;
var
  Written: string;
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Result := False;
  Written := KeyAsWritten(Keys, Key);
  if (Written = '') or not Document.GetValue(ProgramInfoSection, Written, Value, Fixed) then
    Exit;
  if not SettingAsBoolean(Value, Result) then
  begin
    AddProblem(Problems, Key + ' is not true or false');
    Result := False;
  end;
end;

procedure ReportUnknownKeys(const Keys: TStringArray; var Problems: TStringArray);
var
  Key: string;
begin
  for Key in Keys do
    if not IsKnownKey(Key) then
      AddProblem(Problems, 'unknown key ' + Key);
end;

function ParseProgramInfo(const Text, FolderName: string; out Info: TProgramInfo;
  out Problems: TStringArray): Boolean;
var
  Document: TSettingsDocument;
  Keys: TStringArray;
  Problem: string;
  CategoryText: string;
begin
  Info := Default(TProgramInfo);
  Info.FolderName := FolderName;
  Problems := nil;
  Result := True;
  Document := TSettingsDocument.Create;
  try
    Document.Parse(Text);
    for Problem in Document.Problems do
      AddProblem(Problems, Problem);
    Keys := Document.ListKeys(ProgramInfoSection);
    if Length(Keys) = 0 then
    begin
      AddProblem(Problems, 'no [' + ProgramInfoSection + '] section');
      Exit(False);
    end;
    ReportUnknownKeys(Keys, Problems);

    if not ReadText(Document, Keys, 'Name', Info.Name) or (Info.Name = '') then
    begin
      AddProblem(Problems, 'no Name');
      Result := False;
    end;
    if not ReadText(Document, Keys, 'Executable', Info.Executable) or (Info.Executable = '') then
    begin
      AddProblem(Problems, 'no Executable');
      Result := False;
    end
    else if not IsValidExecutableName(Info.Executable) then
    begin
      AddProblem(Problems, 'Executable is not a file name in the folder: ' + Info.Executable);
      Result := False;
    end;
    if not ReadText(Document, Keys, 'Category', CategoryText) or (CategoryText = '') then
    begin
      AddProblem(Problems, 'no Category');
      Result := False;
    end
    else if not ProgramCategoryFromName(CategoryText, Info.Category) then
    begin
      AddProblem(Problems, 'unknown Category ' + CategoryText);
      Result := False;
    end;

    ReadText(Document, Keys, 'Description', Info.Description);
    ReadText(Document, Keys, 'Version', Info.Version);
    if not ReadText(Document, Keys, 'Icon', Info.Icon) or (Info.Icon = '') then
      Info.Icon := DefaultProgramIcon
    else if not IsValidIconName(Info.Icon) then
    begin
      AddProblem(Problems, 'Icon is not an icon name: ' + Info.Icon);
      Info.Icon := DefaultProgramIcon;
    end;
    Info.Keywords := ReadWordList(Document, Keys, 'Keywords');
    Info.Extensions := LowerCaseWords(ReadWordList(Document, Keys, 'Extensions'), True);
    Info.MimeTypes := LowerCaseWords(ReadWordList(Document, Keys, 'MimeTypes'), False);
    Info.Hidden := ReadFlag(Document, Keys, 'Hidden', Problems) or ReadFlag(Document, Keys, 'NoMenu', Problems);
  finally
    Document.Free;
  end;
end;

end.
