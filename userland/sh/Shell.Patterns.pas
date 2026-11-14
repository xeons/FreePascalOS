{
  File name patterns ("globs").

    *        any run of characters
    ?        any one character
    [abc]    one of the listed characters; ranges such as [a-z];
             [!abc] or [^abc] for any character not listed
    \c       the character c itself

  ExpandPattern matches the last component of a path against the
  entries of its directory, e.g. "src/*.pas". Names starting with a dot
  only match a pattern that starts with a dot.
}
unit Shell.Patterns;

{$mode objfpc}
{$pointermath on}

interface

function HasPatternCharacters(Pattern: PChar): Boolean;
function MatchPattern(Pattern, Text: PChar): Boolean;
{ Removes the backslash escapes from a pattern (new heap string). }
function UnescapePattern(Pattern: PChar): PChar;

type
  TMatchCallback = procedure(Path: PChar; Context: Pointer);

{ Calls Callback for every matching path, in sorted order. Returns the
  number of matches. }
function ExpandPattern(Pattern: PChar; Callback: TMatchCallback; Context: Pointer): Integer;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Files,
  Sys.Memory,
  Sys.Text,
  Util.Sorting;

function HasPatternCharacters(Pattern: PChar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while Pattern[Index] <> #0 do
  begin
    case Pattern[Index] of
      '\':
        if Pattern[Index + 1] <> #0 then
          Inc(Index);
      '*', '?', '[':
        Exit(True);
    end;
    Inc(Index);
  end;
  Result := False;
end;

{ Matches a bracket expression at Pattern (just after '['). Returns the
  position after the closing ']' or nil if the expression is not closed. }
function MatchBracket(Pattern: PChar; Character: Char; out Matched: Boolean): PChar;
var
  Negate: Boolean;
  First: Boolean;
  Low: Char;
  High: Char;
begin
  Matched := False;
  Negate := (Pattern^ = '!') or (Pattern^ = '^');
  if Negate then
    Inc(Pattern);
  First := True;
  while (Pattern^ <> #0) and ((Pattern^ <> ']') or First) do
  begin
    First := False;
    Low := Pattern^;
    if (Low = '\') and (Pattern[1] <> #0) then
    begin
      Inc(Pattern);
      Low := Pattern^;
    end;
    High := Low;
    if (Pattern[1] = '-') and (Pattern[2] <> ']') and (Pattern[2] <> #0) then
    begin
      High := Pattern[2];
      Inc(Pattern, 2);
    end;
    if (Character >= Low) and (Character <= High) then
      Matched := True;
    Inc(Pattern);
  end;
  if Pattern^ <> ']' then
    Exit(nil);
  if Negate then
    Matched := not Matched;
  Result := Pattern + 1;
end;

function MatchPattern(Pattern, Text: PChar): Boolean;
var
  Matched: Boolean;
  AfterBracket: PChar;
begin
  while Pattern^ <> #0 do
  begin
    case Pattern^ of
      '*':
        begin
          while Pattern^ = '*' do
            Inc(Pattern);
          if Pattern^ = #0 then
            Exit(True);
          while Text^ <> #0 do
          begin
            if MatchPattern(Pattern, Text) then
              Exit(True);
            Inc(Text);
          end;
          Exit(False);
        end;
      '?':
        begin
          if Text^ = #0 then
            Exit(False);
          Inc(Pattern);
          Inc(Text);
        end;
      '[':
        begin
          if Text^ = #0 then
            Exit(False);
          AfterBracket := MatchBracket(Pattern + 1, Text^, Matched);
          if AfterBracket = nil then
          begin
            { An unclosed '[' is an ordinary character. }
            if Text^ <> '[' then
              Exit(False);
            Inc(Pattern);
          end
          else
          begin
            if not Matched then
              Exit(False);
            Pattern := AfterBracket;
          end;
          Inc(Text);
        end;
    else
      begin
        if (Pattern^ = '\') and (Pattern[1] <> #0) then
          Inc(Pattern);
        if Pattern^ <> Text^ then
          Exit(False);
        Inc(Pattern);
        Inc(Text);
      end;
    end;
  end;
  Result := Text^ = #0;
end;

function UnescapePattern(Pattern: PChar): PChar;
var
  Builder: TTextBuilder;
  Index: Integer;
begin
  BeginText(Builder);
  Index := 0;
  while Pattern[Index] <> #0 do
  begin
    if (Pattern[Index] = '\') and (Pattern[Index + 1] <> #0) then
      Inc(Index);
    AppendCharacter(Builder, Pattern[Index]);
    Inc(Index);
  end;
  Result := FinishText(Builder);
end;

function CompareNames(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := CompareText(PChar(First), PChar(Second));
end;

function ExpandPattern(Pattern: PChar; Callback: TMatchCallback; Context: Pointer): Integer;
var
  LastSlash: PtrInt;
  DirectoryPattern: PChar;
  Directory: PChar;
  NamePattern: PChar;
  Prefix: PChar;
  Handle: Int64;
  Entry: TDirectoryEntry;
  Matches: PPChar;
  MatchCount: Integer;
  Capacity: Integer;
  Builder: TTextBuilder;
  Index: Integer;
begin
  Result := 0;
  LastSlash := FindLastCharacter(Pattern, '/');
  if LastSlash >= 0 then
  begin
    DirectoryPattern := PChar(AllocateMemory(LastSlash + 2));
    CopyText(DirectoryPattern, Pattern, PtrUInt(LastSlash) + 2);
    NamePattern := Pattern + LastSlash + 1;
    Prefix := UnescapePattern(DirectoryPattern);
    FreeMemory(DirectoryPattern);
    if LastSlash = 0 then
      Directory := DuplicateText('/')
    else
    begin
      Directory := DuplicateText(Prefix);
      Directory[TextLength(Directory) - 1] := #0;
    end;
  end
  else
  begin
    NamePattern := Pattern;
    Prefix := DuplicateText('');
    Directory := DuplicateText('.');
  end;

  { Only the last component may contain pattern characters. }
  if HasPatternCharacters(Directory) then
  begin
    FreeMemory(Prefix);
    FreeMemory(Directory);
    Exit;
  end;

  Handle := OpenFile(Directory, OpenRead);
  FreeMemory(Directory);
  if Handle < 0 then
  begin
    FreeMemory(Prefix);
    Exit;
  end;

  Matches := nil;
  MatchCount := 0;
  Capacity := 0;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    if TextIsEqual(@Entry.Name[0], '.') or TextIsEqual(@Entry.Name[0], '..') then
      Continue;
    if (Entry.Name[0] = '.') and (NamePattern[0] <> '.') then
      Continue;
    if not MatchPattern(NamePattern, @Entry.Name[0]) then
      Continue;
    if MatchCount = Capacity then
    begin
      Capacity := Capacity * 2 + 16;
      Matches := PPChar(ReallocateMemory(Matches, QWord(Capacity) * SizeOf(PChar)));
    end;
    BeginText(Builder);
    AppendText(Builder, Prefix);
    AppendText(Builder, @Entry.Name[0]);
    Matches[MatchCount] := FinishText(Builder);
    Inc(MatchCount);
  end;
  CloseFile(Handle);
  FreeMemory(Prefix);

  SortPointers(PPointer(Matches), MatchCount, @CompareNames, nil);
  for Index := 0 to MatchCount - 1 do
  begin
    Callback(Matches[Index], Context);
    FreeMemory(Matches[Index]);
  end;
  FreeMemory(Matches);
  Result := MatchCount;
end;

end.
