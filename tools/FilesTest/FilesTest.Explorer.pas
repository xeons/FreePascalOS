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
  The file manager's newer plain logic, on the host: natural order
  (Controls.NaturalOrder), file kinds (FileManager.FileKinds), calendar
  days (FileManager.CivilDates), the search box's syntax (FileManager.
  SearchQuery), batch renaming (FileManager.BatchNames), undo and redo
  (FileManager.UndoHistory), name conflicts (FileManager.ConflictPolicy),
  which programs open a type (FileManager.TypeAssociations, over
  program.info texts) and the trash's info files (Util.TrashInfo).
}
unit FilesTest.Explorer;

{$mode objfpc}
{$H+}

interface

type
  TCheckProcedure = procedure(const Name: string; Passed: Boolean);

procedure TestExplorerLogic(Check: TCheckProcedure);

implementation

uses
  SysUtils,
  Controls.NaturalOrder,
  Configuration.ProgramInfo,
  Configuration.ProgramFolders,
  Util.TrashInfo,
  FileManager.Items,
  FileManager.OperationTypes,
  FileManager.FileKinds,
  FileManager.CivilDates,
  FileManager.SearchQuery,
  FileManager.BatchNames,
  FileManager.UndoHistory,
  FileManager.ConflictPolicy,
  FileManager.TypeAssociations;

type
  TTakenNames = class
  public
    Names: TStringArray;
    function IsTaken(const Name: string): Boolean;
  end;

function TTakenNames.IsTaken(const Name: string): Boolean;
var
  Each: string;
begin
  for Each in Names do
    if SameText(Each, Name) then
      Exit(True);
  Result := False;
end;

procedure TestNaturalOrder(Check: TCheckProcedure);
begin
  Check('natural: 2 before 10', NaturalCompare('file 2.txt', 'file 10.txt') < 0);
  Check('natural: 10 after 9', NaturalCompare('img10', 'img9') > 0);
  Check('natural: case ignored first', NaturalCompare('apple', 'Banana') < 0);
  Check('natural: equal text is 0', NaturalCompare('same', 'same') = 0);
  Check('natural: different case is not 0', NaturalCompare('Same', 'same') <> 0);
  Check('natural: fewer leading zeros first', NaturalCompare('7', '07') < 0);
  Check('natural: 007 equals 7 in value, after it', NaturalCompare('a007b', 'a7c') < 0);
  Check('natural: a prefix first', NaturalCompare('note', 'notes') < 0);
  Check('natural: big numbers', NaturalCompare('v123456789012345678901', 'v99') > 0);
  Check('natural: digits before letters', NaturalCompare('1abc', 'abc') < 0);
end;

procedure TestFileKinds(Check: TCheckProcedure);
var
  Kind: TFileKind;
begin
  Check('kinds: extension in small letters', ExtensionOf('Photo.JPG') = 'jpg');
  Check('kinds: a dot file has no extension', ExtensionOf('.profile') = '');
  Check('kinds: jpg is a picture', FileKindOfName('a.jpeg') = FileKindPicture);
  Check('kinds: pas is text', FileKindOfName('unit.pas') = FileKindText);
  Check('kinds: unknown is other', FileKindOfName('x.qqq') = FileKindOther);
  Check('kinds: "image" names pictures', FileKindNamed('Image', Kind) and (Kind = FileKindPicture));
  Check('kinds: media type of png', MimeTypeOfExtension('PNG') = 'image/png');
  Check('kinds: svg has a thumbnail', HasThumbnail('svg'));
  Check('kinds: tar.gz is browsable', IsBrowsableArchiveExtension('src.TAR.gz') and
    not IsBrowsableArchiveExtension('notes.gz'));
end;

procedure TestCivilDates(Check: TCheckProcedure);
var
  Date: TCivilDate;
begin
  Check('dates: 1970-01-01 is day 0', DaysFromCivil(1970, 1, 1) = 0);
  Check('dates: 2000-03-01', DaysFromCivil(2000, 3, 1) = 11017);
  Date := CivilFromDays(DaysFromCivil(2024, 2, 29));
  Check('dates: a leap day round trip', (Date.Year = 2024) and (Date.Month = 2) and (Date.Day = 29));
  Date := CivilFromDays(-1);
  Check('dates: the day before 1970', (Date.Year = 1969) and (Date.Month = 12) and (Date.Day = 31));
  Check('dates: 1970-01-01 was a Thursday', WeekdayOfDays(0) = 3);
  Check('dates: local day with an offset', LocalDayOf(23 * 3600, 3600) = 1);
  Check('dates: ISO text', ParseIsoDate('2026-11-21', Date) and (Date.Month = 11) and (Date.Day = 21));
  Check('dates: not a date', not ParseIsoDate('21-11-2026', Date));
