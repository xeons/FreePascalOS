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
  Web.Html.TreeBuilder: the "in body" insertion mode.
}

procedure THtmlTreeBuilder.ModeInBody(var Token: TToken);
begin
  case Token.Kind of
    TokenCharacters:
      BodyCharacters(Token);
    TokenComment:
      InsertComment(Token.Data);
    TokenDoctype:
      ParseError('unexpected-doctype');
    TokenStartTag:
      BodyStartTag(Token);
    TokenEndTag:
      BodyEndTag(Token);
    TokenEndOfFile:
      BodyEndOfFile(Token);
  end;
end;

procedure THtmlTreeBuilder.BodyCharacters(var Token: TToken);
begin
  if Token.Data[1] = #0 then
  begin
    ParseError('unexpected-null-character');
    Exit;
  end;
  ReconstructFormatting;
  InsertCharacters(Token.Data);
  if not IsAllWhitespace(Token.Data) then
    FFramesetOk := False;
end;

procedure THtmlTreeBuilder.BodyEndOfFile(var Token: TToken);
var
  Index: Integer;
  Node: TElement;
begin
  if FTemplateModeCount > 0 then
  begin
    ModeInTemplate(Token);
    Exit;
  end;
  for Index := 0 to FOpenElements.Count - 1 do
  begin
    Node := FOpenElements[Index];
    if not (Node.IsHtml and IsOneOf(Node.LocalNameAtom, [AtomDd, AtomDt, AtomLi, AtomOptgroup, AtomOption, AtomP,
      AtomRb, AtomRp, AtomRt, AtomRtc, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr, AtomBody,
      AtomHtml])) then
    begin
      ParseError('expected-closing-tag-but-got-eof');
      Break;
    end;
  end;
  StopParsing;
end;

{ The "in body" start tags of li, dd and dt: close the open ones. }
procedure CloseListItems(Builder: THtmlTreeBuilder; const Names: array of TAtom);
var
  Index: Integer;
  Node: TElement;
begin
  Builder.FFramesetOk := False;
  Index := Builder.FOpenElements.Count - 1;
  while Index >= 0 do
  begin
    Node := Builder.FOpenElements[Index];
    if Node.IsHtml and IsOneOf(Node.LocalNameAtom, Names) then
    begin
      Builder.GenerateImpliedEndTags(Node.LocalNameAtom);
      if not Builder.CurrentNode.IsHtmlElement(Node.LocalNameAtom) then
        Builder.ParseError('unexpected-open-element');
      Builder.FOpenElements.PopUntilHtml(Node.LocalNameAtom);
      Break;
    end;
    if IsSpecialElement(Node) and not (Node.IsHtml and IsOneOf(Node.LocalNameAtom, [AtomAddress, AtomDiv, AtomP])) then
      Break;
    Dec(Index);
  end;
  Builder.CloseIfPInButtonScope;
end;

procedure THtmlTreeBuilder.BodyStartTag(var Token: TToken);
var
  Index: Integer;
  Element, Body: TElement;
  TypeValue: string;
