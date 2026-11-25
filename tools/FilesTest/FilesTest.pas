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
  FilesTest: the plain logic behind the file manager, on the host.

    FilesTest

  Paths (FileManager.Paths), numbered names for conflicts
  (FileManager.ConflictNames), Back and Forward (FileManager.History),
  the order items are shown in (FileManager.ItemOrder) and their types
  (FileManager.FileTypes), permission texts (FileManager.Permissions),
  what a drop does (FileManager.DropRules), file lists on the clipboard
  (Controls.FileLists), finding a name by typing (Controls.TypeAhead)
  and searching inside an archive (FileManager.ArchiveSearch).
  Every check prints a line; the exit code is 1 if any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program FilesTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Controls.DragData,
  Controls.FileLists,
  Controls.TypeAhead,
  FileManager.Items,
  FileManager.Paths,
  FileManager.ConflictNames,
  FileManager.History,
  FileManager.FileTypes,
  FileManager.ItemOrder,
  FileManager.Permissions,
  FileManager.DropRules,
  FilesTest.Explorer,
  FilesTest.ArchiveSearch;

type
  { Names taken, for FirstFreeName; names for TypeAheadFind. }
  TNameSet = class
  public
    Names: TStringList;
    constructor Create(const Taken: array of string);
    destructor Destroy; override;
    function IsTaken(const Name: string): Boolean;
    function NameOf(Index: LongInt): string;
  end;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[files] pass: ', Name)
  else
  begin
    WriteLn('[files] FAIL: ', Name);
    Inc(Failures);
  end;
end;

procedure CheckText(const Name, Got, Expected: string);
begin
  Check(Name + ' (' + Got + ')', Got = Expected);
end;

constructor TNameSet.Create(const Taken: array of string);
var
  Index: LongInt;
begin
  inherited Create;
  Names := TStringList.Create;
  for Index := 0 to High(Taken) do
    Names.Add(Taken[Index]);
end;

destructor TNameSet.Destroy;
begin
  Names.Free;
  inherited Destroy;
end;

function TNameSet.IsTaken(const Name: string): Boolean;
begin
  Result := Names.IndexOf(Name) >= 0;
end;

function TNameSet.NameOf(Index: LongInt): string;
begin
  Result := Names[Index];
end;

procedure TestPaths;
begin
  Check('a folder is inside itself', IsSameOrInside('/home/user', '/home/user'));
  Check('a path below is inside', IsSameOrInside('/home/user/notes', '/home/user'));
  Check('a longer name beside is not inside', not IsSameOrInside('/home/username', '/home/user'));
  Check('everything is inside the root', IsSameOrInside('/etc', '/'));
  Check('a folder is not inside one below it', not IsSameOrInside('/home', '/home/user'));
  Check('dot files are hidden', IsHiddenName('.profile') and not IsHiddenName('profile'));
  CheckText('an extension in small letters', ExtensionOf('NOTES.TXT'), 'txt');
  CheckText('the last dot counts', ExtensionOf('archive.tar.gz'), 'gz');
  CheckText('a dot file has no extension', ExtensionOf('.profile'), '');
  CheckText('no dot, no extension', ExtensionOf('Makefile'), '');
  Check('a slash is not allowed in a name', NameProblem('a/b') <> '');
  Check('.. is not a name', NameProblem('..') <> '');
  Check('an empty name is refused', NameProblem('') <> '');
  Check('an ordinary name is fine', NameProblem('notes (2).txt') = '');
end;

procedure TestConflictNames;
var
  Taken: TNameSet;
begin
  CheckText('a number before the extension', NumberedName('notes.txt', False, 2), 'notes (2).txt');
  CheckText('a folder gets it at the end', NumberedName('photos.2026', True, 2), 'photos.2026 (2)');
  CheckText('a dot file gets it at the end', NumberedName('.profile', False, 3), '.profile (3)');
  CheckText('a numbered name counts on', NumberedName('notes (2).txt', False, 3), 'notes (3).txt');
  Taken := TNameSet.Create(['notes.txt', 'notes (2).txt', 'New folder']);
  try
    CheckText('a free name is kept', FirstFreeName('other.txt', False, @Taken.IsTaken), 'other.txt');
    CheckText('the first free number', FirstFreeName('notes.txt', False, @Taken.IsTaken), 'notes (3).txt');
    CheckText('from a numbered name', FirstFreeName('notes (2).txt', False, @Taken.IsTaken), 'notes (3).txt');
    CheckText('a new folder', FirstFreeName('New folder', True, @Taken.IsTaken), 'New folder (2)');
  finally
    Taken.Free;
  end;
end;

procedure TestHistory;
var
  History: TNavigationHistory;
