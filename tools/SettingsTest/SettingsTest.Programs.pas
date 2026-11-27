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
  The programs' folders on the host: program.info read and checked
  (Configuration.ProgramInfo) - every key, defaults, keys and categories
  in any case, and each way a description can be wrong; the folders of
  a made-up /app listed in the Start menu's order, broken ones left out
  with why, hidden ones kept from the menu, programs found by executable
  and folder, a folder's own icon before the theme's
  (Configuration.ProgramFolders); and every program.info of the source
  tree (userland/apps/NAME/program.info, userland/apps/demos/NAME/
  program.info) valid, naming NAME as its executable.
}
unit SettingsTest.Programs;

{$mode objfpc}
{$H+}

interface

type
  TProgramCheckProcedure = procedure(const Name: string; Passed: Boolean);

procedure TestProgramInfo(Check: TProgramCheckProcedure);
procedure TestProgramFolders(Check: TProgramCheckProcedure);
procedure TestSourceProgramInfo(Check: TProgramCheckProcedure);

implementation

uses
  SysUtils,
  Configuration.ProgramInfo,
  Configuration.ProgramFolders;

const
  NotepadInfo =
    '# Notepad'#10 +
    '[Program]'#10 +
    'Name = Notepad'#10 +
    'Description = Write and edit plain text files'#10 +
    'Category = Accessories'#10 +
    'Icon = app-text-editor'#10 +
    'Executable = notepad'#10 +
    'Keywords = ["text", "editor"]'#10 +
    'Version = 1.0'#10;

function Parse(const Text: string; out Info: TProgramInfo; out Problems: TStringArray): Boolean;
begin
  Result := ParseProgramInfo(Text, 'sample', Info, Problems);
end;

function HasProblem(const Problems: TStringArray; const Part: string): Boolean;
var
  Problem: string;
begin
  for Problem in Problems do
    if Pos(Part, Problem) > 0 then
      Exit(True);
  Result := False;
end;

procedure TestProgramInfo(Check: TProgramCheckProcedure);
var
  Info: TProgramInfo;
  Problems: TStringArray;
  Valid: Boolean;
  Category: TProgramCategory;