begin
  case Token.TagName of
    AtomHtml:
      begin
        ParseError('unexpected-start-tag');
        if not FOpenElements.ContainsHtml(AtomTemplate) then
          CopyMissingAttributes(Token, FOpenElements[0]);
      end;
    AtomBase, AtomBasefont, AtomBgsound, AtomLink, AtomMeta, AtomNoframes, AtomScript, AtomStyle, AtomTemplate,
    AtomTitle:
      ModeInHead(Token);
    AtomBody:
      begin
        ParseError('unexpected-start-tag');
        if (FOpenElements.Count = 1) or not FOpenElements[1].IsHtmlElement(AtomBody) or
          FOpenElements.ContainsHtml(AtomTemplate) then
          Exit;
        FFramesetOk := False;
        CopyMissingAttributes(Token, FOpenElements[1]);
      end;
    AtomFrameset:
      begin
        ParseError('unexpected-start-tag');
        if (FOpenElements.Count = 1) or not FOpenElements[1].IsHtmlElement(AtomBody) or not FFramesetOk then
          Exit;
        Body := FOpenElements[1];
        if Body.ParentNode <> nil then
          Body.ParentNode.RemoveChild(Body);
        while FOpenElements.Count > 1 do
          FOpenElements.Pop;
        InsertHtmlElement(Token);
        FMode := ImInFrameset;
      end;
    AtomAddress, AtomArticle, AtomAside, AtomBlockquote, AtomCenter, AtomDetails, AtomDialog, AtomDir, AtomDiv,
    AtomDl, AtomFieldset, AtomFigcaption, AtomFigure, AtomFooter, AtomHeader, AtomHgroup, AtomMain, AtomMenu,
    AtomNav, AtomOl, AtomP, AtomSearch, AtomSection, AtomSummary, AtomUl:
      begin
        CloseIfPInButtonScope;
        InsertHtmlElement(Token);
      end;
    AtomH1, AtomH2, AtomH3, AtomH4, AtomH5, AtomH6:
      begin
        CloseIfPInButtonScope;
        if CurrentNode.IsHtml and IsHeadingName(CurrentNode.LocalNameAtom) then
        begin
          ParseError('unexpected-start-tag');
          FOpenElements.Pop;
        end;
        InsertHtmlElement(Token);
      end;
    AtomPre, AtomListing:
      begin
        CloseIfPInButtonScope;
        InsertHtmlElement(Token);
        FIgnoreNextLineFeed := True;
        FFramesetOk := False;
      end;
    AtomForm:
      begin
        if (FFormElement <> nil) and not FOpenElements.ContainsHtml(AtomTemplate) then
        begin
          ParseError('unexpected-start-tag');
          Exit;
        end;
        CloseIfPInButtonScope;
        Element := InsertHtmlElement(Token);
        if not FOpenElements.ContainsHtml(AtomTemplate) then
          FFormElement := Element;
      end;
    AtomLi:
      begin
        CloseListItems(Self, [AtomLi]);
        InsertHtmlElement(Token);
      end;
    AtomDd, AtomDt:
      begin
        CloseListItems(Self, [AtomDd, AtomDt]);
        InsertHtmlElement(Token);
      end;
    AtomPlaintext:
      begin
        CloseIfPInButtonScope;
        InsertHtmlElement(Token);
        FTokenizer.SwitchTo(TsPlainText);
      end;
    AtomButton:
      begin
        if FOpenElements.HasInScope(AtomButton, ScopeDefault) then
        begin
          ParseError('unexpected-start-tag');
          GenerateImpliedEndTags;
          FOpenElements.PopUntilHtml(AtomButton);
        end;
        ReconstructFormatting;
        InsertHtmlElement(Token);
        FFramesetOk := False;
      end;
    AtomA:
      begin
        Index := FFormatting.LastIndexAfterMarker(AtomA);
        if Index >= 0 then
        begin
          ParseError('unexpected-start-tag-implies-end-tag');
          Element := FFormatting[Index].Element;
          if not RunAdoptionAgency(Token) then
            AnyOtherEndTag(Token);
          FFormatting.Remove(Element);
          FOpenElements.Remove(Element);
        end;
        ReconstructFormatting;
        Element := InsertHtmlElement(Token);
        FFormatting.PushElement(Element, Token);
      end;
    AtomB, AtomBig, AtomCode, AtomEm, AtomFont, AtomI, AtomS, AtomSmall, AtomStrike, AtomStrong, AtomTt, AtomU:
      begin
        ReconstructFormatting;
        Element := InsertHtmlElement(Token);
        FFormatting.PushElement(Element, Token);
      end;
    AtomNobr:
      begin
        ReconstructFormatting;
        if FOpenElements.HasInScope(AtomNobr, ScopeDefault) then
        begin
          ParseError('unexpected-start-tag-implies-end-tag');
          if not RunAdoptionAgency(Token) then
            AnyOtherEndTag(Token);
          ReconstructFormatting;
        end;
        Element := InsertHtmlElement(Token);
        FFormatting.PushElement(Element, Token);
      end;
    AtomApplet, AtomMarquee, AtomObject:
      begin
        ReconstructFormatting;
        InsertHtmlElement(Token);
        FFormatting.PushMarker;
        FFramesetOk := False;
      end;
    AtomTable:
      begin
        if FDocument.Mode <> DocumentModeQuirks then
          CloseIfPInButtonScope;
        InsertHtmlElement(Token);
        FFramesetOk := False;
        FMode := ImInTable;
      end;
    AtomArea, AtomBr, AtomEmbed, AtomImg, AtomKeygen, AtomWbr:
      begin
        ReconstructFormatting;
        InsertHtmlElement(Token);
        FOpenElements.Pop;
        Token.SelfClosingAcknowledged := True;
        FFramesetOk := False;
      end;
    AtomInput:
      begin
        ReconstructFormatting;
        InsertHtmlElement(Token);
        FOpenElements.Pop;
        Token.SelfClosingAcknowledged := True;
        TypeValue := AsciiLowerCase(TokenAttributeValue(Token, AtomType));
        if not TokenHasAttribute(Token, AtomType) or (TypeValue <> 'hidden') then
          FFramesetOk := False;
      end;
    AtomParam, AtomSource, AtomTrack:
      begin
        InsertHtmlElement(Token);
        FOpenElements.Pop;
        Token.SelfClosingAcknowledged := True;
      end;
    AtomHr:
      begin
        CloseIfPInButtonScope;
        InsertHtmlElement(Token);
        FOpenElements.Pop;
        Token.SelfClosingAcknowledged := True;
        FFramesetOk := False;
      end;
    AtomImage:
      begin
        ParseError('unexpected-start-tag');
        Token.TagName := AtomImg;
        DispatchToken(Token);
      end;
    AtomTextarea:
      begin
        InsertHtmlElement(Token);
        FIgnoreNextLineFeed := True;
        FTokenizer.SwitchTo(TsRcdata);
        FOriginalMode := FMode;
        FFramesetOk := False;
        FMode := ImText;
      end;
    AtomXmp:
      begin
        CloseIfPInButtonScope;
        ReconstructFormatting;
        FFramesetOk := False;
        ParseRawText(Token, TsRawText);
      end;
    AtomIframe:
      begin
        FFramesetOk := False;
        ParseRawText(Token, TsRawText);
      end;
    AtomNoembed:
      ParseRawText(Token, TsRawText);
    AtomNoscript:
      if FScriptingEnabled then
        ParseRawText(Token, TsRawText)
      else
      begin
        ReconstructFormatting;
        InsertHtmlElement(Token);
      end;
    AtomSelect:
      begin
        ReconstructFormatting;
        InsertHtmlElement(Token);
        FFramesetOk := False;
        if FMode in [ImInTable, ImInCaption, ImInTableBody, ImInRow, ImInCell] then
          FMode := ImInSelectInTable
        else
          FMode := ImInSelect;
      end;
    AtomOptgroup, AtomOption:
      begin
        if CurrentNode.IsHtmlElement(AtomOption) then
          FOpenElements.Pop;
        ReconstructFormatting;
        InsertHtmlElement(Token);
      end;
    AtomRb, AtomRtc:
      begin
        if FOpenElements.HasInScope(AtomRuby, ScopeDefault) then
        begin
          GenerateImpliedEndTags;
          if not CurrentNode.IsHtmlElement(AtomRuby) then
            ParseError('unexpected-start-tag');
        end;
        InsertHtmlElement(Token);
      end;
    AtomRp, AtomRt:
      begin
        if FOpenElements.HasInScope(AtomRuby, ScopeDefault) then
        begin
          GenerateImpliedEndTags(AtomRtc);
          if not (CurrentNode.IsHtmlElement(AtomRtc) or CurrentNode.IsHtmlElement(AtomRuby)) then
            ParseError('unexpected-start-tag');
        end;
        InsertHtmlElement(Token);
      end;
    AtomMath:
      begin
        ReconstructFormatting;
        AdjustMathMlAttributes(Token);
        AdjustForeignAttributes(Token);
        InsertForeignElement(Token, NamespaceMathMl);
        if Token.SelfClosing then
        begin
          FOpenElements.Pop;
          Token.SelfClosingAcknowledged := True;
        end;
      end;
    AtomSvg:
      begin
        ReconstructFormatting;
        AdjustSvgAttributes(Token);
        AdjustForeignAttributes(Token);
        InsertForeignElement(Token, NamespaceSvg);
        if Token.SelfClosing then
        begin
          FOpenElements.Pop;
          Token.SelfClosingAcknowledged := True;
        end;
      end;
    AtomCaption, AtomCol, AtomColgroup, AtomFrame, AtomHead, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead,
    AtomTr:
      ParseError('unexpected-start-tag');
  else
    ReconstructFormatting;
    InsertHtmlElement(Token);
  end;
