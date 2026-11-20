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
  Web.Html.TreeBuilder: in select, in select in table, in template.
}

procedure THtmlTreeBuilder.ModeInSelect(var Token: TToken);
begin
  case Token.Kind of
    TokenCharacters:
      begin
        if Token.Data[1] = #0 then
          ParseError('unexpected-null-character')
        else
          InsertCharacters(Token.Data);
        Exit;
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
        AtomHtml:
          begin
            ModeInBody(Token);
            Exit;
          end;
        AtomOption:
          begin
            if CurrentNode.IsHtmlElement(AtomOption) then
              FOpenElements.Pop;
            InsertHtmlElement(Token);
            Exit;
          end;
        AtomOptgroup:
          begin
            if CurrentNode.IsHtmlElement(AtomOption) then
              FOpenElements.Pop;
            if CurrentNode.IsHtmlElement(AtomOptgroup) then
              FOpenElements.Pop;
            InsertHtmlElement(Token);
            Exit;
          end;
        AtomHr:
          begin
            if CurrentNode.IsHtmlElement(AtomOption) then
              FOpenElements.Pop;
            if CurrentNode.IsHtmlElement(AtomOptgroup) then
              FOpenElements.Pop;
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
            Exit;
          end;
        AtomSelect:
          begin
            ParseError('unexpected-select-in-select');
            if not FOpenElements.HasInScope(AtomSelect, ScopeSelect) then
              Exit;
            FOpenElements.PopUntilHtml(AtomSelect);
            ResetInsertionMode;
            Exit;
          end;
        AtomInput, AtomKeygen, AtomTextarea:
          begin
            ParseError('unexpected-input-in-select');
            if not FOpenElements.HasInScope(AtomSelect, ScopeSelect) then
              Exit;
            FOpenElements.PopUntilHtml(AtomSelect);
            ResetInsertionMode;
            DispatchToken(Token);
            Exit;
          end;
        AtomScript, AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
      end;
    TokenEndTag:
      case Token.TagName of
        AtomOptgroup:
          begin
            if CurrentNode.IsHtmlElement(AtomOption) and (FOpenElements.Count >= 2) and
              FOpenElements[FOpenElements.Count - 2].IsHtmlElement(AtomOptgroup) then
              FOpenElements.Pop;
            if CurrentNode.IsHtmlElement(AtomOptgroup) then
              FOpenElements.Pop
            else
              ParseError('unexpected-end-tag');
            Exit;
          end;
        AtomOption:
          begin
            if CurrentNode.IsHtmlElement(AtomOption) then
              FOpenElements.Pop
            else
              ParseError('unexpected-end-tag');
            Exit;
          end;
        AtomSelect:
          begin
            if not FOpenElements.HasInScope(AtomSelect, ScopeSelect) then
            begin
              ParseError('unexpected-end-tag');
              Exit;
            end;
            FOpenElements.PopUntilHtml(AtomSelect);
            ResetInsertionMode;
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
  ParseError('unexpected-token-in-select');
end;

procedure THtmlTreeBuilder.ModeInSelectInTable(var Token: TToken);
const
  TableNames: array[0..7] of TAtom = (AtomCaption, AtomTable, AtomTbody, AtomTfoot, AtomThead, AtomTr, AtomTd,
    AtomTh);
begin
  if (Token.Kind = TokenStartTag) and IsOneOf(Token.TagName, TableNames) then
  begin
    ParseError('unexpected-table-element-in-select');
    FOpenElements.PopUntilHtml(AtomSelect);
    ResetInsertionMode;
    DispatchToken(Token);
    Exit;
  end;
  if (Token.Kind = TokenEndTag) and IsOneOf(Token.TagName, TableNames) then
  begin
    ParseError('unexpected-table-element-in-select');
    if not FOpenElements.HasInScope(Token.TagName, ScopeTable) then
      Exit;
    FOpenElements.PopUntilHtml(AtomSelect);
    ResetInsertionMode;
    DispatchToken(Token);
    Exit;
  end;
  ModeInSelect(Token);
end;

procedure THtmlTreeBuilder.ModeInTemplate(var Token: TToken);

  procedure SwitchTemplateMode(NewMode: TInsertionMode);
  begin
    PopTemplateMode;
    PushTemplateMode(NewMode);
    Reprocess(NewMode, Token);
  end;

begin
  case Token.Kind of
    TokenCharacters, TokenComment, TokenDoctype:
      ModeInBody(Token);
    TokenStartTag:
      case Token.TagName of
        AtomBase, AtomBasefont, AtomBgsound, AtomLink, AtomMeta, AtomNoframes, AtomScript, AtomStyle, AtomTemplate,
        AtomTitle:
          ModeInHead(Token);
        AtomCaption, AtomColgroup, AtomTbody, AtomTfoot, AtomThead:
          SwitchTemplateMode(ImInTable);
        AtomCol:
          SwitchTemplateMode(ImInColumnGroup);
        AtomTr:
          SwitchTemplateMode(ImInTableBody);
        AtomTd, AtomTh:
          SwitchTemplateMode(ImInRow);
      else
        SwitchTemplateMode(ImInBody);
      end;
    TokenEndTag:
      if Token.TagName = AtomTemplate then
        ModeInHead(Token)
      else
        ParseError('unexpected-end-tag');
    TokenEndOfFile:
      begin
        if not FOpenElements.ContainsHtml(AtomTemplate) then
        begin
          StopParsing;
          Exit;
        end;
        ParseError('eof-in-template');
        FOpenElements.PopUntilHtml(AtomTemplate);
        FFormatting.ClearToLastMarker;
        PopTemplateMode;
        ResetInsertionMode;
        DispatchToken(Token);
      end;
  end;
end;
