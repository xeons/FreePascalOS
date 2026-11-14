{
  Copying and removing files and whole directory trees.

  Used by cp, and by mv when it has to move between volumes (a rename
  cannot cross volumes, so mv copies and then removes). Errors are
  reported as they happen; the functions return False if anything
  failed but carry on with the rest of the tree.
}
unit Util.FileTree;

{$mode objfpc}
{$pointermath on}

interface

type
  TCopyOptions = record
    Recursive: Boolean;
    { Copy symbolic links as links instead of what they point to. }
    KeepLinks: Boolean;
    { Do not replace existing targets. }
    NoClobber: Boolean;
    Verbose: Boolean;
  end;

{ Copies Source to Target (a file, link or, with Recursive, a tree). }
function CopyPath(Source, Target: PChar; const Options: TCopyOptions): Boolean;
{ Removes Path and everything below it. }
function RemoveTree(Path: PChar): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Directories,
  Util.Input,
  Util.Messages,
  Util.Paths;

const
  CopyBufferSize = 64 * 1024;

function CopyFileContents(Source, Target: PChar): Boolean;
var
  SourceHandle: Int64;
  TargetHandle: Int64;
  Buffer: PChar;
  Count: Int64;
  Error: LongInt;
begin
  Result := False;
  SourceHandle := OpenFile(Source, OpenRead);
  if SourceHandle < 0 then
  begin
    ReportError(ErrorCodeOf(SourceHandle), 'cannot open ''%s'' for reading', [ArgumentText(Source)]);
    Exit;
  end;
  TargetHandle := OpenFile(Target, OpenWrite or OpenCreate or OpenTruncate);
  if TargetHandle < 0 then
  begin
    ReportError(ErrorCodeOf(TargetHandle), 'cannot create regular file ''%s''', [ArgumentText(Target)]);
    CloseFile(SourceHandle);
    Exit;
  end;

  Buffer := PChar(AllocateMemory(CopyBufferSize));
  Result := True;
  repeat
    Count := ReadFile(SourceHandle, Buffer, CopyBufferSize);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), 'error reading ''%s''', [ArgumentText(Source)]);
      Result := False;
      Break;
    end;
    if Count = 0 then
      Break;
    Error := WriteAll(TargetHandle, Buffer, QWord(Count));
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'error writing ''%s''', [ArgumentText(Target)]);
      Result := False;
      Break;
    end;
  until False;
  FreeMemory(Buffer);
  CloseFile(SourceHandle);
  CloseFile(TargetHandle);
end;

function CopyLink(Source, Target: PChar): Boolean;
var
  LinkTarget: array[0..PathCapacity - 1] of Char;
  Error: LongInt;
begin
  Error := ReadSymbolicLink(Source, @LinkTarget[0], PathCapacity);
  if Error = ErrorNone then
  begin
    if PathExists(Target) then
      RemovePath(Target);
    Error := CreateSymbolicLink(@LinkTarget[0], Target);
  end;
  if Error <> ErrorNone then
    ReportError(Error, 'cannot create symbolic link ''%s''', [ArgumentText(Target)]);
  Result := Error = ErrorNone;
end;

function CopyDirectory(Source, Target: PChar; const Options: TCopyOptions): Boolean;
var
  Names: TLineList;
  Index: Integer;
  ChildSource: PChar;
  ChildTarget: PChar;
  Error: LongInt;
begin
  if not IsDirectory(Target) then
  begin
    Error := CreateDirectory(Target);
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'cannot create directory ''%s''', [ArgumentText(Target)]);
      Exit(False);
    end;
  end;
  BeginLineList(Names);
  Error := ListDirectory(Source, Names);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot access ''%s''', [ArgumentText(Source)]);
    FreeLineList(Names);
    Exit(False);
  end;
  Result := True;
  for Index := 0 to Names.Count - 1 do
  begin
    ChildSource := JoinPath(Source, Names.Items[Index]);
    ChildTarget := JoinPath(Target, Names.Items[Index]);
    if not CopyPath(ChildSource, ChildTarget, Options) then
      Result := False;
    FreeMemory(ChildSource);
    FreeMemory(ChildTarget);
  end;
  FreeLineList(Names);
end;

function CopyPath(Source, Target: PChar; const Options: TCopyOptions): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  if Options.KeepLinks then
    Error := GetLinkInformation(Source, Information)
  else
    Error := GetFileInformation(Source, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot stat ''%s''', [ArgumentText(Source)]);
    Exit(False);
  end;
  if Options.NoClobber and PathExists(Target) and (Information.Kind <> KindDirectory) then
    Exit(True);
  if Options.Verbose then
    WriteFormatted(StandardOutput, '''%s'' -> ''%s'''#10, [ArgumentText(Source), ArgumentText(Target)]);

  case Information.Kind of
    KindDirectory:
      begin
        if not Options.Recursive then
        begin
          Report('-r not specified; omitting directory ''%s''', [ArgumentText(Source)]);
          Exit(False);
        end;
        Result := CopyDirectory(Source, Target, Options);
      end;
    KindSymbolicLink:
      Result := CopyLink(Source, Target);
  else
    Result := CopyFileContents(Source, Target);
  end;
end;

function RemoveTree(Path: PChar): Boolean;
var
  Information: TFileInformation;
  Names: TLineList;
  Index: Integer;
  ChildPath: PChar;
  Error: LongInt;
begin
  Result := True;
  Error := GetLinkInformation(Path, Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
  begin
    BeginLineList(Names);
    ListDirectory(Path, Names);
    for Index := 0 to Names.Count - 1 do
    begin
      ChildPath := JoinPath(Path, Names.Items[Index]);
      if not RemoveTree(ChildPath) then
        Result := False;
      FreeMemory(ChildPath);
    end;
    FreeLineList(Names);
  end;
  if Error = ErrorNone then
    Error := RemovePath(Path);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot remove ''%s''', [ArgumentText(Path)]);
    Result := False;
  end;
end;

end.
