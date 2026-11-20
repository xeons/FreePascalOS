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
  Web.Html.TreeBuilder: tables. In table, in table text (foster
  parented text), in caption, in column group, in table body, in row,
  in cell.
}

procedure THtmlTreeBuilder.ClearStackBackToTableContext;
begin
  FOpenElements.PopUntilCurrentIsOneOf([AtomTable, AtomTemplate, AtomHtml]);
end;

procedure THtmlTreeBuilder.ClearStackBackToTableBodyContext;
begin
  FOpenElements.PopUntilCurrentIsOneOf([AtomTbody, AtomTfoot, AtomThead, AtomTemplate, AtomHtml]);
end;

procedure THtmlTreeBuilder.ClearStackBackToTableRowContext;
begin
  FOpenElements.PopUntilCurrentIsOneOf([AtomTr, AtomTemplate, AtomHtml]);
end;

procedure THtmlTreeBuilder.ProcessInTableAnythingElse(var Token: TToken);
begin
  ParseError('unexpected-token-in-table');
  FFosterParenting := True;
  try
    ModeInBody(Token);
  finally
    FFosterParenting := False;
  end;
end;

procedure THtmlTreeBuilder.ModeInTable(var Token: TToken);
var
  Node: TElement;
begin
  case Token.Kind of
    TokenCharacters:
      begin
        Node := CurrentNode;
        if Node.IsHtml and IsOneOf(Node.LocalNameAtom, [AtomTable, AtomTbody, AtomTemplate, AtomTfoot, AtomThead,
          AtomTr]) then
        begin
          FPendingTableCharacters.Clear;
          FOriginalMode := FMode;
          Reprocess(ImInTableText, Token);
          Exit;
        end;
      end;
    TokenComment:
      begin
        InsertComment(Token.Data);
        Exit;
      end;
    TokenDoctype:
      begin
        ParseError('unexpected-doctype');
        Exit;
      end;
    TokenStartTag:
      case Token.TagName of
        AtomCaption:
          begin
            ClearStackBackToTableContext;
            FFormatting.PushMarker;
            InsertHtmlElement(Token);
            FMode := ImInCaption;
            Exit;
          end;
        AtomColgroup:
          begin
            ClearStackBackToTableContext;
            InsertHtmlElement(Token);
            FMode := ImInColumnGroup;
            Exit;
          end;
        AtomCol:
          begin
            ClearStackBackToTableContext;
            InsertHtmlElementNamed(AtomColgroup);
            Reprocess(ImInColumnGroup, Token);
            Exit;
          end;
        AtomTbody, AtomTfoot, AtomThead:
          begin
            ClearStackBackToTableContext;
            InsertHtmlElement(Token);
            FMode := ImInTableBody;
            Exit;
          end;
        AtomTd, AtomTh, AtomTr:
          begin
            ClearStackBackToTableContext;
            InsertHtmlElementNamed(AtomTbody);
            Reprocess(ImInTableBody, Token);
            Exit;
          end;
        AtomTable:
          begin
            ParseError('unexpected-start-tag-implies-end-tag');
            if not FOpenElements.HasInScope(AtomTable, ScopeTable) then
              Exit;
            FOpenElements.PopUntilHtml(AtomTable);
            ResetInsertionMode;
            DispatchToken(Token);
            Exit;
          end;
        AtomStyle, AtomScript, AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
        AtomInput:
          if TokenHasAttribute(Token, AtomType) and
            (AsciiLowerCase(TokenAttributeValue(Token, AtomType)) = 'hidden') then
          begin
            ParseError('unexpected-hidden-input-in-table');
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
            Exit;
          end;
        AtomForm:
          begin
            ParseError('unexpected-form-in-table');
            if FOpenElements.ContainsHtml(AtomTemplate) or (FFormElement <> nil) then
              Exit;
            FFormElement := InsertHtmlElement(Token);
            FOpenElements.Pop;
            Exit;
          end;
      end;
    TokenEndTag:
      case Token.TagName of
        AtomTable:
          begin
            if not FOpenElements.HasInScope(AtomTable, ScopeTable) then
            begin
              ParseError('unexpected-end-tag');
              Exit;
            end;
            FOpenElements.PopUntilHtml(AtomTable);
            ResetInsertionMode;
            Exit;
          end;
        AtomBody, AtomCaption, AtomCol, AtomColgroup, AtomHtml, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead,
        AtomTr:
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
        AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
      end;
    TokenEndOfFile:
      begin
        ModeInBody(Token);
        Exit;
      end;
  end;
  ProcessInTableAnythingElse(Token);
end;

procedure THtmlTreeBuilder.ModeInTableText(var Token: TToken);
var
  Pending: TToken;
