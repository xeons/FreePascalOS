{
  Reading whole directories.

  ListDirectory returns the names in a directory (without "." and "..")
  in a line list, so tools can sort them or walk a tree recursively.
}
unit Util.Directories;

{$mode objfpc}
{$pointermath on}

interface

uses
  Util.Input;

{ Returns 0 or an error code. Names are added to List (which the caller
  has begun and must free). }
function ListDirectory(Path: PChar; var List: TLineList): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Memory,
  Util.Paths;

function ListDirectory(Path: PChar; var List: TLineList): LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Information: TFileInformation;
begin
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind <> KindDirectory) then
  begin
    CloseFile(Handle);
    Exit(ErrorNotDirectory);
  end;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    if not IsDotEntry(@Entry.Name[0]) then
      AddLine(List, DuplicateText(@Entry.Name[0]));
  end;
  CloseFile(Handle);
  Result := ErrorNone;
end;

end.