end;

procedure TestSearchQuery(Check: TCheckProcedure);
const
  { 2026-11-21 (a Saturday) 12:00 UTC. }
  Noon = 1795262400;
var
  Query: TSearchQuery;
  Today: Int64;
begin
  Today := DaysFromCivil(2026, 11, 21) * SecondsPerDay;
  Check('search: the noon constant is that day', LocalDayOf(Noon, 0) = DaysFromCivil(2026, 11, 21));
  Query := ParseSearchQuery('holiday "two words" kind:image ext:.PAS size:>1MB modified:today', Noon, 0);
  Check('search: words and a phrase', (Length(Query.NameTerms) = 2) and (Query.NameTerms[1] = 'two words'));
  Check('search: kind', Query.Kinds = [FileKindPicture]);
  Check('search: extension without its dot', (Length(Query.Extensions) = 1) and (Query.Extensions[0] = 'pas'));
  Check('search: size over 1 MB', Query.HasMinimumSize and (Query.MinimumSize = 1024 * 1024 + 1) and
    not Query.HasMaximumSize);
  Check('search: today', Query.HasModifiedFrom and (Query.ModifiedFrom = Today) and
    (Query.ModifiedBefore = Today + SecondsPerDay));
  Check('search: no problems', Length(Query.Problems) = 0);
  Query := ParseSearchQuery('modified:thisweek', Noon, 0);
  Check('search: this week starts on Monday', Query.ModifiedFrom = Today - 5 * SecondsPerDay);
  Query := ParseSearchQuery('modified:lastmonth', Noon, 0);
  Check('search: last month', (Query.ModifiedFrom = DaysFromCivil(2026, 10, 1) * SecondsPerDay) and
    (Query.ModifiedBefore = DaysFromCivil(2026, 11, 1) * SecondsPerDay));
  Query := ParseSearchQuery('modified:2026-01-01..2026-01-31', Noon, 3600);
  Check('search: a date range in local time', (Query.ModifiedFrom = DaysFromCivil(2026, 1, 1) * SecondsPerDay - 3600) and
    (Query.ModifiedBefore = DaysFromCivil(2026, 2, 1) * SecondsPerDay - 3600));
  Query := ParseSearchQuery('size:1KB..2KB', Noon, 0);
  Check('search: a size range', (Query.MinimumSize = 1024) and (Query.MaximumSize = 2048));
  Query := ParseSearchQuery('size:small', Noon, 0);
  Check('search: size by word', (Query.MinimumSize = 16 * 1024) and (Query.MaximumSize = 1024 * 1024 - 1));
  Query := ParseSearchQuery('kind:nonsense size:huge-ish', Noon, 0);
  Check('search: what is not understood is a problem', Length(Query.Problems) = 2);
  Query := ParseSearchQuery('content:needle notes', Noon, 0);
  Check('search: content terms apart', (Length(Query.ContentTerms) = 1) and (Query.ContentTerms[0] = 'needle'));
  Check('search: empty query', IsEmptyQuery(ParseSearchQuery('   ', Noon, 0)));
  Check('search: a word anywhere in the name', NameMatchesTerm('My Holiday.jpg', 'holiday'));
  Check('search: wildcards match the whole name', NameMatchesTerm('report.txt', 're*rt.txt') and
    not NameMatchesTerm('report.txt.bak', 're*rt.txt') and NameMatchesTerm('file1.md', 'file?.md'));
  Query := ParseSearchQuery('kind:picture size:>10', Noon, 0);
  Check('search: an item matches', MatchesQuery(Query, 'a.png', False, 100, Noon));
  Check('search: too small', not MatchesQuery(Query, 'a.png', False, 5, Noon));
  Check('search: wrong kind', not MatchesQuery(Query, 'a.txt', False, 100, Noon));
  Check('search: a folder has no size', not MatchesQuery(Query, 'pics.png', True, 100, Noon));
end;

procedure TestBatchNames(Check: TCheckProcedure);
var
  Items: TBatchItems;
  Names: TStringArray;
  Taken: TTakenNames;