begin
  if Token.Kind = TokenCharacters then
  begin
    if Token.Data[1] = #0 then
      ParseError('unexpected-null-character')
    else
      FPendingTableCharacters.AppendString(Token.Data);
    Exit;
  end;
  if FPendingTableCharacters.Length > 0 then
  begin
    Pending := Default(TToken);
    Pending.Kind := TokenCharacters;
    Pending.Data := FPendingTableCharacters.TakeText;
    if not IsAllWhitespace(Pending.Data) then
      ProcessInTableAnythingElse(Pending)
    else
      InsertCharacters(Pending.Data);
  end;
  Reprocess(FOriginalMode, Token);
end;

procedure THtmlTreeBuilder.ModeInCaption(var Token: TToken);
begin
  if IsEndTag(Token, AtomCaption) or ((Token.Kind = TokenStartTag) and IsOneOf(Token.TagName, [AtomCaption,
    AtomCol, AtomColgroup, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr])) or IsEndTag(Token, AtomTable) then
  begin
    if not FOpenElements.HasInScope(AtomCaption, ScopeTable) then
    begin
      ParseError('unexpected-token-in-caption');
      Exit;
    end;
    GenerateImpliedEndTags;
    if not CurrentNode.IsHtmlElement(AtomCaption) then
      ParseError('end-tag-too-early');
    FOpenElements.PopUntilHtml(AtomCaption);
    FFormatting.ClearToLastMarker;
    FMode := ImInTable;
    if not IsEndTag(Token, AtomCaption) then
      DispatchToken(Token);
    Exit;
  end;
  if (Token.Kind = TokenEndTag) and IsOneOf(Token.TagName, [AtomBody, AtomCol, AtomColgroup, AtomHtml, AtomTbody,
    AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr]) then
  begin
    ParseError('unexpected-end-tag');
    Exit;
  end;
  ModeInBody(Token);
end;