begin
  History := TNavigationHistory.Create;
  try
    History.Visit('/a');
    History.Visit('/a/b');
    History.Visit('/a/b');
    History.Visit('/c');
    Check('nothing ahead at first', History.CanGoBack and not History.CanGoForward);
    CheckText('back', History.GoBack, '/a/b');
    CheckText('back again', History.GoBack, '/a');
    Check('nothing before the first', not History.CanGoBack);
    CheckText('forward', History.GoForward, '/a/b');
    History.Visit('/d');
    Check('a visit forgets what was ahead', not History.CanGoForward);
    CheckText('back from it', History.GoBack, '/a/b');
    History.Forget('/a');
    CheckText('a folder gone is forgotten with what is below it', History.Current, '/d');
    Check('and nothing else is left', not History.CanGoBack and not History.CanGoForward);
  finally
    History.Free;
  end;
end;

function MakeItem(const Name: string; Kind: TItemKind; Size: QWord; Mode: LongWord; Time: Int64): TFolderItem;
begin
  Result := Default(TFolderItem);
  Result.Name := Name;
  Result.Kind := Kind;
  Result.SizeInBytes := Size;
  Result.Mode := Mode;
  Result.ModificationTime := Time;
end;

procedure TestOrderAndTypes;
var
  Folder: TFolderItem;
  Small: TFolderItem;
  Large: TFolderItem;
  Upper: TFolderItem;
  Link: TFolderItem;
begin
  Folder := MakeItem('zeta', ItemFolder, 4096, $1ED, 100);
  Small := MakeItem('beta.txt', ItemFile, 10, $1A4, 300);
  Large := MakeItem('Alpha.bin', ItemFile, 5000, $1ED, 200);
  Upper := MakeItem('Beta.txt', ItemFile, 10, $1A4, 300);
  Check('folders first by name', CompareFolderItems(Folder, Large, SortByName, True, nil) < 0);
  Check('folders first even descending', CompareFolderItems(Folder, Large, SortByName, False, nil) < 0);
  Check('names without regard to case', CompareFolderItems(Large, Small, SortByName, True, nil) < 0);
  Check('equal names but for case keep an order', CompareFolderItems(Upper, Small, SortByName, True, nil) < 0);
  Check('by size', CompareFolderItems(Small, Large, SortBySize, True, nil) < 0);
  Check('by size descending', CompareFolderItems(Small, Large, SortBySize, False, nil) > 0);
  Check('by time modified', CompareFolderItems(Large, Small, SortByModified, True, nil) < 0);
  Check('equal sizes by name', CompareFolderItems(Upper, Small, SortBySize, True, nil) < 0);
  CheckText('a folder''s type', TypeTextOf(Folder), 'Folder');
  CheckText('a text document by its extension', TypeTextOf(Small), 'Text document');
  CheckText('a file with an execute bit is a program', TypeTextOf(Large), 'Program');
  CheckText('another file by its extension', TypeTextOf(MakeItem('photo.png', ItemFile, 1, $1A4, 0)), 'PNG file');
  CheckText('a file without one', TypeTextOf(MakeItem('data', ItemFile, 1, $1A4, 0)), 'File');
  Link := Small;
  Link.IsLink := True;
  CheckText('a link says so', TypeTextOf(Link), 'Text document (link)');
  Link.IsBrokenLink := True;
  Check('a broken link is its own type', FileTypeOf(Link) = FileTypeBrokenLink);
  Check('a .sh script is text before it is a program',
    FileTypeOf(MakeItem('run.sh', ItemFile, 1, $1ED, 0)) = FileTypeText);
end;

procedure TestPermissions;
begin
  CheckText('rwxr-xr-x', PermissionText($1ED), 'rwxr-xr-x');
  CheckText('rw-r-----', PermissionText($1A0), 'rw-r-----');
  CheckText('set-user-id and sticky bits', PermissionText($800 or $200 or $1ED), 'rwsr-xr-t');
  CheckText('octal', OctalModeText($1ED), '0755');
  Check('the owner''s read bit', PermissionBit(PermissionOwner, PermissionRead) = $100);
  Check('the others'' execute bit', PermissionBit(PermissionOthers, PermissionExecute) = 1);
  Check('the group''s write bit', PermissionBit(PermissionGroup, PermissionWrite) = $10);
end;

procedure TestDropRules;
var
  Paths: TStringList;
begin
  Check('one volume: a move', DropEffectFor(1, 1, False, False) = DropMove);
  Check('another volume: a copy', DropEffectFor(1, 2, False, False) = DropCopy);
  Check('Ctrl copies', DropEffectFor(1, 1, True, False) = DropCopy);
  Check('Shift moves', DropEffectFor(1, 2, False, True) = DropMove);
  Paths := TStringList.Create;
  try
    Paths.Add('/home/user/a.txt');
    Paths.Add('/home/user/photos');
    Check('into another folder', CanDropInto(Paths, '/tmp'));
    Check('not where they are', not CanDropInto(Paths, '/home/user'));
    Check('not into themselves', not CanDropInto(Paths, '/home/user/photos/2026'));
    Check('into a folder beside them', CanDropInto(Paths, '/home/user/backup'));
  finally
    Paths.Free;
  end;
