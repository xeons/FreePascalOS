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

(*
  find - search for files in a directory hierarchy

  find [PATH...] [EXPRESSION]

  Walks each PATH (default ".") and evaluates EXPRESSION for every file.
  Symbolic links are not followed.

  Options:     -maxdepth N  -mindepth N  -depth
  Tests:       -name PATTERN  -iname PATTERN  -path PATTERN  -ipath PATTERN
               -type f|d|l|c|b|p  -size [+-]N[cbkMG]  -mtime [+-]N  -mmin [+-]N
               -newer FILE  -empty  -user NAME  -group NAME
               -perm [-/]MODE  -links [+-]N  -true  -false
  Actions:     -print  -print0  -ls  -delete  -prune  -quit
               -exec COMMAND ;   -exec COMMAND {} +
  Operators:   ( EXPR )  ! EXPR  -not EXPR  EXPR -a EXPR  EXPR -and EXPR
               EXPR -o EXPR  EXPR -or EXPR

  Without an action, -print is applied to files for which the whole
  expression is true. Numbers: +N means more than N, -N less than N.
*)
program find;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Processes,
  Sys.Streams,
  Sys.Time,
  Util.Accounts,
  Util.CommandLine,
  Util.Commands,
  Util.Directories,
  Util.Globbing,
  Util.Messages,
  Util.Modes,
  Util.Numbers,
  Util.Paths;

const
  Usage = 'Usage: find [path...] [expression]'#10#10 +
    'Default path is the current directory; default expression is -print.'#10 +
    'Expression may consist of: operators, options, tests, and actions.'#10#10 +
    'Operators: ( EXPR )  ! EXPR  -not EXPR  EXPR1 -a EXPR2  EXPR1 -and EXPR2'#10 +
    '           EXPR1 -o EXPR2  EXPR1 -or EXPR2'#10#10 +
    'Options: -depth -maxdepth LEVELS -mindepth LEVELS'#10#10 +
    'Tests (N can be +N or -N or N): -empty -false -group NAME -iname PATTERN'#10 +
    '      -ipath PATTERN -links N -mmin N -mtime N -name PATTERN -newer FILE'#10 +
    '      -path PATTERN -perm [-/]MODE -size N[bckMG] -true -type [fdl] -user NAME'#10#10 +
    'Actions: -delete -print0 -print -ls -prune -quit'#10 +
    '      -exec COMMAND ; -exec COMMAND {} +'#10;

  MaximumBatch = 256;

type
  TNodeKind = (NodeAnd, NodeOr, NodeNot, NodeName, NodePath, NodeType, NodeSize, NodeModifiedDays,
    NodeModifiedMinutes, NodeNewer, NodeEmpty, NodeUser, NodeGroup, NodePermissions, NodeLinks,
    NodeTrue, NodeFalse, NodePrint, NodePrintNull, NodeList, NodeDelete, NodePrune, NodeQuit,
    NodeExecute);

  TComparison = (CompareEqual, CompareGreater, CompareLess);

  { One operator, test or action of the expression. }
  TFindNode = class
  public
    Kind: TNodeKind;
    Left: TFindNode;
    Right: TFindNode;
    Pattern: string;
    IgnoreCase: Boolean;
    TypeLetter: Char;
    Comparison: TComparison;
    Number: Int64;
    UnitSize: Int64;
    Time: Int64;
    PermissionMode: Char;  { ' ' exact, '-' all bits, '/' any bit }
    Mode: LongWord;
    (* -exec: the command words (with {} placeholders). *)
    Words: TStringArray;
    Batched: Boolean;
    Batch: TStringList;
    constructor Create(NodeKind: TNodeKind);
    destructor Destroy; override;
  end;

  { Reads the expression from the arguments after the paths. }
  TExpressionParser = class
  private
    FArguments: TStringArray;
    FPosition: Integer;
    function Peek: string;
    function PeekIs(const Text: string): Boolean;
    function AtEnd: Boolean;
    function AtExpressionEnd: Boolean;
    function TakeArgument(const Option: string): string;
    procedure ParseComparison(const Text: string; Node: TFindNode; const Option: string);
    procedure ParseSize(const Text: string; Node: TFindNode);
    procedure ParseExecute(Node: TFindNode);
    function ParseWalkOption(const Option: string; out Node: TFindNode): Boolean;
    function ParseTest(const Option: string): TFindNode;
    function ParsePrimary: TFindNode;
    function ParseAnd: TFindNode;
    function ParseOr: TFindNode;
  public
    constructor Create(const Arguments: TStringArray; First: Integer);
    { The whole expression; anything left over ends the program. }
    function Parse: TFindNode;
  end;

