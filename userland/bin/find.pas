{
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
}
program find;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Runtime.Time,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.Accounts,
  Util.Commands,
  Util.Directories,
  Util.Globbing,
  Util.Input,
  Util.Messages,
  Util.Modes,
  Util.Paths;

const
  Usage: PChar = 'Usage: find [path...] [expression]'#10#10 +
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

  PNode = ^TNode;
  TNode = record
    Kind: TNodeKind;
    Left: PNode;
    Right: PNode;
    Text: PChar;
    IgnoreCase: Boolean;
    TypeLetter: Char;
    Comparison: TComparison;
    Number: Int64;
    UnitSize: Int64;
    Time: Int64;
    PermissionMode: Char;  { ' ' exact, '-' all bits, '/' any bit }
    Mode: LongWord;
    { -exec: the command words (with {} placeholders). }
    Words: PPChar;
    WordCount: Integer;
    Batched: Boolean;
    Batch: TLineList;
  end;

var
  Arguments: PPChar;
  ArgumentCountLeft: Integer;
  Position: Integer;
  MaximumDepth: Int64;
  MinimumDepth: Int64;
  DepthFirst: Boolean;
  HasAction: Boolean;
  Root: PNode;
  BatchNodes: array[0..31] of PNode;
  BatchNodeCount: Integer;
  ExitStatus: LongInt;
  Quitting: Boolean;
  Now: Int64;
  { Set by -prune for the current file. }
  PruneRequested: Boolean;

{ --- Parsing --------------------------------------------------------- }

function Peek: PChar;
begin
  if Position < ArgumentCountLeft then
    Result := Arguments[Position]
  else
    Result := nil;
end;

function PeekIs(Text: PChar): Boolean;
begin
  Result := (Peek <> nil) and TextIsEqual(Peek, Text);
end;

function NewNode(Kind: TNodeKind): PNode;
begin
  Result := PNode(AllocateZeroedMemory(SizeOf(TNode)));
  Result^.Kind := Kind;
end;

function TakeArgument(Option: PChar): PChar;
begin
  if Position >= ArgumentCountLeft then
    Fail(1, 'missing argument to `%s''', [ArgumentText(Option)]);
  Result := Arguments[Position];
  Inc(Position);
end;

{ "+N", "-N" or "N". }
procedure ParseComparison(Text: PChar; Node: PNode; Option: PChar);
var
  Value: Int64;
begin
  Node^.Comparison := CompareEqual;
  if Text^ = '+' then
  begin
    Node^.Comparison := CompareGreater;
    Inc(Text);
  end
  else if Text^ = '-' then
  begin
    Node^.Comparison := CompareLess;
    Inc(Text);
  end;
  if not ParseInteger(Text, Value) then
    Fail(1, 'invalid argument `%s'' to `%s''', [ArgumentText(Text), ArgumentText(Option)]);
  Node^.Number := Value;
end;

function Compare(Value, Number: Int64; Comparison: TComparison): Boolean;
begin
  case Comparison of
    CompareGreater: Result := Value > Number;
    CompareLess: Result := Value < Number;
  else
    Result := Value = Number;
  end;
end;

procedure ParseSize(Text: PChar; Node: PNode);
var
  Length: PtrUInt;
  Copy: PChar;
begin
  Copy := DuplicateText(Text);
  Length := TextLength(Copy);
  Node^.UnitSize := 512;
  if (Length > 0) and not IsDigit(Copy[Length - 1]) then
  begin
    case Copy[Length - 1] of
      'c': Node^.UnitSize := 1;
      'w': Node^.UnitSize := 2;
      'b': Node^.UnitSize := 512;
      'k': Node^.UnitSize := 1024;
      'M': Node^.UnitSize := 1024 * 1024;
      'G': Node^.UnitSize := 1024 * 1024 * 1024;
    else
      Fail(1, 'invalid -size type `%c''', [ArgumentCharacter(Copy[Length - 1])]);
    end;
    Copy[Length - 1] := #0;
  end;
  ParseComparison(Copy, Node, '-size');
