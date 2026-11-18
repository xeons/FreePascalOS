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
  What Tab completes a word to, for the line editor: the names of
  programs in PATH for a word in command position, otherwise the names
  in the word's directory.
}
unit Util.LineCompletion;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TCompletion = class
  private
    FMatches: TStringList;
    FDirectory: string;
    FHasDirectory: Boolean;
    FPrefix: string;
    FIsCommand: Boolean;
    procedure CollectMatches(const Directory: string; OnlyFiles: Boolean);
    procedure CollectCommands;
    procedure CollectProgramFolderCommands;
    function GetMatchCount: Integer;
    function GetMatch(Index: Integer): string;
  public
    { The matches for Word; IsCommand when the word is in command
      position (and names no path). }
    constructor Create(const Word: string; IsCommand: Boolean);
    destructor Destroy; override;
    { The longest beginning all matches share ('' without matches). }
    function CommonPrefix: string;
    { True if the single match, in its directory, is a directory. }
    function MatchIsDirectory(Index: Integer): Boolean;
    property MatchCount: Integer read GetMatchCount;
    property Matches[Index: Integer]: string read GetMatch;
    { The part of the word the matches start with (after its last '/'). }
    property Prefix: string read FPrefix;
  end;

{ True if the word at Position (from 0) of Text starts a command:
  nothing but blanks before it, or a separator such as |, ;, & or (. }
function IsCommandPosition(const Text: string; Position: Integer): Boolean;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Environment,
  Sys.Files,
  Sys.ProgramFolders,
  Util.Directories,
  Util.Paths;

function IsCommandPosition(const Text: string; Position: Integer): Boolean;
begin
  while (Position > 0) and (Text[Position] = ' ') do
    Dec(Position);
  Result := (Position = 0) or (Text[Position] in ['|', ';', '&', '(']);
end;

{ Byte-wise order, as the names were always listed. }
function CompareNames(List: TStringList; First, Second: Integer): Integer;
begin
  Result := CompareStr(List[First], List[Second]);
end;

function IsKind(const Path: string; Kind: LongWord): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetFileInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = Kind);
end;

constructor TCompletion.Create(const Word: string; IsCommand: Boolean);
var
  LastSlash: Integer;
begin
  inherited Create;
  FMatches := TStringList.Create;
  FIsCommand := IsCommand;
  if IsCommand then
  begin
    FPrefix := Word;
    CollectCommands;
  end
  else
  begin
    LastSlash := LastDelimiter('/', Word);
    FHasDirectory := True;
    if LastSlash = 1 then
      FDirectory := '/'
    else if LastSlash > 1 then
      FDirectory := Copy(Word, 1, LastSlash - 1)
    else
      FDirectory := '.';
    FPrefix := Copy(Word, LastSlash + 1, MaxInt);
    CollectMatches(FDirectory, False);
  end;
  FMatches.CustomSort(@CompareNames);
end;

destructor TCompletion.Destroy;
begin
  FMatches.Free;
  inherited Destroy;
end;

function TCompletion.GetMatchCount: Integer;
begin
  Result := FMatches.Count;
end;

function TCompletion.GetMatch(Index: Integer): string;
begin
  Result := FMatches[Index];
end;

{ Adds the names in Directory starting with the prefix. }
procedure TCompletion.CollectMatches(const Directory: string; OnlyFiles: Boolean);
var
  Names: TStringList;
  Name: string;
begin
  Names := TStringList.Create;
  try
    if ListDirectory(Directory, Names) <> ErrorNone then
      Exit;
    for Name in Names do
    begin
      if not StartsStr(FPrefix, Name) then
        Continue;
      { Hidden names only when asked for. }
      if (Name[1] = '.') and ((FPrefix = '') or (FPrefix[1] <> '.')) then
        Continue;
      if OnlyFiles and not IsKind(JoinPath(Directory, Name), KindFile) then
        Continue;
      FMatches.Add(Name);
    end;
  finally
    Names.Free;
  end;
end;

procedure TCompletion.CollectCommands;
var
  SearchPath: string;
  Directory: string;
begin
  if not FindVariable('PATH', SearchPath) then
    SearchPath := '/bin';
  for Directory in SplitString(SearchPath, ':') do
    if Directory <> '' then
      CollectMatches(Directory, True);
  CollectProgramFolderCommands;
end;

{ The programs in folders of their own (/app/NAME/NAME), which are
  started by name as well. }
procedure TCompletion.CollectProgramFolderCommands;
var
  Folders: TProgramFolderNames;
  Name: string;
begin
  Folders := ListProgramFolders;
  for Name in Folders do
    if StartsStr(FPrefix, Name) and (FMatches.IndexOf(Name) < 0) and
       IsKind(ProgramFoldersRoot + '/' + Name + '/' + Name, KindFile) then
      FMatches.Add(Name);
end;

function TCompletion.CommonPrefix: string;
var
  Index: Integer;
  Length: Integer;
  Candidate: string;
begin
  if FMatches.Count = 0 then
    Exit('');
  Result := FMatches[0];
  for Index := 1 to FMatches.Count - 1 do
  begin
    Candidate := FMatches[Index];
    Length := 0;
    while (Length < System.Length(Result)) and (Length < System.Length(Candidate)) and
      (Candidate[Length + 1] = Result[Length + 1]) do
      Inc(Length);
    SetLength(Result, Length);
  end;
end;

function TCompletion.MatchIsDirectory(Index: Integer): Boolean;
begin
  Result := not FIsCommand and IsKind(FDirectory + '/' + FMatches[Index], KindDirectory);
end;

end.