var
  MaximumDepth: Int64;
  MinimumDepth: Int64;
  DepthFirst: Boolean;
  HasAction: Boolean;
  Root: TFindNode;
  BatchNodes: array of TFindNode;
  ExitStatus: LongInt;
  Quitting: Boolean;
  StartTime: Int64;
  { Set by -prune for the current file. }
  PruneRequested: Boolean;

constructor TFindNode.Create(NodeKind: TNodeKind);
begin
  inherited Create;
  Kind := NodeKind;
end;

destructor TFindNode.Destroy;
begin
  Left.Free;
  Right.Free;
  Batch.Free;
  inherited Destroy;
end;

{ --- Parsing --------------------------------------------------------- }

constructor TExpressionParser.Create(const Arguments: TStringArray; First: Integer);
begin
  inherited Create;
  FArguments := Arguments;
  FPosition := First;
end;

function TExpressionParser.AtEnd: Boolean;
begin
  Result := FPosition >= Length(FArguments);
end;

function TExpressionParser.Peek: string;
begin
  if AtEnd then
    Result := ''
  else
    Result := FArguments[FPosition];
end;

function TExpressionParser.PeekIs(const Text: string): Boolean;
begin
  Result := not AtEnd and (FArguments[FPosition] = Text);
end;

function TExpressionParser.AtExpressionEnd: Boolean;
begin
  Result := AtEnd or PeekIs(')') or PeekIs('-o') or PeekIs('-or');
end;

function TExpressionParser.TakeArgument(const Option: string): string;
begin
  if AtEnd then
    Fail(1, Format('missing argument to `%s''', [Option]));
  Result := FArguments[FPosition];
  Inc(FPosition);
end;

{ "+N", "-N" or "N". }
procedure TExpressionParser.ParseComparison(const Text: string; Node: TFindNode; const Option: string);
var
  Digits: string;
  Value: Int64;
begin
  Node.Comparison := CompareEqual;
  Digits := Text;
  if (Text <> '') and (Text[1] = '+') then
  begin
    Node.Comparison := CompareGreater;
    Delete(Digits, 1, 1);
  end
  else if (Text <> '') and (Text[1] = '-') then
  begin
    Node.Comparison := CompareLess;
    Delete(Digits, 1, 1);
  end;
  if not ParseDecimal(Digits, Value) then
    Fail(1, Format('invalid argument `%s'' to `%s''', [Digits, Option]));
  Node.Number := Value;
end;

procedure TExpressionParser.ParseSize(const Text: string; Node: TFindNode);
var
  Digits: string;
  UnitLetter: Char;
begin
  Digits := Text;
  Node.UnitSize := 512;
  if (Digits <> '') and not (Digits[Length(Digits)] in ['0'..'9']) then
  begin
    UnitLetter := Digits[Length(Digits)];
    case UnitLetter of
      'c': Node.UnitSize := 1;
      'w': Node.UnitSize := 2;
      'b': Node.UnitSize := 512;
      'k': Node.UnitSize := 1024;
      'M': Node.UnitSize := 1024 * 1024;
      'G': Node.UnitSize := 1024 * 1024 * 1024;
    else
      Fail(1, 'invalid -size type `' + UnitLetter + '''');
    end;
    SetLength(Digits, Length(Digits) - 1);
  end;
  ParseComparison(Digits, Node, '-size');
end;

function IsBatchEnd(const Arguments: TStringArray; Index, Start: Integer): Boolean;
begin
  Result := (Arguments[Index] = '+') and (Index > Start) and (Arguments[Index - 1] = '{}');
end;

procedure TExpressionParser.ParseExecute(Node: TFindNode);
var
  Start: Integer;
  WordCount: Integer;
begin
  Start := FPosition;
  while not AtEnd and (FArguments[FPosition] <> ';') and not IsBatchEnd(FArguments, FPosition, Start) do
    Inc(FPosition);
  if AtEnd then
    Fail(1, 'missing argument to `-exec''');
  Node.Batched := FArguments[FPosition] = '+';
  WordCount := FPosition - Start;
  if WordCount = 0 then
    Fail(1, 'missing argument to `-exec''');
  Inc(FPosition);
  if Node.Batched then
  begin
    (* The {} before + stands for the collected names. *)
    Dec(WordCount);
    Node.Batch := TStringList.Create;
    SetLength(BatchNodes, Length(BatchNodes) + 1);
    BatchNodes[High(BatchNodes)] := Node;
  end;
  Node.Words := Copy(FArguments, Start, WordCount);