end;

procedure ParseExecute(Node: PNode);
var
  Start: Integer;
  Index: Integer;
begin
  Start := Position;
  while (Position < ArgumentCountLeft) and not TextIsEqual(Arguments[Position], ';') and
        not (TextIsEqual(Arguments[Position], '+') and (Position > Start) and
             TextIsEqual(Arguments[Position - 1], '{}')) do
    Inc(Position);
  if Position >= ArgumentCountLeft then
    Fail(1, 'missing argument to `-exec''', []);
  Node^.Batched := TextIsEqual(Arguments[Position], '+');
  Node^.WordCount := Position - Start;
  if Node^.WordCount = 0 then
    Fail(1, 'missing argument to `-exec''', []);
  Node^.Words := PPChar(AllocateZeroedMemory(QWord(Node^.WordCount + 1) * SizeOf(PChar)));
  for Index := 0 to Node^.WordCount - 1 do
    Node^.Words[Index] := Arguments[Start + Index];
  Inc(Position);
  if Node^.Batched then
  begin
    { The {} before + stands for the collected names. }
    Dec(Node^.WordCount);
    BeginLineList(Node^.Batch);
    if BatchNodeCount < Length(BatchNodes) then
    begin
      BatchNodes[BatchNodeCount] := Node;
      Inc(BatchNodeCount);
    end;
  end;
end;

function ParseOr: PNode; forward;

function ParsePrimary: PNode;
var
  Option: PChar;
  Text: PChar;
  Information: TFileInformation;
  Change: TModeChange;
  Id: LongWord;
  Value: Int64;