begin
  Valid := Parse(NotepadInfo, Info, Problems);
  Check('program.info: a full description is valid, with no problems', Valid and (Length(Problems) = 0));
  Check('program.info: name, description, executable, version',
    (Info.Name = 'Notepad') and (Info.Description = 'Write and edit plain text files') and
    (Info.Executable = 'notepad') and (Info.Version = '1.0') and (Info.FolderName = 'sample'));
  Check('program.info: category and icon', (Info.Category = CategoryAccessories) and (Info.Icon = 'app-text-editor'));
  Check('program.info: keywords as a list',
    (Length(Info.Keywords) = 2) and (Info.Keywords[0] = 'text') and (Info.Keywords[1] = 'editor'));
  Check('program.info: shown unless hidden', not Info.Hidden);

  Valid := Parse('[Program]'#10'name = Paint'#10'CATEGORY = graphics'#10'executable = paint'#10 +
    'keywords = draw; picture, image'#10, Info, Problems);
  Check('program.info: keys and categories in any case', Valid and (Info.Name = 'Paint') and
    (Info.Category = CategoryGraphics) and (Info.Executable = 'paint'));
  Check('program.info: keywords as one string, split at ; and ,',
    (Length(Info.Keywords) = 3) and (Info.Keywords[2] = 'image'));
  Check('program.info: the icon is app-generic without one', Info.Icon = DefaultProgramIcon);
  Check('program.info: description and version empty without them', (Info.Description = '') and (Info.Version = ''));

  Valid := Parse('[Program]'#10'Name = Tool'#10'Category = System'#10'Executable = tool'#10'Hidden = true'#10,
    Info, Problems);
  Check('program.info: Hidden = true', Valid and Info.Hidden);
  Valid := Parse('[Program]'#10'Name = Tool'#10'Category = System'#10'Executable = tool'#10'NoMenu = yes'#10,
    Info, Problems);
  Check('program.info: NoMenu is read as Hidden', Valid and Info.Hidden);
  Valid := Parse('[Program]'#10'Name = Tool'#10'Category = System'#10'Executable = tool'#10'Hidden = maybe'#10,
    Info, Problems);
  Check('program.info: a Hidden that is not a boolean is a problem, not fatal',
    Valid and not Info.Hidden and HasProblem(Problems, 'Hidden'));
  Valid := Parse('[Program]'#10'Name = Tool'#10'Category = System'#10'Executable = tool'#10'Colour = red'#10,
    Info, Problems);
  Check('program.info: an unknown key is reported but allowed', Valid and HasProblem(Problems, 'unknown key Colour'));

  Valid := Parse('Name = Notepad'#10'Category = Accessories'#10'Executable = notepad'#10, Info, Problems);
  Check('program.info: invalid without a [Program] section', not Valid and HasProblem(Problems, '[Program]'));
  Valid := Parse('[Program]'#10'Category = Accessories'#10'Executable = notepad'#10, Info, Problems);
  Check('program.info: invalid without a Name', not Valid and HasProblem(Problems, 'no Name'));
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Category = Accessories'#10, Info, Problems);
  Check('program.info: invalid without an Executable', not Valid and HasProblem(Problems, 'no Executable'));
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Executable = notepad'#10, Info, Problems);
  Check('program.info: invalid without a Category', not Valid and HasProblem(Problems, 'no Category'));
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Category = Office'#10'Executable = notepad'#10, Info, Problems);
  Check('program.info: invalid with an unknown Category', not Valid and HasProblem(Problems, 'unknown Category Office'));
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Category = Accessories'#10'Executable = ../../bin/sh'#10,
    Info, Problems);
  Check('program.info: invalid with an Executable outside the folder', not Valid);
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Category = Accessories'#10'Executable = program.info'#10,
    Info, Problems);
  Check('program.info: invalid with program.info as the Executable', not Valid);
  Valid := Parse('[Program]'#10'Name = Notepad'#10'Category = Accessories'#10'Executable = notepad'#10 +
    'Icon = ../secret'#10, Info, Problems);
  Check('program.info: an icon with a path is a problem, app-generic instead',
    Valid and (Info.Icon = DefaultProgramIcon) and HasProblem(Problems, 'Icon'));
  Valid := Parse('[Program]'#10'Name = "Notepad'#10'Category = Accessories'#10'Executable = notepad'#10, Info, Problems);
  Check('program.info: a line that cannot be read is a problem', HasProblem(Problems, 'line 2'));

  Check('categories: names both ways, any case', ProgramCategoryFromName('multimedia', Category) and
    (Category = CategoryMultimedia) and (ProgramCategoryNames[CategorySettings] = 'Settings') and
    not ProgramCategoryFromName('Office', Category));
end;

procedure WriteText(const Path, Text: string);
var
  Output: TextFile;
begin
  AssignFile(Output, Path);
  Rewrite(Output);
  Write(Output, Text);
  CloseFile(Output);
end;

procedure MakeProgram(const Root, Folder, Info: string; WithExecutable: Boolean);
begin
  ForceDirectories(Root + '/' + Folder);
  if Info <> '' then
    WriteText(Root + '/' + Folder + '/' + ProgramInfoFileName, Info);
  if WithExecutable then
    WriteText(Root + '/' + Folder + '/' + Folder, 'not really a program');
end;

function Describe(const Name, Category, Executable: string): string;
begin
  Result := '[Program]'#10'Name = ' + Name + #10'Category = ' + Category + #10'Executable = ' + Executable + #10 +
    'Icon = app-' + Executable + #10;
end;

procedure RemoveTree(const Path: string);
var
  Search: TSearchRec;
begin
  if FindFirst(Path + '/*', faAnyFile or faDirectory, Search) = 0 then
  begin
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      if (Search.Attr and faDirectory) <> 0 then
        RemoveTree(Path + '/' + Search.Name)
      else
        DeleteFile(Path + '/' + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  RemoveDir(Path);
end;

procedure TestProgramFolders(Check: TProgramCheckProcedure);
var
  Root: string;
  List: TProgramList;
  Shown: TProgramList;
  Skipped: TProgramFolderProblems;
  Info: TProgramInfo;
  Problems: TStringArray;
  Paint: Integer;
begin
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'programfolders-test-' + IntToStr(GetProcessID);
  RemoveTree(Root);
  ForceDirectories(Root);
  MakeProgram(Root, 'notepad', Describe('Notepad', 'Accessories', 'notepad'), True);
  MakeProgram(Root, 'calculator', Describe('Calculator', 'Accessories', 'calculator'), True);
  MakeProgram(Root, 'paint', Describe('Paint', 'Graphics', 'paint'), True);
  MakeProgram(Root, 'controlpanel', Describe('Control Panel', 'Settings', 'controlpanel'), True);
  MakeProgram(Root, 'taskmanager', Describe('Task Manager', 'System', 'taskmanager'), True);
  MakeProgram(Root, 'helper', Describe('Helper', 'System', 'helper') + 'Hidden = true'#10, True);
  MakeProgram(Root, 'broken', '[Program]'#10'Name = Broken'#10, True);
  MakeProgram(Root, 'noexecutable', Describe('Missing', 'Games', 'noexecutable'), False);
  MakeProgram(Root, 'empty', '', False);
  ForceDirectories(Root + '/paint/' + ProgramIconFolderName);
  WriteText(Root + '/paint/' + ProgramIconFolderName + '/app-paint.ico', 'an icon');
  WriteText(Root + '/notafolder', 'a file beside the folders');

  List := DiscoverPrograms(Root, Skipped);
  Check('folders: the six programs found, the three broken folders skipped',
    (Length(List) = 6) and (Length(Skipped) = 3));
  Check('folders: sorted by category, then name',
    (Length(List) = 6) and (List[0].Name = 'Calculator') and (List[1].Name = 'Notepad') and
    (List[2].Name = 'Paint') and (List[3].Name = 'Helper') and (List[4].Name = 'Task Manager') and
    (List[5].Name = 'Control Panel'));
  Shown := ShownPrograms(List);
  Check('folders: hidden programs kept out of the menu', (Length(Shown) = 5) and
    (FindProgramByExecutable(Shown, 'helper') < 0));
  Check('folders: found by executable and by folder', (FindProgramByExecutable(List, 'notepad') = 1) and
    (FindProgramByFolder(List, 'taskmanager') = 4) and (FindProgramByExecutable(List, 'missing') = -1));
  Check('folders: the executable''s full path',
    (Length(List) = 6) and (ProgramExecutablePath(List[1]) = Root + '/notepad/notepad'));
  Paint := FindProgramByFolder(List, 'paint');
  Check('folders: a folder''s own icon comes first, as a full path',
    (Paint >= 0) and (ProgramIconName(List[Paint]) = Root + '/paint/icons/app-paint.ico'));
  Check('folders: else the theme''s icon by name', ProgramIconName(List[1]) = 'app-notepad');
  Check('folders: no executable is a reason to skip',
    not ReadProgramFolder(Root + '/noexecutable', Info, Problems) and HasProblem(Problems, 'no executable'));
  Check('folders: no program.info is a reason to skip',
    not ReadProgramFolder(Root + '/empty', Info, Problems) and HasProblem(Problems, 'no program.info'));
  Check('folders: a missing root has no programs', Length(DiscoverPrograms(Root + '/nothing-here')) = 0);

  { A second root (ported software's /usr/local/app): its programs join
    the first's, sorted with them; one named like a first root's folder
    is skipped; a missing root adds nothing. }
  MakeProgram(Root + '/ports', 'doom', Describe('Doom', 'Games', 'doom'), True);
  MakeProgram(Root + '/ports', 'notepad', Describe('Other Notepad', 'Accessories', 'notepad'), True);
  List := DiscoverProgramsIn([Root, Root + '/ports', Root + '/nothing-here'], Skipped);
  Check('roots: the second root''s program joins the first''s, in category order',
    (Length(List) = 7) and (List[2].Name = 'Doom') and (List[2].Folder = Root + '/ports/doom'));
  Check('roots: a folder named like an earlier root''s is skipped',
    (List[FindProgramByFolder(List, 'notepad')].Name = 'Notepad') and (Length(Skipped) = 5) and
    (Skipped[4].Folder = Root + '/ports/notepad'));
  RemoveTree(Root);
end;

procedure TestSourceProgramInfo(Check: TProgramCheckProcedure);
const
  ProgramFolderRoots: array[0..1] of string = ('userland/apps', 'userland/apps/demos');
var
  Search: TSearchRec;
  Text: string;
  Info: TProgramInfo;
  Problems: TStringArray;
  Count: Integer;
  AllValid: Boolean;
  Input: TextFile;
  Line, FolderRoot, FileName: string;
begin
  Count := 0;
  AllValid := True;
  for FolderRoot in ProgramFolderRoots do
    if FindFirst(FolderRoot + '/*', faDirectory, Search) = 0 then
    begin
      repeat
        FileName := FolderRoot + '/' + Search.Name + '/' + ProgramInfoFileName;
        if not FileExists(FileName) then
          Continue;
        AssignFile(Input, FileName);
        Reset(Input);
        Text := '';
        while not Eof(Input) do
        begin
          ReadLn(Input, Line);
          Text := Text + Line + #10;
        end;
        CloseFile(Input);
        Inc(Count);
        if not ParseProgramInfo(Text, Search.Name, Info, Problems) or (Length(Problems) > 0) or
           (Info.Executable <> Search.Name) or (Info.Description = '') then
        begin
          AllValid := False;
          WriteLn('[settings] ', Search.Name, '/program.info: ', string.Join('; ', Problems));
        end;
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
  Check('source tree: program.info files found', Count > 0);
  Check('source tree: every program.info valid, described, naming its folder''s program', AllValid);
end;

end.
