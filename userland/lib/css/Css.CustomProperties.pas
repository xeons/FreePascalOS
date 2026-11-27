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
  Custom properties (CSS Custom Properties for Cascading Variables
  Level 1 and 2): the computed set an element has, and var() and env()
  substitution.

  A set is immutable once made and reference counted; an element that
  declares no custom property shares its parent's set. Values are token
  lists (substituted already: a set never holds a var()).

  Pages declare hundreds of variables on the root and a few more here
  and there below it, so a set made for an element that declares some
  does not copy its parent's: it is layered over a flat set (the
  parent's, or the one the parent is layered over) and holds only what
  differs from it, a removed name as a tombstone. When the differences
  grow past LayerLimit the set is flattened, and the sets below layer
  over it in turn. A lookup is then at most two binary searches, and
  making a set costs the differences, not the whole set.
}
unit Css.CustomProperties;

{$mode objfpc}
{$H+}

interface

uses
  Css.Atoms, Css.Tokens;

type
  TCssCustomProperties = class
  private
    FReferences: LongInt;
    { The flat set this one is layered over (nil: this set is flat). }
    FBase: TCssCustomProperties;
    { Sorted by name: all the entries of a flat set, the differences
      from FBase of a layered one. }
    FNames: array of TCssAtom;
    FValues: array of TCssTokenArray;
    FCount: Integer;
    function Search(Name: TCssAtom; out Index: Integer): Boolean;
    procedure InsertAt(Index: Integer; Name: TCssAtom; const Tokens: TCssTokenArray);
    procedure DeleteAt(Index: Integer);
    procedure Flatten;
    function SameEntries(Other: TCssCustomProperties): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { A modifiable set with Parent's entries (none for nil), to build a
      child's set; Finish it when done. }
    class function Over(Parent: TCssCustomProperties): TCssCustomProperties;
    { Ends building a set made Over(Parent): Parent itself (a new
      reference, Self released) when nothing differs from it, else Self,
      flattened when its differences grew too many. nil for an empty
      set over nil. }
    function Finish(Parent: TCssCustomProperties): TCssCustomProperties;
    function AddRef: TCssCustomProperties;
    procedure Release;
    function Find(Name: TCssAtom; out Tokens: TCssTokenArray): Boolean;
    procedure Put(Name: TCssAtom; const Tokens: TCssTokenArray);
    procedure Remove(Name: TCssAtom);
    { The number of custom properties in the set. }
    function Count: Integer;
    function Equals(Other: TCssCustomProperties): Boolean; reintroduce;
    function Bytes: PtrUInt;
  end;

  { Finds the value of a custom property while substituting; False if
    it has none (or is invalid). The style resolver supplies this to
    resolve an element's own custom properties in dependency order. }
  TCssVariableLookup = function(Name: TCssAtom; out Tokens: TCssTokenArray; Data: Pointer): Boolean;

{ Replaces every var() and env() in Tokens. False when a reference
  cannot be resolved and has no fallback (invalid at computed-value
  time). }
function SubstituteVariables(const Tokens: TCssTokenArray; Lookup: TCssVariableLookup; Data: Pointer;
  out Output: TCssTokenArray): Boolean;
{ The value of env(Name), False for unknown names. Hosts can set them. }
function EnvironmentVariable(const Name: string; out Tokens: TCssTokenArray): Boolean;
procedure SetEnvironmentVariable(const Name, Value: string);
{ Whether a token range has var() or env() in it (custom property values). }
function HasVariableReference(const Tokens: TCssTokenArray): Boolean;

implementation

uses
  SysUtils, Css.Tokenizer;

const
  { The most differences a layered set keeps before it is flattened. }
  LayerLimit = 32;

var
  { The value of a layered set's tombstones (compared by pointer). }
  RemovedValue: TCssTokenArray;

function IsRemoved(const Tokens: TCssTokenArray): Boolean; inline;
begin
  Result := Pointer(Tokens) = Pointer(RemovedValue);
end;

constructor TCssCustomProperties.Create;
begin
  inherited Create;
  FReferences := 1;
end;

destructor TCssCustomProperties.Destroy;
begin
  FBase.Release;
  inherited Destroy;
end;

class function TCssCustomProperties.Over(Parent: TCssCustomProperties): TCssCustomProperties;
var
  Index: Integer;
begin
  Result := TCssCustomProperties.Create;
  if Parent = nil then
    Exit;
  if Parent.FBase = nil then
  begin
    Result.FBase := Parent.AddRef;
    Exit;
  end;
  { Over the same flat set as the parent, starting with its differences. }
  Result.FBase := Parent.FBase.AddRef;
  SetLength(Result.FNames, Parent.FCount);
  SetLength(Result.FValues, Parent.FCount);
  for Index := 0 to Parent.FCount - 1 do
  begin
    Result.FNames[Index] := Parent.FNames[Index];
    Result.FValues[Index] := Parent.FValues[Index];
  end;
  Result.FCount := Parent.FCount;
end;

{ Whether Self's own entries are Other's, by pointer. }
function TCssCustomProperties.SameEntries(Other: TCssCustomProperties): Boolean;
var
  Index: Integer;
begin
  if FCount <> Other.FCount then
    Exit(False);
  for Index := 0 to FCount - 1 do
    if (FNames[Index] <> Other.FNames[Index]) or (Pointer(FValues[Index]) <> Pointer(Other.FValues[Index])) then
      Exit(False);
  Result := True;
end;

function TCssCustomProperties.Finish(Parent: TCssCustomProperties): TCssCustomProperties;
begin
  if Parent = nil then
  begin
    if FCount = 0 then
    begin
      Release;
      Exit(nil);
    end;
    Exit(Self);
  end;
  if ((Parent.FBase = nil) and (FBase = Parent) and (FCount = 0)) or
    ((Parent.FBase <> nil) and (FBase = Parent.FBase) and SameEntries(Parent)) then
  begin
    Release;
    Exit(Parent.AddRef);
  end;
  if FCount > LayerLimit then
    Flatten;
  Result := Self;
end;

{ Merges the differences into a copy of the base: the set becomes flat. }
procedure TCssCustomProperties.Flatten;
var
  Names: array of TCssAtom;
  Values: array of TCssTokenArray;
  Merged, BaseIndex, OwnIndex: Integer;
  Base: TCssCustomProperties;

  procedure Add(Name: TCssAtom; const Tokens: TCssTokenArray);
  begin
    if IsRemoved(Tokens) then
      Exit;
    Names[Merged] := Name;
    Values[Merged] := Tokens;
    Inc(Merged);
  end;

begin
  Base := FBase;
  if Base = nil then
    Exit;
  Names := nil;
  Values := nil;
  SetLength(Names, Base.FCount + FCount);
  SetLength(Values, Base.FCount + FCount);
  Merged := 0;
  BaseIndex := 0;
  OwnIndex := 0;
  while (BaseIndex < Base.FCount) or (OwnIndex < FCount) do
    if (OwnIndex >= FCount) or ((BaseIndex < Base.FCount) and (Base.FNames[BaseIndex] < FNames[OwnIndex])) then
    begin
      Add(Base.FNames[BaseIndex], Base.FValues[BaseIndex]);
      Inc(BaseIndex);
    end
    else
    begin
      if (BaseIndex < Base.FCount) and (Base.FNames[BaseIndex] = FNames[OwnIndex]) then
        Inc(BaseIndex);
      Add(FNames[OwnIndex], FValues[OwnIndex]);
      Inc(OwnIndex);
    end;
  FNames := Names;
  FValues := Values;
  FCount := Merged;
  FBase := nil;
  Base.Release;
end;

function TCssCustomProperties.AddRef: TCssCustomProperties;
begin
  if Self <> nil then
    InterlockedIncrement(FReferences);
  Result := Self;
end;

procedure TCssCustomProperties.Release;
begin
  if Self = nil then
    Exit;
  if InterlockedDecrement(FReferences) = 0 then
    Free;
end;

function TCssCustomProperties.Search(Name: TCssAtom; out Index: Integer): Boolean;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := FCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if FNames[Middle] = Name then
    begin
      Index := Middle;
      Exit(True);
    end;
    if FNames[Middle] < Name then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Index := Low;
  Result := False;
end;

{ The entries move as raw memory: a value's reference moves with it, so
  no count changes (the slot left behind is cleared without a release). }
procedure TCssCustomProperties.InsertAt(Index: Integer; Name: TCssAtom; const Tokens: TCssTokenArray);
begin
  if FCount >= Length(FNames) then
  begin
    SetLength(FNames, FCount * 2 + 4);
    SetLength(FValues, Length(FNames));
  end;
  if Index < FCount then
  begin
    Move(FNames[Index], FNames[Index + 1], (FCount - Index) * SizeOf(TCssAtom));
    Move(FValues[Index], FValues[Index + 1], (FCount - Index) * SizeOf(Pointer));
    Pointer(FValues[Index]) := nil;
  end;
  FNames[Index] := Name;
  FValues[Index] := Tokens;
  Inc(FCount);
end;

procedure TCssCustomProperties.DeleteAt(Index: Integer);
begin
  FValues[Index] := nil;
  if Index < FCount - 1 then
  begin
    Move(FNames[Index + 1], FNames[Index], (FCount - Index - 1) * SizeOf(TCssAtom));
    Move(FValues[Index + 1], FValues[Index], (FCount - Index - 1) * SizeOf(Pointer));
    Pointer(FValues[FCount - 1]) := nil;
  end;
  Dec(FCount);
end;

function TCssCustomProperties.Find(Name: TCssAtom; out Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  Tokens := nil;
  if Self = nil then
    Exit(False);
  if Search(Name, Index) then
  begin
    if IsRemoved(FValues[Index]) then
      Exit(False);
    Tokens := FValues[Index];
    Exit(True);
  end;
  Result := FBase.Find(Name, Tokens);
end;

procedure TCssCustomProperties.Put(Name: TCssAtom; const Tokens: TCssTokenArray);
var
  Index: Integer;
  Found: Boolean;
  BaseTokens: TCssTokenArray;
begin
  Found := Search(Name, Index);
  { The base's own value is no difference to keep (so that a set equal
    to its parent's is seen to be). }
  if (FBase <> nil) and FBase.Find(Name, BaseTokens) and (Pointer(BaseTokens) = Pointer(Tokens)) then
  begin
    if Found then
      DeleteAt(Index);
    Exit;
  end;
  if Found then
    FValues[Index] := Tokens
  else
    InsertAt(Index, Name, Tokens);
end;

procedure TCssCustomProperties.Remove(Name: TCssAtom);
var
  Index: Integer;
  Found: Boolean;
  Tokens: TCssTokenArray;
begin
  Found := Search(Name, Index);
  if FBase.Find(Name, Tokens) then
  begin
    { The base has it: a tombstone hides it. }
    if Found then
      FValues[Index] := RemovedValue
    else
      InsertAt(Index, Name, RemovedValue);
  end
  else if Found then
    DeleteAt(Index);
end;

type
  { Walks a set's entries in name order, through its layer. }
  TEntryCursor = record
    Properties: TCssCustomProperties;
    OwnIndex, BaseIndex: Integer;
    Name: TCssAtom;
    { The entry's TCssTokenArray, not counted. }
    Value: Pointer;
  end;

procedure StartCursor(out Cursor: TEntryCursor; Properties: TCssCustomProperties);
begin
  Cursor.Properties := Properties;
  Cursor.OwnIndex := 0;
  Cursor.BaseIndex := 0;
  Cursor.Name := NoAtom;
  Cursor.Value := nil;
end;

{ Moves to the next entry (an own entry hides the base's of its name, a
  tombstone hides both); False at the end. }
function NextEntry(var Cursor: TEntryCursor): Boolean;
var
  Own, Base: TCssCustomProperties;
  OwnLeft, BaseLeft: Boolean;
begin
  Own := Cursor.Properties;
  if Own = nil then
    Exit(False);
  Base := Own.FBase;
  repeat
    OwnLeft := Cursor.OwnIndex < Own.FCount;
    BaseLeft := (Base <> nil) and (Cursor.BaseIndex < Base.FCount);
    if not OwnLeft and not BaseLeft then
      Exit(False);
    if OwnLeft and (not BaseLeft or (Own.FNames[Cursor.OwnIndex] <= Base.FNames[Cursor.BaseIndex])) then
    begin
      if BaseLeft and (Base.FNames[Cursor.BaseIndex] = Own.FNames[Cursor.OwnIndex]) then
        Inc(Cursor.BaseIndex);
      Cursor.Name := Own.FNames[Cursor.OwnIndex];
      Cursor.Value := Pointer(Own.FValues[Cursor.OwnIndex]);
      Inc(Cursor.OwnIndex);
    end
    else
    begin
      Cursor.Name := Base.FNames[Cursor.BaseIndex];
      Cursor.Value := Pointer(Base.FValues[Cursor.BaseIndex]);
      Inc(Cursor.BaseIndex);
    end;
  until Cursor.Value <> Pointer(RemovedValue);
  Result := True;
end;

function TCssCustomProperties.Count: Integer;
var
  Cursor: TEntryCursor;
begin
  if Self = nil then
    Exit(0);
  if FBase = nil then
    Exit(FCount);
  Result := 0;
  StartCursor(Cursor, Self);
  while NextEntry(Cursor) do
    Inc(Result);
end;

function SameTokens(const A, B: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  if Pointer(A) = Pointer(B) then
    Exit(True);
  if Length(A) <> Length(B) then
    Exit(False);
  for Index := 0 to High(A) do
    if (A[Index].Kind <> B[Index].Kind) or (A[Index].Text <> B[Index].Text) or
      (A[Index].Number <> B[Index].Number) then
      Exit(False);
  Result := True;
end;

{ Whether two sets layered over the same base differ in nothing. }
function SameDifferences(Mine, Theirs: TCssCustomProperties): Boolean;
var
  Index: Integer;
begin
  if (Mine.FBase <> Theirs.FBase) or (Mine.FCount <> Theirs.FCount) then
    Exit(False);
  for Index := 0 to Mine.FCount - 1 do
    if (Mine.FNames[Index] <> Theirs.FNames[Index]) or
      (IsRemoved(Mine.FValues[Index]) <> IsRemoved(Theirs.FValues[Index])) or
      not SameTokens(Mine.FValues[Index], Theirs.FValues[Index]) then
      Exit(False);
  Result := True;
end;

function TCssCustomProperties.Equals(Other: TCssCustomProperties): Boolean;
var
  MineCursor, TheirCursor: TEntryCursor;
  MineMore, TheirMore: Boolean;
begin
  if Self = Other then
    Exit(True);
  if (Self <> nil) and (Other <> nil) then
  begin
    if SameDifferences(Self, Other) then
      Exit(True);
    { Flat sets have no tombstones: their entries are the whole answer. }
    if (FBase = nil) and (Other.FBase = nil) then
      Exit(False);
  end;
  StartCursor(MineCursor, Self);
  StartCursor(TheirCursor, Other);
  repeat
    MineMore := NextEntry(MineCursor);
    TheirMore := NextEntry(TheirCursor);
    if MineMore <> TheirMore then
      Exit(False);
    if not MineMore then
      Exit(True);
    if (MineCursor.Name <> TheirCursor.Name) or
      not SameTokens(TCssTokenArray(MineCursor.Value), TCssTokenArray(TheirCursor.Value)) then
      Exit(False);
  until False;
end;

function TCssCustomProperties.Bytes: PtrUInt;
begin
  if Self = nil then
    Exit(0);
  Result := InstanceSize + PtrUInt(Length(FNames)) * (SizeOf(TCssAtom) + SizeOf(Pointer));
end;

{ ---- environment variables ---- }

var
  EnvironmentNames: array of string;
  EnvironmentValues: array of TCssTokenArray;

procedure SetEnvironmentVariable(const Name, Value: string);
var
  Index: Integer;
begin
  for Index := 0 to High(EnvironmentNames) do
    if EnvironmentNames[Index] = Name then
    begin
      EnvironmentValues[Index] := TokenizeCss(Value);
      Exit;
    end;
  SetLength(EnvironmentNames, Length(EnvironmentNames) + 1);
  SetLength(EnvironmentValues, Length(EnvironmentValues) + 1);
  EnvironmentNames[High(EnvironmentNames)] := Name;
  EnvironmentValues[High(EnvironmentValues)] := TokenizeCss(Value);
end;

function EnvironmentVariable(const Name: string; out Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  Tokens := nil;
  for Index := 0 to High(EnvironmentNames) do
    if EnvironmentNames[Index] = Name then
    begin
      Tokens := EnvironmentValues[Index];
      Exit(True);
    end;
  Result := False;
end;

function HasVariableReference(const Tokens: TCssTokenArray): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    if (Tokens[Index].Kind = tkFunction) and (AsciiSameText(Tokens[Index].Text, 'var') or
      AsciiSameText(Tokens[Index].Text, 'env')) then
      Exit(True);
  Result := False;
end;

{ ---- substitution ---- }

type
  TOutput = record
    Tokens: TCssTokenArray;
    Count: Integer;
  end;

procedure Append(var Output: TOutput; const Token: TCssToken);
begin
  if Output.Count >= Length(Output.Tokens) then
    SetLength(Output.Tokens, Output.Count * 2 + 16);
  Output.Tokens[Output.Count] := Token;
  Inc(Output.Count);
end;

{ Appends a token list (without its EOF). }
procedure AppendAll(var Output: TOutput; const Tokens: TCssTokenArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Tokens) do
    if Tokens[Index].Kind <> tkEof then
      Append(Output, Tokens[Index]);
end;

function SubstituteRange(const Tokens: TCssTokenArray; First, Stop: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean; forward;

{ var(--name [, fallback]?) or env(name [, fallback]?) at Index. }
function SubstituteReference(const Tokens: TCssTokenArray; Index: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean;
var
  Position, Stop: Integer;
  IsEnvironment, HasFallback: Boolean;
  Name: string;
  Value: TCssTokenArray;
begin
  Result := False;
  if Depth > 64 then
    Exit;
  IsEnvironment := AsciiSameText(Tokens[Index].Text, 'env');
  Stop := Tokens[Index].Match;
  if (Stop < 0) or (Stop > High(Tokens)) then
    Stop := High(Tokens);
  Position := Index + 1;
  while (Position < Stop) and (Tokens[Position].Kind = tkWhitespace) do
    Inc(Position);
  if (Position >= Stop) or (Tokens[Position].Kind <> tkIdent) then
    Exit;
  Name := Tokens[Position].Text;
  if not IsEnvironment and not ((Length(Name) > 2) and (Name[1] = '-') and (Name[2] = '-')) then
    Exit;
  Inc(Position);
  while (Position < Stop) and (Tokens[Position].Kind = tkWhitespace) do
    Inc(Position);
  HasFallback := False;
  if Position < Stop then
  begin
    if Tokens[Position].Kind <> tkComma then
      Exit;
    HasFallback := True;
    Inc(Position);
  end;
  if IsEnvironment then
  begin
    if EnvironmentVariable(AsciiLowercase(Name), Value) then
    begin
      AppendAll(Output, Value);
      Exit(True);
    end;
  end
  else if Lookup(InternAtom(Name), Value, Data) then
  begin
    AppendAll(Output, Value);
    Exit(True);
  end;
  if HasFallback then
    Result := SubstituteRange(Tokens, Position, Stop, Lookup, Data, Output, Depth + 1);
end;

function SubstituteRange(const Tokens: TCssTokenArray; First, Stop: Integer; Lookup: TCssVariableLookup;
  Data: Pointer; var Output: TOutput; Depth: Integer): Boolean;
var
  Index, Last: Integer;
  Token: PCssToken;
begin
  Result := True;
  Index := First;
  while Index < Stop do
  begin
    Token := @Tokens[Index];
    if Token^.Kind = tkEof then
      Break;
    if (Token^.Kind = tkFunction) and (AsciiSameText(Token^.Text, 'var') or AsciiSameText(Token^.Text, 'env')) then
    begin
      if not SubstituteReference(Tokens, Index, Lookup, Data, Output, Depth) then
        Exit(False);
      Last := Token^.Match;
      if (Last < 0) or (Last >= Stop) then
        Index := Stop
      else
        Index := Last + 1;
      Continue;
    end;
    Append(Output, Token^);
    Inc(Index);
  end;
end;

function SubstituteVariables(const Tokens: TCssTokenArray; Lookup: TCssVariableLookup; Data: Pointer;
  out Output: TCssTokenArray): Boolean;
var
  Buffer: TOutput;
  Eof: TCssToken;
begin
  Output := nil;
  Buffer.Tokens := nil;
  Buffer.Count := 0;
  Result := SubstituteRange(Tokens, 0, Length(Tokens), Lookup, Data, Buffer, 0);
  if not Result then
    Exit;
  Eof := EofToken;
  Append(Buffer, Eof);
  SetLength(Buffer.Tokens, Buffer.Count);
  MatchBlocks(Buffer.Tokens);
  Output := Buffer.Tokens;
end;

procedure SetDefaultEnvironment;
begin
  SetEnvironmentVariable('safe-area-inset-top', '0px');
  SetEnvironmentVariable('safe-area-inset-right', '0px');
  SetEnvironmentVariable('safe-area-inset-bottom', '0px');
  SetEnvironmentVariable('safe-area-inset-left', '0px');
  SetEnvironmentVariable('safe-area-max-inset-top', '0px');
  SetEnvironmentVariable('safe-area-max-inset-right', '0px');
  SetEnvironmentVariable('safe-area-max-inset-bottom', '0px');
  SetEnvironmentVariable('safe-area-max-inset-left', '0px');
  SetEnvironmentVariable('titlebar-area-x', '0px');
  SetEnvironmentVariable('titlebar-area-y', '0px');
  SetEnvironmentVariable('titlebar-area-width', '0px');
  SetEnvironmentVariable('titlebar-area-height', '0px');
  SetEnvironmentVariable('keyboard-inset-top', '0px');
  SetEnvironmentVariable('keyboard-inset-right', '0px');
  SetEnvironmentVariable('keyboard-inset-bottom', '0px');
  SetEnvironmentVariable('keyboard-inset-left', '0px');
  SetEnvironmentVariable('keyboard-inset-width', '0px');
  SetEnvironmentVariable('keyboard-inset-height', '0px');
  SetEnvironmentVariable('scrollbar-inline-size', '0px');
end;

initialization
  SetLength(RemovedValue, 1);
  RemovedValue[0] := EofToken;
  SetDefaultEnvironment;
end.