begin
  Items := nil;
  SetLength(Items, 3);
  Items[0].Name := 'a.jpg';
  Items[1].Name := 'b.JPG';
  Items[2].Name := 'stuff';
  Items[2].IsFolder := True;
  Names := BatchRenameNames('Holiday', Items, nil);
  Check('batch: numbered with their own extensions', (Names[0] = 'Holiday (1).jpg') and
    (Names[1] = 'Holiday (2).JPG') and (Names[2] = 'Holiday (3)'));
  Names := BatchRenameNames('Holiday.jpg', Items, nil);
  Check('batch: a typed extension is not doubled', Names[0] = 'Holiday (1).jpg');
  Taken := TTakenNames.Create;
  try
    Taken.Names := ['Holiday (1).jpg'];
    Names := BatchRenameNames('Holiday', Items, @Taken.IsTaken);
    Check('batch: a name taken outside is passed over', (Names[0] = 'Holiday (2).jpg') and
      (Names[1] = 'Holiday (3).JPG'));
  finally
    Taken.Free;
  end;
end;

procedure TestUndoHistory(Check: TCheckProcedure);
var
  History: TUndoHistory;
  Entry: TUndoEntry;
  Steps: TPlanSteps;
begin
  History := TUndoHistory.Create;
  try
    Check('undo: nothing at first', not History.CanUndo and not History.CanRedo);
    History.Push(MakeEntry(UndoRename, ['/a/old'], ['/a/new']));
    History.Push(MakeEntry(UndoMove, ['/a/x', '/a/y'], ['/b/x', '/b/y']));
    Check('undo: the last first', History.CanUndo and (History.NextUndo.Kind = UndoMove));
    Entry := History.Undo;
    Steps := PlanFor(Entry, True);
    Check('undo: a move goes back, the last pair first', (Length(Steps) = 2) and (Steps[0].Kind = StepMove) and
      (Steps[0].Source = '/b/y') and (Steps[0].Target = '/a/y'));
    Check('undo: then it can be redone', History.CanRedo and (History.NextRedo.Kind = UndoMove));
    Steps := PlanFor(History.Redo, False);
    Check('redo: moved again in order', (Steps[0].Source = '/a/x') and (Steps[0].Target = '/b/x'));
    History.Undo;
    History.Push(MakeEntry(UndoNewFolder, [''], ['/a/New folder']));
    Check('undo: something new empties redo', not History.CanRedo and (History.UndoCount = 2));
    Steps := PlanFor(History.NextUndo, True);
    Check('undo: a new folder goes to the trash', (Steps[0].Kind = StepTrash) and (Steps[0].Source = '/a/New folder'));
    Steps := PlanFor(MakeEntry(UndoTrash, ['/a/f.txt'], ['/t/f.txt']), True);
    Check('undo: from the trash restored', (Steps[0].Kind = StepRestore) and (Steps[0].Target = '/a/f.txt'));
    Steps := PlanFor(MakeEntry(UndoCopy, ['/a/f'], ['/b/f']), True);
    Check('undo: a copy to the trash', (Steps[0].Kind = StepTrash) and (Steps[0].Source = '/b/f'));
    Check('undo: described', EntryDescription(MakeEntry(UndoRename, ['x'], ['y']), True) = 'Undo rename');
  finally
    History.Free;
  end;
end;

procedure TestConflictPolicy(Check: TCheckProcedure);
var
  Older: TFolderItem;
  Newer: TFolderItem;
begin
  Check('conflict: a copy onto itself is numbered',
    DecideBeforeAsking(OperationCopy, '/a/f', '/a/f', False, False) = DecideNumberedName);
  Check('conflict: a move onto itself does nothing',
    DecideBeforeAsking(OperationMove, '/a/f', '/a/f', False, False) = DecideNothingToDo);
  Check('conflict: folders merge', DecideBeforeAsking(OperationCopy, '/a/d', '/b/d', True, True) = DecideMerge);
  Check('conflict: files ask', DecideBeforeAsking(OperationCopy, '/a/f', '/b/f', False, False) = DecideAsk);
  Check('conflict: replace', DecisionForAnswer(ConflictReplace, True) = DecideReplace);
  Check('conflict: no replacing a folder', DecisionForAnswer(ConflictReplace, False) = DecideSkip);
  Check('conflict: keep both', DecisionForAnswer(ConflictRename, True) = DecideKeepBoth);
  Older := Default(TFolderItem);
  Older.Kind := ItemFile;
  Older.ModificationTime := 100;
  Older.SizeInBytes := 10;
  Newer := Older;
  Newer.ModificationTime := 200;
  Newer.SizeInBytes := 20;
  Check('conflict: compared', CompareText(Newer, Older) = 'The arriving one is newer and larger.');
  Check('conflict: the same', CompareText(Older, Older) = 'Both have the same date and size.');