end;

{ Options that apply to the whole walk count as "true". }
function TExpressionParser.ParseWalkOption(const Option: string; out Node: TFindNode): Boolean;
var
  Text: string;
  Value: Int64;
begin
  Node := nil;
  if (Option = '-maxdepth') or (Option = '-mindepth') then
  begin
    Text := TakeArgument(Option);
    if not ParseDecimal(Text, Value) or (Value < 0) then
      Fail(1, Format('Expected a positive decimal integer argument to %s, but got `%s''', [Option, Text]));
    if Option[3] = 'a' then
      MaximumDepth := Value
    else
      MinimumDepth := Value;
    Node := TFindNode.Create(NodeTrue);
  end
  else if (Option = '-depth') or (Option = '-d') then
  begin
    DepthFirst := True;
    Node := TFindNode.Create(NodeTrue);
  end;
  Result := Node <> nil;
end;

function TExpressionParser.ParseTest(const Option: string): TFindNode;
var
  Text: string;
  Information: TFileInformation;
  Change: TModeChange;
  Id: LongWord;
begin
  if (Option = '-name') or (Option = '-iname') then
  begin
    Result := TFindNode.Create(NodeName);
    Result.Pattern := TakeArgument(Option);
    Result.IgnoreCase := Option[2] = 'i';
  end
  else if (Option = '-path') or (Option = '-ipath') or (Option = '-wholename') then
  begin
    Result := TFindNode.Create(NodePath);
    Result.Pattern := TakeArgument(Option);
    Result.IgnoreCase := Option[2] = 'i';
  end
  else if Option = '-type' then
  begin
    Result := TFindNode.Create(NodeType);
    Text := TakeArgument(Option);
    if (Length(Text) <> 1) or not (Text[1] in ['f', 'd', 'l', 'c', 'b', 'p']) then
      Fail(1, Format('Unknown argument to -type: %s', [Text]));
    Result.TypeLetter := Text[1];
  end
  else if Option = '-size' then
  begin
    Result := TFindNode.Create(NodeSize);
    ParseSize(TakeArgument(Option), Result);
  end
  else if (Option = '-mtime') or (Option = '-mmin') then
  begin
    if Option[3] = 't' then
      Result := TFindNode.Create(NodeModifiedDays)
    else
      Result := TFindNode.Create(NodeModifiedMinutes);
    ParseComparison(TakeArgument(Option), Result, Option);
  end
  else if Option = '-newer' then
  begin
    Result := TFindNode.Create(NodeNewer);
    Text := TakeArgument(Option);
    if GetFileInformation(PChar(Text), Information) <> ErrorNone then
      Fail(1, Format('`%s'': No such file or directory', [Text]));
    Result.Time := Information.ModificationTime;
  end
  else if Option = '-empty' then
    Result := TFindNode.Create(NodeEmpty)
  else if Option = '-user' then
  begin
    Result := TFindNode.Create(NodeUser);
    Text := TakeArgument(Option);
    if not FindUserId(Text, Id) then
      Fail(1, Format('`%s'' is not the name of a known user', [Text]));
    Result.Number := Id;
  end
  else if Option = '-group' then
  begin
    Result := TFindNode.Create(NodeGroup);
    Text := TakeArgument(Option);
    if not FindGroupId(Text, Id) then
      Fail(1, Format('`%s'' is not the name of an existing group', [Text]));
    Result.Number := Id;
  end
  else if Option = '-perm' then
  begin
    Result := TFindNode.Create(NodePermissions);
    Text := TakeArgument(Option);
    Result.PermissionMode := ' ';
    if (Text <> '') and (Text[1] in ['-', '/']) then
    begin
      Result.PermissionMode := Text[1];
      Delete(Text, 1, 1);
    end;
    if not ParseModeChange(Text, Change) then
      Fail(1, Format('invalid mode `%s''', [Text]));
    Result.Mode := ApplyModeChange(Change, 0, False);
  end
  else if Option = '-links' then
  begin
    Result := TFindNode.Create(NodeLinks);
    ParseComparison(TakeArgument(Option), Result, Option);
  end
  else if Option = '-true' then
    Result := TFindNode.Create(NodeTrue)
  else if Option = '-false' then
    Result := TFindNode.Create(NodeFalse)
  else if Option = '-print' then
  begin
    Result := TFindNode.Create(NodePrint);
    HasAction := True;
  end
  else if Option = '-print0' then
  begin
    Result := TFindNode.Create(NodePrintNull);
    HasAction := True;
  end
  else if Option = '-ls' then
  begin
    Result := TFindNode.Create(NodeList);
    HasAction := True;
  end
  else if Option = '-delete' then
  begin
    Result := TFindNode.Create(NodeDelete);
    HasAction := True;
    DepthFirst := True;
  end
  else if Option = '-prune' then
    Result := TFindNode.Create(NodePrune)
  else if Option = '-quit' then
    Result := TFindNode.Create(NodeQuit)
  else if Option = '-exec' then
  begin
    Result := TFindNode.Create(NodeExecute);
    HasAction := True;
    ParseExecute(Result);
  end
  else
  begin
    Fail(1, Format('unknown predicate `%s''', [Option]));
    Result := nil;
  end;
