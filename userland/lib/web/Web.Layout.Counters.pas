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
  CSS counters and generated text.

  One walk over the box tree in tree order applies counter-reset,
  counter-set and counter-increment (and the list-item counter's own
  increment on list items), with CSS Lists 3 scoping: a counter made by
  an element lives for its following siblings and their descendants.
  On the way it writes the text of the generated content boxes:
  ::before and ::after content (strings, counter(), counters(), attr(),
  the quotes) and the list markers (the ::marker content, else the
  list-style-type with its suffix). Counter styles are the predefined
  ones of CSS Counter Styles 3 that lists use.
}
unit Web.Layout.Counters;

{$mode objfpc}
{$H+}

interface

uses
  Web.Layout.Boxes, Css.Keywords;

{ Applies the counters and fills in the generated text of Root's tree. }
procedure ResolveGeneratedContent(Root: TLayoutBox);
{ A counter value in a counter style (decimal, lower-roman, disc ...). }
function FormatCounter(Value: Integer; Style: TCssKeyword): string;
{ The text of a list marker for a value and list-style-type. }
function MarkerText(Value: Integer; Style: TCssKeyword): string;

implementation

uses
  SysUtils, Web.Dom, Css.ComputedStyle, Css.ComputedValues, Css.Values, Css.PropertyIds;

type
  TCounterInstance = record
    Name: string;
    Value: Integer;
    Owner: TLayoutBox;
  end;

  TCounterState = record
    Counters: array of TCounterInstance;
    Count: Integer;
    QuoteDepth: Integer;
  end;

function ToRoman(Value: Integer; Upper: Boolean): string;
const
  Numbers: array[0..12] of Integer = (1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1);
  Letters: array[0..12] of string = ('m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i');
var
  Index: Integer;
begin
  Result := '';
  if (Value <= 0) or (Value >= 4000) then
    Exit(IntToStr(Value));
  for Index := 0 to 12 do
    while Value >= Numbers[Index] do
    begin
      Result := Result + Letters[Index];
      Dec(Value, Numbers[Index]);
    end;
  if Upper then
    Result := UpperCase(Result);
end;

function ToAlphabetic(Value: Integer; const Alphabet: array of string): string;
var
  Base: Integer;
begin
  Result := '';
  if Value <= 0 then
    Exit(IntToStr(Value));
  Base := Length(Alphabet);
  while Value > 0 do
  begin
    Dec(Value);
    Result := Alphabet[Value mod Base] + Result;
    Value := Value div Base;
  end;
end;

function FormatCounter(Value: Integer; Style: TCssKeyword): string;
const
  Latin: array[0..25] of string = ('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
    'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z');
  UpperLatin: array[0..25] of string = ('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N',
    'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z');
  Greek: array[0..23] of string = (#$CE#$B1, #$CE#$B2, #$CE#$B3, #$CE#$B4, #$CE#$B5, #$CE#$B6, #$CE#$B7,
    #$CE#$B8, #$CE#$B9, #$CE#$BA, #$CE#$BB, #$CE#$BC, #$CE#$BD, #$CE#$BE, #$CE#$BF, #$CF#$80, #$CF#$81,
    #$CF#$83, #$CF#$84, #$CF#$85, #$CF#$86, #$CF#$87, #$CF#$88, #$CF#$89);
begin
  case Style of
    kwNone: Result := '';
    kwDisc: Result := #$E2#$80#$A2;
    kwCircle: Result := #$E2#$97#$A6;
    kwSquare: Result := #$E2#$96#$AA;
    kwDisclosureOpen: Result := #$E2#$96#$BE;
    kwDisclosureClosed: Result := #$E2#$96#$B8;
    kwDecimalLeadingZero:
      if (Value >= 0) and (Value < 10) then
        Result := '0' + IntToStr(Value)
      else
        Result := IntToStr(Value);
    kwLowerRoman: Result := ToRoman(Value, False);
    kwUpperRoman: Result := ToRoman(Value, True);
    kwLowerAlpha, kwLowerLatin: Result := ToAlphabetic(Value, Latin);
    kwUpperAlpha, kwUpperLatin: Result := ToAlphabetic(Value, UpperLatin);
    kwLowerGreek: Result := ToAlphabetic(Value, Greek);
  else
    Result := IntToStr(Value);
  end;
end;

function MarkerText(Value: Integer; Style: TCssKeyword): string;
begin
  case Style of
    kwNone: Result := '';
    kwDisc, kwCircle, kwSquare, kwDisclosureOpen, kwDisclosureClosed:
      Result := FormatCounter(Value, Style) + ' ';
  else
    Result := FormatCounter(Value, Style) + '. ';
  end;
end;

function FindCounter(var State: TCounterState; const Name: string): Integer;
var
  Index: Integer;
begin
  Index := State.Count - 1;
  while Index >= 0 do
  begin
    if State.Counters[Index].Name = Name then
      Exit(Index);
    Dec(Index);
  end;
  Result := -1;
end;

procedure PushCounter(var State: TCounterState; const Name: string; Value: Integer; Owner: TLayoutBox);
begin
  if State.Count >= Length(State.Counters) then
    SetLength(State.Counters, State.Count * 2 + 8);
  State.Counters[State.Count].Name := Name;
  State.Counters[State.Count].Value := Value;
  State.Counters[State.Count].Owner := Owner;
  Inc(State.Count);
end;

procedure PopCounters(var State: TCounterState; Owner: TLayoutBox);
begin
  while (State.Count > 0) and (State.Counters[State.Count - 1].Owner = Owner) do
  begin
    State.Counters[State.Count - 1].Name := '';
    Dec(State.Count);
  end;
end;

{ Calls back for each (name, value) pair of a counter property. }
type
  TCounterAction = (caReset, caSet, caIncrement);

function CounterListMentions(List: PCssComputedValue; const Name: string): Boolean;
var
  Index: Integer;
  Item: TCssValue;
begin
  Result := False;
  if (List^.Kind <> cvValue) or (List^.Data = nil) then
    Exit;
  for Index := 0 to List^.Data.Count - 1 do
  begin
    Item := List^.Data.Items[Index];
    if (Item.Kind = vkList) and (Item.Count > 0) and (Item.Items[0].Text = Name) then
      Exit(True);
    if (Item.Kind = vkCustomIdent) and (Item.Text = Name) then
      Exit(True);
  end;
end;

procedure ApplyCounterProperty(var State: TCounterState; List: PCssComputedValue; Action: TCounterAction;
  Owner: TLayoutBox);
var
  Index, Found, Amount: Integer;
  Item: TCssValue;
  Name: string;
begin
  if (List^.Kind <> cvValue) or (List^.Data = nil) then
    Exit;
  for Index := 0 to List^.Data.Count - 1 do
  begin
    Item := List^.Data.Items[Index];
    if Item.Kind = vkList then
    begin
      if Item.Count = 0 then
        Continue;
      Name := Item.Items[0].Text;
      if Item.Count > 1 then
        Amount := Round(Item.Items[1].Number)
      else if Action = caIncrement then
        Amount := 1
      else
        Amount := 0;
    end
    else
    begin
      Name := Item.Text;
      if Action = caIncrement then
        Amount := 1
      else
        Amount := 0;
    end;
    if Name = '' then
      Continue;
    case Action of
      caReset:
        PushCounter(State, Name, Amount, Owner);
      caSet:
        begin
          Found := FindCounter(State, Name);
          if Found < 0 then
            PushCounter(State, Name, Amount, Owner)
          else
            State.Counters[Found].Value := Amount;
        end;
      caIncrement:
        begin
          Found := FindCounter(State, Name);
          if Found < 0 then
            PushCounter(State, Name, Amount, Owner)
          else
            Inc(State.Counters[Found].Value, Amount);
        end;
    end;
  end;
end;

procedure ApplyCounters(var State: TCounterState; Box: TLayoutBox; Style: TCssComputedStyle);
var
  Increment: PCssComputedValue;
  Found: Integer;
begin
  ApplyCounterProperty(State, Style.Value(cpCounterReset), caReset, Box.Parent);
  Increment := Style.Value(cpCounterIncrement);
  if (bfListItem in Box.Flags) and not CounterListMentions(Increment, 'list-item') then
  begin
    Found := FindCounter(State, 'list-item');
    if Found < 0 then
      PushCounter(State, 'list-item', 1, Box.Parent)
    else
      Inc(State.Counters[Found].Value);
  end;
  ApplyCounterProperty(State, Increment, caIncrement, Box.Parent);
  ApplyCounterProperty(State, Style.Value(cpCounterSet), caSet, Box.Parent);
end;

function CounterValue(var State: TCounterState; const Name: string; Owner: TLayoutBox): Integer;
var
  Found: Integer;
begin
  Found := FindCounter(State, Name);
  if Found < 0 then
  begin
    PushCounter(State, Name, 0, Owner);
    Exit(0);
  end;
  Result := State.Counters[Found].Value;
end;

function StyleKeywordOf(Value: TCssValue): TCssKeyword;
begin
  Result := kwDecimal;
  if (Value <> nil) and (Value.Kind = vkKeyword) then
    Result := Value.Keyword
  else if (Value <> nil) and (Value.Kind = vkCustomIdent) then
    Result := kwDecimal;
end;

function QuoteText(Style: TCssComputedStyle; Depth: Integer; Open: Boolean): string;
var
  Quotes: PCssComputedValue;
  Pairs, Index: Integer;
begin
  Quotes := Style.Value(cpQuotes);
  if (Quotes^.Kind = cvValue) and (Quotes^.Data <> nil) and (Quotes^.Data.Count >= 2) then
  begin
    Pairs := Quotes^.Data.Count div 2;
    Index := Depth;
    if Index >= Pairs then
      Index := Pairs - 1;
    if Open then
      Result := Quotes^.Data.Items[Index * 2].Text
    else
      Result := Quotes^.Data.Items[Index * 2 + 1].Text;
    Exit;
  end;
  if (Quotes^.Kind = cvKeyword) and (TCssKeyword(Quotes^.Keyword) = kwNone) then
    Exit('');
  if Depth = 0 then
  begin
    if Open then
      Result := #$E2#$80#$9C
    else
      Result := #$E2#$80#$9D;
  end
  else if Open then
    Result := #$E2#$80#$98
  else
    Result := #$E2#$80#$99;
end;

function ContentText(var State: TCounterState; Style: TCssComputedStyle; Element: TNode;
  Owner: TLayoutBox): string;
var
  Content: PCssComputedValue;
  Items: TCssValue;
  Index, Instance: Integer;
  Item: TCssValue;
  Name, Separator, Piece: string;
  CounterStyle: TCssKeyword;
begin
  Result := '';
  Content := Style.Value(cpContent);
  if (Content^.Kind <> cvValue) or (Content^.Data = nil) then
    Exit;
  Items := Content^.Data;
  { content: a / "alt": only the part before the slash. }
  if (Items.Kind = vkList) and (Items.Separator = lsSlash) and (Items.Count > 0) then
    Items := Items.Items[0];
  for Index := 0 to Items.Count - 1 do
  begin
    if Items.Kind = vkList then
      Item := Items.Items[Index]
    else
      Item := Items;
    case Item.Kind of
      vkString:
        Result := Result + Item.Text;
      vkKeyword:
        case Item.Keyword of
          kwOpenQuote:
            begin
              Result := Result + QuoteText(Style, State.QuoteDepth, True);
              Inc(State.QuoteDepth);
            end;
          kwCloseQuote:
            begin
              if State.QuoteDepth > 0 then
                Dec(State.QuoteDepth);
              Result := Result + QuoteText(Style, State.QuoteDepth, False);
            end;
          kwNoOpenQuote:
            Inc(State.QuoteDepth);
          kwNoCloseQuote:
            if State.QuoteDepth > 0 then
              Dec(State.QuoteDepth);
        end;
      vkFunction:
        if (Item.Text = 'counter') and (Item.Count >= 1) then
        begin
          CounterStyle := kwDecimal;
          if Item.Count >= 2 then
            CounterStyle := StyleKeywordOf(Item.Items[1]);
          Result := Result + FormatCounter(CounterValue(State, Item.Items[0].Text, Owner), CounterStyle);
        end
        else if (Item.Text = 'counters') and (Item.Count >= 2) then
        begin
          Name := Item.Items[0].Text;
          Separator := Item.Items[1].Text;
          CounterStyle := kwDecimal;
          if Item.Count >= 3 then
            CounterStyle := StyleKeywordOf(Item.Items[2]);
          Piece := '';
          for Instance := 0 to State.Count - 1 do
            if State.Counters[Instance].Name = Name then
            begin
              if Piece <> '' then
                Piece := Piece + Separator;
              Piece := Piece + FormatCounter(State.Counters[Instance].Value, CounterStyle);
            end;
          if Piece = '' then
            Piece := FormatCounter(CounterValue(State, Name, Owner), CounterStyle);
          Result := Result + Piece;
        end
        else if (Item.Text = 'attr') and (Item.Count >= 1) and (Element <> nil) and Element.IsElement then
          Result := Result + TElement(Element).GetAttribute(Item.Items[0].Text);
    end;
    if Items.Kind <> vkList then
      Break;
  end;
end;

function ListMarkerText(var State: TCounterState; Box: TLayoutBox): string;
var
  ListItem: TLayoutBox;
  TypeValue: PCssComputedValue;
  Content: PCssComputedValue;
begin
  Content := Box.Style.Value(cpContent);
  if Content^.Kind = cvValue then
    Exit(ContentText(State, Box.Style, Box.Node, Box.Parent));
  ListItem := Box.Parent;
  TypeValue := ListItem.Style.Value(cpListStyleType);
  if (TypeValue^.Kind = cvValue) and (TypeValue^.Data <> nil) and (TypeValue^.Data.Kind = vkString) then
    Exit(TypeValue^.Data.Text);
  Result := MarkerText(CounterValue(State, 'list-item', ListItem.Parent), ListItem.Style.Keyword(cpListStyleType));
end;

procedure SetGeneratedText(Box: TLayoutBox; const Text: string);
var
  Child: TLayoutBox;
begin
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    if (Child is TTextBox) and TTextBox(Child).IsGenerated then
    begin
      if TTextBox(Child).GeneratedText <> Text then
      begin
        TTextBox(Child).GeneratedText := Text;
        Child.MarkNeedsLayout;
      end;
      Exit;
    end;
    Child := Child.NextSibling;
  end;
end;

procedure WalkBox(var State: TCounterState; Box: TLayoutBox);
var
  Child: TLayoutBox;
  IsPrincipal: Boolean;
begin
  IsPrincipal := (Box.Node <> nil) and Box.Node.IsElement and
    ([bfBefore, bfAfter, bfMarker, bfAnonymous] * Box.Flags = []);
  if IsPrincipal then
    ApplyCounters(State, Box, Box.Style)
  else if ([bfBefore, bfAfter] * Box.Flags <> []) then
  begin
    ApplyCounters(State, Box, Box.Style);
    SetGeneratedText(Box, ContentText(State, Box.Style, Box.Node, Box.Parent));
  end
  else if bfMarker in Box.Flags then
    SetGeneratedText(Box, ListMarkerText(State, Box));
  Child := Box.FirstChild;
  while Child <> nil do
  begin
    WalkBox(State, Child);
    Child := Child.NextSibling;
  end;
  PopCounters(State, Box);
end;

procedure ResolveGeneratedContent(Root: TLayoutBox);
var
  State: TCounterState;
begin
  State.Counters := nil;
  State.Count := 0;
  State.QuoteDepth := 0;
  WalkBox(State, Root);
end;

end.