end;

function ProgramFrom(const Text, Folder: string): TProgramInfo;
var
  Problems: TStringArray;
begin
  ParseProgramInfo(Text, Folder, Result, Problems);
end;

procedure TestTypeAssociations(Check: TCheckProcedure);
const
  Head = '[Program]'#10'Category = Accessories'#10;
var
  List: TProgramList;
  Handlers: TProgramList;
begin
  List := nil;
  SetLength(List, 3);
  List[0] := ProgramFrom(Head + 'Name = Viewer'#10'Executable = viewer'#10'MimeTypes = ["image/*"]'#10, 'viewer');
  List[1] := ProgramFrom(Head + 'Name = Paint'#10'Executable = paint'#10'Extensions = [".PNG", "bmp"]'#10, 'paint');
  List[2] := ProgramFrom(Head + 'Name = Editor'#10'Executable = editor'#10'Extensions = "txt; md"'#10, 'editor');
  Check('types: extensions read in small letters without the dot', (Length(List[1].Extensions) = 2) and
    (List[1].Extensions[0] = 'png'));
  Check('types: a word list in one string', (Length(List[2].Extensions) = 2) and (List[2].Extensions[1] = 'md'));
  Handlers := HandlersFor(List, 'png', 'image/png');
  Check('types: the extension before the family', (Length(Handlers) = 2) and (Handlers[0].FolderName = 'paint') and
    (Handlers[1].FolderName = 'viewer'));
  Check('types: default is the best', DefaultHandlerIndex(Handlers, '') = 0);
  Check('types: the chosen default wins', DefaultHandlerIndex(Handlers, 'viewer') = 1);
  Check('types: a chosen program that cannot open it is passed over', DefaultHandlerIndex(Handlers, 'editor') = 0);
  Handlers := HandlersFor(List, 'jpg', 'image/jpeg');
  Check('types: the family alone', (Length(Handlers) = 1) and (Handlers[0].FolderName = 'viewer'));
  Check('types: nobody for an unknown type', Length(HandlersFor(List, 'qqq', 'application/octet-stream')) = 0);
end;

procedure TestTrashInfo(Check: TCheckProcedure);
var
  Path: string;
  Seconds: Int64;
  Taken: TTakenNames;
begin
  Check('trash: encoded path', PercentEncodePath('/home/a/My notes%.txt') = '/home/a/My%20notes%25.txt');
  Check('trash: decoded path', PercentDecodePath('/a/b%20c', Path) and (Path = '/a/b c'));
  Check('trash: a bad escape', not PercentDecodePath('/a/%2', Path));
  Check('trash: date text', TrashDateText(DaysFromCivil(2026, 11, 21) * SecondsPerDay + 3723) = '2026-11-21T01:02:03');
  Check('trash: info round trip', ParseTrashInfo(FormatTrashInfo('/x/ü y.txt', 86400 + 60), Path, Seconds) and
    (Path = '/x/ü y.txt') and (Seconds = 86400 + 60));
  Check('trash: info without a path refused', not ParseTrashInfo('[Trash Info]'#10'DeletionDate=x'#10, Path, Seconds));
  Taken := TTakenNames.Create;
  try
    Taken.Names := ['notes.txt', 'notes.2.txt'];
    Check('trash: a free name in the trash', FreeTrashName('notes.txt', @Taken.IsTaken) = 'notes.3.txt');
    Check('trash: a free name kept', FreeTrashName('other', @Taken.IsTaken) = 'other');
  finally
    Taken.Free;
  end;
end;

procedure TestExplorerLogic(Check: TCheckProcedure);
begin
  TestNaturalOrder(Check);
  TestFileKinds(Check);
  TestCivilDates(Check);
  TestSearchQuery(Check);
  TestBatchNames(Check);
  TestUndoHistory(Check);
  TestConflictPolicy(Check);
  TestTypeAssociations(Check);
  TestTrashInfo(Check);
end;

end.