begin
  Option := Peek;
  if Option = nil then
    Fail(1, 'expected an expression', []);
  Inc(Position);

  if TextIsEqual(Option, '(') then
  begin
    Result := ParseOr();
    if not PeekIs(')') then
      Fail(1, 'invalid expression; I was expecting to find a '')'' somewhere but did not see one.', []);
    Inc(Position);
    Exit;
  end;
  if TextIsEqual(Option, '!') or TextIsEqual(Option, '-not') then
  begin
    Result := NewNode(NodeNot);
    Result^.Left := ParsePrimary();
    Exit;
  end;

  { Options that apply to the whole walk count as "true". }
  if TextIsEqual(Option, '-maxdepth') or TextIsEqual(Option, '-mindepth') then
  begin
    Text := TakeArgument(Option);
    if not ParseInteger(Text, Value) or (Value < 0) then
      Fail(1, 'Expected a positive decimal integer argument to %s, but got `%s''',
        [ArgumentText(Option), ArgumentText(Text)]);
    if Option[2] = 'a' then
      MaximumDepth := Value
    else
      MinimumDepth := Value;
    Exit(NewNode(NodeTrue));
  end;
  if TextIsEqual(Option, '-depth') or TextIsEqual(Option, '-d') then
  begin
    DepthFirst := True;
    Exit(NewNode(NodeTrue));
  end;

  if TextIsEqual(Option, '-name') or TextIsEqual(Option, '-iname') then
  begin
    Result := NewNode(NodeName);
    Result^.Text := TakeArgument(Option);
    Result^.IgnoreCase := Option[1] = 'i';
  end
  else if TextIsEqual(Option, '-path') or TextIsEqual(Option, '-ipath') or
          TextIsEqual(Option, '-wholename') then
  begin
    Result := NewNode(NodePath);
    Result^.Text := TakeArgument(Option);
    Result^.IgnoreCase := Option[1] = 'i';
  end
  else if TextIsEqual(Option, '-type') then
  begin
    Result := NewNode(NodeType);
    Text := TakeArgument(Option);
    if not (Text[0] in ['f', 'd', 'l', 'c', 'b', 'p']) or (Text[1] <> #0) then
      Fail(1, 'Unknown argument to -type: %s', [ArgumentText(Text)]);
    Result^.TypeLetter := Text[0];
  end
  else if TextIsEqual(Option, '-size') then
  begin
    Result := NewNode(NodeSize);
    ParseSize(TakeArgument(Option), Result);
  end
  else if TextIsEqual(Option, '-mtime') or TextIsEqual(Option, '-mmin') then
  begin
    if Option[2] = 't' then
      Result := NewNode(NodeModifiedDays)
    else
      Result := NewNode(NodeModifiedMinutes);
    ParseComparison(TakeArgument(Option), Result, Option);
  end
  else if TextIsEqual(Option, '-newer') then
  begin
    Result := NewNode(NodeNewer);
    Text := TakeArgument(Option);
    if GetFileInformation(Text, Information) <> ErrorNone then
      Fail(1, '`%s'': No such file or directory', [ArgumentText(Text)]);
    Result^.Time := Information.ModificationTime;
  end
  else if TextIsEqual(Option, '-empty') then
    Result := NewNode(NodeEmpty)
  else if TextIsEqual(Option, '-user') then
  begin
    Result := NewNode(NodeUser);
    Text := TakeArgument(Option);
    if not FindUserId(Text, Id) then
      Fail(1, '`%s'' is not the name of a known user', [ArgumentText(Text)]);
    Result^.Number := Id;
  end
  else if TextIsEqual(Option, '-group') then
  begin
    Result := NewNode(NodeGroup);
    Text := TakeArgument(Option);
    if not FindGroupId(Text, Id) then
      Fail(1, '`%s'' is not the name of an existing group', [ArgumentText(Text)]);
    Result^.Number := Id;
  end
  else if TextIsEqual(Option, '-perm') then
  begin
    Result := NewNode(NodePermissions);
    Text := TakeArgument(Option);
    Result^.PermissionMode := ' ';
    if (Text^ = '-') or (Text^ = '/') then
    begin
      Result^.PermissionMode := Text^;
      Inc(Text);
    end;
    if not ParseModeChange(Text, Change) then
      Fail(1, 'invalid mode `%s''', [ArgumentText(Text)]);
    Result^.Mode := ApplyModeChange(Change, 0, False);
  end
  else if TextIsEqual(Option, '-links') then
  begin
    Result := NewNode(NodeLinks);
    ParseComparison(TakeArgument(Option), Result, Option);
  end
  else if TextIsEqual(Option, '-true') then
    Result := NewNode(NodeTrue)
  else if TextIsEqual(Option, '-false') then
    Result := NewNode(NodeFalse)
  else if TextIsEqual(Option, '-print') then
  begin
    Result := NewNode(NodePrint);
    HasAction := True;
  end
  else if TextIsEqual(Option, '-print0') then
  begin
    Result := NewNode(NodePrintNull);
    HasAction := True;
  end
  else if TextIsEqual(Option, '-ls') then
  begin
    Result := NewNode(NodeList);
    HasAction := True;
  end
  else if TextIsEqual(Option, '-delete') then
  begin
    Result := NewNode(NodeDelete);
    HasAction := True;
    DepthFirst := True;
  end
  else if TextIsEqual(Option, '-prune') then
    Result := NewNode(NodePrune)
  else if TextIsEqual(Option, '-quit') then
    Result := NewNode(NodeQuit)
  else if TextIsEqual(Option, '-exec') then
  begin
    Result := NewNode(NodeExecute);
    HasAction := True;
    ParseExecute(Result);
  end
  else
  begin
    Fail(1, 'unknown predicate `%s''', [ArgumentText(Option)]);
    Result := nil;
  end;
end;

function AtExpressionEnd: Boolean;
begin
  Result := (Peek = nil) or PeekIs(')') or PeekIs('-o') or PeekIs('-or');
end;

function ParseAnd: PNode;
var
  Node: PNode;
begin
  Result := ParsePrimary();
  while not AtExpressionEnd do
  begin
    if PeekIs('-a') or PeekIs('-and') then
      Inc(Position);
    Node := NewNode(NodeAnd);
    Node^.Left := Result;
    Node^.Right := ParsePrimary();
    Result := Node;
  end;
end;

function ParseOr: PNode;
var
  Node: PNode;
begin
  Result := ParseAnd();
  while PeekIs('-o') or PeekIs('-or') do
  begin
    Inc(Position);
    Node := NewNode(NodeOr);
    Node^.Left := Result;
    Node^.Right := ParseAnd();
    Result := Node;
  end;
end;

{ --- Actions --------------------------------------------------------- }

{ Runs Words (with every "{}" inside a word replaced by Path). }
function RunCommand(Words: PPChar; WordCount: Integer; Extra: PPChar; ExtraCount: Integer): LongInt;
var
  ArgumentList: PPChar;
  Index: Integer;
  Options: TProcessOptions;
  Handle: Int64;
  Status: LongInt;
begin
  ArgumentList := PPChar(AllocateZeroedMemory(QWord(WordCount + ExtraCount + 1) * SizeOf(PChar)));
  for Index := 0 to WordCount - 1 do
    ArgumentList[Index] := Words[Index];
  for Index := 0 to ExtraCount - 1 do
    ArgumentList[WordCount + Index] := Extra[Index];
  DefaultProcessOptions(Options);
  FlushStandardStreams;
  Handle := StartCommand(ArgumentList, Options, Status);
  if Handle >= 0 then
    Status := WaitForProgram(Handle);
  FreeMemory(ArgumentList);
  Result := Status;
end;

{ Replaces every "{}" in Word with Path. }
function SubstitutePath(Word, Path: PChar): PChar;
var
  Builder: TTextBuilder;
  Index: PtrUInt;
begin
  BeginText(Builder);
  Index := 0;
  while Word[Index] <> #0 do
  begin
    if (Word[Index] = '{') and (Word[Index + 1] = '}') then
    begin
      AppendText(Builder, Path);
      Inc(Index, 2);
    end
    else
    begin
      AppendCharacter(Builder, Word[Index]);
      Inc(Index);
    end;
  end;
  Result := FinishText(Builder);
end;

function ExecuteForPath(Node: PNode; Path: PChar): Boolean;
var
  Words: PPChar;
  Index: Integer;
begin
  Words := PPChar(AllocateZeroedMemory(QWord(Node^.WordCount + 1) * SizeOf(PChar)));
  for Index := 0 to Node^.WordCount - 1 do
    Words[Index] := SubstitutePath(Node^.Words[Index], Path);
  Result := RunCommand(Words, Node^.WordCount, nil, 0) = 0;
  for Index := 0 to Node^.WordCount - 1 do
    FreeMemory(Words[Index]);
  FreeMemory(Words);
end;

procedure FlushBatch(Node: PNode);
begin
  if Node^.Batch.Count = 0 then
    Exit;
  if RunCommand(Node^.Words, Node^.WordCount, Node^.Batch.Items, Node^.Batch.Count) <> 0 then
    ExitStatus := 1;
  FreeLineList(Node^.Batch);
end;

procedure ListEntry(Path: PChar; const Information: TFileInformation);
var
  ModeText: array[0..15] of Char;
  TypeLetter: Char;
  DateTime: TDateTime;
  Owner: PChar;
  Group: PChar;
  NumberText: TNumberText;
  GroupText: TNumberText;
begin
  case Information.Kind of
    KindDirectory: TypeLetter := 'd';
    KindSymbolicLink: TypeLetter := 'l';
  else
    TypeLetter := '-';
  end;
  ModeText[0] := TypeLetter;
  FormatModeText(Information.Mode, @ModeText[1]);
  Owner := UserNameOf(Information.OwnerId);
  if Owner = nil then
    Owner := FormatDecimal(Information.OwnerId, NumberText);
  Group := GroupNameOf(Information.GroupId);
  if Group = nil then
    Group := FormatDecimal(Information.GroupId, GroupText);
  DecodeTime(Information.ModificationTime, DateTime);
  WriteFormatted(StandardOutput, '%9u %6u %s %3u %-8s %-8s %8u %s %2d %02d:%02d %s'#10, [
    ArgumentUnsigned(Information.NodeNumber), ArgumentUnsigned((Information.SizeInBytes + 1023) div 1024),
    ArgumentText(@ModeText[0]), ArgumentUnsigned(Information.LinkCount), ArgumentText(Owner),
    ArgumentText(Group), ArgumentUnsigned(Information.SizeInBytes), ArgumentText(MonthName(DateTime.Month)),
    ArgumentNumber(DateTime.Day), ArgumentNumber(DateTime.Hour), ArgumentNumber(DateTime.Minute),
    ArgumentText(Path)]);
