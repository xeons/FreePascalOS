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
  Free Pascal's decorated symbol names made readable, as
  scripts/symbolize.py writes them: "P$CORETEST_$$_CRASHONPURPOSE" is
  CORETEST.CRASHONPURPOSE, "SYSUTILS_$$_FORMAT$ANSISTRING$array_of_const
  $$ANSISTRING" SYSUTILS.FORMAT, a nested routine OUTER.INNER,
  "INIT$_$SYSUTILS" SYSUTILS.initialization. Other names (C routines)
  stay as they are. Pure code: the host test runs it too.
}
unit Processes.SymbolNames;

{$mode objfpc}
{$pointermath on}

interface

{ Writes Symbol readable into Destination (Capacity bytes with the
  terminating zero, cut short if need be). }
procedure ReadableSymbolName(Symbol: PChar; Destination: PChar; Capacity: LongWord);

implementation

type
  TNameWriter = record
    Destination: PChar;
    Capacity: LongWord;
    Used: LongWord;
  end;

procedure Append(var Writer: TNameWriter; Text: PChar; Count: LongWord);
var
  Index: LongWord;
begin
  Index := 0;
  while (Index < Count) and (Writer.Used + 1 < Writer.Capacity) do
  begin
    Writer.Destination[Writer.Used] := Text[Index];
    Inc(Writer.Used);
    Inc(Index);
  end;
  Writer.Destination[Writer.Used] := #0;
end;

function TextLengthOf(Text: PChar): LongWord;
begin
  Result := 0;
  while Text[Result] <> #0 do
    Inc(Result);
end;

{ Where Token starts in Text[From, Limit), or Limit. }
function FindToken(Text: PChar; From, Limit: LongWord; Token: PChar): LongWord;
var
  TokenLength: LongWord;
  Index: LongWord;
begin
  TokenLength := TextLengthOf(Token);
  Result := From;
  while Result + TokenLength <= Limit do
  begin
    Index := 0;
    while (Index < TokenLength) and (Text[Result + Index] = Token[Index]) do
      Inc(Index);
    if Index = TokenLength then
      Exit;
    Inc(Result);
  end;
  Result := Limit;
end;

function StartsWith(Text, Prefix: PChar): Boolean;
var
  Index: LongWord;
begin
  Index := 0;
  while (Prefix[Index] <> #0) and (Text[Index] = Prefix[Index]) do
    Inc(Index);
  Result := Prefix[Index] = #0;
end;

{ Appends a routine piece without its parameter list, '.' first. }
procedure AppendPlainPiece(var Writer: TNameWriter; Text: PChar; From, Limit: LongWord);
var
  Finish: LongWord;
begin
  Finish := FindToken(Text, From, Limit, '$');
  { Trailing underscores go, unless that leaves nothing. }
  while (Finish > From + 1) and (Text[Finish - 1] = '_') do
    Dec(Finish);
  if Finish = From then
    Exit;
  Append(Writer, '.', 1);
  Append(Writer, Text + From, Finish - From);
end;

{ The pieces of Text[From, Limit) between "$_$" separators; the first
  is the unit when IsHead. }
procedure AppendPieces(var Writer: TNameWriter; Text: PChar; From, Limit: LongWord; IsHead: Boolean);
var
  Separator: LongWord;
begin
  repeat
    Separator := FindToken(Text, From, Limit, '$_$');
    if IsHead then
    begin
      if StartsWith(Text + From, 'P$') and (Separator >= From + 2) then
        From := From + 2;
      Append(Writer, Text + From, Separator - From);
      IsHead := False;
    end
    else
      AppendPlainPiece(Writer, Text, From, Separator);
    From := Separator + 3;
  until Separator >= Limit;
end;

procedure ReadableSymbolName(Symbol: PChar; Destination: PChar; Capacity: LongWord);
var
  Writer: TNameWriter;
  Length: LongWord;
  From: LongWord;
  Separator: LongWord;
  IsHead: Boolean;
begin
  if Capacity = 0 then
    Exit;
  Writer.Destination := Destination;
  Writer.Capacity := Capacity;
  Writer.Used := 0;
  Destination[0] := #0;
  Length := TextLengthOf(Symbol);
  if StartsWith(Symbol, 'INIT$_$') then
  begin
    Append(Writer, Symbol + 7, Length - 7);
    Append(Writer, '.initialization', 15);
    Exit;
  end;
  if StartsWith(Symbol, 'FINALIZE$_$') then
  begin
    Append(Writer, Symbol + 11, Length - 11);
    Append(Writer, '.finalization', 13);
    Exit;
  end;
  if FindToken(Symbol, 0, Length, '_$$_') = Length then
  begin
    Append(Writer, Symbol, Length);
    Exit;
  end;
  From := 0;
  IsHead := True;
  repeat
    Separator := FindToken(Symbol, From, Length, '_$$_');
    AppendPieces(Writer, Symbol, From, Separator, IsHead);
    IsHead := False;
    From := Separator + 4;
  until Separator >= Length;
end;

end.