end;

procedure THtmlTreeBuilder.BodyEndTag(var Token: TToken);
var
  Node: TElement;
  Index: Integer;
  ImpliedToken: TToken;
begin
  case Token.TagName of
    AtomTemplate:
      ModeInHead(Token);
    AtomBody, AtomHtml:
      begin
        if not FOpenElements.HasInScope(AtomBody, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        for Index := 0 to FOpenElements.Count - 1 do
        begin
          Node := FOpenElements[Index];
          if not (Node.IsHtml and IsOneOf(Node.LocalNameAtom, [AtomDd, AtomDt, AtomLi, AtomOptgroup, AtomOption,
            AtomP, AtomRb, AtomRp, AtomRt, AtomRtc, AtomTbody, AtomTd, AtomTfoot, AtomTh, AtomThead, AtomTr,
            AtomBody, AtomHtml])) then
          begin
            ParseError('expected-one-end-tag-but-got-another');
            Break;
          end;
        end;
        FMode := ImAfterBody;
        if Token.TagName = AtomHtml then
          DispatchToken(Token);
      end;
    AtomAddress, AtomArticle, AtomAside, AtomBlockquote, AtomButton, AtomCenter, AtomDetails, AtomDialog, AtomDir,
    AtomDiv, AtomDl, AtomFieldset, AtomFigcaption, AtomFigure, AtomFooter, AtomHeader, AtomHgroup, AtomListing,
    AtomMain, AtomMenu, AtomNav, AtomOl, AtomPre, AtomSearch, AtomSection, AtomSummary, AtomUl:
      begin
        if not FOpenElements.HasInScope(Token.TagName, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags;
        if not CurrentNode.IsHtmlElement(Token.TagName) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHtml(Token.TagName);
      end;
    AtomForm:
      if not FOpenElements.ContainsHtml(AtomTemplate) then
      begin
        Node := FFormElement;
        FFormElement := nil;
        if (Node = nil) or not FOpenElements.HasElementInScope(Node, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags;
        if CurrentNode <> Node then
          ParseError('end-tag-too-early');
        FOpenElements.Remove(Node);
      end
      else
      begin
        if not FOpenElements.HasInScope(AtomForm, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags;
        if not CurrentNode.IsHtmlElement(AtomForm) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHtml(AtomForm);
      end;
    AtomP:
      begin
        if not FOpenElements.HasInScope(AtomP, ScopeButton) then
        begin
          ParseError('unexpected-end-tag');
          InsertHtmlElementNamed(AtomP);
        end;
        ClosePElement;
      end;
    AtomLi:
      begin
        if not FOpenElements.HasInScope(AtomLi, ScopeListItem) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags(AtomLi);
        if not CurrentNode.IsHtmlElement(AtomLi) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHtml(AtomLi);
      end;
    AtomDd, AtomDt:
      begin
        if not FOpenElements.HasInScope(Token.TagName, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags(Token.TagName);
        if not CurrentNode.IsHtmlElement(Token.TagName) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHtml(Token.TagName);
      end;
    AtomH1, AtomH2, AtomH3, AtomH4, AtomH5, AtomH6:
      begin
        if not FOpenElements.HasHeadingInScope then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags;
        if not CurrentNode.IsHtmlElement(Token.TagName) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHeading;
      end;
    AtomA, AtomB, AtomBig, AtomCode, AtomEm, AtomFont, AtomI, AtomNobr, AtomS, AtomSmall, AtomStrike, AtomStrong,
    AtomTt, AtomU:
      if not RunAdoptionAgency(Token) then
        AnyOtherEndTag(Token);
    AtomApplet, AtomMarquee, AtomObject:
      begin
        if not FOpenElements.HasInScope(Token.TagName, ScopeDefault) then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        GenerateImpliedEndTags;
        if not CurrentNode.IsHtmlElement(Token.TagName) then
          ParseError('end-tag-too-early');
        FOpenElements.PopUntilHtml(Token.TagName);
        FFormatting.ClearToLastMarker;
      end;
    AtomBr:
      begin
        ParseError('unexpected-end-tag');
        MakeTagToken(ImpliedToken, TokenStartTag, AtomBr);
        BodyStartTag(ImpliedToken);
      end;
  else
    AnyOtherEndTag(Token);
  end;
end;

procedure THtmlTreeBuilder.AnyOtherEndTag(var Token: TToken);
var
  Index: Integer;
  Node: TElement;
begin
  Index := FOpenElements.Count - 1;
  while Index >= 0 do
  begin
    Node := FOpenElements[Index];
    if Node.IsHtmlElement(Token.TagName) then
    begin
      GenerateImpliedEndTags(Token.TagName);
      if Node <> CurrentNode then
        ParseError('unexpected-end-tag');
      FOpenElements.PopUntilElement(Node);
      Exit;
    end;
    if IsSpecialElement(Node) then
    begin
      ParseError('unexpected-end-tag');
      Exit;
    end;
    Dec(Index);
  end;
end;