end;

function TExpressionParser.ParsePrimary: TFindNode;
var
  Option: string;
begin
  if AtEnd then
    Fail(1, 'expected an expression');
  Option := Peek;
  Inc(FPosition);

  if Option = '(' then
  begin
    Result := ParseOr;
    if not PeekIs(')') then
      Fail(1, 'invalid expression; I was expecting to find a '')'' somewhere but did not see one.');
    Inc(FPosition);
    Exit;
  end;
  if (Option = '!') or (Option = '-not') then
  begin
    Result := TFindNode.Create(NodeNot);
    Result.Left := ParsePrimary();
    Exit;
  end;
  if not ParseWalkOption(Option, Result) then
    Result := ParseTest(Option);
end;

function TExpressionParser.ParseAnd: TFindNode;
var
  Node: TFindNode;
begin
  Result := ParsePrimary;
  while not AtExpressionEnd do
  begin
    if PeekIs('-a') or PeekIs('-and') then
      Inc(FPosition);
    Node := TFindNode.Create(NodeAnd);
    Node.Left := Result;
    Node.Right := ParsePrimary;
    Result := Node;
  end;
end;

function TExpressionParser.ParseOr: TFindNode;
var
  Node: TFindNode;
begin
  Result := ParseAnd;
  while PeekIs('-o') or PeekIs('-or') do
  begin
    Inc(FPosition);
    Node := TFindNode.Create(NodeOr);
    Node.Left := Result;
    Node.Right := ParseAnd;
    Result := Node;
  end;
end;

function TExpressionParser.Parse: TFindNode;
begin
  Result := ParseOr;
  if not AtEnd then
    Fail(1, Format('unexpected `%s''', [Peek]));
end;

{ --- Actions --------------------------------------------------------- }

function Compare(Value, Number: Int64; Comparison: TComparison): Boolean;
begin
  case Comparison of
    CompareGreater: Result := Value > Number;
    CompareLess: Result := Value < Number;
  else
    Result := Value = Number;
  end;
end;

{ Runs Words followed by Extra; returns the exit status. }
function RunCommand(const Words, Extra: array of string): LongInt;
var
  CommandWords: TStringArray;
  Index: Integer;
  Options: TProcessOptions;
  Handle: Int64;
  Status: LongInt;
begin
  CommandWords := nil;
  SetLength(CommandWords, Length(Words) + Length(Extra));
  for Index := 0 to High(Words) do
    CommandWords[Index] := Words[Index];
  for Index := 0 to High(Extra) do
    CommandWords[Length(Words) + Index] := Extra[Index];
  DefaultProcessOptions(Options);
  FlushStandardStreams;
  Handle := StartCommand(CommandWords, Options, Status);
  if Handle >= 0 then
    Status := WaitForProgram(Handle);
  Result := Status;
end;

(* Runs the command with every "{}" inside a word replaced by Path. *)
function ExecuteForPath(Node: TFindNode; const Path: string): Boolean;
var
  Words: TStringArray;
  Index: Integer;