procedure THtmlTreeBuilder.ModeInColumnGroup(var Token: TToken);
begin
  case Token.Kind of
    TokenCharacters:
      if not SplitWhitespace(Token, @InsertCharacters) then
        Exit;
    TokenComment:
      begin
        InsertComment(Token.Data);
        Exit;
      end;
    TokenDoctype:
      begin
        ParseError('unexpected-doctype');
        Exit;
      end;
    TokenStartTag:
      case Token.TagName of
        AtomHtml:
          begin
            ModeInBody(Token);
            Exit;
          end;
        AtomCol:
          begin
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
            Exit;
          end;
        AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
      end;
    TokenEndTag:
      case Token.TagName of
        AtomColgroup:
          begin
            if not CurrentNode.IsHtmlElement(AtomColgroup) then
            begin
              ParseError('unexpected-end-tag');
              Exit;
            end;
            FOpenElements.Pop;
            FMode := ImInTable;
            Exit;
          end;
        AtomCol:
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
        AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
      end;
    TokenEndOfFile:
      begin
        ModeInBody(Token);
        Exit;
      end;
  end;
  if not CurrentNode.IsHtmlElement(AtomColgroup) then
  begin
    ParseError('unexpected-token-in-column-group');
    { Only the first character is ignored (a template's column group):
      the rest of the run is taken afresh. }
    if Token.Kind = TokenCharacters then
    begin
      Delete(Token.Data, 1, FirstCharacterLength(Token.Data));
      if Token.Data <> '' then
        DispatchToken(Token);
    end;
    Exit;
  end;
  FOpenElements.Pop;
  Reprocess(ImInTable, Token);
end;

procedure THtmlTreeBuilder.ModeInTableBody(var Token: TToken);
begin
  if Token.Kind = TokenStartTag then
    case Token.TagName of
      AtomTr:
        begin
          ClearStackBackToTableBodyContext;
          InsertHtmlElement(Token);
          FMode := ImInRow;
          Exit;
        end;
      AtomTh, AtomTd:
        begin
          ParseError('unexpected-cell-in-table-body');
          ClearStackBackToTableBodyContext;
          InsertHtmlElementNamed(AtomTr);
          Reprocess(ImInRow, Token);
          Exit;
        end;
      AtomCaption, AtomCol, AtomColgroup, AtomTbody, AtomTfoot, AtomThead:
        begin
          if not (FOpenElements.HasInScope(AtomTbody, ScopeTable) or FOpenElements.HasInScope(AtomThead, ScopeTable) or
            FOpenElements.HasInScope(AtomTfoot, ScopeTable)) then
          begin
            ParseError('unexpected-start-tag');
            Exit;
          end;
          ClearStackBackToTableBodyContext;
          FOpenElements.Pop;
          Reprocess(ImInTable, Token);
          Exit;
        end;
    end
  else if Token.Kind = TokenEndTag then
    case Token.TagName of
      AtomTbody, AtomTfoot, AtomThead:
        begin
          if not FOpenElements.HasInScope(Token.TagName, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          ClearStackBackToTableBodyContext;
          FOpenElements.Pop;
          FMode := ImInTable;
          Exit;
        end;
      AtomTable:
        begin
          if not (FOpenElements.HasInScope(AtomTbody, ScopeTable) or FOpenElements.HasInScope(AtomThead, ScopeTable) or
            FOpenElements.HasInScope(AtomTfoot, ScopeTable)) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          ClearStackBackToTableBodyContext;
          FOpenElements.Pop;
          Reprocess(ImInTable, Token);
          Exit;
        end;
      AtomBody, AtomCaption, AtomCol, AtomColgroup, AtomHtml, AtomTd, AtomTh, AtomTr:
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
    end;
  ModeInTable(Token);
end;

procedure THtmlTreeBuilder.ModeInRow(var Token: TToken);
begin
  if Token.Kind = TokenStartTag then
    case Token.TagName of
      AtomTh, AtomTd:
        begin
          ClearStackBackToTableRowContext;
          InsertHtmlElement(Token);
          FMode := ImInCell;
          FFormatting.PushMarker;
          Exit;
        end;
      AtomCaption, AtomCol, AtomColgroup, AtomTbody, AtomTfoot, AtomThead, AtomTr:
        begin
          if not FOpenElements.HasInScope(AtomTr, ScopeTable) then
          begin
            ParseError('unexpected-start-tag');
            Exit;
          end;
          ClearStackBackToTableRowContext;
          FOpenElements.Pop;
          Reprocess(ImInTableBody, Token);
          Exit;
        end;
    end
  else if Token.Kind = TokenEndTag then
    case Token.TagName of
      AtomTr:
        begin
          if not FOpenElements.HasInScope(AtomTr, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          ClearStackBackToTableRowContext;
          FOpenElements.Pop;
          FMode := ImInTableBody;
          Exit;
        end;
      AtomTable:
        begin
          if not FOpenElements.HasInScope(AtomTr, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          ClearStackBackToTableRowContext;
          FOpenElements.Pop;
          Reprocess(ImInTableBody, Token);
          Exit;
        end;
      AtomTbody, AtomTfoot, AtomThead:
        begin
          if not FOpenElements.HasInScope(Token.TagName, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          if not FOpenElements.HasInScope(AtomTr, ScopeTable) then
            Exit;
          ClearStackBackToTableRowContext;
          FOpenElements.Pop;
          Reprocess(ImInTableBody, Token);
          Exit;
        end;
      AtomBody, AtomCaption, AtomCol, AtomColgroup, AtomHtml, AtomTd, AtomTh:
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
    end;
  ModeInTable(Token);
end;

procedure THtmlTreeBuilder.CloseCell;
begin
  GenerateImpliedEndTags;
  if not (CurrentNode.IsHtmlElement(AtomTd) or CurrentNode.IsHtmlElement(AtomTh)) then
    ParseError('unexpected-cell-end');
  while FOpenElements.Count > 0 do
  begin
    if FOpenElements.Current.IsHtmlElement(AtomTd) or FOpenElements.Current.IsHtmlElement(AtomTh) then
    begin
      FOpenElements.Pop;
      Break;
    end;
    FOpenElements.Pop;
  end;
  FFormatting.ClearToLastMarker;
  FMode := ImInRow;
end;

procedure THtmlTreeBuilder.ModeInCell(var Token: TToken);
begin
  if Token.Kind = TokenEndTag then
    case Token.TagName of
      AtomTd, AtomTh:
        begin
          if not FOpenElements.HasInScope(Token.TagName, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          GenerateImpliedEndTags;
          if not CurrentNode.IsHtmlElement(Token.TagName) then
            ParseError('end-tag-too-early');
          FOpenElements.PopUntilHtml(Token.TagName);
          FFormatting.ClearToLastMarker;
          FMode := ImInRow;
          Exit;
        end;
      AtomBody, AtomCaption, AtomCol, AtomColgroup, AtomHtml:
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
      AtomTable, AtomTbody, AtomTfoot, AtomThead, AtomTr:
        begin
          if not FOpenElements.HasInScope(Token.TagName, ScopeTable) then
          begin
            ParseError('unexpected-end-tag');
            Exit;
          end;
          CloseCell;
          DispatchToken(Token);
          Exit;
        end;
    end
  else if (Token.Kind = TokenStartTag) and IsOneOf(Token.TagName, [AtomCaption, AtomCol, AtomColgroup, AtomTbody,
    AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr]) then
  begin
    if not (FOpenElements.HasInScope(AtomTd, ScopeTable) or FOpenElements.HasInScope(AtomTh, ScopeTable)) then
    begin
      ParseError('unexpected-start-tag');
      Exit;
    end;
    CloseCell;
    DispatchToken(Token);
    Exit;
  end;
  ModeInBody(Token);
end;
