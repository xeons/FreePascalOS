{
  Path name manipulation (purely textual; the file system is not
  consulted). Results are new heap strings.
}
unit Util.Paths;

{$mode objfpc}
{$pointermath on}

interface

{ The last component: "/usr/lib/" -> "lib", "/" -> "/". }
function BaseName(Path: PChar): PChar;
{ Everything before the last component: "/usr/lib" -> "/usr",
  "file" -> ".", "/" -> "/". }
function DirectoryName(Path: PChar): PChar;
{ Directory + '/' + Name, without doubling the slash. }
function JoinPath(Directory, Name: PChar): PChar;
{ True for "." and "..". }
function IsDotEntry(Name: PChar): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Memory,
  Sys.Text;

function CopyRange(Text: PChar; Start, Finish: PtrInt): PChar;
var
  Length: PtrInt;
begin
  Length := Finish - Start;
  if Length < 0 then
    Length := 0;
  Result := PChar(AllocateMemory(Length + 1));
  CopyMemory(Result, Text + Start, Length);
  Result[Length] := #0;
end;

function BaseName(Path: PChar): PChar;
var
  Finish: PtrInt;
  Start: PtrInt;
begin
  Finish := PtrInt(TextLength(Path));
  if Finish = 0 then
    Exit(DuplicateText(''));
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  if (Finish = 1) and (Path[0] = '/') then
    Exit(DuplicateText('/'));
  Start := Finish;
  while (Start > 0) and (Path[Start - 1] <> '/') do
    Dec(Start);
  Result := CopyRange(Path, Start, Finish);
end;

function DirectoryName(Path: PChar): PChar;
var
  Finish: PtrInt;
begin
  Finish := PtrInt(TextLength(Path));
  { Drop trailing slashes, then the last component, then the slashes
    separating it. }
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  while (Finish > 0) and (Path[Finish - 1] <> '/') do
    Dec(Finish);
  if Finish = 0 then
    Exit(DuplicateText('.'));
  while (Finish > 1) and (Path[Finish - 1] = '/') do
    Dec(Finish);
  Result := CopyRange(Path, 0, Finish);
end;

function JoinPath(Directory, Name: PChar): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  AppendText(Builder, Directory);
  if (Builder.Length > 0) and (Builder.Text[Builder.Length - 1] <> '/') then
    AppendCharacter(Builder, '/');
  AppendText(Builder, Name);
  Result := FinishText(Builder);
end;

function IsDotEntry(Name: PChar): Boolean;
begin
  Result := TextIsEqual(Name, '.') or TextIsEqual(Name, '..');
end;

end.