begin
  Words := Copy(Node.Words);
  for Index := 0 to High(Words) do
    Words[Index] := StringReplace(Words[Index], '{}', Path, [rfReplaceAll]);
  Result := RunCommand(Words, []) = 0;
end;

procedure FlushBatch(Node: TFindNode);
begin
  if Node.Batch.Count = 0 then
    Exit;
  if RunCommand(Node.Words, Node.Batch.ToStringArray) <> 0 then
    ExitStatus := 1;
  Node.Batch.Clear;
end;

procedure ListEntry(const Path: string; const Information: TFileInformation);
var
  TypeLetter: Char;
  DateTime: Sys.Time.TDateTime;
begin
  case Information.Kind of
    KindDirectory: TypeLetter := 'd';
    KindSymbolicLink: TypeLetter := 'l';
  else
    TypeLetter := '-';
  end;
  Sys.Time.DecodeTime(Information.ModificationTime, DateTime);
  PrintString(Format('%9d %6d %s %3d %-8s %-8s %8d %s %2d %.2d:%.2d %s'#10, [
    Information.NodeNumber, (Information.SizeInBytes + 1023) div 1024,
    TypeLetter + FormatModeText(Information.Mode), Information.LinkCount,
    UserNameOrNumber(Information.OwnerId), GroupNameOrNumber(Information.GroupId), Information.SizeInBytes,
    string(MonthName(DateTime.Month)), DateTime.Day, DateTime.Hour, DateTime.Minute, Path]));
end;

{ --- Evaluating ------------------------------------------------------ }

function DirectoryIsEmpty(const Path: string): Boolean;
var
  Names: TStringList;
begin
  Names := TStringList.Create;
  try
    ListDirectory(Path, Names);
    Result := Names.Count = 0;
  finally
    Names.Free;
  end;
end;

function DeletePath(const Path: string): Boolean;
var
  Error: LongInt;
begin
  Result := True;
  if Path = '.' then
    Exit;
  Error := RemovePath(PChar(Path));
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('cannot delete `%s''', [Path]));
    ExitStatus := 1;
    Result := False;
  end;
end;

function MatchesType(TypeLetter: Char; const Information: TFileInformation): Boolean;
begin
  case TypeLetter of
    'f': Result := Information.Kind = KindFile;
    'd': Result := Information.Kind = KindDirectory;
    'c': Result := Information.Kind = KindCharacterDevice;
    'b': Result := Information.Kind = KindBlockDevice;
    'p': Result := Information.Kind = KindFifo;
  else
    Result := Information.Kind = KindSymbolicLink;
  end;
end;

function MatchesPermissions(Node: TFindNode; const Information: TFileInformation): Boolean;
begin
  case Node.PermissionMode of
    '-': Result := (Information.Mode and Node.Mode) = Node.Mode;
    '/': Result := (Node.Mode = 0) or ((Information.Mode and Node.Mode) <> 0);
  else
    Result := (Information.Mode and $FFF) = Node.Mode;
  end;
end;

function Evaluate(Node: TFindNode; const Path: string; const Information: TFileInformation): Boolean;
var
  Units: Int64;
  Age: Int64;