end;

{ --- Evaluating ------------------------------------------------------ }

function DirectoryIsEmpty(Path: PChar): Boolean;
var
  Names: TLineList;
begin
  BeginLineList(Names);
  ListDirectory(Path, Names);
  Result := Names.Count = 0;
  FreeLineList(Names);
end;

function Evaluate(Node: PNode; Path: PChar; const Information: TFileInformation): Boolean;
var
  Base: PChar;
  Units: Int64;
  Age: Int64;
  Error: LongInt;
begin
  case Node^.Kind of
    NodeAnd: Result := Evaluate(Node^.Left, Path, Information) and Evaluate(Node^.Right, Path, Information);
    NodeOr: Result := Evaluate(Node^.Left, Path, Information) or Evaluate(Node^.Right, Path, Information);
    NodeNot: Result := not Evaluate(Node^.Left, Path, Information);
    NodeName:
      begin
        Base := BaseName(Path);
        Result := MatchWildcards(Node^.Text, Base, Node^.IgnoreCase);
        FreeMemory(Base);
      end;
    NodePath: Result := MatchWildcards(Node^.Text, Path, Node^.IgnoreCase);
    NodeType:
      case Node^.TypeLetter of
        'f': Result := Information.Kind = KindFile;
        'd': Result := Information.Kind = KindDirectory;
        'c': Result := Information.Kind = KindCharacterDevice;
        'b': Result := Information.Kind = KindBlockDevice;
        'p': Result := Information.Kind = KindFifo;
      else
        Result := Information.Kind = KindSymbolicLink;
      end;
    NodeSize:
      begin
        { Sizes are rounded up to whole units. }
        Units := (Int64(Information.SizeInBytes) + Node^.UnitSize - 1) div Node^.UnitSize;
        Result := Compare(Units, Node^.Number, Node^.Comparison);
      end;
    NodeModifiedDays:
      begin
        Age := (Now - Information.ModificationTime) div 86400;
        Result := Compare(Age, Node^.Number, Node^.Comparison);
      end;
    NodeModifiedMinutes:
      begin
        Age := (Now - Information.ModificationTime + 59) div 60;
        Result := Compare(Age, Node^.Number, Node^.Comparison);
      end;
    NodeNewer: Result := Information.ModificationTime > Node^.Time;
    NodeEmpty:
      if Information.Kind = KindDirectory then
        Result := DirectoryIsEmpty(Path)
      else
        Result := (Information.Kind = KindFile) and (Information.SizeInBytes = 0);
    NodeUser: Result := Information.OwnerId = LongWord(Node^.Number);
    NodeGroup: Result := Information.GroupId = LongWord(Node^.Number);
    NodePermissions:
      case Node^.PermissionMode of
        '-': Result := (Information.Mode and Node^.Mode) = Node^.Mode;
        '/': Result := (Node^.Mode = 0) or ((Information.Mode and Node^.Mode) <> 0);
      else
        Result := (Information.Mode and $FFF) = Node^.Mode;
      end;
    NodeLinks: Result := Compare(Information.LinkCount, Node^.Number, Node^.Comparison);
    NodeTrue: Result := True;
    NodeFalse: Result := False;
    NodePrint:
      begin
        WriteLine(StandardOutput, Path);
        Result := True;
      end;
    NodePrintNull:
      begin
        WriteText(StandardOutput, Path);
        WriteCharacter(StandardOutput, #0);
        Result := True;
      end;
    NodeList:
      begin
        ListEntry(Path, Information);
        Result := True;
      end;
    NodeDelete:
      begin
        Result := True;
        if TextIsEqual(Path, '.') then
          Exit;
        Error := RemovePath(Path);
        if Error <> ErrorNone then
        begin
          ReportError(Error, 'cannot delete `%s''', [ArgumentText(Path)]);
          ExitStatus := 1;
          Result := False;
        end;
      end;
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
      if Node^.Batched then
      begin
        AddLine(Node^.Batch, DuplicateText(Path));
        if Node^.Batch.Count >= MaximumBatch then
          FlushBatch(Node);
        Result := True;
      end
      else
        Result := ExecuteForPath(Node, Path);
  else
    Result := False;
  end;
end;

procedure Visit(Path: PChar; Depth: Int64);
var
  Information: TFileInformation;
  Error: LongInt;
  Names: TLineList;
  Index: Integer;
  Child: PChar;
  Descend: Boolean;
  Matched: Boolean;

  procedure EvaluateHere;
  begin
    if Depth < MinimumDepth then
      Exit;
    PruneRequested := False;
    Matched := Evaluate(Root, Path, Information);
    if Matched and not HasAction then
      WriteLine(StandardOutput, Path);
  end;

begin
  if Quitting then
    Exit;
  Error := GetLinkInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    ReportError(Error, '`%s''', [ArgumentText(Path)]);
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
    BeginLineList(Names);
    Error := ListDirectory(Path, Names);
    if Error <> ErrorNone then
    begin
      ReportError(Error, '`%s''', [ArgumentText(Path)]);
      ExitStatus := 1;
    end;
    for Index := 0 to Names.Count - 1 do
    begin
      Child := JoinPath(Path, Names.Items[Index]);
      Visit(Child, Depth + 1);
      FreeMemory(Child);
      if Quitting then
        Break;
    end;
    FreeLineList(Names);
  end;
  if DepthFirst and not Quitting then
    EvaluateHere;
end;

var
  FirstExpression: Integer;
  Index: Integer;
  Paths: TLineList;
begin
  ExitStatus := 0;
  MaximumDepth := -1;
  MinimumDepth := 0;
  Now := CurrentTime;
  Arguments := ArgumentValues + 1;
  ArgumentCountLeft := ArgumentTotal - 1;
  if (ArgumentCountLeft = 1) and TextIsEqual(Arguments[0], '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;

  { Paths come first, up to the first argument that starts an expression. }
  BeginLineList(Paths);
  FirstExpression := 0;
  while (FirstExpression < ArgumentCountLeft) and (Arguments[FirstExpression][0] <> '-') and
        not TextIsEqual(Arguments[FirstExpression], '(') and not TextIsEqual(Arguments[FirstExpression], '!') do
  begin
    AddLine(Paths, Arguments[FirstExpression]);
    Inc(FirstExpression);
  end;
  if Paths.Count = 0 then
    AddLine(Paths, '.');

  Position := FirstExpression;
  if Position < ArgumentCountLeft then
  begin
    Root := ParseOr();
    if Position < ArgumentCountLeft then
      Fail(1, 'unexpected `%s''', [ArgumentText(Arguments[Position])]);
  end
  else
    Root := NewNode(NodeTrue);

  for Index := 0 to Paths.Count - 1 do
  begin
    Visit(Paths.Items[Index], 0);
    if Quitting then
      Break;
  end;
  for Index := 0 to BatchNodeCount - 1 do
    FlushBatch(BatchNodes[Index]);
  Halt(ExitStatus);
end.
