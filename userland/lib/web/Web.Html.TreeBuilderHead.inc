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
  Web.Html.TreeBuilder: the insertion modes up to the body: initial,
  before html, before head, in head, in head noscript, after head.
}

{ Splits a character run: the leading whitespace is handled by
  HandleWhitespace (when not nil), and True is returned with the rest
  in Token when something other than whitespace remains. }
type
  TWhitespaceHandler = procedure(const Text: string) of object;

function SplitWhitespace(var Token: TToken; HandleWhitespace: TWhitespaceHandler): Boolean;
var
  Count: SizeInt;
begin
  Count := LeadingWhitespace(Token.Data);
  if (Count > 0) and Assigned(HandleWhitespace) then
    HandleWhitespace(Copy(Token.Data, 1, Count));
  if Count = Length(Token.Data) then
    Exit(False);
  if Count > 0 then
    Delete(Token.Data, 1, Count);
  Result := True;
end;

procedure THtmlTreeBuilder.ModeInitial(var Token: TToken);
var
  Doctype: TDocumentType;
begin
  case Token.Kind of
    TokenCharacters:
      if not SplitWhitespace(Token, nil) then
        Exit;
    TokenComment:
      begin
        InsertComment(Token.Data, FDocument);
        Exit;
      end;
    TokenDoctype:
      begin
        if IsDoctypeParseError(Token) then
          ParseError('unexpected-doctype');
        Doctype := FDocument.NewDocumentType(Token.DoctypeName, Token.PublicId, Token.SystemId);
        FDocument.InsertNodeBefore(Doctype, nil);
        FDocument.Mode := DocumentModeForDoctype(Token);
        FMode := ImBeforeHtml;
        Exit;
      end;
  end;
  ParseError('expected-doctype');
  FDocument.Mode := DocumentModeQuirks;
  Reprocess(ImBeforeHtml, Token);
end;

procedure THtmlTreeBuilder.ModeBeforeHtml(var Token: TToken);
var
  Element: TElement;
begin
  case Token.Kind of
    TokenDoctype:
      begin
        ParseError('unexpected-doctype');
        Exit;
      end;
    TokenComment:
      begin
        InsertComment(Token.Data, FDocument);
        Exit;
      end;
    TokenCharacters:
      if not SplitWhitespace(Token, nil) then
        Exit;
    TokenStartTag:
      if Token.TagName = AtomHtml then
      begin
        Element := CreateElementForToken(Token, NamespaceHtml, FDocument);
        FDocument.InsertNodeBefore(Element, nil);
        FOpenElements.Push(Element);
        FMode := ImBeforeHead;
        Exit;
      end;
    TokenEndTag:
      if not IsOneOf(Token.TagName, [AtomHead, AtomBody, AtomHtml, AtomBr]) then
      begin
        ParseError('unexpected-end-tag');
        Exit;
      end;
  end;
  Element := FDocument.NewElement(AtomHtml, NamespaceHtml);
  FDocument.InsertNodeBefore(Element, nil);
  FOpenElements.Push(Element);
  Reprocess(ImBeforeHead, Token);
end;

procedure THtmlTreeBuilder.ModeBeforeHead(var Token: TToken);
begin
  case Token.Kind of
    TokenCharacters:
      if not SplitWhitespace(Token, nil) then
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
      begin
        if Token.TagName = AtomHtml then
        begin
          ModeInBody(Token);
          Exit;
        end;
        if Token.TagName = AtomHead then
        begin
          FHeadElement := InsertHtmlElement(Token);
          FMode := ImInHead;
          Exit;
        end;
      end;
    TokenEndTag:
      if not IsOneOf(Token.TagName, [AtomHead, AtomBody, AtomHtml, AtomBr]) then
      begin
        ParseError('unexpected-end-tag');
        Exit;
      end;
  end;
  FHeadElement := InsertHtmlElementNamed(AtomHead);
  Reprocess(ImInHead, Token);
end;