begin
  case Node.Kind of
    NodeAnd: Result := Evaluate(Node.Left, Path, Information) and Evaluate(Node.Right, Path, Information);
    NodeOr: Result := Evaluate(Node.Left, Path, Information) or Evaluate(Node.Right, Path, Information);
    NodeNot: Result := not Evaluate(Node.Left, Path, Information);
    NodeName: Result := MatchWildcards(Node.Pattern, BaseName(Path), Node.IgnoreCase);
    NodePath: Result := MatchWildcards(Node.Pattern, Path, Node.IgnoreCase);
    NodeType: Result := MatchesType(Node.TypeLetter, Information);
    NodeSize:
      begin
        { Sizes are rounded up to whole units. }
        Units := (Int64(Information.SizeInBytes) + Node.UnitSize - 1) div Node.UnitSize;
        Result := Compare(Units, Node.Number, Node.Comparison);
      end;
    NodeModifiedDays:
      begin
        Age := (StartTime - Information.ModificationTime) div 86400;
        Result := Compare(Age, Node.Number, Node.Comparison);
      end;
    NodeModifiedMinutes:
      begin
        Age := (StartTime - Information.ModificationTime + 59) div 60;
        Result := Compare(Age, Node.Number, Node.Comparison);
      end;
    NodeNewer: Result := Information.ModificationTime > Node.Time;
    NodeEmpty:
      if Information.Kind = KindDirectory then
        Result := DirectoryIsEmpty(Path)
      else
        Result := (Information.Kind = KindFile) and (Information.SizeInBytes = 0);
    NodeUser: Result := Information.OwnerId = LongWord(Node.Number);
    NodeGroup: Result := Information.GroupId = LongWord(Node.Number);
    NodePermissions: Result := MatchesPermissions(Node, Information);
    NodeLinks: Result := Compare(Information.LinkCount, Node.Number, Node.Comparison);
    NodeTrue: Result := True;
    NodeFalse: Result := False;
    NodePrint:
      begin
        PrintStringLine(Path);
        Result := True;
      end;
    NodePrintNull:
      begin
        PrintString(Path + #0);
        Result := True;
      end;
    NodeList:
      begin
        ListEntry(Path, Information);
        Result := True;
      end;
    NodeDelete: Result := DeletePath(Path);
    NodePrune:
      begin
        PruneRequested := True;
        Result := True;
      end;
    NodeQuit:
      begin
        Quitting := True;
        Result := True;
      end;
    NodeExecute:
      if Node.Batched then
      begin
        Node.Batch.Add(Path);
        if Node.Batch.Count >= MaximumBatch then
          FlushBatch(Node);
        Result := True;
      end
      else
        Result := ExecuteForPath(Node, Path);
  else
    Result := False;
  end;
end;

procedure Visit(const Path: string; Depth: Int64);
var
  Information: TFileInformation;
  Error: LongInt;
  Names: TStringList;
  Name: string;
  Descend: Boolean;

  procedure EvaluateHere;
  begin
    if Depth < MinimumDepth then
      Exit;
    PruneRequested := False;
    if Evaluate(Root, Path, Information) and not HasAction then
      PrintStringLine(Path);
  end;

begin
  if Quitting then
    Exit;
  Error := GetLinkInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, Format('`%s''', [Path]));
    ExitStatus := 1;
    Exit;
  end;
  PruneRequested := False;
  if not DepthFirst then
    EvaluateHere;
  Descend := (Information.Kind = KindDirectory) and ((MaximumDepth < 0) or (Depth < MaximumDepth)) and
    not (PruneRequested and not DepthFirst);
  if Descend and not Quitting then
  begin
    Names := TStringList.Create;
    try
      Error := ListDirectory(Path, Names);
      if Error <> ErrorNone then
      begin
        ReportError(Error, Format('`%s''', [Path]));
        ExitStatus := 1;
      end;
      for Name in Names do
      begin
        Visit(JoinPath(Path, Name), Depth + 1);
        if Quitting then
          Break;
      end;
    finally
      Names.Free;
    end;
  end;
  if DepthFirst and not Quitting then
    EvaluateHere;
end;

{ Paths come first, up to the first argument that starts an expression. }
function IsPathArgument(const Text: string): Boolean;
begin
  Result := ((Text = '') or (Text[1] <> '-')) and (Text <> '(') and (Text <> '!');
end;

var
  Arguments: TStringArray;
  Paths: TStringArray;
  FirstExpression: Integer;
  Parser: TExpressionParser;
  Path: string;
  BatchNode: TFindNode;
begin
  ExitStatus := 0;
  MaximumDepth := -1;
  MinimumDepth := 0;
  StartTime := CurrentTime;
  Arguments := ProgramArguments;
  if (Length(Arguments) = 1) and (Arguments[0] = '--help') then
  begin
    PrintString(Usage);
    Halt(0);
  end;

  FirstExpression := 0;
  while (FirstExpression < Length(Arguments)) and IsPathArgument(Arguments[FirstExpression]) do
    Inc(FirstExpression);
  Paths := Copy(Arguments, 0, FirstExpression);
  if Length(Paths) = 0 then
    Paths := ['.'];

  if FirstExpression < Length(Arguments) then
  begin
    Parser := TExpressionParser.Create(Arguments, FirstExpression);
    Root := Parser.Parse;
    Parser.Free;
  end
  else
    Root := TFindNode.Create(NodeTrue);

  for Path in Paths do
  begin
    Visit(Path, 0);
    if Quitting then
      Break;
  end;
  for BatchNode in BatchNodes do
    FlushBatch(BatchNode);
  Halt(ExitStatus);
end.