end;

procedure TestFileLists;
var
  Paths: TStringList;
  Read: TStringList;
  Action: TFileListAction;
  Path: string;
  Text: string;
begin
  CheckText('a plain path as a URI', PathToFileUri('/home/user/notes.txt'), 'file:///home/user/notes.txt');
  CheckText('spaces and others escaped', PathToFileUri('/tmp/a b%#.txt'), 'file:///tmp/a%20b%25%23.txt');
  CheckText('UTF-8 byte by byte', PathToFileUri('/tmp/'#$C3#$A9), 'file:///tmp/%C3%A9');
  Check('back from a URI', FileUriToPath('file:///tmp/a%20b', Path) and (Path = '/tmp/a b'));
  Check('small hexadecimal digits too', FileUriToPath('file:///tmp/%c3%a9', Path) and (Path = '/tmp/'#$C3#$A9));
  Check('a broken escape is refused', not FileUriToPath('file:///tmp/%2', Path));
  Check('another host is refused', not FileUriToPath('file://host/tmp', Path));
  Paths := TStringList.Create;
  Read := TStringList.Create;
  try
    Paths.Add('/home/user/notes.txt');
    Paths.Add('/home/user/line'#10'feed');
    Text := EncodeFileList(FileListCut, Paths);
    CheckText('the text of a list', StringReplace(Text, #10, '|', [rfReplaceAll]),
      'file-list cut|file:///home/user/notes.txt|file:///home/user/line%0Afeed|');
    Check('read back', DecodeFileList(Text, Action, Read) and (Action = FileListCut) and (Read.Count = 2) and
      (Read[0] = Paths[0]) and (Read[1] = Paths[1]));
    Check('carriage returns and plain paths are taken',
      DecodeFileList('file-list copy'#13#10'/etc/passwd'#13#10#13#10, Action, Read) and (Action = FileListCopy) and
      (Read.Count = 1) and (Read[0] = '/etc/passwd'));
    Check('ordinary text is not a list', not DecodeFileList('hello'#10'/etc/passwd', Action, Read) and
      (Read.Count = 0));
    Check('a list with a bad line is refused', not DecodeFileList('file-list copy'#10'http://x/y', Action, Read));
    SetClipboardFileList(FileListCopy, Paths);
    Check('on the clipboard', ClipboardHoldsFileList and ClipboardFileList(Action, Read) and
      (Action = FileListCopy) and (Read.Count = 2));
  finally
    Read.Free;
    Paths.Free;
  end;
end;

procedure TestTypeAhead;
var
  Names: TNameSet;
  State: TTypeAhead;
  Found: LongInt;
begin
  Names := TNameSet.Create(['alpha', 'beta', 'bin', 'Boot', 'etc', 'readme']);
  try
    ResetTypeAhead(State);
    Found := TypeAheadFind(State, Ord('b'), 1000, -1, Names.Names.Count, @Names.NameOf);
    Check('a first letter finds the first name with it', Found = 1);
    Found := TypeAheadFind(State, Ord('o'), 1200, Found, Names.Names.Count, @Names.NameOf);
    Check('the next letter narrows it, in either case', Found = 3);
    ResetTypeAhead(State);
    Found := TypeAheadFind(State, Ord('b'), 5000, 0, Names.Names.Count, @Names.NameOf);
    Found := TypeAheadFind(State, Ord('b'), 5100, Found, Names.Names.Count, @Names.NameOf);
    Check('the same letter again steps to the next', Found = 2);
    Found := TypeAheadFind(State, Ord('b'), 5200, Found, Names.Names.Count, @Names.NameOf);
    Found := TypeAheadFind(State, Ord('b'), 5300, Found, Names.Names.Count, @Names.NameOf);
    Check('...and round to the first again', Found = 1);
    Found := TypeAheadFind(State, Ord('r'), 9000, Found, Names.Names.Count, @Names.NameOf);
    Check('after a pause a new start', Found = 5);
    Found := TypeAheadFind(State, Ord('z'), 20000, Found, Names.Names.Count, @Names.NameOf);
    Check('no name: nothing found', Found = -1);
  finally
    Names.Free;
  end;
end;

begin
  TestPaths;
  TestConflictNames;
  TestHistory;
  TestOrderAndTypes;
  TestPermissions;
  TestDropRules;
  TestFileLists;
  TestTypeAhead;
  TestExplorerLogic(@Check);
  TestArchiveSearch(@Check);
  WriteLn('[files] ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