procedure THtmlTreeBuilder.ModeInHead(var Token: TToken);
var
  Parent, Before: TNode;
  Element: TElement;
  Charset, HttpEquiv: string;
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
        AtomBase, AtomBasefont, AtomBgsound, AtomLink:
          begin
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
            Exit;
          end;
        AtomMeta:
          begin
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
            if Assigned(FOnEncodingDeclared) then
            begin
              Charset := TokenAttributeValue(Token, AtomCharset);
              HttpEquiv := AsciiLowerCase(TokenAttributeValue(Token, AtomHttpEquiv));
              if TokenHasAttribute(Token, AtomCharset) then
                FOnEncodingDeclared(Charset, False)
              else if (HttpEquiv = 'content-type') and TokenHasAttribute(Token, AtomContent) then
                FOnEncodingDeclared(TokenAttributeValue(Token, AtomContent), True);
            end;
            Exit;
          end;
        AtomTitle:
          begin
            ParseRawText(Token, TsRcdata);
            Exit;
          end;
        AtomNoframes, AtomStyle:
          begin
            ParseRawText(Token, TsRawText);
            Exit;
          end;
        AtomNoscript:
          begin
            if FScriptingEnabled then
              ParseRawText(Token, TsRawText)
            else
            begin
              InsertHtmlElement(Token);
              FMode := ImInHeadNoscript;
            end;
            Exit;
          end;
        AtomScript:
          begin
            AppropriatePlace(nil, Parent, Before);
            Element := CreateElementForToken(Token, NamespaceHtml, Parent);
            if FContextElement <> nil then
              Element.ElementState := ElementStateParserInserted or ElementStateAlreadyStarted
            else
              Element.ElementState := ElementStateParserInserted;
            InsertAt(Element, Parent, Before);
            FOpenElements.Push(Element);
            FTokenizer.SwitchTo(TsScriptData);
            FOriginalMode := FMode;
            FMode := ImText;
            Exit;
          end;
        AtomTemplate:
          begin
            InsertHtmlElement(Token);
            FFormatting.PushMarker;
            FFramesetOk := False;
            FMode := ImInTemplate;
            PushTemplateMode(ImInTemplate);
            Exit;
          end;
        AtomHead:
          begin
            ParseError('unexpected-start-tag');
            Exit;
          end;
      end;
    TokenEndTag:
      case Token.TagName of
        AtomHead:
          begin
            FOpenElements.Pop;
            FMode := ImAfterHead;
            Exit;
          end;
        AtomBody, AtomHtml, AtomBr:
          ;
        AtomTemplate:
          begin
            if not FOpenElements.ContainsHtml(AtomTemplate) then
            begin
              ParseError('unexpected-end-tag');
              Exit;
            end;
            GenerateAllImpliedEndTagsThoroughly;
            if not CurrentNode.IsHtmlElement(AtomTemplate) then
              ParseError('unexpected-end-tag');
            FOpenElements.PopUntilHtml(AtomTemplate);
            FFormatting.ClearToLastMarker;
            PopTemplateMode;
            ResetInsertionMode;
            Exit;
          end;
      else
        ParseError('unexpected-end-tag');
        Exit;
      end;
  end;
  FOpenElements.Pop;
  Reprocess(ImAfterHead, Token);
end;

procedure THtmlTreeBuilder.ModeInHeadNoscript(var Token: TToken);
begin
  case Token.Kind of
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
        AtomBasefont, AtomBgsound, AtomLink, AtomMeta, AtomNoframes, AtomStyle:
          begin
            ModeInHead(Token);
            Exit;
          end;
        AtomHead, AtomNoscript:
          begin
            ParseError('unexpected-start-tag');
            Exit;
          end;
      end;
    TokenEndTag:
      if Token.TagName = AtomNoscript then
      begin
        FOpenElements.Pop;
        FMode := ImInHead;
        Exit;
      end
      else if Token.TagName <> AtomBr then
      begin
        ParseError('unexpected-end-tag');
        Exit;
      end;
    TokenCharacters:
      if not SplitWhitespace(Token, @InsertCharacters) then
        Exit;
    TokenComment:
      begin
        ModeInHead(Token);
        Exit;
      end;
  end;
  ParseError('unexpected-token-in-noscript');
  FOpenElements.Pop;
  Reprocess(ImInHead, Token);
end;

procedure THtmlTreeBuilder.ModeAfterHead(var Token: TToken);
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
        AtomBody:
          begin
            InsertHtmlElement(Token);
            FFramesetOk := False;
            FMode := ImInBody;
            Exit;
          end;
        AtomFrameset:
          begin
            InsertHtmlElement(Token);
            FMode := ImInFrameset;
            Exit;
          end;
        AtomBase, AtomBasefont, AtomBgsound, AtomLink, AtomMeta, AtomNoframes, AtomScript, AtomStyle,
        AtomTemplate, AtomTitle:
          begin
            ParseError('unexpected-start-tag');
            FOpenElements.Push(FHeadElement);
            ModeInHead(Token);
            FOpenElements.Remove(FHeadElement);
            Exit;
          end;
        AtomHead:
          begin
            ParseError('unexpected-start-tag');
            Exit;
          end;
      end;
    TokenEndTag:
      case Token.TagName of
        AtomTemplate:
          begin
            ModeInHead(Token);
            Exit;
          end;
        AtomBody, AtomHtml, AtomBr:
          ;
      else
        ParseError('unexpected-end-tag');
        Exit;
      end;
  end;
  InsertHtmlElementNamed(AtomBody);
  Reprocess(ImInBody, Token);
end;
