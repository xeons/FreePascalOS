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
  Web.Html.TreeBuilder: the rules for parsing tokens in foreign content
  (inside svg and math).
}

{ The start tags that break out of foreign content back to HTML. }
function IsBreakoutStartTag(const Token: TToken): Boolean;
begin
  case Token.TagName of
    AtomB, AtomBig, AtomBlockquote, AtomBody, AtomBr, AtomCenter, AtomCode, AtomDd, AtomDiv, AtomDl, AtomDt, AtomEm,
    AtomEmbed, AtomH1, AtomH2, AtomH3, AtomH4, AtomH5, AtomH6, AtomHead, AtomHr, AtomI, AtomImg, AtomLi,
    AtomListing, AtomMenu, AtomMeta, AtomNobr, AtomOl, AtomP, AtomPre, AtomRuby, AtomS, AtomSmall, AtomSpan,
    AtomStrong, AtomStrike, AtomSub, AtomSup, AtomTable, AtomTt, AtomU, AtomUl, AtomVar:
      Result := True;
    AtomFont:
      Result := TokenHasAttribute(Token, AtomColor) or TokenHasAttribute(Token, AtomFace) or
        TokenHasAttribute(Token, AtomSize);
  else
    Result := False;
  end;
end;

procedure THtmlTreeBuilder.ProcessForeignContent(var Token: TToken);
var
  Node, Adjusted: TElement;
  Index: Integer;
  Namespace: TNamespaceId;
begin
  case Token.Kind of
    TokenCharacters:
      begin
        if Token.Data[1] = #0 then
        begin
          ParseError('unexpected-null-character');
          InsertCharacters(#$EF#$BF#$BD);
          Exit;
        end;
        InsertCharacters(Token.Data);
        if not IsAllWhitespace(Token.Data) then
          FFramesetOk := False;
      end;
    TokenComment:
      InsertComment(Token.Data);
    TokenDoctype:
      ParseError('unexpected-doctype');
    TokenStartTag:
      begin
        if IsBreakoutStartTag(Token) then
        begin
          ParseError('unexpected-html-element-in-foreign-content');
          while (FOpenElements.Count > 0) and not (IsMathMlTextIntegrationPoint(CurrentNode) or
            IsHtmlIntegrationPoint(CurrentNode) or CurrentNode.IsHtml) do
            FOpenElements.Pop;
          ProcessInMode(FMode, Token);
          Exit;
        end;
        Adjusted := AdjustedCurrentNode;
        if Adjusted.NamespaceAtom = AtomMathMlNamespace then
        begin
          AdjustMathMlAttributes(Token);
          Namespace := NamespaceMathMl;
        end
        else if Adjusted.NamespaceAtom = AtomSvgNamespace then
        begin
          Token.TagName := AdjustSvgTagName(Token.TagName);
          AdjustSvgAttributes(Token);
          Namespace := NamespaceSvg;
        end
        else
          Namespace := NamespaceIdOf(Adjusted.NamespaceAtom, AtomNone);
        AdjustForeignAttributes(Token);
        InsertForeignElement(Token, Namespace);
        if Token.SelfClosing then
        begin
          Token.SelfClosingAcknowledged := True;
          { An SVG script's end: the script host gets it (phase 2). }
          if (Token.TagName = AtomScript) and (Namespace = NamespaceSvg) then
          begin
            Node := CurrentNode;
            FOpenElements.Pop;
            if Assigned(FOnScriptEnd) then
              FOnScriptEnd(Node);
          end
          else
            FOpenElements.Pop;
        end;
      end;
    TokenEndTag:
      begin
        if (Token.TagName = AtomBr) or (Token.TagName = AtomP) then
        begin
          ParseError('unexpected-html-element-in-foreign-content');
          while (FOpenElements.Count > 0) and not (IsMathMlTextIntegrationPoint(CurrentNode) or
            IsHtmlIntegrationPoint(CurrentNode) or CurrentNode.IsHtml) do
            FOpenElements.Pop;
          ProcessInMode(FMode, Token);
          Exit;
        end;
        if (Token.TagName = AtomScript) and (CurrentNode.LocalNameAtom = AtomScript) and
          (CurrentNode.NamespaceAtom = AtomSvgNamespace) then
        begin
          Node := CurrentNode;
          FOpenElements.Pop;
          if Assigned(FOnScriptEnd) then
            FOnScriptEnd(Node);
          Exit;
        end;
        Index := FOpenElements.Count - 1;
        Node := FOpenElements[Index];
        if AsciiLowerCase(Node.LocalName) <> NameOfAtom(Token.TagName) then
          ParseError('unexpected-end-tag');
        while True do
        begin
          if Index = 0 then
            Exit;
          if AsciiLowerCase(Node.LocalName) = NameOfAtom(Token.TagName) then
          begin
            FOpenElements.PopUntilElement(Node);
            Exit;
          end;
          Dec(Index);
          Node := FOpenElements[Index];
          if Node.IsHtml then
            Break;
        end;
        ProcessInMode(FMode, Token);
      end;
    TokenEndOfFile:
      ProcessInMode(FMode, Token);
  end;
end;
